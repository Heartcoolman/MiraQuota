import SwiftUI
import Combine

/// 语义色随外观取不同深浅：系统 `.orange`/`.green` 是亮色系，浅色外观下盖在
/// 磨砂材质上对比度不足；取值与 JS 控件浅色主题的 `--warn`/`--ok` 一致。
extension Color {
    static let warnTone = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1.00, green: 0.69, blue: 0.30, alpha: 1)   // #ffb04d
            : NSColor(srgbRed: 0.70, green: 0.42, blue: 0.02, alpha: 1)   // #b26a05
    })
    static let okTone = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.30, green: 0.83, blue: 0.44, alpha: 1)   // #4cd471
            : NSColor(srgbRed: 0.12, green: 0.62, blue: 0.31, alpha: 1)   // #1e9e50
    })
}

struct PanelView: View {
    @ObservedObject var engine: QuotaEngine
    @State private var now = Date()
    /// 倒计时的定时器只在弹层可见期间存在。常驻期间挂着一个每秒触发的 publisher
    /// 只为刷新看不见的界面，属白烧。
    @State private var ticker: AnyCancellable?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header

            if let notice = engine.report.accountNotice {
                banner(notice)
            }
            if let detail = engine.report.state.detail {
                banner(detail)
            }

            if engine.report.windows.isEmpty {
                empty
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(engine.report.windows.enumerated()), id: \.element.label) { index, w in
                        WindowCard(window: w, now: now, measured: engine.report.state.isMeasured,
                                   primary: index == 0)
                    }
                }
            }

            if let speed = engine.report.speed {
                SpeedCard(report: speed, now: now)
            }

            footer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(width: 340)
        // NSPopover 默认材质只做模糊、不做亮度校正，暗背景透进来会压暗整个面板。
        // 系统菜单的 .menu 材质自带向主题底色的亮度提升（浅色外观推白、深色推黑），
        // 深色壁纸下仍是浅灰模糊底，磨砂感与可读性同时保住；纯色垫层则会盖掉模糊。
        .background(FrostBackground())
        .onAppear {
            now = Date()
            ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
                .sink { now = $0 }
        }
        .onDisappear {
            ticker?.cancel()
            ticker = nil
        }
    }

    // MARK: 头

    private var header: some View {
        HStack(spacing: 8) {
            Text("额度")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            statusChip
            Button { engine.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("重新向 Mirasim 查询")
        }
    }

    private var statusChip: some View {
        HStack(spacing: 4) {
            Circle().fill(statusTone).frame(width: 5, height: 5)
            Text(engine.report.state.label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(statusTone.opacity(0.12)))
        .animation(.smooth(duration: 0.3), value: engine.report.state)
        .help(engine.report.state.detail ?? "数据来自 Mirasim 本地通道")
    }

    private var statusTone: Color {
        switch engine.report.state {
        case .exact: return .okTone
        case .live: return .mint
        case .stale: return .yellow
        case .reckoned: return .warnTone
        case .mismatch: return .red
        case .local, .connecting: return .gray
        }
    }

    private func banner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10.5))
                .foregroundStyle(statusTone)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 6).fill(statusTone.opacity(0.08)))
    }

    private var empty: some View {
        Text("等待 Mirasim 回传额度…")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
    }

    // MARK: 脚

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            if let price = engine.report.unitPriceUSD {
                metaRow("满额", String(format: "回归标定优先 · 兜底 额度点 × $%.6f", price))
            } else if let notice = engine.report.unitPriceNotice {
                metaRow("满额", notice)
            } else if !engine.report.windows.isEmpty {
                metaRow("标定", calibrationLine)
            }
            metaRow("账本", "\(engine.report.bucketCount) 分钟桶 · 新增 \(engine.report.newRecords) 条 · \(engine.pricingSource)")
            HStack(spacing: 5) {
                Text(Self.clock.string(from: engine.report.capturedAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("\(modeLabel) \(engine.report.host) · \(engine.report.relayStatus)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("窗口") {
                    NotificationCenter.default.post(name: AppDelegate.openWindowRequest, object: nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                // 与「退出」拉开距离：两者紧邻时，偏几个点的点击会把常驻进程关掉。
                .padding(.trailing, 7)
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 1)
        }
    }

    private func metaRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 25, alignment: .leading)
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var calibrationLine: String {
        engine.report.windows
            .map { "\($0.label) \($0.sampleCount) 观测 \($0.confidence.label)" }
            .joined(separator: " · ")
    }

    private var modeLabel: String {
        switch engine.report.mode {
        case "cloud": return "云端"
        case "local": return "本地"
        case "smart": return "智能"
        default: return engine.report.mode
        }
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// 面板底衬：取系统菜单同款材质，见 body 处说明。
private struct FrostBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - 窗口卡片

/// 单个窗口：金额、百分比、带均速游标的进度条、重置倒计时。
/// 金额主行按点数口径折算（`满额 × 百分比`），与百分比、进度条同分母；
/// 本机账本支出落到副行，两者的差值反映当前窗口的用量构成与标定期不同。
struct WindowCard: View {
    let window: WindowReport
    let now: Date
    let measured: Bool
    let primary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Formatting.windowTitle(window.label))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .leading)
                Text(headline.text)
                    .font(.system(size: primary ? 21 : 19, weight: .semibold, design: .rounded).monospacedDigit())
                    // 数字过渡只挂在按报告刷新的字段上；倒计时那类秒级走动的不挂，否则每秒抖一次。
                    .contentTransition(.numericText(value: headline.value))
                    .animation(.smooth(duration: 0.35), value: headline.value)
                Text(quotaSuffix)
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                percentBadge
            }

            ProgressBar(percent: window.usedPercent, marker: window.pacePercent, tone: tone)

            HStack(spacing: 6) {
                Text(leftText)
                    .font(.system(size: 10.5, weight: etaSoon ? .medium : .regular))
                    .foregroundStyle(etaSoon ? Color.warnTone : Color.secondary)
                    .padding(.horizontal, etaSoon ? 5 : 0)
                    .padding(.vertical, etaSoon ? 1.5 : 0)
                    // 纯色文字盖在磨砂材质上，色相稍暗时几乎读不出来；打满临近时才加底色垫一层，够不上阈值时不占地方。
                    .background { if etaSoon { Capsule().fill(Color.warnTone.opacity(0.14)) } }
                Spacer(minLength: 4)
                Text(resetText)
                    // 时钟形式的倒计时用等宽稳住宽度；「5 天后重置」这类走等宽会拉出空隙。
                    .font(.system(size: 10.5, design: resetText.contains(":") ? .monospaced : .default))
                    .foregroundStyle(.tertiary)
            }

            if let sub = subText {
                Text(sub)
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .cardSkin(emphasis: primary)
        .help(hint)
    }

    /// 主行口径。折算值优先；满额不可用而点数在手时改用点数，
    /// 不把此刻已判定不可信的账本支出抬到主行；两者都没有才退回账本。
    private enum Headline {
        case scaled(Double)
        case points(Double)
        case ledger(Double)
    }

    private var headline: (text: String, value: Double) {
        switch headlineKind {
        case .scaled(let v), .ledger(let v): return (Formatting.usd(v), v)
        case .points(let v): return ("\(Formatting.kilo(v)) 点", v)
        }
    }

    private var headlineKind: Headline {
        if let scaled = window.scaledSpentUSD { return .scaled(scaled) }
        if window.fullUSD == nil, let p = window.points { return .points(p.used) }
        return .ledger(window.spentUSD)
    }

    private var percentBadge: some View {
        Text((window.inferred ? "≈" : "") + String(format: "%.1f%%", window.usedPercent))
            .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(tone)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tone.opacity(0.13)))
            .contentTransition(.numericText(value: window.usedPercent))
            .animation(.smooth(duration: 0.35), value: window.usedPercent)
    }

    /// 满额部分。未收敛的标定值标 `~`，避免把推断值读成确定值。
    private var quotaSuffix: String {
        guard let full = window.fullUSD else { return "/ 标定中" }
        let prefix = window.confidence == .high ? "" : "~"
        return "/ \(prefix)\(Formatting.usd(full))"
    }

    private var tone: Color {
        if window.usedPercent >= 95 { return .red }
        if window.usedPercent >= 80 { return .warnTone }
        return window.inferred ? .secondary : .accentColor
    }

    /// 剩余额度与按点增速外推的打满时刻；两者缺失时退回均速偏离。
    private var leftText: String {
        if let rem = window.remainingUSD {
            let mark = window.confidence == .high ? "" : "~"
            var text = "余 \(mark)\(Formatting.usd(rem))"
            if let eta = window.etaSeconds {
                if let reset = window.resetAt, now.addingTimeInterval(eta) >= reset {
                    text += " · 到重置不满"
                } else {
                    text += " · ≈\(Formatting.duration(eta))后打满"
                }
            }
            return text
        }
        guard let pace = window.pacePercent, let delta = window.paceDelta else {
            return window.resetAt == nil ? "滚动窗口" : "—"
        }
        let word = delta >= 0 ? "超出均速" : "低于均速"
        return String(format: "均速 %.0f%% · %@ %.1f%%", pace, word, abs(delta))
    }

    /// 打满早于重置时才把这一行标成橙色；否则它只是个平静的余额。
    private var etaSoon: Bool {
        guard let eta = window.etaSeconds, window.remainingUSD != nil else { return false }
        guard let reset = window.resetAt else { return true }
        return now.addingTimeInterval(eta) < reset
    }

    private var subText: String? {
        var bits: [String] = []
        // 主行已经是账本值时不再重复，其余情形都把账本支出留在副行。
        if case .ledger = headlineKind {} else {
            bits.append("账本 \(Formatting.usd(window.spentUSD))")
        }
        if let p = window.points {
            bits.append("\(Formatting.kilo(p.used))/\(Formatting.kilo(p.budget)) 点")
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private var resetText: String {
        guard let reset = window.resetAt else { return "无固定重置" }
        let remaining = reset.timeIntervalSince(now)
        guard remaining > 0 else { return "即将重置" }
        let text = Formatting.countdown(remaining)
        // 数字与汉字之间留空格，汉字之间不留。
        return text + (text.last?.isNumber == true ? " " : "") + "后重置"
    }

    private var hint: String {
        var lines = ["主行为按点数口径折算的已用额度（满额 × 百分比）"]
        lines.append("本机 API 等价支出为 \(Formatting.usd(window.spentUSD))，两者口径不同")
        if let p = window.points {
            lines.append(String(format: "额度点 %.1f / %.0f，取自路由端口的 /v1/limits", p.used, p.budget))
        }
        if window.inferred {
            lines.append("百分比由本机支出推算，未计入共享额度中他人的占用")
        } else if !measured {
            lines.append("为最后一次实测值")
        }
        if let reset = window.resetAt {
            lines.append("重置于 " + PanelView.clock.string(from: reset))
        }
        return lines.joined(separator: "\n")
    }
}

/// 卡片皮，窗口卡与速度卡共用。主窗口底色重一档。
extension View {
    func cardSkin(emphasis: Bool = false) -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(emphasis ? 0.075 : 0.045))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            )
    }
}

