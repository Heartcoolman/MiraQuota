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
        // 宽度由速度卡最宽的一行定：模型名 78 + 指标 132 + 偏离标 44 + 时刻 46，
        // 加列间距约 316pt，再加面板与卡片的左右内边距 44pt。窄于此值这一行会互相压住。
        .frame(width: 365)
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
            if let rates = Formatting.rateLine(engine.report.rates) {
                metaRow("扣点", rates)
            } else if let price = engine.report.unitPriceUSD {
                metaRow("满额", String(format: "回归标定优先 · 兜底 额度点 × $%.6f", price))
            } else if let notice = engine.report.unitPriceNotice {
                metaRow("满额", notice)
            } else if !engine.report.windows.isEmpty {
                metaRow("标定", calibrationLine)
            }
            // 与客户端控件同为三行键值，时刻与按钮另起一行。
            metaRow("账本", "\(engine.report.bucketCount) 分钟桶 · \(engine.pricingSource)")
            metaRow("线路", "\(modeLabel) \(engine.report.host) · \(engine.report.relayStatus)")
            HStack(spacing: 5) {
                Text(Self.clock.string(from: engine.report.capturedAt))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
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
            .padding(.top, 4)
        }
    }

    private func metaRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .leading)
            // 单行截尾，全文挂在悬浮提示上：页脚折行会把整个弹层撑高一截。
            Text(value)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(value)
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

    /// 字号与层级对齐客户端控件（`widget/miraquota-widget.js` 的 `.crow` / `.foot` / `.alt` / `.sub`）：
    /// 金额 16/14pt、满额浅色小字，余额行只给打满时刻挂徽标，重置写作「重置 X」。
    /// 此前金额 21/19pt、整行橙底，与控件并排看时显得拥挤（09-26 用户对照截图）。
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                // 模型标签放在标题下方：挤进卡头会把金额与满额压到折行（09-26 截图 `$1,29` / `8`）。
                VStack(alignment: .leading, spacing: 3) {
                    Text(Formatting.windowTitle(window.label))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let head = window.head { modelChip(head) }
                }
                .frame(width: 74, alignment: .leading)
                Text(headline.text)
                    .font(.system(size: primary ? 16.5 : 14, weight: .bold).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
                    // 数字过渡只挂在按报告刷新的字段上；倒计时那类秒级走动的不挂，否则每秒抖一次。
                    .contentTransition(.numericText(value: headline.value))
                    .animation(.smooth(duration: 0.35), value: headline.value)
                Text(quotaSuffix)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 4)
                percentBadge
            }

            ProgressBar(percent: window.usedPercent, marker: window.pacePercent, tone: tone)
                .padding(.top, 7)

            HStack(spacing: 4) {
                Text(leftText)
                    .foregroundStyle(.secondary)
                if let eta = etaPart {
                    Text(eta.text)
                        .foregroundStyle(eta.soon ? Color.warnTone : Color.secondary)
                        .padding(.horizontal, eta.soon ? 4 : 0)
                        // 纯色文字盖在磨砂材质上，色相稍暗时几乎读不出来；只有打满早于重置时才垫一层底色。
                        .background { if eta.soon { RoundedRectangle(cornerRadius: 4).fill(Color.warnTone.opacity(0.14)) } }
                }
                Spacer(minLength: 4)
                Text(resetText)
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 10).monospacedDigit())
            .lineLimit(1)
            .padding(.top, 6)

            if let alt = altLine {
                // 放不下时折到第二行，不截断：被截掉的正是要比较的余额。
                alt
                    .font(.system(size: 9.5).monospacedDigit())
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            if let mix = mixLine {
                mix
                    .font(.system(size: 9.5).monospacedDigit())
                    .lineLimit(1)
                    .padding(.top, 2)
            }

            if let sub = subText {
                Text(sub)
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.top, 3)
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

    /// 卡头模型标签：当前在用的模型着强调色，推算值与待测值挂「估」「待测」。
    private func modelChip(_ m: ModelQuota) -> some View {
        (Text(m.name) + (m.tag.map { Text(" " + $0).foregroundColor(.warnTone) } ?? Text("")))
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(m.current ? Color.accentColor : Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill((m.current ? Color.accentColor : Color.secondary).opacity(0.13)))
            .truncationMode(.tail)
            .frame(maxWidth: 78, alignment: .leading)
    }

    private var headlineKind: Headline {
        // 分模型：美元按卡头模型的每美元扣点折算；该模型扣点率待测时主行改点数。
        if let head = window.head {
            if let v = head.usedAsUSD { return .scaled(v) }
            if let p = window.points { return .points(p.used) }
        }
        if let scaled = window.scaledSpentUSD { return .scaled(scaled) }
        if window.fullUSD == nil, let p = window.points { return .points(p.used) }
        return .ledger(window.spentUSD)
    }

    private var percentBadge: some View {
        Text((window.inferred ? "≈" : "") + String(format: "%.1f%%", window.usedPercent))
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(tone)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tone.opacity(0.13)))
            .contentTransition(.numericText(value: window.usedPercent))
            .animation(.smooth(duration: 0.35), value: window.usedPercent)
    }

    /// 满额部分。未收敛的标定值标 `~`，避免把推断值读成确定值。
    private var quotaSuffix: String {
        if let head = window.head {
            if let full = head.fullUSD { return "/ ~\(Formatting.usd(full))" }
            if let p = window.points { return "/ \(Formatting.kilo(p.budget)) 点" }
        }
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
        if window.head != nil || window.remainingUSD != nil {
            var text: String
            if let head = window.head {
                text = (head.remainingUSD.map { "余 ~\(Formatting.usd($0)) · " } ?? "余 ")
                    + "\(Formatting.kilo(head.remainingPoints)) 点"
                if let cap = head.cappedBy { text += " · 受\(Formatting.windowTitle(cap))限" }
            } else {
                let mark = window.confidence == .high ? "" : "~"
                text = "余 \(mark)\(Formatting.usd(window.remainingUSD ?? 0))"
            }
            return text
        }
        guard let pace = window.pacePercent, let delta = window.paceDelta else {
            return window.resetAt == nil ? "滚动窗口" : "—"
        }
        let word = delta >= 0 ? "超出均速" : "低于均速"
        return String(format: "均速 %.0f%% · %@ %.1f%%", pace, word, abs(delta))
    }

    /// 按点增速外推的打满时刻。打满早于重置才挂橙色徽标；否则只是一句平静的「到重置不满」。
    private var etaPart: (text: String, soon: Bool)? {
        guard let eta = window.etaSeconds, window.head != nil || window.remainingUSD != nil else { return nil }
        if let reset = window.resetAt, now.addingTimeInterval(eta) >= reset { return ("· 到重置不满", false) }
        return ("≈\(Formatting.duration(eta))后打满", true)
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
        // 各模型实际扣掉的点：两个以上模型有消耗才列。
        let spenders = (window.models ?? []).filter { $0.usedPoints >= 1 }
        if spenders.count >= 2 {
            bits += spenders.prefix(2).map { "\($0.name) \(Formatting.kilo($0.usedPoints))" }
        }
        if let u = window.unattributedPoints, let p = window.points, u >= 0.02 * p.used {
            bits.append("其他 \(Formatting.kilo(u))")
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    /// 按用法：近期混用多个模型时，按各模型支出比例折出的余额。
    private var mixLine: Text? {
        guard window.head != nil, let m = window.mix else { return nil }
        var line = Text("按用法 ").foregroundColor(.secondary.opacity(0.7))
            + Text("~\(Formatting.usd(m.remainingUSD))").foregroundColor(.secondary)
        if m.estimated {
            line = line + Text("\u{00A0}估").font(.system(size: 8.5, weight: .semibold)).foregroundColor(.warnTone)
        }
        // 只列占比最高的两个，其余归「等」：模型一多整行被截，截掉的恰是后面的名字。
        let parts = m.shares.prefix(2).map { "\($0.name) \(Int(($0.share * 100).rounded()))%" }.joined(separator: " · ")
        return line + Text(" · \(m.span) \(parts)\(m.shares.count > 2 ? " 等" : "")").foregroundColor(.secondary.opacity(0.7))
    }

    /// 换用：同一点数池按其余模型各自的扣点率折出的余额，最多三个。「估」「待测」用橙色小字。
    /// 项内用不换行空格：折行只落在各项之间，不把模型名与它的余额拆到两行。
    private var altLine: Text? {
        guard let head = window.head else { return nil }
        let others = Array((window.models ?? []).filter { $0.key != head.key }.prefix(3))
        guard !others.isEmpty else { return nil }
        let nb = { (s: String) in s.replacingOccurrences(of: " ", with: "\u{00A0}") }
        var line = Text("换用 ").foregroundColor(.secondary.opacity(0.7))
        for (i, m) in others.enumerated() {
            if i > 0 { line = line + Text(" · ").foregroundColor(.secondary.opacity(0.6)) }
            line = line + Text(nb(m.name + (m.remainingUSD.map { " ~\(Formatting.usd($0))" } ?? ""))).foregroundColor(.secondary)
            if let tag = m.tag {
                line = line + Text("\u{00A0}" + tag).font(.system(size: 8.5, weight: .semibold)).foregroundColor(.warnTone)
            }
        }
        return line
    }

    private var resetText: String {
        guard let reset = window.resetAt else { return "无固定重置" }
        let remaining = reset.timeIntervalSince(now)
        guard remaining > 0 else { return "即将重置" }
        return "重置 " + Formatting.countdown(remaining)
    }

    private var hint: String {
        if let models = window.models, !models.isEmpty {
            var lines = ["各模型共用同一点数池，美元按各自每美元扣点折算"]
            for m in models {
                let rate = m.rate.map { String(format: "%.1f 点/$", $0) + (m.tag.map { "（\($0)）" } ?? "") } ?? "扣点率待测"
                let left = m.remainingUSD.map { " ≈ \(Formatting.usd($0))" } ?? ""
                lines.append("\(m.current ? "▶ " : "")\(m.name) · \(rate) · 本窗口已扣 \(Formatting.kilo(m.usedPoints)) 点"
                             + " · 账本 \(Formatting.usd(m.usedUSD)) · 余 \(Formatting.kilo(m.remainingPoints)) 点\(left)")
            }
            if let mix = window.mix {
                lines.append(String(format: "按%@用法每 $1 平均扣 %.1f 点，余 ≈ %@：", mix.span, mix.pointsPerUSD,
                                    Formatting.usd(mix.remainingUSD))
                             + mix.shares.map { String(format: "%@ %.1f%%", $0.name, $0.share * 100) }.joined(separator: " · "))
            }
            if let reset = window.resetAt { lines.append("重置于 " + PanelView.clock.string(from: reset)) }
            return lines.joined(separator: "\n")
        }
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
                        Text("生成中 \(report.inflightSince.count) 条 · 已 \(Formatting.elapsed(now.timeIntervalSince(oldest)))")
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
                            .frame(width: 78, alignment: .leading)
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
        // 标签取 `首`（不写成 `首 token`）：365pt 面板宽下，带偏离标的行会因这 6 个字符折行。
        // 有首 token 才能扣除等待时间；否则上面的分支明确显示端到端速度。
        let head = row.ttft.map { String(format: row.measured ? "首 %.1fs · " : "首 ≈%.1fs · ", $0) } ?? ""
        return head + String(format: "出字 %.0f tok/s", rate)
    }

    private var hint: String {
        var lines = [
            "出字速度：扣除首 token 等待后的输出速率；有首 token 时才显示",
            "端到端速度：输出量 ÷ 请求总时长，包含排队、首 token 和流式输出",
            "Claude Code 的 OTel trace 有逐请求首 token；GPT/Codex 网关没有，因此显示端到端速度",
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

    /// 页脚「满额」行：各模型每美元扣点，取前三个有值的。全由本机数据求得，「估」为推算值。
    static func rateLine(_ rates: [ModelRate]) -> String? {
        let known = rates.filter { $0.pointsPerUSD != nil }.prefix(3)
        guard !known.isEmpty else { return nil }
        return known.map { r in
            String(format: "%@ %.0f", r.name, r.pointsPerUSD!) + (r.tag ?? "")
        }.joined(separator: " · ") + " 点/$"
    }

    static func windowTitle(_ label: String) -> String {
        switch label.lowercased() {
        case "5h": return "5 小时"
        case "7d": return "7 天"
        case "7d_fable": return "7 天 · Fable"
        case "7d_claude": return "7 天 · Claude"
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

    /// 在途时长。过 90 秒后纯秒数要心算，改成分秒。
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return s < 90 ? "\(s) 秒" : "\(s / 60) 分 \(s % 60) 秒"
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
