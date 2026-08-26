import Foundation
import Combine

/// 采集与计算的协调层。
///
/// 百分比来自 Mirasim 的 relay 帧，支出来自本地 transcript 与网关账本，满额由两者反推。
/// 全部计算在专用串行队列上完成，只把结论发回主线程。
///
/// 通道不可用时按五级阶梯逐级退让，任何一级都仍有可读输出：
/// 精确（`/v1/limits` 原始额度点）→ 实测（relay 帧百分比）→ 过期实测 → 锚点推算 → 本地滚动窗口。
final class QuotaEngine: ObservableObject {
    @Published private(set) var report = QuotaReport.placeholder(.connecting)

    /// 实测帧超过该龄期即视为停更。轮询间隔 20 秒，留三倍余量。
    private static let liveWindow: TimeInterval = 75
    /// 超过该龄期即便连接仍在也不再展示实测值，转为推算。
    private static let staleLimit: TimeInterval = 600
    /// 心跳间隔，驱动倒计时、账本增量与降级判定。
    /// 取 5 秒是为了让速度卡跟得上请求落账；一轮重建只做增量尾读与几次二分查找。
    private static let heartbeat: TimeInterval = 5
    /// 反推额度点单价所需的最少已用点数。点数太少时比值噪声过大。
    private static let minPointsForRate: Double = 200

    private let work = DispatchQueue(label: "miraquota.engine")
    private let pricing: Pricing
    private let ledger: CostLedger
    private let calibrator = Calibrator()
    private let speed = SpeedStats()
    private let anchors = AnchorStore()
    private let accounts = AccountStore()
    private let limits = LimitsClient()
    private let relay: RelayClient
    private var timer: DispatchSourceTimer?

    private var seeded = false
    /// 原始点数的近期轨迹（窗口标签 → 观测序列），用于按点增速外推打满时刻。
    /// 只在工作队列上读写；保留 2 小时，外推只用最近 1 小时。
    private var pointsTrail: [String: [(at: Date, used: Double, resetAt: Date)]] = [:]
    /// 工作队列上的最新结论。`@Published` 经主队列投递，主线程阻塞时读不到。
    private var latest = QuotaReport.placeholder(.connecting)
    private var lastSnapshot: RelaySnapshot?
    private var lastLimits: LimitsSnapshot?
    private var lastFrameAt: Date?
    private var reachable = false
    private var mismatchReason: String?
    private var unreachableReason: String?

    var pricingSource: String { pricing.source }

    init(port: Int? = nil) {
        let p = Pricing()
        pricing = p
        ledger = CostLedger(pricing: p)
        relay = RelayClient(port: port)
    }

    func start() {
        relay.onEvent = { [weak self] event in
            self?.work.async { self?.handle(event) }
        }
        relay.start()

        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + Self.heartbeat, repeating: Self.heartbeat)
        t.setEventHandler { [weak self] in self?.rebuild() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel(); timer = nil
        relay.stop()
    }

    /// 面板上的手动刷新：让 Mirasim 绕过自身缓存重新问一次 relay。
    func refresh() {
        relay.poll(fresh: true)
        work.async { [weak self] in self?.rebuild() }
    }

    // MARK: 事件

    private func handle(_ event: RelayEvent) {
        switch event {
        case .snapshot(let s):
            // 断线后重连：Mirasim 很可能刚重启，会话端口全换过，
            // 缓存的路由端口必然失效，立刻重新枚举而不是等静默期过去。
            if !reachable { limits.invalidate() }
            lastSnapshot = s
            lastFrameAt = Date()
            reachable = true
            mismatchReason = nil
            unreachableReason = nil
            // 换账号即换上游账号池，切换前的速度样本不再可比，一律弃用；
            // 同账号内换套餐档位则只改样本归属，各档位的样本各自保留。
            if !accounts.adopt(s.accountTag, plan: s.plan).isEmpty {
                speed.adopt(epochStart: accounts.since, planWindows: accounts.currentWindows())
            }
            if !seeded { calibrator.seed(from: s); seeded = true }
            calibrator.record(s)
            anchors.update(from: s)
        case .unreachable(let why):
            reachable = false
            unreachableReason = why
        case .mismatch(let why):
            reachable = true
            mismatchReason = why
        }
        rebuild()
    }

