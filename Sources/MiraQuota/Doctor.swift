import Foundation

/// `--doctor`：逐项检查数据链路，指出断点与处置办法。
///
/// 通道失效时先跑这个，它会说明是 Mirasim 没运行、端口变了、协议变了，
/// 还是本地账本的问题，并给出对应动作。
enum Doctor {
    private enum Mark: String {
        case ok = "✓", warn = "!", bad = "✗"
    }

    private static var failures = 0
    private static var warnings = 0

    static func run(port: Int?) -> Int32 {
        failures = 0
        warnings = 0

        print("MiraQuota 自检\n")

        section("Mirasim 通道")
        let discovered = checkChannel(port: port)

        section("本地账本")
        checkLedger()

        section("标定与退路")
        checkFallback()

        section("客户端控件")
        checkWidget()

        section("常驻")
        checkAgent()

        print("")
        if failures > 0 {
            print("结论：\(failures) 项失败，\(warnings) 项告警。实时百分比不可用时插件会自动转入推算模式。")
        } else if warnings > 0 {
            print("结论：链路可用，\(warnings) 项告警。")
        } else {
            print("结论：链路完整。")
        }
        _ = discovered
        return failures > 0 ? 1 : 0
    }

    // MARK: 分项

    private static func checkChannel(port: Int?) -> Int? {
        let running = RelayClient.portsFromProcessList()
        if running.isEmpty {
            line(.warn, "Mirasim 进程", "未在进程列表中找到 server.cjs",
                 fix: "启动 Mirasim；未运行时插件仍会按锚点推算")
        } else {
            line(.ok, "Mirasim 进程", "命令行声明端口 \(running.map(String.init).joined(separator: ", "))")
        }

        guard let found = RelayClient.discoverPort(preferred: port ?? 4970, wide: true) else {
            line(.bad, "本地端口", "4970 与进程列表中的端口均无响应",
                 fix: "确认 Mirasim 正在运行；若它改用了其他端口，用 --port <N> 指定")
            return nil
        }
        line(.ok, "本地端口", "\(found) 上的 /api/health 返回 mirasim")

        // 实连一次，确认握手与帧格式。
        let client = RelayClient(port: found)
        let done = DispatchSemaphore(value: 0)
        var result: RelayEvent?
        client.onEvent = { event in
            if result == nil { result = event; done.signal() }
        }
        client.start()
        let timedOut = done.wait(timeout: .now() + 20) == .timedOut
        client.stop()

        switch (timedOut, result) {
        case (true, _):
            line(.bad, "relay 帧", "20 秒内未收到回应",
                 fix: "Mirasim 可能仍在初始化；重试仍无回应则用 MIRAQUOTA_DEBUG=1 查看原始帧")
        case (_, .some(.snapshot(let s))):
            let desc = s.windows.map { String(format: "%@ %.1f%%", $0.label, $0.usedPercent) }
                .joined(separator: " · ")
            line(.ok, "relay 帧", desc.isEmpty ? "已回传，但窗口为空" : desc)
            if s.windows.isEmpty {
                line(.warn, "额度窗口", "帧内无窗口，线路可能为本地模式",
                     fix: "本地模式下额度由自有 Anthropic 账号计量，不经 relay")
            }
            line(.ok, "线路", "\(s.mode) \(s.host) · \(s.relayStatus)")
            if !s.history.isEmpty {
                line(.ok, "历史缓冲", "\(s.history.count) 点，可用于冷启动补样本")
            }
        case (_, .some(.mismatch(let why))):
            line(.bad, "relay 帧", "收到帧但解析失败：\(why)",
                 fix: "Mirasim 可能已更新协议；/v1/limits 可读时插件仍为精确口径，两者都不可用才转入推算")
        case (_, .some(.unreachable(let why))):
            line(.bad, "relay 帧", why, fix: "确认 Mirasim 正在运行")
        case (_, .none):
            line(.bad, "relay 帧", "无回应")
        }
        // 主源不依赖 relay 帧：帧解析失败时 /v1/limits 往往照常可读。
        // 只在帧成功时才查主源，会在恰恰需要 Doctor 的场景（协议变动）里
        // 漏掉主通道状态、给出错误的降级结论。
        var frame: RelaySnapshot?
        if case .some(.snapshot(let s)) = result { frame = s }
        checkLimits(frame: frame, anchorPort: found)
        return found
    }

    /// 路由端口上的 `/v1/limits`。取不到不算失败：旧版 Mirasim 没有这个端点，
    /// 插件会退回 relay 帧的百分比。
    private static var limits: LimitsSnapshot?

