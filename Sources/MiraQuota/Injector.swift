import Foundation

/// 把控件脚本注入 Mirasim 的渲染进程。
///
/// Mirasim 是 Electron 应用，带 `--remote-debugging-port` 启动后可经 CDP
/// 在页面上下文里执行脚本：`Page.addScriptToEvaluateOnNewDocument` 覆盖此后每次导航，
/// `Runtime.evaluate` 补上当前这次。**不改 Mirasim 的任何文件**，升级不失效。
///
/// 渲染进程的 CSP 是 `script-src 'self'`，普通 script 标签加载不了外部脚本；
/// 而 CDP 执行的代码不受 CSP 约束，控件再用 `connect-src` 允许的
/// `http://127.0.0.1:*` 回来拉 `Feed` 的数据。
final class Injector {
    /// 调试端口。Mirasim 需以 `--remote-debugging-port=<N>` 启动。
    static let defaultPort: UInt16 = 9333

    /// 巡检间隔。命中且版本一致时退避到 idleInterval，减少渲染进程侧的 CDP 往返
    /// （每轮每个 target 一次 WebSocket 往返，稳定期这笔开销没有产出）。
    private static let sweepInterval: TimeInterval = 10
    private static let idleInterval: TimeInterval = 30
    /// 连续这么多轮全部命中才退避，避免刚注入完就把节奏放慢。
    private static let steadyThreshold = 3

    private let queue = DispatchQueue(label: "miraquota.injector")
    private var timer: DispatchSourceTimer?
    private var source: String?
    /// 控件脚本里声明的版本号，用来判断页面里那份是否已过期。
    private var sourceVersion = 0
    /// 已登记过「新文档时执行」的 target。同一 target 只登记一次，
    /// 否则每轮巡检都追加一份，页面一刷新就会把同一段脚本跑上几十遍。
    private var registered: Set<String> = []
    private weak var feed: Feed?
    /// 控件当前是否活在某个页面里。状态变化时回调一次，供菜单栏项联动。
    private(set) var present = false
    /// 连续几轮找不到调试端口才认定控件不在，避免图标闪烁。
    private var absentRounds = 0
    var onPresence: ((Bool) -> Void)?
    /// 最近一次巡检的概况，供 --doctor 显示。
    private(set) var lastSummary = "未巡检"
    /// 连续全部命中的轮数与当前生效的巡检间隔。
    private var steadyRounds = 0
    private var interval = Injector.sweepInterval


    private struct Target {
        let id: String
        let socket: String
    }

