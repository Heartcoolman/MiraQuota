import Foundation

/// 额度的原始值：已用与总额，单位是 Mirasim 自己的额度点。
struct LimitsSnapshot: Sendable {
    struct Window: Sendable {
        let label: String
        let used: Double
        let budget: Double
        let resetAt: Date
        /// 该窗口是否只计特定模型档位的用量（实测 `7d_fable`）。
        /// 这类窗口的等价支出须按同一档位过滤，否则会挂上全机支出。
        var modelScoped: Bool = false

        var usedPercent: Double { budget > 0 ? min(100, used / budget * 100) : 0 }
        /// 模型档位组名，取窗口名下划线之后的部分。非 modelScoped 窗口为 nil。
        var modelGroup: String? { modelScoped ? QuotaWindow.modelGroup(of: label) : nil }
        var quotaWindow: QuotaWindow {
            QuotaWindow(label: label, usedPercent: usedPercent, resetAt: resetAt,
                        modelScoped: modelScoped)
        }
    }

    let windows: [Window]
    let capturedAt: Date
    let suspended: Bool
    let unmetered: Bool
    let degraded: Bool
    /// 是否付费账号。内测账号为 false，额度按官方口径减半（见 `PlanRate`）；
    /// 旧版端点不带该字段时为 nil，美元折算退回账本标定。
    let paid: Bool?

    func window(_ label: String) -> Window? {
        windows.first { $0.label.caseInsensitiveCompare(label) == .orderedSame }
    }

    /// 账号状态异常时的一句话说明，正常则为 nil。
    var notice: String? {
        if suspended { return "账号被暂停，额度数字仅供参考" }
        if unmetered { return "账号不计量，额度上限不适用" }
        if degraded { return "上游降级运行中" }
        return nil
    }
}

/// 会话在路由端口上的入口。取自 Mirasim 拉起的会话进程环境：`ANTHROPIC_BASE_URL`
/// 自 0.0.273 起带一段随机路径前缀，闸门按前缀放行、不再看令牌；0.0.235–0.0.272
/// 则按 `x-api-key` 校验裸路径。两样都带上，哪一版都能过。
struct SessionRoute: Sendable {
    /// 不带尾斜杠的 base URL，`/v1/limits` 直接拼在后面。
    let baseURL: String
    let token: String?
}

/// `/v1/limits` 客户端。
///
/// Mirasim 分给每个会话的回环端口（Claude Code 的 `ANTHROPIC_BASE_URL`）上挂着一个路由，
/// `GET <base>/v1/limits` 回传 `windows[].{name, used, budget, reset_at}`。
/// `used` 带小数位，优于 relay 帧的 0.1% 分辨率；`reset_at` 与帧一致。
/// 端点未公开（v0.0.220 实测可用），故只当主源用，取不到就退回 relay 帧。
final class LimitsClient {
    /// 两次取值之间的最小间隔。心跳与帧事件都会触发重建，不必每次都问一遍。
    private static let minInterval: TimeInterval = 15
    /// 端口枚举全军覆没后的静默期。旧版 Mirasim 没有这个端点，不必每 15 秒重扫一遍。
    private static let rediscoverAfter: TimeInterval = 300
    /// mirachannel 首页端口。server.cjs 一起来就绑定，且只回 HTML，
    /// 不能拿它的失败当作「这版 Mirasim 没有该端点」的证据。
    private static let homePort = 4970

    private let lock = NSLock()
    private var cachedPort: Int?
    /// 该端口配对的会话入口（路径前缀与令牌）。两者随会话存亡，故与端口一同缓存、一同失效。
    private var cachedRoute: SessionRoute?
    private var last: LimitsSnapshot?
    private var lastAttempt = Date.distantPast
    private var discoveryFailedAt = Date.distantPast
    /// 端点在本机确认可用过。静默期只该拦「这版 Mirasim 没有该端点」；
    /// 端点挂在会话端口上，会话退出端口即消失，新会话的端口晚几秒才起来，
    /// 确认过存在之后的失败都是这类瞬态，进静默期会让面板平白降级五分钟。
    private var endpointConfirmed = false

