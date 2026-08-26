import Foundation
import Network

/// 本机 JSON 接口。
///
/// 客户端里的控件跑在 Mirasim 的渲染进程里，读不到 `~/.claude/projects` 与网关账本，
/// 故由本进程把算好的结论挂在回环端口上供它拉取。渲染进程的 CSP 允许
/// `connect-src http://127.0.0.1:*`，但页面本身是 `file://` 源，因此必须带 CORS 头。
///
/// 只监听 127.0.0.1，不落盘，不接受任何写入——除 `/quit` 之外没有副作用。
/// `/quit` 有副作用，须带令牌：回环端口上任意浏览器页面都能把请求发到，
/// 令牌把「能发请求」与「有权退出」分开，任意网页拿不到令牌值。
final class Feed {
    /// 首选端口，被占用时向后顺延。
    static let preferredPort: UInt16 = 4988
    private static let portRange: ClosedRange<UInt16> = 4988...4995

    private let queue = DispatchQueue(label: "miraquota.feed")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// 最新结论的 JSON 字节，由引擎每轮刷新时替换。
    private var body = Data("{}".utf8)
    private let lock = NSLock()

    /// 监听端口在 feed 队列上写入，注入器在自己的队列上读，须经锁。
    private var boundPort: UInt16?
    var port: UInt16? {
        lock.lock(); defer { lock.unlock() }
        return boundPort
    }

    /// `/quit` 的令牌。首启生成并以 0600 落盘，跨启动稳定；
    /// 控件经注入器拿到同一份，随请求头回传。
    let token: String = Feed.loadOrCreateToken()

    /// 供 `/quit` 调用。未设置时该路由返回 404。
    var onQuit: (() -> Void)?