    // MARK: 构建

    private func rebuild() {
        ledger.refresh()
        speed.refresh()
        let now = Date()
        lastLimits = limits.snapshot(now: now, anchorPort: relay.currentPort)
        if let l = lastLimits {
            recordTrail(l)
            calibrator.record(l)
            // modelScoped 窗口的等价支出须按同一档位过滤，账本据此另开一路分桶；
            // 速度行同样标出档位，供界面把两者对上。
            let groups = l.windows.compactMap(\.modelGroup)
            ledger.adoptScopedGroups(groups)
            speed.adoptScopedGroups(groups)
        }
        let state = resolveState(now: now)
        let known = anchors.lastKnown
        let rate = lastLimits.flatMap { unitPrice($0, now: now) }

        let windows: [WindowReport]
        switch state {
        case .exact:
            windows = (lastLimits?.windows ?? []).map { exact($0, rate: rate, snapshot: lastSnapshot, now: now) }
        case .live, .stale:
            let snap = lastSnapshot
            windows = (snap?.windows ?? []).map { measured($0, snapshot: snap, now: now) }
        case .connecting:
            windows = []
        case .reckoned, .mismatch:
            windows = known.anchors.map { reckoned($0, now: now) }
        case .local:
            windows = rollingFallback(now: now)
        }

        latest = QuotaReport(
            windows: windows,
            capturedAt: lastSnapshot?.capturedAt ?? known.capturedDate,
            state: state,
            mode: lastSnapshot?.mode ?? known.mode,
            host: lastSnapshot?.host ?? known.host,
            relayStatus: lastSnapshot?.relayStatus ?? known.relayStatus,
            newRecords: ledger.totalRecords,
            bucketCount: ledger.bucketCount,
            speed: speed.report(now: now),
            unitPriceUSD: rate,
            accountNotice: lastLimits?.notice
        )
        publish(latest)
    }

    private func resolveState(now: Date) -> ChannelState {
        let age = lastFrameAt.map { now.timeIntervalSince($0) }

        if let l = lastLimits, !l.windows.isEmpty, now.timeIntervalSince(l.capturedAt) < Self.liveWindow {
            return .exact
        }
        if let age, age < Self.liveWindow, lastSnapshot?.windows.isEmpty == false {
            return .live
        }
        if let why = mismatchReason, anchorsUsable {
            return .mismatch(why)
        }
        if let age, age < Self.staleLimit, reachable, lastSnapshot?.windows.isEmpty == false {
            return .stale(age)
        }
        if anchorsUsable {
            return .reckoned(now.timeIntervalSince(anchors.lastKnown.capturedDate))
        }
        if let why = mismatchReason { return .mismatch(why) }
        // 从未拿到过锚点：若本地账本有数据仍可给出滚动窗口支出，否则还在连接。
        if lastFrameAt == nil && unreachableReason == nil { return .connecting }
        return .local
    }

    private var anchorsUsable: Bool {
        let known = anchors.lastKnown
        guard !known.anchors.isEmpty else { return false }
        // 锚点过老时窗口边界的滚动误差会累积，超过 30 天不再采信。
        return Date().timeIntervalSince(known.capturedDate) < 30 * 86400
    }

    /// 记录一次原始点数观测。LimitsClient 未到间隔时回同一份快照，按采集时刻去重。
    private func recordTrail(_ l: LimitsSnapshot) {
        for w in l.windows {
            var list = pointsTrail[w.label] ?? []
            if let last = list.last, last.at >= l.capturedAt { continue }
            list.append((l.capturedAt, w.used, w.resetAt))
            let cutoff = l.capturedAt.addingTimeInterval(-7200)
            list.removeAll { $0.at < cutoff }
            pointsTrail[w.label] = list
        }
    }

