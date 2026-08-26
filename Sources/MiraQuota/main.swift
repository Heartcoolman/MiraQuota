import AppKit
import SwiftUI
import Combine

// MARK: 参数

let arguments = CommandLine.arguments

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    MiraQuota · Mirasim 额度估算

    用法：
      MiraQuota                以菜单栏常驻方式运行
      MiraQuota --once         采集一次并打印，用于自检
      MiraQuota --doctor       逐项检查数据链路，指出断点与处置办法
      MiraQuota --port <N>     指定 Mirasim 本地端口（默认自动发现）

    数据来源：
      额度原始值  Mirasim 路由端口的 /v1/limits，给出已用与总额的额度点数
      额度百分比  退路，Mirasim 本地通道 /mirachannel/ws 的 relay 帧，分辨率 0.1%
      等价支出    ~/.claude/projects 的 transcript 与 ~/.mirasim/insights 的网关账本
      价目表      ~/.mirasim/models-dev-cache.json，缺失时用内置表
      速度实测    Claude Code OTel trace（回环 4319 接收），逐请求首 token 与时长
      满额        额度点 × 单价（单价由同期支出 ÷ 已用点数反推）；端点不可读时改由
                  「同期支出 ÷ 百分比增量」反推，样本落在 ~/.miraquota

    通道不可用时按五级阶梯退让，任何一级都仍有输出：
      精确 → 实时 → 过期实测 → 锚点推算（Mirasim 关闭也可用）→ 本地滚动窗口
    """)
    exit(0)
}

let portOverride: Int? = {
    guard let i = arguments.firstIndex(of: "--port"), i + 1 < arguments.count else { return nil }
    return Int(arguments[i + 1])
}()

if arguments.contains("--doctor") {
    exit(Doctor.run(port: portOverride))
}

if arguments.contains("--once") {
    let engine = QuotaEngine(port: portOverride)
    let code = withExtendedLifetime(engine) { engine.runOnce() }
    exit(code)
}

guard InstanceLock.acquire() else {
    FileHandle.standardError.write(Data("MiraQuota 已在运行\n".utf8))
    exit(0)
}

// MARK: 菜单栏宿主

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine: QuotaEngine
    /// 客户端内控件的数据源。Mirasim 渲染进程读不到本地账本，只能由这里喂。
    private let feed = Feed()
    /// Claude Code OTel trace 的接收端，逐请求实测首 token 与时长在此落盘。
    private let otlp = OtlpReceiver()
    private let injector = Injector()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover!
    private var bag = Set<AnyCancellable>()
    /// 外部点击监听。弹层改为自管开合后，需要它来实现「点别处收起」。
    private var outsideClick: Any?
    /// 自有的开合状态。带动画时 `popover.isShown` 在动画期间取值不可靠，
    /// 快速点击会读到过渡态；这个标志在每次转换开始时同步置位，与动画时序无关。
    private var panelOpen = false
    /// 上一次向 relay 要新数据的时刻，用于限流。
    private var lastRefreshAt = Date.distantPast

    init(port: Int?) {
        engine = QuotaEngine(port: port)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.action = #selector(toggle)
        item.button?.target = self
        statusItem = item
        render(engine.report)
        Diag.log("statusItem button=\(item.button != nil) visible=\(item.isVisible) "
                 + "len=\(item.length) policy=\(NSApp.activationPolicy().rawValue) "
                 + "bundle=\(Bundle.main.bundleIdentifier ?? "nil")")

        popover = NSPopover()
        // 不用 .transient：它会在鼠标按下时自行关闭，而按钮动作要到抬起才触发，
        // 快速点击时两者先后翻转，`isShown` 读到的就不是点击时的状态。
        // 改为自管开合，状态始终由本类决定，另配外部点击监听来收起。
        popover.behavior = .applicationDefined
        // 展开动画保留。跟手与否取决于上面的 behavior，与动画无关。
        popover.animates = true
        // 尺寸不预设：`NSHostingController` 按 preferredContentSize 报实际内容高度，
        // 预设一个对不上的值会让首次展开出现一次可见的尺寸校正。
        let hosting = NSHostingController(rootView: PanelView(engine: engine))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        engine.$report
            .receive(on: RunLoop.main)
            .sink { [weak self] report in
                guard let self else { return }
                self.render(report)
                self.feed.publish(report, pricing: self.engine.pricingSource)
            }
            .store(in: &bag)

        engine.start()

        feed.onQuit = { NSApplication.shared.terminate(nil) }
        feed.start()
        otlp.start()
        // 控件注入到 Mirasim 的渲染进程里，数据从上面那个回环接口拉。
        // 客户端里已经有控件时收起菜单栏图标；注入不可用时再放出来，
        // 保证任何时候都至少有一处能看到额度。
        injector.onPresence = { [weak self] inClient in
            DispatchQueue.main.async { self?.statusItem?.isVisible = Diag.statusAlways || !inClient }
        }
        injector.start(feed: feed)

        // MIRAQUOTA_OPEN=1 时启动后自动展开面板，便于截图核对排版。
        if ProcessInfo.processInfo.environment["MIRAQUOTA_OPEN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.toggle() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        injector.stop()
        otlp.stop()
        feed.stop()
        engine.stop()
    }

    /// 标题栏只放最紧的一条：主窗口的百分比与已用金额。
    /// 非实测状态加 `≈`，避免把推算值当成实测值读。
    private func render(_ report: QuotaReport) {
        guard let button = statusItem?.button else { return }
        let primary = report.windows.first { $0.label.lowercased() == "5h" } ?? report.windows.first

        guard let w = primary else {
            button.attributedTitle = styled("额度 —", tone: .secondaryLabelColor)
            button.toolTip = report.state.detail ?? "等待 Mirasim"
            return
        }

        let color: NSColor = w.usedPercent >= 95 ? .systemRed
            : (w.usedPercent >= 80 ? .systemOrange
               : (w.inferred ? .secondaryLabelColor : .labelColor))
        let mark = w.inferred ? "≈" : ""
        // 小数位与面板、控件一致；金额取按点数口径折算的已用额度，与百分比同分母。
        button.attributedTitle = styled(String(format: "%@%.1f%% · %@", mark, w.usedPercent,
                                               Formatting.usd(w.scaledSpentUSD ?? w.spentUSD)),
                                        tone: color)

        var tip = report.windows
            .map { w in
                let amount = Formatting.usd(w.scaledSpentUSD ?? w.spentUSD)
                return "\(Formatting.windowTitle(w.label)) \(String(format: "%.1f%%", w.usedPercent)) · \(amount)"
            }
            .joined(separator: "   ")
        if let detail = report.state.detail { tip += "\n" + detail }
        button.toolTip = tip
    }

    /// 等宽数字，避免刷新时标题宽度抖动。
    private func styled(_ text: String, tone: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: tone,
        ])
    }

    /// 一次点击对应一次开合。弹层不会自行关闭，`isShown` 始终是点击时的真实状态，
    /// 无论点得多快都不会错位。
    @objc private func toggle() {
        guard let button = statusItem?.button else { return }
        Diag.log("toggle panelOpen=\(panelOpen) isShown=\(popover.isShown)")
        if panelOpen { close() } else { open(from: button) }
    }

    private func open(from button: NSStatusBarButton) {
        panelOpen = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // 展开后的实际内容尺寸，用于核对排版高度。取值要等一帧布局落定。
        if Diag.enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, let size = self.popover.contentViewController?.view.fittingSize else { return }
                Diag.log("panel size=\(Int(size.width))×\(Int(size.height)) windows=\(self.engine.report.windows.count)")
            }
        }
        // 菜单栏的点击经由系统 UI 派发，全局监听同样会收到状态栏按钮自身的点击。
        // 若不排除，监听会先把弹层关掉，随后 toggle 看到「未展开」又重新打开，
        // 结果是按钮永远关不上弹层。故落在按钮范围内的点击一律交给 toggle。
        outsideClick = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            if self.statusButtonFrame()?.contains(NSEvent.mouseLocation) == true { return }
            self.close()
        }
        requestFresh()
    }

    /// 状态与监听都在这里同步归位。不依赖关闭动画结束的回调——
    /// 那个回调会迟到，快速点击时落在下一次展开之后，把已展开的状态清掉。
    private func close() {
        panelOpen = false
        if let monitor = outsideClick {
            NSEvent.removeMonitor(monitor)
            outsideClick = nil
        }
        popover.close()
        // AppKit 会丢弃落在展开动画期间的关闭请求，画面就会停在展开态而与逻辑状态不符。
        // 动画窗口过后对账一次：仍是「逻辑已关、画面还开着」就补关。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let self, !self.panelOpen, self.popover.isShown else { return }
            self.popover.close()
        }
    }

    /// 状态栏项在屏幕坐标系里的可点范围。
    /// 用它自己的窗口 frame 而非 `button.bounds`：后者比实际命中区域窄几个点，
    /// 点在边缘时会被误判成「点了别处」而先关掉弹层。
    private func statusButtonFrame() -> NSRect? {
        statusItem?.button?.window?.frame.insetBy(dx: -6, dy: -6)
    }

    /// 展开后再要新数据，且限流。连续点击不该反复让 Mirasim 去问一趟 relay。
    private func requestFresh() {
        let now = Date()
        guard now.timeIntervalSince(lastRefreshAt) > 3 else { return }
        lastRefreshAt = now
        engine.refresh()
    }
}

let delegate = AppDelegate(port: portOverride)
let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