    private static func checkLimits(frame: RelaySnapshot?, anchorPort: Int?) {
        let client = LimitsClient()
        guard let snapshot = client.snapshot(anchorPort: anchorPort) else {
            line(.warn, "额度原始值", "Mirasim 持有的回环端口上均无 /v1/limits",
                 fix: "旧版 Mirasim 无该端点；插件退回 relay 帧的百分比（分辨率 0.1%）")
            return
        }
        limits = snapshot
        let desc = snapshot.windows
            .map { String(format: "%@ %.2f%%（%.1f / %.0f 点）", $0.label, $0.usedPercent, $0.used, $0.budget) }
            .joined(separator: " · ")
        line(.ok, "额度原始值", desc + (client.port.map { " · 端口 \($0)" } ?? ""))
        if let notice = snapshot.notice {
            line(.warn, "账号状态", notice, fix: "额度上限的含义随之改变，数字仅供参考")
        }
        guard let frame else { return }
        // 与帧对账：帧只精确到 0.1%，故允许量化误差内的偏差。
        let gaps = snapshot.windows.compactMap { w -> String? in
            guard let f = frame.window(w.label) else { return nil }
            let gap = abs(f.usedPercent - w.usedPercent)
            return gap > 0.15 ? String(format: "%@ 差 %.2f%%", w.label, gap) : nil
        }
        if gaps.isEmpty {
            line(.ok, "与帧对账", "两侧百分比一致（帧只精确到 0.1%）")
        } else {
            line(.warn, "与帧对账", gaps.joined(separator: " · "),
                 fix: "帧与原始值的口径可能已分叉，插件以原始值为准")
        }
    }

    private static func checkLedger() {
        let fm = FileManager.default
        if fm.fileExists(atPath: Paths.claudeProjects.path) {
            let count = (try? fm.contentsOfDirectory(atPath: Paths.claudeProjects.path).count) ?? 0
            line(.ok, "transcript", "\(Paths.claudeProjects.path) · \(count) 个项目目录")
        } else {
            line(.bad, "transcript", "\(Paths.claudeProjects.path) 不存在",
                 fix: "没有 Claude Code 会话记录则无法计量支出")
        }

        let pricing = Pricing()
        line(pricing.source.contains("内置") ? .warn : .ok, "价目表", pricing.source,
             fix: pricing.source.contains("内置") ? "models-dev-cache.json 缺失，回退到内置表，价格可能滞后" : nil)

        let ledger = CostLedger(pricing: pricing)
        ledger.refresh()
        line(ledger.bucketCount > 0 ? .ok : .warn, "成本桶",
             "分钟桶 \(ledger.bucketCount) · 本轮新增 transcript \(ledger.transcriptRecords) 条 / 网关 \(ledger.ledgerRecords) 条",
             fix: ledger.bucketCount == 0 ? "保留期内无用量记录，金额会显示为 0" : nil)
        if ledger.unpricedRecords > 0 {
            line(.warn, "未定价", "\(ledger.unpricedRecords) 条记录的模型不在价目表内",
                 fix: "这部分支出未计入，金额偏低")
        }

        let calibrator = Calibrator()
        for label in ["5h", "7d"] {
            let dump = calibrator.debugDump(label: label, ledger: ledger)
            line(.ok, "标定 \(label)", dump.replacingOccurrences(of: "\(label): ", with: ""))
        }

        if let limits { checkUnitPrice(limits, ledger: ledger, calibrator: calibrator) }

        checkSpeed()
    }

    /// 额度点单价，以及它与回归标定的互校。两条路径互相独立，差得多说明其中一条有问题。
    private static func checkUnitPrice(_ limits: LimitsSnapshot, ledger: CostLedger, calibrator: Calibrator) {
        let now = Date()
        var best: (label: String, points: Double, usd: Double)?
        for w in limits.windows {
            guard w.used >= 200, let start = w.quotaWindow.startAt else { continue }
            let usd = ledger.spent(from: start, to: now, includeOpenMinute: true)
            guard usd > 0 else { continue }
            if best == nil || w.used > best!.points { best = (w.label, w.used, usd) }
        }
        guard let best else {
            line(.warn, "额度点单价", "已用点数不足 200，暂不反推单价",
                 fix: "窗口刚重置时属常态，累积用量后自动给出；此前满额沿用回归标定")
            return
        }
        let price = best.usd / best.points
        line(.ok, "额度点单价",
             String(format: "$%.6f/点（按 %@ 窗口 %.0f 点 / $%.2f 反推）", price, best.label, best.points, best.usd))
        for w in limits.windows {
            let fromPoints = price * w.budget
            guard let regression = calibrator.estimate(label: w.label, ledger: ledger)?.fullUSD else { continue }
            let gap = abs(fromPoints - regression) / fromPoints * 100
            line(gap <= 15 ? .ok : .warn, "满额互校 \(w.label)",
                 String(format: "额度点口径 $%.0f · 回归标定 $%.0f · 差 %.1f%%", fromPoints, regression, gap),
                 fix: gap > 15 ? "两条独立路径分歧超过 15%，检查账本是否漏记、标定样本是否跨窗口" : nil)
        }
    }