    /// 按近 1 小时点增速外推的打满秒数。轨迹只取当前窗口期内（重置时刻一致）的观测，
    /// 跨度不足 3 分钟或增速为零时不给数。窗口重置后旧轨迹自然失配，从头积累。
    private func etaSeconds(_ w: LimitsSnapshot.Window, now: Date) -> Double? {
        let trail = (pointsTrail[w.label] ?? []).filter {
            $0.resetAt == w.resetAt && now.timeIntervalSince($0.at) <= 3600
        }
        guard let first = trail.first, let last = trail.last,
              last.at.timeIntervalSince(first.at) >= 180 else { return nil }
        let rate = (last.used - first.used) / last.at.timeIntervalSince(first.at)
        guard rate > 0 else { return nil }
        return (w.budget - last.used) / rate
    }

    /// `/v1/limits` 精确值：百分比为 `used / budget`，满额折美元按窗口自己的标定优先。
    /// 各窗口的点是同一单位（实测 Δ5h点/Δ7d点 恒在 1.0 附近），但每点美元随时段的模型混比
    /// 与缓存读占比漂移，实测跨 $0.00235–0.00502。全局单价由已用点数最多的窗口反推（恒为 7d），
    /// 因而只对该窗口成立：挪到 5h 上实测偏高约 12%。故仅在标定未收敛时作兜底，且标为低置信。
    private func exact(_ w: LimitsSnapshot.Window, rate: Double?,
                       snapshot: RelaySnapshot?, now: Date) -> WindowReport {
        let bounds = w.quotaWindow
        let start = bounds.startAt
        let group = w.modelGroup
        let spent = start.map {
            ledger.spent(from: $0, to: now, includeOpenMinute: true, group: group)
        } ?? 0
        let estimate = calibrator.estimate(label: w.label, ledger: ledger,
                                           budget: w.budget, group: group)
        let fullUSD: Double?
        let confidence: Calibration.Confidence
        if let estimate, estimate.confidence == .high || estimate.confidence == .medium {
            fullUSD = estimate.fullUSD
            confidence = estimate.confidence
        } else if let rate {
            fullUSD = rate * w.budget
            confidence = .low
        } else {
            fullUSD = estimate?.fullUSD
            confidence = estimate?.confidence ?? .none
        }
        return WindowReport(
            label: w.label,
            usedPercent: w.usedPercent,
            spentUSD: spent,
            fullUSD: fullUSD,
            confidence: confidence,
            sampleCount: estimate?.observations ?? 0,
            resetAt: w.resetAt,
            pacePercent: pace(start: start, duration: bounds.duration, now: now),
            inferred: false,
            trend: snapshot?.trend(for: w.label) ?? [],
            points: PointBalance(used: w.used, budget: w.budget),
            scaledSpentUSD: fullUSD.map { $0 * w.usedPercent / 100 },
            etaSeconds: etaSeconds(w, now: now),
            remainingUSD: fullUSD.map { max(0, $0 * (100 - w.usedPercent) / 100) },
            modelGroup: group
        )
    }

    /// 额度点单价，美元/点。取已用点数最多的窗口反推，各窗口共用同一取值：
    /// 刚重置的窗口点数太少会失真。取值恒由 7d 反推，故 `rate × budget_7d` 与 7d 的
    /// 百分比标定是同一个式子（支出 ÷ 百分比），两者吻合不构成互校。
    private func unitPrice(_ limits: LimitsSnapshot, now: Date) -> Double? {
        var best: (points: Double, usd: Double)?
        for w in limits.windows {
            guard !w.modelScoped, w.used >= Self.minPointsForRate,
                  let start = w.quotaWindow.startAt else { continue }
            // 已用点数含开分钟内的消耗（快照是即时值），美元不含会系统性压低单价。
            let usd = ledger.spent(from: start, to: now, includeOpenMinute: true)
            guard usd > 0 else { continue }
            if best == nil || w.used > best!.points { best = (w.used, usd) }
        }
        guard let best else { return nil }
        return best.usd / best.points
    }