    func start() {
        queue.async { [weak self] in self?.bind(Self.portRange.lowerBound) }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            for c in self.connections.values { c.cancel() }
            self.connections.removeAll()
        }
    }

    func publish(_ report: QuotaReport, pricing: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: Self.payload(report, pricing: pricing)) else { return }
        lock.lock()
        body = data
        lock.unlock()
    }

    // MARK: 监听

    private func bind(_ candidate: UInt16) {
        guard candidate <= Self.portRange.upperBound, let nwPort = NWEndpoint.Port(rawValue: candidate) else {
            Diag.log("feed 无可用端口")
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 只绑回环，避免把额度数据暴露到局域网。
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        guard let l = try? NWListener(using: params) else { return bind(candidate + 1) }
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock(); self.boundPort = candidate; self.lock.unlock()
                Diag.log("feed 监听 127.0.0.1:\(candidate)")
            case .failed:
                l.cancel()
                self.listener = nil
                self.bind(candidate + 1)
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener = l
        l.start(queue: queue)
    }

    private func accept(_ c: NWConnection) {
        connections[ObjectIdentifier(c)] = c
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connections[ObjectIdentifier(c)] = nil
            default:
                break
            }
        }
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    /// 只读到请求头结束就够了：本接口没有请求体。
    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, _ in
            guard let self else { return }
            var acc = buffer
            if let data { acc.append(data) }
            if let range = acc.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(c, head: acc[acc.startIndex..<range.lowerBound])
                return
            }
            if done || acc.count > 8192 {
                c.cancel()
                return
            }
            self.receive(c, buffer: acc)
        }
    }

    private func respond(_ c: NWConnection, head: Data) {
        let text = String(decoding: head, as: UTF8.self)
        // "\r\n" 在 Swift 里是单个字素簇 Character，与 "\r"、"\n" 都不相等，
        // 谓词漏掉它就切不了行。
        let line = text.prefix(while: { $0 != "\r" && $0 != "\n" && $0 != "\r\n" })
        let parts = line.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        // 查询串要剥掉：控件会带 ?t=<时间戳> 破缓存，按整串匹配会全部落到 404。
        // split 对全 '?' 的路径返回空数组，强制下标会让整个进程崩溃，必须走 first。
        let path = parts.count > 1
            ? (parts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/")
            : "/"

        switch (method, path) {
        case ("OPTIONS", _):
            send(c, status: "204 No Content", body: Data(), type: nil)
        case ("GET", "/quota.json"), ("GET", "/"):
            lock.lock(); let payload = body; lock.unlock()
            send(c, status: "200 OK", body: payload, type: "application/json; charset=utf-8")
        case ("POST", "/quit"):
            // 令牌不符一律 403。GET 分支已删：img 标签一类的简单请求不经预检就能送达，
            // 带自定义头的 POST 则必须先过 OPTIONS，令牌值才是真正的闸门。
            guard Self.headerValue(text, "x-miraquota-token") == token else {
                send(c, status: "403 Forbidden", body: Data(), type: nil)
                return
            }
            if let onQuit {
                send(c, status: "200 OK", body: Data("{\"ok\":true}".utf8), type: "application/json")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onQuit() }
            } else {
                send(c, status: "404 Not Found", body: Data(), type: nil)
            }
        default:
            send(c, status: "404 Not Found", body: Data(), type: nil)
        }
    }

    /// 头字段取值，头名大小写不敏感。`name` 传小写。
    /// "\r\n" 是单个字素簇，须与 "\r"、"\n" 并列判断。
    private static func headerValue(_ head: String, _ name: String) -> String? {
        for raw in head.split(whereSeparator: { $0 == "\r" || $0 == "\n" || $0 == "\r\n" }).dropFirst() {
            guard let colon = raw.firstIndex(of: ":") else { continue }
            if raw[raw.startIndex..<colon].lowercased() == name {
                return raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func loadOrCreateToken() -> String {
        if let existing = try? String(contentsOf: Paths.feedToken, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 16 { return trimmed }
        }
        let fresh = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        Paths.ensureStateDir()
        FileManager.default.createFile(atPath: Paths.feedToken.path,
                                       contents: Data(fresh.utf8),
                                       attributes: [.posixPermissions: 0o600])
        return fresh
    }

    private func send(_ c: NWConnection, status: String, body: Data, type: String?) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        if let type { header += "Content-Type: \(type)\r\n" }
        // 页面源是 file://（渲染进程），跨源请求必须显式放行。
        // 自定义头要在预检里列名，控件的带令牌 POST 才过得去；
        // 放行头名不等于放行请求——令牌值仍是 /quit 的闸门。
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        header += "Access-Control-Allow-Headers: X-MiraQuota-Token\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: 序列化

    private static func payload(_ r: QuotaReport, pricing: String) -> [String: Any] {
        var root: [String: Any] = [
            "stateLabel": r.state.label,
            "state": r.state.key,
            "measured": r.state.isMeasured,
            "capturedAt": r.capturedAt.timeIntervalSince1970,
            "mode": r.mode,
            "host": r.host,
            "relayStatus": r.relayStatus,
            "pricing": pricing,
            "buckets": r.bucketCount,
            "windows": r.windows.map(window),
        ]
        if let detail = r.state.detail { root["detail"] = detail }
        if let notice = r.accountNotice { root["accountNotice"] = notice }
        if let price = r.unitPriceUSD { root["unitPriceUSD"] = price }
        if let speed = r.speed { root["speed"] = self.speed(speed) }
        return root
    }

    private static func window(_ w: WindowReport) -> [String: Any] {
        var out: [String: Any] = [
            "label": w.label,
            "usedPercent": w.usedPercent,
            "spentUSD": w.spentUSD,
            "inferred": w.inferred,
            "confidence": w.confidence.rawValue,
        ]
        if let full = w.fullUSD { out["fullUSD"] = full }
        if let reset = w.resetAt { out["resetAt"] = reset.timeIntervalSince1970 }
        if let pace = w.pacePercent { out["pacePercent"] = pace }
        if let delta = w.paceDelta { out["paceDelta"] = delta }
        if let p = w.points { out["points"] = ["used": p.used, "budget": p.budget] }
        if let eta = w.etaSeconds { out["etaSeconds"] = eta }
        if let rem = w.remainingUSD { out["remainingUSD"] = rem }
        // 按点数口径折算的已用美元。与 usedPercent、进度条同分母，控件主行用它，
        // spentUSD（本机账本支出）降为副行。
        if let scaled = w.scaledSpentUSD { out["scaledSpentUSD"] = scaled }
        return out
    }

    private static func speed(_ s: SpeedReport) -> [String: Any] {
        var out: [String: Any] = [
            "recentCount": s.recentCount,
            "sampleTotal": s.sampleTotal,
            "inflight": s.inflightSince.map { $0.timeIntervalSince1970 },
            "rows": s.rows.map { row -> [String: Any] in
                var r: [String: Any] = ["model": row.model, "samples": row.samples,
                                        "endToEnd": row.endToEnd,
                                        "measured": row.measured,
                                        "latestAt": row.latestAt.timeIntervalSince1970]
                if let t = row.ttft { r["ttft"] = t }
                if let rate = row.rate { r["rate"] = rate }
                if let base = row.baselineRate { r["baselineRate"] = base }
                if let drift = row.drift { r["drift"] = drift }
                // 界面只显示过闸门的偏离，阈值由 SpeedRow.notableDrift 统一把关，
                // 两个显示面不各自定阈值。
                if let notable = row.notableDrift { r["driftNotable"] = notable }
                return r
            },
            // 按会话分行，状态栏据此只取本窗口的数据。全部来自实测路径。
            "sessions": s.sessions.map { row -> [String: Any] in
                var r: [String: Any] = ["session": row.session, "model": row.model,
                                        "samples": row.samples, "measured": true,
                                        "latestAt": row.latestAt.timeIntervalSince1970]
                if let t = row.ttft { r["ttft"] = t }
                if let rate = row.rate { r["rate"] = rate }
                return r
            },
        ]
        if let m = s.measuredTurnTTFB {
            out["measuredTurnTTFB"] = ["median": m.median, "count": m.count]
        }
        return out
    }
}