    /// 速度估计只依赖网关账本，不需要 relay，故单独验一遍。
    private static func checkSpeed() {
        let stats = SpeedStats()
        stats.refresh()
        guard let report = stats.report() else {
            line(.warn, "速度样本", "\(Paths.mirasimInsights.path) 内无可用记录",
                 fix: "网关账本缺失或全部记录未回填 token，面板不显示速度卡片")
            return
        }
        guard !report.rows.isEmpty else {
            line(.warn, "速度样本", "近期仅 \(report.sampleTotal) 次请求，不足以成行",
                 fix: "同模型累积到 2 次即可给出速度，12 次后才有首 token")
            return
        }
        let desc = report.rows.map { row -> String in
            let ttft = row.ttft.map { String(format: row.measured ? "首 %.1fs" : "首 ≈%.1fs", $0) } ?? "首 -"
            let rate = row.rate.map { String(format: "%.0f tok/s", $0) } ?? String(format: "端到端 %.0f tok/s", row.endToEnd)
            let drift = row.drift.map { String(format: " 较常态 %+.0f%%", $0) } ?? ""
            let age = Formatting.age(Date().timeIntervalSince(row.latestAt))
            return "\(row.model)[\(row.measured ? "实测" : "回归")] \(ttft) · \(rate) · 最近 \(row.samples) 次 · \(age)前\(drift)"
        }.joined(separator: " · ")
        line(.ok, "速度样本", desc)
        if let m = report.measuredTurnTTFB {
            line(.ok, "实测对照", String(format: "Mirasim 整轮首字节 中位 %.1fs（%d 次，仅量级对照）", m.median, m.count))
        }
        checkMeasuredChannel()
    }