    /// relay 实测：百分比直接采用，满额由标定反推。
    private func measured(_ w: QuotaWindow, snapshot: RelaySnapshot?, now: Date) -> WindowReport {
        let start = w.startAt
        let group = w.modelGroup
        let spent = start.map {
            ledger.spent(from: $0, to: now, includeOpenMinute: true, group: group)
        } ?? 0
        let estimate = calibrator.estimate(label: w.label, ledger: ledger, group: group)
        let full = estimate?.fullUSD ?? inferFull(percent: w.usedPercent, spent: spent)
        return WindowReport(
            label: w.label,
            usedPercent: w.usedPercent,
            spentUSD: spent,
            fullUSD: full,
            confidence: estimate?.confidence ?? (w.usedPercent >= 1 ? .low : .none),
            sampleCount: estimate?.observations ?? 0,
            resetAt: w.resetAt,
            pacePercent: pace(start: start, duration: w.duration, now: now),
            inferred: false,
            trend: snapshot?.trend(for: w.label) ?? [],
            points: nil,
            scaledSpentUSD: full.map { $0 * w.usedPercent / 100 },
            remainingUSD: full.map { max(0, $0 * (100 - w.usedPercent) / 100) },
            modelGroup: group
        )
    }

    /// 锚点推算：窗口边界由锚点滚动得出，百分比由本机支出除以标定满额。
    /// 他人对共享额度的占用在本机不可见，故该百分比是下界。
    private func reckoned(_ a: Anchor, now: Date) -> WindowReport {
        let bounds = a.window(at: now)
        // 锚点只留窗口名与边界，modelScoped 标志不在其中，按窗口名推档位组：
        // 带下划线后缀的窗口名只出现在 modelScoped 窗口上（实测 `7d_fable`）。
        let group = QuotaWindow.modelGroup(of: a.label)
        let spent = bounds.map {
            ledger.spent(from: $0.start, to: now, includeOpenMinute: true, group: group)
        } ?? 0
        let estimate = calibrator.estimate(label: a.label, ledger: ledger, group: group)
        let percent = estimate.map { min(100, spent / $0.fullUSD * 100) } ?? 0
        return WindowReport(
            label: a.label,
            usedPercent: percent,
            spentUSD: spent,
            fullUSD: estimate?.fullUSD,
            confidence: estimate?.confidence ?? .none,
            sampleCount: estimate?.observations ?? 0,
            resetAt: bounds?.end,
            pacePercent: pace(start: bounds?.start, duration: a.duration, now: now),
            inferred: true,
            trend: [],
            points: nil
        )
    }

    /// 连锚点都没有时的最后一级：按最近 5 小时 / 7 天的滚动窗口统计本机支出。
    /// 滚动窗口与固定窗口的边界不同，只作量级参考。
    private func rollingFallback(now: Date) -> [WindowReport] {
        [("5h", TimeInterval(5 * 3600)), ("7d", TimeInterval(7 * 86400))].map { label, duration in
            let spent = ledger.spent(from: now.addingTimeInterval(-duration), to: now,
                                     includeOpenMinute: true)
            let estimate = calibrator.estimate(label: label, ledger: ledger)
            return WindowReport(
                label: label,
                usedPercent: estimate.map { min(100, spent / $0.fullUSD * 100) } ?? 0,
                spentUSD: spent,
                fullUSD: estimate?.fullUSD,
                confidence: estimate?.confidence ?? .none,
                sampleCount: estimate?.observations ?? 0,
                resetAt: nil,
                pacePercent: nil,
                inferred: true,
                trend: [],
                points: nil
            )
        }
    }

    private func pace(start: Date?, duration: TimeInterval?, now: Date) -> Double? {
        guard let start, let duration, duration > 0 else { return nil }
        return min(100, max(0, now.timeIntervalSince(start) / duration * 100))
    }

    /// 标定样本尚未积累时的兜底：用当前窗口的支出与百分比直接相除。
    /// 百分比很低时该比值噪声过大，此时不给数。
    private func inferFull(percent: Double, spent: Double) -> Double? {
        guard percent >= 1, spent > 0 else { return nil }
        return spent / percent * 100
    }

    private func publish(_ r: QuotaReport) {
        DispatchQueue.main.async { [weak self] in self?.report = r }
    }

    // MARK: 一次性自检

