import Foundation
import Network

/// OTLP/HTTP(json) 接收端，速度卡「实测口径」的数据源。
///
/// Claude Code 开启 traces beta（`CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1`）后，
/// 每个 API 请求结束把 `claude_code.llm_request` span POST 到这里，属性带客户端
/// 实测的 `ttft_ms` 与 `duration_ms`，`request_id` 与网关账本的 `providerCallId`
/// 同源可关联。据此首 token 与出字速度都成为逐请求测量值，不再依赖回归估计。
///
/// 只监听 127.0.0.1、只追加写 ~/.miraquota/measured/，对任何 POST 都回 200——
/// 导出器拿不到 2xx 会重试积压，静默吞掉比报错更合适。
final class OtlpReceiver {
    /// 固定端口：地址写死在 ~/.claude/settings.json 的 env 里，不能像 Feed 那样顺延。
    /// 避开 Feed 的 4988...4995；4318 留给可能出现的标准 collector。
    static let port: UInt16 = 4319
    /// trace 批次实测在几 KB 量级，超出这个大小的请求体按异常丢弃。
    private static let bodyCap = 4 << 20
    /// 样本文件按 UTC 日期分片，保留最近这么多天；SpeedStats 的保留期是 48 小时。
    private static let keepDays = 3

    private let queue = DispatchQueue(label: "miraquota.otlp")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    func start() {
        queue.async { [weak self] in self?.bind() }
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

    private func bind() {
        guard let nwPort = NWEndpoint.Port(rawValue: Self.port) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        guard let l = try? NWListener(using: params) else {
            Diag.log("otlp 端口 \(Self.port) 不可用")
            return
        }
        l.stateUpdateHandler = { state in
            if case .ready = state { Diag.log("otlp 监听 127.0.0.1:\(Self.port)") }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener = l
        l.start(queue: queue)
        prune()
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

    /// 读到头结束后按 Content-Length 收满请求体。CC ≥2.1.212 的导出器带
    /// Content-Length；没有该头（更老版本用 chunked）时不解析，直接回 200 丢弃。
    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, _ in
            guard let self else { return }
            var acc = buffer
            if let data { acc.append(data) }
            if let range = acc.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: acc[acc.startIndex..<range.lowerBound], as: UTF8.self)
                let expect = Self.contentLength(head) ?? 0
                guard expect <= Self.bodyCap else { c.cancel(); return }
                self.receiveBody(c, head: head, body: Data(acc[range.upperBound...]), expect: expect)
                return
            }
            if done || acc.count > 1 << 16 { c.cancel(); return }
            self.receive(c, buffer: acc)
        }
    }

    private func receiveBody(_ c: NWConnection, head: String, body: Data, expect: Int) {
        guard body.count < expect else {
            handle(c, head: head, body: body.prefix(expect))
            return
        }
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, _ in
            guard let self else { return }
            var acc = body
            if let data { acc.append(data) }
            if acc.count >= expect || done {
                self.handle(c, head: head, body: acc.prefix(expect))
            } else {
                self.receiveBody(c, head: head, body: acc, expect: expect)
            }
        }
    }

    private func handle(_ c: NWConnection, head: String, body: Data) {
        let line = head.prefix(while: { $0 != "\r" && $0 != "\n" && $0 != "\r\n" })
        let parts = line.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let path = parts.count > 1
            ? (parts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/")
            : "/"
        // /health 供 doctor 从进程外探活。POST 一律 200：logs/metrics 误开也不积压重试。
        if method == "POST", path == "/v1/traces" { ingest(body) }
        let ok = method == "GET" ? path == "/health" : method == "POST"
        send(c, status: ok ? "200 OK" : "404 Not Found")
    }

    private func send(_ c: NWConnection, status: String) {
        let body = "{}"
        let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data((header + body).utf8), completion: .contentProcessed { _ in c.cancel() })
    }

    private static func contentLength(_ head: String) -> Int? {
        for raw in head.split(whereSeparator: { $0 == "\r" || $0 == "\n" || $0 == "\r\n" }).dropFirst() {
            guard let colon = raw.firstIndex(of: ":") else { continue }
            if raw[raw.startIndex..<colon].lowercased() == "content-length" {
                return Int(raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    // MARK: 落盘

    private func ingest(_ body: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let resourceSpans = root["resourceSpans"] as? [[String: Any]] else { return }
        var lines = Data()
        for rs in resourceSpans {
            for ss in (rs["scopeSpans"] as? [[String: Any]]) ?? [] {
                for span in (ss["spans"] as? [[String: Any]]) ?? [] {
                    guard (span["name"] as? String) == "claude_code.llm_request",
                          let record = Self.record(span),
                          let data = try? JSONSerialization.data(withJSONObject: record) else { continue }
                    lines.append(data)
                    lines.append(0x0A)
                }
            }
        }
        guard !lines.isEmpty else { return }
        append(lines)
    }

    private static func record(_ span: [String: Any]) -> [String: Any]? {
        var attrs: [String: Any] = [:]
        for a in (span["attributes"] as? [[String: Any]]) ?? [] {
            guard let k = a["key"] as? String, let v = a["value"] as? [String: Any] else { continue }
            attrs[k] = v["stringValue"] ?? v["intValue"] ?? v["boolValue"] ?? v["doubleValue"]
        }
        guard let ttft = int(attrs["ttft_ms"]), ttft > 0,
              let duration = int(attrs["duration_ms"]), duration > 0,
              var model = attrs["model"] as? String, !model.isEmpty else { return nil }
        // 完成时刻取 span 结束时间。OTLP-JSON 的 int64 按规范是字符串，实测是数字，两者都收。
        guard let nanos = int(span["endTimeUnixNano"]) else { return nil }
        // CC 侧模型名可能带 `[1m]` 一类后缀，账本与展示都用裸名。
        if let bracket = model.firstIndex(of: "[") { model = String(model[model.startIndex..<bracket]) }
        return [
            "at": nanos / 1_000_000_000,
            "model": model,
            "ttftMs": ttft,
            "durationMs": duration,
            "out": int(attrs["output_tokens"]) ?? 0,
            "requestId": (attrs["request_id"] as? String) ?? "",
            // 会话 UUID，与 transcript 文件名同源。速度按会话分行靠它。
            "session": (attrs["session.id"] as? String) ?? "",
            "attempt": int(attrs["attempt"]) ?? 1,
            "success": (attrs["success"] as? Bool) ?? true,
        ]
    }

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private func append(_ lines: Data) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.measuredDir, withIntermediateDirectories: true)
        let file = Paths.measuredDir.appending(path: "speed-\(Self.dayStamp()).ndjson")
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil)
            prune()
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: lines)
    }

    private static func dayStamp(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: now)
    }

    private func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.measuredDir,
                                                      includingPropertiesForKeys: nil) else { return }
        let floor = Self.dayStamp(now: Date(timeIntervalSinceNow: -Double(Self.keepDays) * 86400))
        for f in files where f.lastPathComponent.hasPrefix("speed-") && f.pathExtension == "ndjson" {
            let stamp = f.deletingPathExtension().lastPathComponent.dropFirst("speed-".count)
            if stamp < floor { try? fm.removeItem(at: f) }
        }
    }
}