    /// 实测通道三个环节各自可断：env 没注入（新会话不发 trace）、
    /// 接收端不在（常驻应用没跑）、样本没落盘（前两者之一断了或近期无请求）。
    private static func checkMeasuredChannel() {
        var envOK = false
        if let data = try? Data(contentsOf: Paths.claudeSettings),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let env = root["env"] as? [String: Any] {
            envOK = (env["OTEL_EXPORTER_OTLP_ENDPOINT"] as? String) == "http://127.0.0.1:\(OtlpReceiver.port)"
                && (env["CLAUDE_CODE_ENHANCED_TELEMETRY_BETA"] as? String) != nil
        }
        if !envOK {
            line(.warn, "实测通道", "~/.claude/settings.json 未注入 OTel env，新会话不上报逐请求实测",
                 fix: "补齐 env：CLAUDE_CODE_ENABLE_TELEMETRY/ENHANCED_TELEMETRY_BETA=1、OTEL_TRACES_EXPORTER=otlp、http/json 指向 127.0.0.1:\(OtlpReceiver.port)")
        }
        if fetch("http://127.0.0.1:\(OtlpReceiver.port)/health") == nil {
            line(.warn, "实测接收端", "127.0.0.1:\(OtlpReceiver.port) 无响应",
                 fix: "接收端随常驻应用启动，检查 MiraQuota 是否在运行")
        }
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Paths.measuredDir, includingPropertiesForKeys: nil)) ?? []
        var count = 0
        var newest = 0
        let cutoff = Int(Date().timeIntervalSince1970) - 48 * 3600
        for f in files where f.lastPathComponent.hasPrefix("speed-") && f.pathExtension == "ndjson" {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for lineText in text.split(separator: "\n") {
                guard let root = try? JSONSerialization.jsonObject(with: Data(lineText.utf8)) as? [String: Any],
                      let at = root["at"] as? Int, at >= cutoff else { continue }
                count += 1
                newest = max(newest, at)
            }
        }
        if count > 0 {
            let age = Formatting.age(Date().timeIntervalSince1970 - Double(newest))
            line(.ok, "实测样本", "48 小时内 \(count) 条 · 最新 \(age)前")
        } else {
            line(.warn, "实测样本", "48 小时内无实测记录，速度卡将回落到回归估计",
                 fix: "env 注入后需重启 CC 会话才生效；Mirasim 派生会话不经此通道，属预期")
        }
    }

    /// 客户端内控件：本机接口是否在、Mirasim 是否以调试端口启动、页面里是否已带控件。
    private static func checkWidget() {
        var feedPort: UInt16?
        for p in Feed.preferredPort...(Feed.preferredPort + 7) {
            if let data = fetch("http://127.0.0.1:\(p)/quota.json"),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               root["windows"] != nil {
                feedPort = p
                break
            }
        }
        if let feedPort {
            line(.ok, "本机接口", "http://127.0.0.1:\(feedPort)/quota.json 可读")
        } else {
            line(.warn, "本机接口", "\(Feed.preferredPort) 起的端口上都没有响应",
                 fix: "菜单栏实例未运行时该接口不存在；控件会显示「接口不可达」")
        }

        let widget = Bundle.main.resourceURL?.appending(path: "widget.js")
        if let widget, FileManager.default.fileExists(atPath: widget.path) {
            line(.ok, "控件脚本", widget.path)
        } else {
            line(.warn, "控件脚本", "应用包里没有 widget.js",
                 fix: "重新执行 ./scripts/install.sh；开发目录下可用 MIRAQUOTA_WIDGET 指定路径")
        }

        let s = Injector.status()
        guard let port = s.port else {
            line(.warn, "调试端口", "9333 / 9222 上都没有 CDP 端点",
                 fix: "用 ./scripts/mirasim-debug.sh 重启 Mirasim（会带 --remote-debugging-port）")
            return
        }
        line(.ok, "调试端口", "\(port) 上有 CDP 端点")
        line(s.live > 0 ? .ok : .warn, "注入状态",
             "\(s.live)/\(s.targets) 个页面已带控件",
             fix: s.live == 0 ? "菜单栏实例每 10 秒巡检一次，稍等或看 ~/.miraquota/agent.log" : nil)
    }

    private static func fetch(_ url: String) -> Data? {
        guard let u = URL(string: url) else { return nil }
        var request = URLRequest(url: u)
        request.timeoutInterval = 2
        var out: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { out = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        return out
    }

    private static func checkFallback() {
        let known = AnchorStore().lastKnown
        if known.anchors.isEmpty {
            line(.warn, "窗口锚点", "尚未落盘",
                 fix: "连接 Mirasim 成功一次即会写入；在此之前只能按滚动窗口估算")
            return
        }
        let age = Date().timeIntervalSince(known.capturedDate)
        let desc = known.anchors.map { a -> String in
            let b = a.window(at: Date())
            let end = b.map { Self.stamp.string(from: $0.end) } ?? "-"
            return "\(a.label) 下次重置 \(end)"
        }.joined(separator: " · ")
        line(age < 30 * 86400 ? .ok : .warn, "窗口锚点",
             "\(Formatting.age(age))前采集 · \(desc)",
             fix: age >= 30 * 86400 ? "锚点过老，滚动误差累积，已不再采信" : nil)
        line(.ok, "落盘", Paths.anchorState.path)
    }

    private static func checkAgent() {
        let plist = Paths.home.appending(path: "Library/LaunchAgents/local.miraquota.plist")
        guard FileManager.default.fileExists(atPath: plist.path) else {
            line(.warn, "开机自启", "未安装", fix: "运行 ./scripts/install.sh 安装 LaunchAgent")
            return
        }
        // 只看 plist 在不在不够：作业可能已注册却没运行，或根本没注册成功。
        let out = shell("/bin/launchctl", ["print", "gui/\(getuid())/local.miraquota"])
        if out.contains("state = running") {
            line(.ok, "开机自启", "LaunchAgent 运行中 · \(plist.path)")
        } else if out.isEmpty {
            line(.bad, "开机自启", "plist 存在但作业未注册",
                 fix: "重新运行 ./scripts/install.sh")
        } else {
            line(.bad, "开机自启", "作业已注册但未运行",
                 fix: "查看 ~/.miraquota/agent.log，然后重新运行 ./scripts/install.sh")
        }
    }

    private static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: 输出

    private static func section(_ title: String) {
        print("\u{001B}[2m\(title)\u{001B}[0m")
    }

    private static func line(_ mark: Mark, _ key: String, _ value: String, fix: String? = nil) {
        switch mark {
        case .bad: failures += 1
        case .warn: warnings += 1
        case .ok: break
        }
        let color = mark == .ok ? "32" : (mark == .warn ? "33" : "31")
        print("  \u{001B}[\(color)m\(mark.rawValue)\u{001B}[0m \(pad(key, 14))\(value)")
        if let fix { print("    \u{001B}[2m→ \(fix)\u{001B}[0m") }
    }

    /// 终端里 CJK 占两列，按显示宽度补齐才能对齐。
    private static func pad(_ s: String, _ width: Int) -> String {
        let w = s.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x2E80 ? 2 : 1) }
        return s + String(repeating: " ", count: max(1, width - w))
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}