    /// `--once` 模式：连接、采集、打印，然后退出。
    /// Mirasim 不可用时不空手而归，改打印推算结果，便于确认退路本身是通的。
    func runOnce(timeout: TimeInterval = 120) -> Int32 {
        let done = DispatchSemaphore(value: 0)
        var finished = false
        // 一次性流程刻意强持有 self：进程随即退出，循环引用无害，
        // 而弱引用会在 release 构建下被提前释放。
        relay.onEvent = { event in
            self.work.async {
                self.handle(event)
                guard !finished else { return }
                switch event {
                case .snapshot:
                    finished = true
                    done.signal()
                case .unreachable, .mismatch:
                    // 通道不可用时立刻走退路，无需空等到超时。
                    finished = true
                    done.signal()
                }
            }
        }
        relay.start()
        _ = done.wait(timeout: .now() + timeout)
        // 主线程此刻正阻塞在上面的等待里，不能取 @Published 的值（它经 main 队列投递）。
        // 直接在工作队列上重建并读取。
        let final: QuotaReport = work.sync { rebuild(); return latest }
        printReport(final)
        return final.windows.isEmpty ? 1 : 0
    }

    private func printReport(_ r: QuotaReport) {
        print("Mirasim  \(r.host)  线路 \(r.mode)  状态 \(r.relayStatus)")
        print("通道     \(r.state.label)" + (r.state.detail.map { " · " + $0 } ?? ""))
        print("价目表   \(pricing.source)")
        print("账本     分钟桶 \(ledger.bucketCount) · 本轮新增 transcript \(ledger.transcriptRecords) 条 / 网关 \(ledger.ledgerRecords) 条 · 未定价 \(ledger.unpricedRecords) 条")
        printSpeed(r.speed)
        if let price = r.unitPriceUSD {
            print(String(format: "单价     %.6f 美元/额度点（由账本支出 ÷ 已用点数反推）", price))
        }
        if let notice = r.accountNotice { print("账号     \(notice)") }
        print("")
        for w in r.windows {
            let full = w.fullUSD.map { String(format: "$%.0f", $0) } ?? "标定中"
            let pace = w.paceDelta.map { String(format: "%+.1f%%", $0) } ?? "-"
            let mark = w.inferred ? "≈" : " "
            print(String(format: "%-4@%@%5.1f%%   已用 $%.2f / %@   均速偏离 %@   观测 %d (%@)",
                         w.label as NSString, mark, w.usedPercent,
                         w.scaledSpentUSD ?? w.spentUSD, full, pace,
                         w.sampleCount, w.confidence.label))
            if w.scaledSpentUSD != nil {
                print(String(format: "      账本支出 $%.2f（按点数口径折算的已用为上一行）", w.spentUSD))
            }
            if let p = w.points {
                print(String(format: "      额度点 %.1f / %.0f", p.used, p.budget))
            }
            if let rem = w.remainingUSD {
                let eta = w.etaSeconds.map { String(format: " · 按近 1 小时点增速 ≈%.1f 小时后满", $0 / 3600) } ?? ""
                print(String(format: "      余 $%.0f%@", rem, eta))
            }
            if let reset = w.resetAt {
                print("      重置 \(Self.stamp.string(from: reset))")
            } else {
                print("      滚动窗口，无固定重置时刻")
            }
        }
    }

    private func printSpeed(_ s: SpeedReport?) {
        guard let s else { return }
        if let oldest = s.inflightSince.first {
            let n = s.inflightSince.count
            print(String(format: "速度     ▶ 生成中 %d 条 · 最长已 %.0f 秒", n,
                         Date().timeIntervalSince(oldest)))
        }
        if s.rows.isEmpty, s.inflightSince.isEmpty {
            print("速度     近期无请求（\(s.sampleTotal) 次）")
        }
        for row in s.rows {
            let ttft = row.ttft.map { String(format: "首 ≈%.1fs", $0) } ?? "首 -"
            let rate = row.rate.map { String(format: "出字 %.0f tok/s", $0) } ?? "出字 -"
            let drift = row.drift.map { String(format: " · 较常态 %+.0f%%", $0) } ?? ""
            let age = Formatting.age(Date().timeIntervalSince(row.latestAt))
            print(String(format: "速度     %@  %@ · %@ · 端到端 %.0f tok/s · 最近 %d 次 · %@前%@",
                         row.model, ttft, rate, row.endToEnd, row.samples, age, drift))
        }
        if let m = s.measuredTurnTTFB {
            print(String(format: "         Mirasim 实测整轮首字节 中位 %.1fs（%d 次，口径为整轮，仅作对照）",
                         m.median, m.count))
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}
