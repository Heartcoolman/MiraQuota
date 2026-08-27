import SwiftUI
import AppKit
import Combine

/// Dock 应用的主窗口。菜单栏弹层受高度约束，只放最紧的几行；这里不受限，
/// 故按分区铺开：额度窗口的完整读数、按模型与按会话的速度、自检结论、路径与动作。
///
/// 数据同源于 `QuotaEngine`，与弹层、客户端控件读的是同一份 `report`，
/// 不另起采集：多一路采集就会多一份与另外两处对不上的数字。
struct MainWindow: View {
    @ObservedObject var engine: QuotaEngine
    let port: Int?

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "额度"
        case speed = "速度"
        case doctor = "自检"
        case about = "关于"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .overview: return "gauge.with.dots.needle.67percent"
            case .speed: return "bolt.horizontal"
            case .doctor: return "stethoscope"
            case .about: return "info.circle"
            }
        }
    }

    @State private var tab: Tab = .overview
    @State private var now = Date()
    @State private var ticker: AnyCancellable?

    var body: some View {
        NavigationSplitView {
            // 用 ForEach + tag 而不是 `List(data, selection:)`：后者把选中值绑成元素的
            // id（String），与 `$tab`（Tab）不是同一类型，编译得过但点了不换页。
            List(selection: $tab) {
                ForEach(Tab.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 220)
        } detail: {
            Group {
                switch tab {
                case .overview: OverviewPane(engine: engine, now: now)
                case .speed: SpeedPane(engine: engine, now: now)
                case .doctor: DoctorPane(port: port)
                case .about: AboutPane(engine: engine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("MiraQuota")
            .navigationSubtitle(tab.rawValue)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        engine.refresh()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .help("向 Mirasim 要一次新数据")
                }
            }
        }
        .onAppear {
            // 倒计时与「多久之前」逐秒变动，定时器只在窗口可见期间存在。
            ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
                .sink { now = $0 }
        }
        .onDisappear { ticker = nil }
    }
}

// MARK: - 额度

private struct OverviewPane: View {
    @ObservedObject var engine: QuotaEngine
    let now: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                StatusStrip(report: engine.report, now: now)

                if let notice = engine.report.accountNotice {
                    Notice(text: notice)
                }
                if let detail = engine.report.state.detail {
                    Notice(text: detail)
                }

                if engine.report.windows.isEmpty {
                    Placeholder(text: "还没有窗口数据。Mirasim 未运行时按锚点推算，"
                                + "锚点也没有时要等第一次采集。")
                } else {
                    ForEach(Array(engine.report.windows.enumerated()), id: \.element.label) { index, w in
                        WindowCard(window: w, now: now,
                                   measured: engine.report.state.isMeasured, primary: index == 0)
                    }
                }

                MetaGrid(report: engine.report, pricing: engine.pricingSource)
            }
            .padding(18)
            .frame(maxWidth: 620, alignment: .leading)
        }
    }
}

/// 顶部状态条：通道档位、采集时刻、在途请求。弹层把这三样挤在一行里，
/// 这里分开写，`state` 的含义直接给出而不是只给一个词。
private struct StatusStrip: View {
    let report: QuotaReport
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(spacing: 5) {
                Circle().fill(tone).frame(width: 7, height: 7)
                Text(report.state.label).font(.system(size: 13, weight: .semibold))
            }
            Text(explain)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(Formatting.age(now.timeIntervalSince(report.capturedAt)) + "前采集")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var tone: Color {
        report.state.isMeasured ? Color.okTone : Color.warnTone
    }

    private var explain: String {
        report.state.isMeasured
            ? "百分比来自 Mirasim 的实测读数"
            : "百分比为本地推算，随实测到达即刻校正"
    }
}

/// 页脚那几项元信息在弹层里挤成一行，这里按键值铺开。
private struct MetaGrid: View {
    let report: QuotaReport
    let pricing: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("口径").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                if let unit = report.unitPriceUSD {
                    row("满额", "回归标定优先 · 兜底 额度点 × $" + String(format: "%.6f", unit))
                }
                row("账本", "\(report.bucketCount) 分钟桶 · 本进程新增 \(report.newRecords) 条 · \(pricing)")
                row("线路", [report.mode, report.host, report.relayStatus]
                        .filter { !$0.isEmpty && $0 != "-" }.joined(separator: " · "))
            }
        }
        .padding(.top, 2)
    }

    private func row(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 速度

private struct SpeedPane: View {
    @ObservedObject var engine: QuotaEngine
    let now: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let speed = engine.report.speed {
                    SpeedCard(report: speed, now: now)

                    if speed.sessions.isEmpty {
                        Placeholder(text: "按会话分行需要逐请求实测样本。未注入 OTel env 的会话"
                                    + "只进模型行，不进会话行。")
                    } else {
                        SessionTable(rows: speed.sessions, now: now)
                    }

                    Provenance(speed: speed)
                } else {
                    Placeholder(text: "近期没有请求，或账本与实测两路都还没有样本。")
                }
            }
            .padding(18)
            .frame(maxWidth: 620, alignment: .leading)
        }
    }
}

