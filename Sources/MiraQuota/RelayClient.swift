import Foundation

/// 通道事件。区分「连不上」与「连上了但帧看不懂」，两者的处置方式不同：
/// 前者退到本地推算并持续重连，后者说明 Mirasim 可能改了协议，需要提示。
enum RelayEvent: Sendable {
    case snapshot(RelaySnapshot)
    case unreachable(String)
    case mismatch(String)
}

/// Mirasim 本地通道客户端。
///
/// 额度百分比不落盘，只在 Mirasim 进程内。它的 mirachannel WebSocket 对本机连接
/// 放行读操作，`{type:"host", payload:{type:"getRelay"}}` 帧回传 relay 状态，
/// 其中 `usage.windows` 即界面上那两个百分比，`history` 是百分比环形缓冲。
///
/// 解析刻意宽松：键名按候选列表逐个尝试，数值接受 Double/Int/String，
/// 常规路径落空时在帧内做一次有界深搜。Mirasim 小幅调整字段命名不会导致失效。
final class RelayClient {
    private let queue = DispatchQueue(label: "miraquota.relay")
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var pollTimer: DispatchSourceTimer?
    private var reconnectDelay: TimeInterval = 1
    /// 只在 relay 队列上写；跨队列读经 `portLock`，不再 queue.sync——
    /// 端口发现期间队列会被 ps 与逐口探测占住数秒，同步读会把引擎心跳一起拖住。
    private var port: Int
    private let portLock = NSLock()
    private var stopped = false
    private var consecutiveFailures = 0
    /// 连接存活但持续收不到可解析额度帧的轮询计数，用于上报静默的协议变化。
    private var pollsSinceSnapshot = 0
    private var silentMismatchSent = false

    var onEvent: ((RelayEvent) -> Void)?

    /// 当前实际连接的端口。用于把 `/v1/limits` 的探测限定在同一个 Mirasim 实例上：
    /// 同时跑着开发实例时，别的实例可能登着另一个账号，端口枚举会读到错的额度。
    var currentPort: Int {
        portLock.lock(); defer { portLock.unlock() }
        return port
    }

    init(port: Int? = nil) {
        self.port = port ?? 4970
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
    }

    func start() {
        queue.async { [weak self] in self?.attach() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.pollTimer?.cancel(); self.pollTimer = nil
            self.task?.cancel(with: .goingAway, reason: nil); self.task = nil
        }
    }