    /// 取当前额度。`anchorPort` 是已连上的 mirachannel 端口，探测只在同一进程持有的
    /// 端口上进行，避免读到另一个 Mirasim 实例（可能是另一个账号）的额度。
    /// 未到间隔时返回上一次的结果，取不到返回 nil。
    func snapshot(now: Date = Date(), anchorPort: Int? = nil) -> LimitsSnapshot? {
        lock.lock()
        if now.timeIntervalSince(lastAttempt) < Self.minInterval, let last {
            lock.unlock()
            return last
        }
        lastAttempt = now
        let port = cachedPort
        let route = cachedRoute
        let quietUntil = discoveryFailedAt.addingTimeInterval(Self.rediscoverAfter)
        lock.unlock()

        if Diag.forceOffline || Diag.noLimits { return nil }

        var found = port.flatMap { Self.fetch(port: $0, route: route) }
        if found == nil, now.timeIntervalSince(quietUntil) >= 0 {
            let candidates = Self.routerPorts(anchor: anchorPort)
            let routes = candidates.isEmpty ? [:] : Self.sessionRoutes()
            for candidate in candidates where candidate != port {
                if let s = Self.fetch(port: candidate, route: routes[candidate]) {
                    found = s
                    lock.lock()
                    cachedPort = candidate
                    cachedRoute = routes[candidate]
                    lock.unlock()
                    break
                }
            }
            // 只有「会话端口在、却没有这个端点、且从未成功过」才进静默期——
            // 那是旧版 Mirasim 的表现。候选只剩首页端口说明会话尚未注册：
            // Mirasim 重启后首页端口立刻就绪，会话端口要晚几十秒；
            // 确认过端点的实例失败属会话端口更替，两者按常规间隔重试即可。
            if found == nil, !endpointConfirmed,
               candidates.contains(where: { $0 != Self.homePort }) {
                lock.lock(); discoveryFailedAt = now; lock.unlock()
            }
        }

        lock.lock()
        if found == nil {
            cachedPort = nil
            cachedRoute = nil
        } else {
            endpointConfirmed = true
        }
        last = found
        lock.unlock()
        return found
    }

    /// Mirasim 重连后调用：清掉缓存端口与静默期，立刻重新枚举。
    /// 重启会换掉全部会话端口，旧缓存必然失效。
    func invalidate() {
        lock.lock()
        cachedPort = nil
        cachedRoute = nil
        last = nil
        discoveryFailedAt = .distantPast
        lastAttempt = .distantPast
        lock.unlock()
    }

    /// 已确认可用的路由端口，供自检显示。
    var port: Int? {
        lock.lock(); defer { lock.unlock() }
        return cachedPort
    }

    // MARK: 取值

    private static func fetch(port: Int, route: SessionRoute?) -> LimitsSnapshot? {
        // 没有会话入口的端口（预热槽）只能试裸路径；0.0.220 那版对本机免认证。
        let base = route?.baseURL ?? "http://127.0.0.1:\(port)"
        guard let url = URL(string: base + "/v1/limits") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        // 按令牌校验的那几版看这个头，按前缀放行的版本不看，带上无害。
        if let token = route?.token { request.setValue(token, forHTTPHeaderField: "x-api-key") }
        var payload: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { payload = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        guard let payload else { return nil }
        return parse(payload)
    }

    static func parse(_ data: Data) -> LimitsSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["windows"] as? [[String: Any]] else { return nil }
        let now = Date().timeIntervalSince1970
        let windows: [LimitsSnapshot.Window] = raw.compactMap { w in
            guard let name = w["name"] as? String,
                  let used = number(w["used"]), let budget = number(w["budget"]), budget > 0,
                  var reset = number(w["reset_at"]) else { return nil }
            // 端点未公开，单位可能改毫秒（帧解析同款归一化）。归一化后仍不在
            // 合理区间的窗口丢弃：重置时刻落在将来数万年会让窗口起点跑到将来，
            // 已用金额静默显示 $0 且不触发任何降级。
            if reset > 1e11 { reset /= 1000 }
            guard reset > now - 86400, reset < now + 30 * 86400 else { return nil }
            let scoped = (w["model_scoped"] as? Bool) ?? (w["modelScoped"] as? Bool) ?? false
            return LimitsSnapshot.Window(label: name, used: used, budget: budget,
                                         resetAt: Date(timeIntervalSince1970: reset),
                                         modelScoped: scoped)
        }
        guard !windows.isEmpty else { return nil }
        return LimitsSnapshot(windows: windows, capturedAt: Date(),
                              suspended: root["suspended"] as? Bool ?? false,
                              unmetered: root["unmetered"] as? Bool ?? false,
                              degraded: root["degraded"] as? Bool ?? false,
                              paid: root["paid"] as? Bool)
    }