/// 按会话分行。同一台机器上并行开着几个 Claude Code 窗口时，模型行会被
/// 请求最频繁的那个窗口顶掉，这张表按会话拆开，各窗口互不遮盖。
private struct SessionTable: View {
    let rows: [SessionSpeedRow]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按会话").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(rows, id: \.session) { r in
                    GridRow {
                        Text(r.session.prefix(8))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .help(r.session)
                        Text(r.model)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(detail(r))
                            .font(.system(size: 10.5).monospacedDigit())
                            .lineLimit(1)
                        Text(Formatting.age(now.timeIntervalSince(r.latestAt)) + "前")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
        .cardSkin()
    }

    private func detail(_ r: SessionSpeedRow) -> String {
        let head = r.ttft.map { String(format: "首 %.1fs · ", $0) } ?? ""
        return head + (r.rate.map { String(format: "%.0f tok/s", $0) } ?? "—")
    }
}

/// 速度这一页的数字出处。两条路径给出的含义不同，混着看会读错，故写明。
private struct Provenance: View {
    let speed: SpeedReport

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("出处").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            ForEach(notes, id: \.self) { note in
                Text("· " + note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var notes: [String] {
        var out = [
            "实测行（首 token 不带 ≈）：Claude Code 的 OTel trace 逐请求上报首 token 与时长",
            "回归行（首 token 带 ≈）：网关账本只有总时长，首 token 取 48 小时样本的回归截距",
            "出字速度取最近 \(speed.recentCount) 次请求按 token 加权，测的是客户端观测到的投递速率",
            "近期通过筛选的请求 \(speed.sampleTotal) 次",
        ]
        if let m = speed.measuredTurnTTFB {
            out.append(String(format: "Mirasim 整轮首字节中位 %.1fs（%d 次，口径是整轮，仅作量级对照）",
                              m.median, m.count))
        }
        return out
    }
}

// MARK: - 自检

private struct DoctorPane: View {
    let port: Int?
    @State private var result: Doctor.Result?
    @State private var running = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button(running ? "检查中…" : "重新检查") { start() }
                        .disabled(running)
                    if let r = result {
                        Text(r.summary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(r.failures > 0 ? Color.warnTone : .secondary)
                    }
                }

                if result == nil && !running {
                    Placeholder(text: "自检会逐项探测数据链路：Mirasim 通道、本地账本、"
                                + "标定与退路、客户端控件、常驻。要发几次本地请求，耗时数秒。")
                }

                ForEach(result?.sections ?? []) { section in
                    if !section.lines.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            ForEach(section.lines) { line in
                                DoctorRow(line: line)
                            }
                        }
                        .cardSkin()
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onAppear { if result == nil { start() } }
    }

    /// 自检里有本地网络请求，放到后台队列；主线程跑会把窗口卡住数秒。
    private func start() {
        guard !running else { return }
        running = true
        let port = port
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Doctor.inspect(port: port)
            DispatchQueue.main.async {
                result = r
                running = false
            }
        }
    }
}

private struct DoctorRow: View {
    let line: Doctor.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.mark.rawValue)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tone)
                .frame(width: 12)
            Text(line.key)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.value)
                    .font(.system(size: 11.5).monospacedDigit())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = line.fix {
                    Text("→ " + fix)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var tone: Color {
        switch line.mark {
        case .ok: return .okTone
        case .warn: return .warnTone
        case .bad: return .red
        }
    }
}

// MARK: - 关于

private struct AboutPane: View {
    @ObservedObject var engine: QuotaEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MiraQuota").font(.system(size: 18, weight: .semibold))
                    Text("Mirasim 额度与速度估算 · \(version)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("路径").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    ForEach(paths, id: \.0) { key, url in
                        HStack(spacing: 8) {
                            Text(key)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .frame(width: 68, alignment: .leading)
                            Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer(minLength: 4)
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                .buttonStyle(.link)
                                .font(.system(size: 11))
                        }
                    }
                }
                .cardSkin()

                VStack(alignment: .leading, spacing: 8) {
                    Text("退让阶梯").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    Text("精确 → 实时 → 过期实测 → 锚点推算（Mirasim 关闭也可用）→ 本地滚动窗口。"
                         + "任何一级都仍有输出；当前处于「\(engine.report.state.label)」。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .cardSkin()

                HStack(spacing: 10) {
                    Button("退出 MiraQuota") { NSApplication.shared.terminate(nil) }
                    Text("退出后菜单栏图标与客户端控件一并消失，登录时由 LaunchAgent 再拉起。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(18)
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发构建"
        return "v" + v
    }

    private var paths: [(String, URL)] {
        [("状态", Paths.stateDir),
         ("实测样本", Paths.measuredDir),
         ("网关账本", Paths.mirasimInsights),
         ("会话记录", Paths.claudeProjects)]
    }
}

// MARK: - 公用小件

private struct Notice: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Color.warnTone)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.warnTone.opacity(0.13)))
    }
}

private struct Placeholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.045)))
    }
}