// MARK: - 速度卡片

/// 按模型分行的出字速度与首 token 等待。出字速度只看最近几次请求，反映当下；
/// 首 token 无法直接测量，由「时长 ≈ 首字等待 + 输出量 ÷ 出字速度」回归得出，故标 `≈`。
struct SpeedCard: View {
    let report: SpeedReport
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("速度")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let oldest = report.inflightSince.first {
                    // 在途请求来自诊断事件流，请求发出瞬间即可见；出字速度仍要等落账。
                    HStack(spacing: 4) {
                        Circle().fill(Color.okTone).frame(width: 5, height: 5)
                        Text("生成中 \(report.inflightSince.count) 条 · 已 \(Int(now.timeIntervalSince(oldest))) 秒")
                            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    }
                    .foregroundStyle(Color.okTone)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.okTone.opacity(0.13)))
                } else {
                    Text("最近 \(report.recentCount) 次")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }

            if report.rows.isEmpty, report.inflightSince.isEmpty {
                Text("近期无请求（\(report.sampleTotal) 次）")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(report.rows, id: \.model) { row in
                    // 四列定宽：模型名与数值列给最小宽度，偏离标与时刻才会逐行对齐。
                    // 各段一律单行不折——数值折行会撑高行高，并把右侧两列推成参差。
                    HStack(spacing: 6) {
                        Text(row.model)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 60, alignment: .leading)
                        Text(Self.detail(row))
                            .font(.system(size: 10.5).monospacedDigit())
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: 112, alignment: .leading)
                        // 闸门由 SpeedStats 统一把关（样本 ≥3、幅度进 25% 出 18%、
                        // 当下值不超过基准三倍），两个显示面不各自定阈值。
                        if let drift = row.notableDrift {
                            Text(String(format: "%@%.0f%%", drift > 0 ? "快" : "慢", abs(drift)))
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(drift < 0 ? Color.warnTone : Color.okTone)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill((drift < 0 ? Color.warnTone : Color.okTone).opacity(0.13)))
                        }
                        Spacer(minLength: 4)
                        // 显示样本新鲜度而非条数：数字不动多半是没有新请求，
                        // 把这件事说出来，免得看的人以为界面卡住了。
                        Text(Formatting.age(now.timeIntervalSince(row.latestAt)) + "前")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
        .cardSkin()
        .help(hint)
    }

    private static func detail(_ row: SpeedRow) -> String {
        guard let rate = row.rate else {
            return String(format: "端到端 %.0f tok/s", row.endToEnd)
        }
        // 实测行的首 token 是逐请求测量值的中位数，不带 ≈；回归行才是截距估计。
        // 标签取 `首`（不写成 `首 token`）：340pt 面板宽下，带偏离标的行会因这 6 个字符折行。
        let head = row.ttft.map { String(format: row.measured ? "首 %.1fs · " : "首 ≈%.1fs · ", $0) } ?? ""
        return head + String(format: "%.0f tok/s", rate)
    }

    private var hint: String {
        var lines = [
            "出字速度取最近 \(report.recentCount) 次请求，按 token 加权，并对显示值做一阶平滑",
            "实测行（首 token 不带 ≈）：Claude Code OTel trace 逐请求上报首 token 与时长",
            "回归行（首 token 带 ≈）：账本只有总时长，首 token 取 48 小时样本的回归截距",
            "常态基准为同路径样本的出字速度；端到端为输出量除以总时长，含首字等待",
        ]
        if let m = report.measuredTurnTTFB {
            lines.append(String(format: "Mirasim 实测整轮首字节 中位 %.1fs（%d 次）· 口径为整轮而非单次请求，仅作量级对照", m.median, m.count))
        }
        lines.append("数据源 ~/.miraquota/measured 与 ~/.mirasim/insights，token 未回填的请求不计入")
        return lines.joined(separator: "\n")
    }
}