    /// 全局复用一个会话。每次调用新建 URLSession 而不 invalidate 会让 WebSocket 连接滞留，
    /// 而 CDP 的 `/devtools/page/<id>` 端点同一时刻只接受一个客户端——
    /// 滞留的连接会把后续探测与 `--doctor` 全挡在门外，表现为「注入状态 0/1」。
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        return URLSession(configuration: cfg)
    }()

    func start(feed: Feed) {
        self.feed = feed
        queue.async { [weak self] in
            guard let self else { return }
            self.source = Self.loadWidget()
            self.sourceVersion = self.source.flatMap(Self.version) ?? 0
            if self.source == nil { Diag.log("injector 找不到控件脚本，注入跳过") }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: Self.sweepInterval)
        t.setEventHandler { [weak self] in self?.sweep() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: 巡检

    private func sweep() {
        guard let source, let feed, let feedPort = feed.port else { return }
        guard let port = Self.debugPort() else {
            lastSummary = "未发现调试端口（Mirasim 未以 --remote-debugging-port 启动）"
            note(false)
            pace(steady: false)
            return
        }
        let targets = Self.targets(port: port)
        guard !targets.isEmpty else {
            lastSummary = "调试端口 \(port) 上没有可注入的页面"
            note(false)
            pace(steady: false)
            return
        }

        // 端口是注入时刻的快照，控件失联后会自行在 4988–4995 里重找；
        // 令牌跨启动稳定，持久注册的脚本不会因它过期。
        let payload = "window.__MIRAQUOTA_FEED__=\"http://127.0.0.1:\(feedPort)\";\n"
            + "window.__MIRAQUOTA_TOKEN__=\"\(feed.token)\";\n" + source
        // 每轮都探一次而不是记住注入过的 target：页面刷新后 target id 不变，
        // 但页面里的控件已经没了，只按 id 去重会让刷新后再也注不进去。
        registered.formIntersection(Set(targets.map(\.id)))
        var live = 0
        for t in targets {
            let inPage = Self.widgetVersion(t)
            if inPage == sourceVersion, inPage > 0 { live += 1; continue }
            // 页面里那份过期了：脚本顶部的守卫会让新代码直接返回，
            // 必须先清掉守卫与旧宿主，否则改完控件要重开 Mirasim 才生效。
            if inPage > 0 { Self.reset(t) }
            let first = !registered.contains(t.id)
            if Self.inject(payload, into: t, persist: first) {
                if first { registered.insert(t.id) }
                live += 1
                Diag.log("injector 已注入 target \(t.id)（页面 v\(inPage) → v\(sourceVersion)）")
            }
        }
        lastSummary = "调试端口 \(port) · \(live)/\(targets.count) 个页面已带控件"
        note(live > 0)
        pace(steady: live == targets.count)
    }

    /// 全部页面都带着最新控件时退避到 30 秒；任何一轮落空立刻回到 10 秒，
    /// 这样改完控件仍能很快被顶上去。
    private func pace(steady: Bool) {
        steadyRounds = steady ? steadyRounds + 1 : 0
        let want = steadyRounds >= Self.steadyThreshold ? Self.idleInterval : Self.sweepInterval
        guard want != interval, let timer else { return }
        interval = want
        timer.schedule(deadline: .now() + want, repeating: want)
    }

    /// 状态收敛：注入成功立刻算「在」，判定「不在」要连续三轮落空。
    private func note(_ ok: Bool) {
        if ok {
            absentRounds = 0
            if !present { present = true; onPresence?(true) }
            return
        }
        absentRounds += 1
        if present, absentRounds >= 3 { present = false; onPresence?(false) }
    }

    /// 供 `--doctor` 独立查一次：调试端口、页面数、已带控件的页面数。
    static func status() -> (port: UInt16?, targets: Int, live: Int) {
        guard let port = debugPort() else { return (nil, 0, 0) }
        let list = targets(port: port)
        return (port, list.count, list.filter { widgetVersion($0) > 0 }.count)
    }

    /// 调试端口：环境变量覆盖 → 默认 9333 → Chromium 惯用的 9222。
    private static func debugPort() -> UInt16? {
        var candidates: [UInt16] = []
        if let raw = ProcessInfo.processInfo.environment["MIRAQUOTA_CDP_PORT"],
           let n = UInt16(raw) { candidates.append(n) }
        candidates.append(contentsOf: [defaultPort, 9222])
        for p in candidates where probe(port: p) { return p }
        return nil
    }

    private static func probe(port: UInt16) -> Bool {
        guard let data = get("http://127.0.0.1:\(port)/json/version"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return root["webSocketDebuggerUrl"] != nil || root["Browser"] != nil
    }

    /// 可注入的页面目标。devtools 自身与扩展页面跳过。
    private static func targets(port: UInt16) -> [Target] {
        guard let data = get("http://127.0.0.1:\(port)/json/list"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard (item["type"] as? String) == "page",
                  let id = item["id"] as? String,
                  let socket = item["webSocketDebuggerUrl"] as? String else { return nil }
            let url = (item["url"] as? String) ?? ""
            guard !url.hasPrefix("devtools://"), !url.hasPrefix("chrome-extension://") else { return nil }
            return Target(id: id, socket: socket)
        }
    }

    /// 页面里控件的版本号，没有则 0。
    private static func widgetVersion(_ target: Target) -> Int {
        guard let reply = call(target, method: "Runtime.evaluate",
                               params: ["expression": "window.__miraquotaVersion||0",
                                        "returnByValue": true]) else { return 0 }
        let result = (reply["result"] as? [String: Any])?["result"] as? [String: Any]
        if let n = result?["value"] as? Int { return n }
        if let d = result?["value"] as? Double { return Int(d) }
        return 0
    }

    /// 清掉页面里的旧控件，为重注入让路。
    private static func reset(_ target: Target) {
        _ = call(target, method: "Runtime.evaluate", params: [
            "expression": "delete window.__miraquotaWidget;"
                + "document.querySelectorAll('#miraquota-widget').forEach(e=>e.remove());true",
            "returnByValue": true,
        ])
    }

    /// 从脚本里读版本号声明。
    private static func version(_ source: String) -> Int? {
        guard let r = source.range(of: "__miraquotaVersion\\s*=\\s*[0-9]+", options: .regularExpression),
              let n = source[r].split(separator: "=").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) })
        else { return nil }
        return n
    }

    /// 单次 CDP 往返：连上、发一条、等对应 id 的回应、断开。
    private static func call(_ target: Target, method: String, params: [String: Any]) -> [String: Any]? {
        guard let url = URL(string: target.socket) else { return nil }
        let task = Self.session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let frame: [String: Any] = ["id": 1, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let sent = DispatchSemaphore(value: 0)
        var sendError: Error?
        task.send(.string(text)) { sendError = $0; sent.signal() }
        if sent.wait(timeout: .now() + 5) == .timedOut {
            Diag.log("cdp \(method) 发送超时")
            return nil
        }
        if let sendError {
            Diag.log("cdp \(method) 发送失败 \(sendError)")
            return nil
        }

        for _ in 0..<6 {
            let done = DispatchSemaphore(value: 0)
            var reply: [String: Any]?
            var failure: Error?
            task.receive { result in
                switch result {
                case .success(.string(let s)):
                    if let d = s.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        reply = obj
                    }
                case .failure(let e):
                    failure = e
                default:
                    break
                }
                done.signal()
            }
            if done.wait(timeout: .now() + 5) == .timedOut {
                Diag.log("cdp \(method) 等回应超时")
                return nil
            }
            if let failure {
                Diag.log("cdp \(method) 接收失败 \(failure)")
                return nil
            }
            guard let reply else { return nil }
            if (reply["id"] as? Int) == 1 { return reply }
        }
        return nil
    }

    private static func inject(_ script: String, into target: Target, persist: Bool) -> Bool {
        guard let url = URL(string: target.socket) else { return false }
        let task = Self.session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        var commands: [[String: Any]] = [["id": 1, "method": "Page.enable"]]
        if persist {
            commands.append(["id": 2, "method": "Page.addScriptToEvaluateOnNewDocument",
                             "params": ["source": script]])
        }
        commands.append(["id": 3, "method": "Runtime.evaluate",
                         "params": ["expression": script, "awaitPromise": false,
                                    "returnByValue": false]])
        for command in commands {
            guard let data = try? JSONSerialization.data(withJSONObject: command),
                  let text = String(data: data, encoding: .utf8) else { return false }
            let done = DispatchSemaphore(value: 0)
            var failed = false
            task.send(.string(text)) { error in
                failed = error != nil
                done.signal()
            }
            if done.wait(timeout: .now() + 5) == .timedOut || failed { return false }
        }
        // 必须等到 evaluate 那一条的回应：只等任意一帧会拿到 Page.enable 的回执，
        // 随后 defer 里的 cancel 可能在脚本真正执行前就把连接断了，页面就此空着。
        for _ in 0..<12 {
            let done = DispatchSemaphore(value: 0)
            var reply: [String: Any]?
            task.receive { result in
                if case .success(.string(let s)) = result,
                   let d = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    reply = obj
                }
                done.signal()
            }
            if done.wait(timeout: .now() + 5) == .timedOut { return false }
            guard let reply else { return false }
            if (reply["id"] as? Int) == 3 {
                // 脚本自身抛异常时不算注入成功，下一轮还会再试。
                return (reply["result"] as? [String: Any])?["exceptionDetails"] == nil
            }
        }
        return false
    }

    private static func get(_ url: String) -> Data? {
        guard let u = URL(string: url) else { return nil }
        var request = URLRequest(url: u)
        request.timeoutInterval = 2
        var payload: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { payload = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        return payload
    }

    /// 控件脚本：环境变量覆盖 → 应用包 Resources → 仓库里的开发副本。
    private static func loadWidget() -> String? {
        var candidates: [URL] = []
        if let raw = ProcessInfo.processInfo.environment["MIRAQUOTA_WIDGET"] {
            candidates.append(URL(fileURLWithPath: raw))
        }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appending(path: "widget.js"))
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(exe.appending(path: "../../widget/miraquota-widget.js"))
        candidates.append(exe.appending(path: "../../../widget/miraquota-widget.js"))
        for url in candidates {
            if let text = try? String(contentsOf: url.standardizedFileURL, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return nil
    }
}