    /// 立刻要一次新数据，`fresh` 会让 Mirasim 绕过它自己的缓存重新问 relay。
    func poll(fresh: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.task == nil { self.attach() } else { self.send(["type": "getRelay"], fresh: fresh) }
        }
    }

    // MARK: 连接

    /// 先确认端口可达再建 WebSocket。Mirasim 未运行时不做无谓的连接尝试。
    private func attach() {
        guard !stopped else { return }
        // 已有连接就不再建：退避期内用户开面板会经 poll() 立刻 attach，
        // 之前调度的延时 attach 随后到达，不挡住会叠出第二条连接且旧的永不取消。
        guard task == nil else { return }
        if Diag.forceOffline {
            consecutiveFailures += 1
            onEvent?(.unreachable("MIRAQUOTA_OFFLINE=1 强制离线"))
            scheduleReconnect()
            return
        }
        guard let found = Self.discoverPort(preferred: port, wide: consecutiveFailures >= 3) else {
            consecutiveFailures += 1
            onEvent?(.unreachable("未找到正在运行的 Mirasim"))
            scheduleReconnect()
            return
        }
        portLock.lock(); port = found; portLock.unlock()
        connect()
    }

    private func connect() {
        guard !stopped, let url = URL(string: "ws://127.0.0.1:\(port)/mirachannel/ws") else { return }
        let t = session.webSocketTask(with: url)
        task = t
        pollsSinceSnapshot = 0
        t.resume()
        send(["type": "hello", "v": 1, "client": ["name": "miraquota", "platform": "macos"]], raw: true)
        send(["type": "getRelay"])
        listen()
        startPolling()
    }

    private func startPolling() {
        pollTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 20, repeating: 20)
        t.setEventHandler { [weak self] in
            guard let self, self.task != nil else { return }
            self.send(["type": "ping", "t": Date().timeIntervalSince1970], raw: true)
            self.send(["type": "getRelay"])
            // 连接活着、要了数据却一直解析不出快照——多半是帧类型或键名整体改了名，
            // 连子串预筛都不再命中。不上报会静默滑向「已过期 → 推算」，界面看不出原因。
            self.pollsSinceSnapshot += 1
            if self.pollsSinceSnapshot >= 3, !self.silentMismatchSent {
                self.silentMismatchSent = true
                self.onEvent?(.mismatch("连接正常但持续收不到可解析的额度帧"))
            }
        }
        t.resume()
        pollTimer = t
    }

    private func send(_ payload: [String: Any], fresh: Bool = false, raw: Bool = false) {
        var body = payload
        if fresh { body["fresh"] = true }
        let frame: [String: Any] = raw ? body : ["type": "host", "payload": body]
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func listen() {
        guard let t = task else { return }
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                // 身份守卫须盖住两个分支：陈旧任务的成功回调会把接收环二次挂到
                // 当前任务上（一条连接两个环，此后每次失败双倍退避、双发不可达），
                // 失败回调则会替新任务多触发一次重连。每个任务同时只挂一个 receive，
                // 串行队列上它先于任何置 nil 路径执行，当前任务不会被误吞。
                guard self.task === t else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let s): self.handle(s)
                    case .data(let d): if let s = String(data: d, encoding: .utf8) { self.handle(s) }
                    @unknown default: break
                    }
                    self.listen()
                case .failure(let error):
                    self.consecutiveFailures += 1
                    self.onEvent?(.unreachable("与 Mirasim 的连接中断：\(error.localizedDescription)"))
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        pollTimer?.cancel(); pollTimer = nil
        task = nil
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.attach() }
    }

    // MARK: 解析

    private func handle(_ text: String) {
        Diag.log("recv \(text.count)B \(text.prefix(80))")
        guard text.contains("\"relay\"") || text.contains("\"usage\"") else { return }
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // 常规路径：host → payload(type=relay) → relay。失败则退到深搜。
        let payload = root["payload"] as? [String: Any]
        let relay = (payload?["relay"] as? [String: Any])
            ?? (root["relay"] as? [String: Any])
            ?? payload
            ?? root

        let usage = (relay["usage"] as? [String: Any]) ?? relay
        var rawWindows = usage["windows"] as? [[String: Any]]
        if rawWindows == nil || rawWindows!.isEmpty {
            rawWindows = Self.deepFindWindows(root)
        }
        guard let rawWindows, !rawWindows.isEmpty else {
            // 只有明确表示自己是 relay 帧却解不出窗口时才判为协议不符，
            // 避免把心跳、事件推送等无关帧误报成故障。
            if (payload?["type"] as? String) == "relay" {
                onEvent?(.mismatch("帧内无可识别的额度窗口"))
            }
            return
        }

        var parsed: [(label: String, used: Double, remaining: Double?, reset: Date,
                      scoped: Bool)] = []
        for raw in rawWindows {
            guard let label = Self.pick(raw, ["label", "name", "window", "id"]) as? String,
                  let used = Self.number(Self.pick(raw, ["usedPercent", "utilization", "percent",
                                                         "used", "usage"])),
                  let reset = Self.date(Self.pick(raw, ["resetAt", "resetsAt", "reset", "expiresAt"]))
            else { continue }
            let remaining = Self.number(Self.pick(raw, ["remainingPercent", "remaining_percent",
                                                        "remaining"]))
            let scoped = (Self.pick(raw, ["modelScoped", "model_scoped"]) as? Bool) ?? false
            parsed.append((label, used, remaining, reset, scoped))
        }

        var rawHistory: [(at: Date, five: Double?, seven: Double?)] = []
        for raw in (relay["history"] as? [[String: Any]]) ?? [] {
            guard let at = Self.date(Self.pick(raw, ["at", "t", "time"])) else { continue }
            rawHistory.append((at,
                               Self.number(Self.pick(raw, ["fiveHour", "five_hour", "5h"])),
                               Self.number(Self.pick(raw, ["sevenDay", "seven_day", "7d"]))))
        }

        // 刻度推断。真实协议以百分数为单位，个别实现用 0–1 小数；逐值判断
        // 区分不了「真实的 0.4%」与「小数的 0.4」——重置后的窗口恰好常落在 (0,1]。
        //
        // 首选证据是「已用 + 剩余」之和：百分数刻度下恒为 100，小数刻度下恒为 1，
        // 与用量高低无关。量级判据只在缺 remaining 字段时启用，且它在低用量期会判错：
        // 7d 窗口重置后整帧连同 history 都落在 (0,1]，一律 ×100 会把 0.9% 画成 90%
        // 并把同样放大的样本写进标定。
        let totals = parsed.compactMap { w in w.remaining.map { w.used + $0 } }
            .filter { $0 > 0.5 }
        let fractional: Bool
        if let total = totals.max() {
            fractional = total < 50
        } else {
            // 刚重置时 history 环形缓冲仍可能留着重置前 >1 的旧值，据此仍可判对。
            let magnitudes = parsed.map(\.used)
                + rawHistory.flatMap { [$0.five, $0.seven].compactMap { $0 } }
            fractional = magnitudes.contains { $0 > 0 } && magnitudes.allSatisfy { $0 <= 1.0 }
        }
        let scale = fractional ? 100.0 : 1.0

        var windows: [QuotaWindow] = []
        for w in parsed {
            let percent = w.used * scale
            // 值域闸门：归一化后仍不在 0–100 的不是百分比，宁可判协议不符也不显示。
            guard percent >= 0, percent <= 100.5 else { continue }
            windows.append(QuotaWindow(label: w.label, usedPercent: percent, resetAt: w.reset,
                                       modelScoped: w.scoped))
        }
        guard !windows.isEmpty else {
            onEvent?(.mismatch("窗口缺少标签、百分比或重置时刻，或取值不在 0–100"))
            return
        }

        reconnectDelay = 1
        consecutiveFailures = 0
        pollsSinceSnapshot = 0
        silentMismatchSent = false

        // history 与窗口共用同一刻度，越界分量弃掉，别让坏点混进标定种子。
        let bounded: (Double?) -> Double? = { v in
            v.map { $0 * scale }.flatMap { $0 >= 0 && $0 <= 100.5 ? $0 : nil }
        }
        var history: [RelaySnapshot.HistoryPoint] = []
        for h in rawHistory {
            history.append(RelaySnapshot.HistoryPoint(
                at: h.at, fiveHour: bounded(h.five), sevenDay: bounded(h.seven)))
        }

        let captured = Self.date(Self.pick(usage, ["capturedAt", "at", "updatedAt"])) ?? Date()

        onEvent?(.snapshot(RelaySnapshot(
            windows: windows,
            capturedAt: captured,
            host: (relay["host"] as? String) ?? "-",
            mode: (relay["mode"] as? String) ?? "-",
            relayStatus: (relay["relayStatus"] as? String) ?? (relay["status"] as? String) ?? "-",
            history: history,
            accountTag: Self.accountTag(relay),
            plan: Self.plan(relay)
        )))
    }

    /// 账号身份判据，只认 `login.userId`。缺该字段时返回 nil 而非退到令牌尾号：
    /// 尾号随令牌每小时轮换，拿它当判据会把轮换判成换账号。实测部分帧不带 login，
    /// 有退路时状态会在两个命名空间之间来回切，尾号一换就误记一次切换时刻
    /// （落盘 01:02:56，上一枚令牌的 `exp` 为 00:58:46），把样本下界抬到当下，
    /// 账本里 1450 行可用记录被挡在门外。判不出账号即不动状态，由自检报出。
    private static func accountTag(_ relay: [String: Any]) -> String? {
        guard let login = relay["login"] as? [String: Any],
              let id = pick(login, ["userId", "user_id", "id"]) as? String, !id.isEmpty
        else { return nil }
        return AccountTag.user(id)
    }

    /// 套餐标识。`login.plan` 是当前生效的档位，`referral.currentPlan` 为同义退路。
    private static func plan(_ relay: [String: Any]) -> String? {
        let login = relay["login"] as? [String: Any]
        let referral = relay["referral"] as? [String: Any]
        let value = (login.flatMap { pick($0, ["plan", "tier"]) } ?? referral.flatMap {
            pick($0, ["currentPlan", "current_plan", "plan"])
        }) as? String
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func pick(_ dict: [String: Any], _ keys: [String]) -> Any? {
        for k in keys { if let v = dict[k], !(v is NSNull) { return v } }
        return nil
    }

    private static func number(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private static func date(_ any: Any?) -> Date? {
        if let s = any as? String {
            if let e = fastEpochSeconds(s) { return Date(timeIntervalSince1970: Double(e)) }
            if let n = Double(s) { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
            return nil
        }
        guard let n = number(any), n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
    }

    /// 有界深搜：在帧内找形如「含标签且含百分比」的字典数组。
    /// 用于 Mirasim 调整了嵌套层级时仍能取到数据。
    private static func deepFindWindows(_ node: Any, depth: Int = 0) -> [[String: Any]]? {
        guard depth < 6 else { return nil }
        if let array = node as? [[String: Any]] {
            // 只看键名会先锁定帧内碰巧同形的无关数组（点数余额、账号列表——
            // used 是几千点而非百分比），随后原样上屏。数值像百分比、
            // 重置像将来的时刻，才算找到了窗口。
            let now = Date()
            let looksRight = array.contains { d in
                guard pick(d, ["label", "name", "window"]) is String,
                      let used = number(pick(d, ["usedPercent", "utilization", "percent", "used"])),
                      used >= 0, used <= 100.5,
                      let reset = date(pick(d, ["resetAt", "resetsAt", "reset", "expiresAt"]))
                else { return false }
                return reset > now.addingTimeInterval(-86400)
                    && reset < now.addingTimeInterval(35 * 86400)
            }
            if looksRight { return array }
        }
        if let dict = node as? [String: Any] {
            for key in dict.keys.sorted() {
                if let found = deepFindWindows(dict[key]!, depth: depth + 1) { return found }
            }
        } else if let array = node as? [Any] {
            for item in array {
                if let found = deepFindWindows(item, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    // MARK: 端口发现

    /// 依次尝试：偏好端口 → 默认 4970 → 从进程命令行解析。
    /// `wide` 在连续失败后打开，额外扫一段邻近端口，覆盖 Mirasim 改端口的情况。
    static func discoverPort(preferred: Int, wide: Bool = false) -> Int? {
        var candidates = [preferred, 4970]
        candidates.append(contentsOf: portsFromProcessList())
        if wide { candidates.append(contentsOf: 4970...4980) }
        var seen = Set<Int>()
        for p in candidates where seen.insert(p).inserted {
            if probe(port: p) { return p }
        }
        return nil
    }

    static func probe(port: Int) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        var ok = false
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                ok = (root["name"] as? String) == "mirasim"
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        return ok
    }

    static func portsFromProcessList() -> [Int] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "command"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var out: [Int] = []
        for line in text.split(separator: "\n") where line.contains("server.cjs") && line.contains("--port") {
            let parts = line.split(separator: " ")
            if let i = parts.firstIndex(of: "--port"), i + 1 < parts.count,
               let n = Int(parts[i + 1]) { out.append(n) }
        }
        return out
    }
}
