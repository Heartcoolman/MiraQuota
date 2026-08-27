import AppKit
import SwiftUI
import Combine

// MARK: 参数

let arguments = CommandLine.arguments

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    MiraQuota · Mirasim 额度估算

    用法：
      MiraQuota                打开主窗口，同时在菜单栏常驻
      MiraQuota --background   只常驻，不开窗口、不占 Dock（LaunchAgent 用这个）
      MiraQuota --once         采集一次并打印，用于自检
      MiraQuota --doctor       逐项检查数据链路，指出断点与处置办法
      MiraQuota --port <N>     指定 Mirasim 本地端口（默认自动发现）

    数据来源：
      额度原始值  Mirasim 路由端口的 /v1/limits，给出已用与总额的额度点数
      额度百分比  退路，Mirasim 本地通道 /mirachannel/ws 的 relay 帧，分辨率 0.1%
      等价支出    ~/.claude/projects 的 transcript 与 ~/.mirasim/insights 的网关账本
      价目表      ~/.mirasim/models-dev-cache.json，缺失时用内置表
      速度实测    Claude Code OTel trace（回环 4319 接收），逐请求首 token 与时长
      满额        标定优先：「同期支出 ÷ 同期点数增量 × 预算点」，样本落在 ~/.miraquota；
                  端点不可读时退回百分比口径；标定未收敛时才用全局单价 × 预算点兜底

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

/// LaunchAgent 用它在登录时只常驻不开窗；从 Dock / 访达点起来则开窗。
let background = arguments.contains("--background")

// launchd 重启本进程时旧实例可能还在退出途中，故常驻模式重试；
// 手工点起来的那次不等，立刻把「打开窗口」转交给常驻实例。
guard InstanceLock.acquire(retries: background ? 10 : 0) else {
    let handed = Feed.requestOpen()
    FileHandle.standardError.write(Data(
        (handed ? "MiraQuota 已在运行，已请它打开窗口\n" : "MiraQuota 已在运行\n").utf8))
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
    /// 主窗口惰性建立：常驻模式下从不打开的话就不该有这份开销。
    private var window: NSWindow?
    private let port: Int?
    private let background: Bool
    private var bag = Set<AnyCancellable>()
    /// 外部点击监听。弹层改为自管开合后，需要它来实现「点别处收起」。
    private var outsideClick: Any?
    /// 自有的开合状态。带动画时 `popover.isShown` 在动画期间取值不可靠，
    /// 快速点击会读到过渡态；这个标志在每次转换开始时同步置位，与动画时序无关。
    private var panelOpen = false
    /// 上一次向 relay 要新数据的时刻，用于限流。
    private var lastRefreshAt = Date.distantPast

    init(port: Int?, background: Bool) {
        self.port = port
        self.background = background
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

        // 第二个实例被点起来时不再自建一份采集，把开窗的意图转交给这里。
        feed.onOpen = { [weak self] in self?.showWindow() }
        NotificationCenter.default.addObserver(
            forName: Self.openWindowRequest, object: nil, queue: .main
        ) { [weak self] _ in self?.showWindow() }

        buildMenu()
        if !background { showWindow() }

        // MIRAQUOTA_OPEN=1 时启动后自动展开面板，便于截图核对排版。
        if ProcessInfo.processInfo.environment["MIRAQUOTA_OPEN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.toggle() }
        }
    }

    /// 面板脚上的「窗口」按钮经它转交，避免 SwiftUI 视图直接持有 AppDelegate。
    static let openWindowRequest = Notification.Name("MiraQuota.openMainWindow")

    // MARK: 主窗口

    /// 常驻实例被点第二次时也走这里：窗口已存在就抬到前面，不重建。
    func showWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: MainWindow(engine: engine, port: port))
            let w = NSWindow(contentViewController: hosting)
            w.title = "MiraQuota"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 880, height: 620))
            w.contentMinSize = NSSize(width: 640, height: 420)
            // 关窗不退出应用，故窗口自己不能被释放，否则再开就是野指针。
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("MiraQuotaMain")
            w.center()
            window = w
        }
        // 登录时以 .accessory 起步（不占 Dock），开窗这一刻才转为常规应用。
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 关掉最后一个窗口不退出：本体是常驻采集，菜单栏项与客户端控件还要继续。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 点 Dock 图标（或再次从访达打开）时回到窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    /// 常规应用必须自带菜单栏，否则连 ⌘Q 与文本拷贝都没有。
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 MiraQuota", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 MiraQuota", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 MiraQuota", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // 自检那一页的结论要能拷出来，Edit 菜单不能省。
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        let show = NSMenuItem(title: "MiraQuota 窗口", action: #selector(openWindow), keyEquivalent: "0")
        show.target = self
        windowMenu.addItem(show)
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    @objc private func openWindow() { showWindow() }

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

let delegate = AppDelegate(port: portOverride, background: background)
let application = NSApplication.shared
application.delegate = delegate
// 常驻模式不占 Dock；从 Dock / 访达点起来的那次直接以常规应用起步，
// 免得先出现图标再被收走造成一次闪动。
application.setActivationPolicy(background ? .accessory : .regular)
application.run()