    private static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    // MARK: 端口发现

    /// Mirasim 进程持有的回环监听端口。会话进出会增减端口，故每次失败后重新枚举。
    /// 给了 `anchor` 就只取持有该端口的那个进程，避免读到并行开发实例的额度。
    ///
    /// `lsof` 必须用 `-p` 限定进程：`lsof -iTCP:<port>` 不带 `-p` 会全系统扫描，
    /// 实测会把调用线程卡住上百秒。故先用 `ps` 拿到候选进程，再一次 `lsof` 取端口。
    static func routerPorts(anchor: Int? = nil) -> [Int] {
        let pids = mirasimPIDs()
        guard !pids.isEmpty else { return [] }
        let args = ["-nP", "-w", "-iTCP", "-sTCP:LISTEN", "-a",
                    "-p", pids.map(String.init).joined(separator: ","), "-Fpn"]
        guard let text = run("/usr/sbin/lsof", args) else { return [] }

        var byPID: [Int: [Int]] = [:]
        var current: Int?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("p") {
                current = Int(line.dropFirst())
            } else if line.hasPrefix("n127.0.0.1:"), let pid = current,
                      let port = Int(line.dropFirst("n127.0.0.1:".count)) {
                byPID[pid, default: []].append(port)
            }
        }

        let ports: [Int]
        if let anchor {
            // 限定同一进程是同账号保证的全部意义：锚点端口找不到归属时退回
            // 全实例扫描，恰好在并行开发实例的场景里读到别的账号。找不到就空手而归，
            // 额度退回 relay 帧口径（帧本就来自锚点那个实例）。
            ports = byPID.first(where: { $0.value.contains(anchor) })?.value ?? []
        } else {
            ports = byPID.values.flatMap { $0 }
        }
        // mirachannel 那个端口回的是首页 HTML，放到最后再试。
        return Array(Set(ports)).sorted { a, b in (a == homePort ? 1 : 0) < (b == homePort ? 1 : 0) }
    }

    /// 路由端口 → 会话入口。前缀与令牌都不落盘，只在 Mirasim 拉起的会话进程环境里：
    /// 同一进程的 `ANTHROPIC_BASE_URL` 指向哪个回环端口，它的路径与 `ANTHROPIC_AUTH_TOKEN`
    /// 就是那个端口的入口；前缀与端口一一绑定，拿别的会话的前缀打本端口同样 401。
    /// 会话退出后三者一并消失，故每轮发现都重新读。
    ///
    /// `ps` 必须用 `-U` 限定用户：BSD 语法下不给选择符时只列「同用户且同控制终端」的
    /// 进程，LaunchAgent 没有控制终端，结果会是空的。
    static func sessionRoutes() -> [Int: SessionRoute] {
        guard let text = run("/bin/ps", ["eww", "-U", NSUserName(), "-o", "command="]) else { return [:] }

        let urlPrefix = "ANTHROPIC_BASE_URL=http://127.0.0.1:"
        var map: [Int: SessionRoute] = [:]
        for line in text.split(separator: "\n") {
            var port: Int?
            var base: String?
            var token: String?
            // 逐个环境项精确匹配前缀：同一行还有 `MIRASIM_PTY_PIN_ANTHROPIC_BASE_URL`
            // 这类同名后缀的变量，子串匹配会配错。
            for field in line.split(separator: " ") {
                if field.hasPrefix(urlPrefix) {
                    port = Int(field.dropFirst(urlPrefix.count).prefix { $0.isNumber })
                    var value = String(field.dropFirst("ANTHROPIC_BASE_URL=".count))
                    while value.hasSuffix("/") { value.removeLast() }
                    base = value
                } else if field.hasPrefix("ANTHROPIC_AUTH_TOKEN=") {
                    let t = String(field.dropFirst("ANTHROPIC_AUTH_TOKEN=".count))
                    token = t.isEmpty ? nil : t
                }
            }
            if let port, let base { map[port] = SessionRoute(baseURL: base, token: token) }
        }
        return map
    }

    private static func mirasimPIDs() -> [Int] {
        guard let text = run("/bin/ps", ["-axo", "pid=,command="]) else { return [] }
        var pids: [Int] = []
        for line in text.split(separator: "\n") where line.contains("server.cjs") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let pid = Int(trimmed.prefix(while: { $0.isNumber })) { pids.append(pid) }
        }
        return pids
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