struct ProgressBar: View {
    let percent: Double
    let marker: Double?
    let tone: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(LinearGradient(colors: [tone.opacity(0.65), tone],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, w * min(percent, 100) / 100))
                    .animation(.smooth(duration: 0.5), value: percent)
                if let marker, marker > 1, marker < 99 {
                    // 均速游标：用量条越过它表示快于线性消耗。
                    Capsule()
                        .fill(Color.primary.opacity(0.5))
                        .frame(width: 2, height: 6)
                        .offset(x: min(w - 2, w * marker / 100))
                        .animation(.smooth(duration: 0.5), value: marker)
                }
            }
        }
        .frame(height: 5)
    }
}

// MARK: - 格式

enum Formatting {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    static func usd(_ v: Double) -> String {
        if v >= 1000 { return "$" + (grouped.string(from: v as NSNumber) ?? String(Int(v))) }
        if v >= 100 { return String(format: "$%.0f", v) }
        return String(format: "$%.1f", v)
    }

    /// 额度点的紧凑写法。六位数字并排会把底行挤满，量级本身够读。
    static func kilo(_ v: Double) -> String {
        if v >= 100_000 { return String(format: "%.0fk", v / 1000) }
        if v >= 10_000 { return String(format: "%.1fk", v / 1000) }
        return String(format: "%.0f", v)
    }

    static func windowTitle(_ label: String) -> String {
        switch label.lowercased() {
        case "5h": return "5 小时"
        case "7d": return "7 天"
        case "7d_fable": return "7 天 · Fable"
        default: return label
        }
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s >= 86400 {
            let d = s / 86400, h = (s % 86400) / 3600
            return h > 0 ? "\(d) 天 \(h) 小时" : "\(d) 天"
        }
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// 打满外推的时长，单位与倒计时统一。
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 5400 { return String(format: "%.0f 分钟", seconds / 60) }
        if seconds < 86400 { return String(format: "%.1f 小时", seconds / 3600) }
        return String(format: "%.1f 天", seconds / 86400)
    }

    /// 龄期的口语化表述，用于说明数据有多旧。
    static func age(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 90 { return "\(s) 秒" }
        if s < 5400 { return "\(s / 60) 分钟" }
        if s < 172_800 { return "\(s / 3600) 小时" }
        return "\(s / 86400) 天"
    }
}
