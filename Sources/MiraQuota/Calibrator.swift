import Foundation

enum Calibration {
    enum Confidence: String, Sendable {
        case none, low, medium, high

        var label: String {
            switch self {
            case .none: return "无样本"
            case .low: return "标定中"
            case .medium: return "收敛中"
            case .high: return "高置信"
            }
        }

        var rank: Int {
            switch self {
            case .none: return 0
            case .low: return 1
            case .medium: return 2
            case .high: return 3
            }
        }
    }

    /// 标定所依据的口径。点数口径跨预算点变更仍可比，百分比口径不可比。
    enum Basis: String, Sendable {
        case points, percent

        var label: String { self == .points ? "点数" : "百分比" }
    }

    struct Estimate: Sendable {
        let fullUSD: Double
        let confidence: Confidence
        let observations: Int
        /// 标定累计覆盖的百分比跨度，是置信度的主要依据。
        let coveredPercent: Double
        let basis: Basis
    }
}

/// 满额自校准。
///
/// 原始额度点与 API 等价支出在观测窗口内呈线性关系，故满额可由
/// 「一段时间的支出 ÷ 同期点数增量 × 预算点」反推。`/v1/limits` 可读时走点数口径；
/// 取不到时退回 relay 帧的百分比口径，分辨率 0.1%。
/// 支出与增量两侧都会挂起到对面也非零时才成为一次观测：
/// 只挂起支出会低估满额，只挂起增量会高估（见 `observe`）。
///
/// 两个口径并存是因为百分比跨预算点变更不可比：实测 5h 预算点在 2026-08-24 17:34
/// 由约 42525 扩到 156800，`used` 不变而百分比直落到 27%，此前的 1 个百分点只值
/// 425 点、此后值 1568 点，混算会把满额压低三成。点数是绝对量，不受该变更影响；
/// 百分比口径则按 `epochStart` 裁掉断点之前的样本。
final class Calibrator {
    private struct Sample: Codable {
        let at: Double
        let percent: Double
        let resetAt: Double
        /// 采样当时的套餐档位。预算点随档位而变，1 个百分点值多少点不再可比，
        /// 故估算只取当前档位的样本。必须是 Optional：本版本之前落盘的样本无此标签，
        /// 由 `adoptPlan` 在首次观测到档位时回填。
        var plan: String? = nil
    }

    /// 原始点数样本。`used` 带小数位，且跨预算点变更可比。
    private struct PointSample: Codable {
        let at: Double
        let used: Double
        let budget: Double
        let resetAt: Double
    }

    private struct Persisted: Codable {
        var samples: [String: [Sample]] = [:]
        /// 状态版本。1 及以下的 `accountSince` 可能来自令牌尾号判据下的轮换误判
        /// （见 `AccountTag`），升级时撤销：留着会让点数口径继续拒用当前账号的预算点。
        /// 必须是 Optional，理由同 `points`。
        var v: Int? = nil
        /// 样本所属账号的标识（relay 帧的 tokenTail）。同为 Optional，理由同 `points`。
        var account: String? = nil
        /// 最后一次账号切换的时刻，unix 秒。点数口径据此拒用旧套餐的预算点。
        var accountSince: Double? = nil
        /// 当前套餐档位，以及它最后一次生效的时刻。同账号内换档位时预算点会变，
        /// 点数口径的预算点退路据此拒用旧档位的取值。
        var plan: String? = nil
        var planSince: Double? = nil
        /// 点数样本，来源是 `/v1/limits`。必须是 Optional：合成 Codable 只对 Optional
        /// 走 decodeIfPresent，旧 calibration.json 缺该键时非可选会让整个状态解码失败被静默清空。
        var points: [String: [PointSample]]? = nil
    }

    /// 样本保留时长。
    static let retention: TimeInterval = 14 * 86400
    /// 单窗口样本上限，防止长期运行后无界增长。
    static let maxSamples = 4000
    /// 点数样本的保留时长与上限。标定只需覆盖窗口长度量级的跨度，
    /// 而点数每 15 秒就变一次，按百分比样本的口径留 14 天会让状态文件涨到数兆。
    static let pointRetention: TimeInterval = 3 * 86400
    static let maxPointSamples = 12000
    /// 两条点数样本之间的最小间隔。`/v1/limits` 每 15 秒一取，减半即够标定用。
    static let pointMinInterval: TimeInterval = 30
    /// 判定「预算点变更或配额重算」的百分比回落阈值。窗口正常重置时 `resetAt` 必变，
    /// 故「resetAt 不变却大幅回落」只出现在上游改口径时。
    static let epochDrop: Double = 5
    /// 挂起的百分比增量等待本机支出的上限。超过此时长仍无支出，
    /// 判为账号池中他人的占用，不能记到本机美元上。实测归属滞后均在 4 分钟内消解。
    static let carryTimeout: TimeInterval = 600

    private var state = Persisted()
    private let lock = NSLock()

    init() { load() }

    // MARK: 持久化

    /// 状态版本，与 `AccountStore.version` 同步推进。
    static let version = 2

    private func load() {
        guard let data = try? Data(contentsOf: Paths.calibState),
              var p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        if (p.v ?? 1) < Self.version {
            p.accountSince = nil
            p.v = Self.version
            state = p
            save()
            return
        }
        state = p
    }

    /// 落盘前先并回磁盘上的样本。
    /// 菜单栏常驻实例与 `--once` 自检可能同时在写，直接覆盖会丢掉对方积累的样本。
    /// 读-合-写全程持文件锁：无锁时两边都以旧盘面为基线，后写者吞掉先写者刚并入的样本。
    private func save() {
        Paths.ensureStateDir()
        let fd = open(Paths.calibLock.path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        // 盘面属于另一个账号时不并样本：那是另一套预算点下的百分比，并回来等于把
        // `adoptAccount` 刚裁掉的断点前样本请回来。无标识的旧盘面按同账号处理，
        // 保持升级前的行为。
        if let data = try? Data(contentsOf: Paths.calibState),
           let disk = try? JSONDecoder().decode(Persisted.self, from: data),
           disk.account == nil || disk.account == state.account {
            for (label, diskSamples) in disk.samples {
                var byTime: [Int: Sample] = [:]
                for s in diskSamples { byTime[Int(s.at)] = s }
                for s in state.samples[label] ?? [] { byTime[Int(s.at)] = s }
                state.samples[label] = byTime.values.sorted { $0.at < $1.at }
            }
            for (label, diskPoints) in disk.points ?? [:] {
                var byTime: [Int: PointSample] = [:]
                for s in diskPoints { byTime[Int(s.at)] = s }
                for s in state.points?[label] ?? [] { byTime[Int(s.at)] = s }
                var merged = state.points ?? [:]
                merged[label] = byTime.values.sorted { $0.at < $1.at }
                state.points = merged
            }
        }
        prune()
        state.v = Self.version
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Paths.calibState, options: .atomic)
    }

    // MARK: 采样

    /// 记录一次观测。百分比未变时不追加，使支出自然累积到下一个变化点。
    func record(_ snapshot: RelaySnapshot) {
        lock.lock(); defer { lock.unlock() }
        var dirty = adoptAccount(snapshot.accountTag)
        if adoptPlan(snapshot.plan) { dirty = true }
        for w in snapshot.windows {
            let s = Sample(at: snapshot.capturedAt.timeIntervalSince1970,
                           percent: w.usedPercent,
                           resetAt: w.resetAt.timeIntervalSince1970,
                           plan: state.plan)
            if appendIfChanged(label: w.label, s) { dirty = true }
        }
        if dirty { save() }
    }

    /// 记录一次原始点数观测。`/v1/limits` 未到间隔时回同一份快照，按采集时刻去重。
    /// 百分比样本仍只由 relay 帧写入：两个来源的百分比尺度不同（此处精确、帧只到 0.1%），
    /// 交替写入会造出锯齿式回落，把连续窗口切成碎片。
    func record(_ limits: LimitsSnapshot) {
        lock.lock(); defer { lock.unlock() }
        var dirty = false
        for w in limits.windows where w.budget > 0 {
            let s = PointSample(at: limits.capturedAt.timeIntervalSince1970,
                                used: w.used, budget: w.budget,
                                resetAt: w.resetAt.timeIntervalSince1970)
            if appendPointIfChanged(label: w.label, s) { dirty = true }
        }
        if dirty { save() }
    }

    /// 冷启动时导入 relay 自带的百分比环形缓冲，缩短首次标定等待。
    func seed(from snapshot: RelaySnapshot) {
        lock.lock(); defer { lock.unlock() }
        var dirty = adoptAccount(snapshot.accountTag)
        if adoptPlan(snapshot.plan) { dirty = true }
        for w in snapshot.windows {
            let key = w.label.lowercased()
            let pick: (RelaySnapshot.HistoryPoint) -> Double? =
                key == "5h" ? { $0.fiveHour } : (key == "7d" ? { $0.sevenDay } : { _ in nil })
            guard let start = w.startAt else { continue }
            for point in snapshot.history.sorted(by: { $0.at < $1.at }) {
                guard point.at >= start, let p = pick(point) else { continue }
                let s = Sample(at: point.at.timeIntervalSince1970, percent: p,
                               resetAt: w.resetAt.timeIntervalSince1970,
                               plan: state.plan)
                if appendIfChanged(label: w.label, s) { dirty = true }
            }
        }
        if dirty { save() }
    }

    /// 账号切换即百分比口径的断点。额度点预算随套餐而变，1 个百分点值多少点不再可比；
    /// 而换账号时窗口重置时刻同样会变，`epochStart` 那条「同 resetAt 大幅回落」的判据
    /// 分不出这是换账号还是窗口正常重置。帧里的 tokenTail 是唯一可用的身份判据，
    /// 变化即弃掉全部百分比样本。
    ///
    /// 点数样本不必弃：`used` 是绝对量、`budget` 取自当帧，比值跨账号仍可比；
    /// 且切换时 `used` 回落，`observe` 见回落即清挂起，不会把跨界的支出配进来。
    /// 返回是否需要落盘。
    private func adoptAccount(_ tag: String?) -> Bool {
        guard let tag, !tag.isEmpty else { return false }
        guard let known = state.account else {
            state.account = tag
            return true
        }
        guard known != tag else { return false }
        // 判据来源改变不是换账号（见 `AccountStore.adopt`），样本照留，
        // 令牌尾号判据下记的断点一并撤销。
        guard AccountTag.source(known) == AccountTag.source(tag) else {
            state.account = tag
            state.accountSince = nil
            return true
        }
        state.samples = [:]
        state.account = tag
        state.accountSince = Date().timeIntervalSince1970
        // 旧账号的档位对新账号没有意义，且切换下界已卡住更早的样本，重新起记。
        state.plan = nil
        state.planSince = nil
        return true
    }

    /// 采纳当前套餐档位。首次观测到档位时回填无标签的旧样本——它们确实采于该档位；
    /// 此后换档位只改当前值，旧样本已带各自的标签，按档位分组保留、切回即复用。
    /// 返回是否需要落盘。
    private func adoptPlan(_ plan: String?) -> Bool {
        guard let plan, !plan.isEmpty, state.plan != plan else { return false }
        if state.plan == nil {
            for (label, list) in state.samples {
                state.samples[label] = list.map {
                    $0.plan == nil ? Sample(at: $0.at, percent: $0.percent,
                                            resetAt: $0.resetAt, plan: plan) : $0
                }
            }
            state.plan = plan
            state.planSince = 0
            return true
        }
        state.plan = plan
        state.planSince = Date().timeIntervalSince1970
        return true
    }

    private func appendIfChanged(label: String, _ s: Sample) -> Bool {
        var list = state.samples[label] ?? []
        if let last = list.last {
            if s.at <= last.at { return false }
            // 百分比未变的样本对估计无贡献，支出会自然累积到下一个变化点。
            // 不能只在 resetAt 也相同时才跳过：5h 窗口在零用量时段报的 resetAt
            // 随时钟滚动（每次轮询都是新值，窗口边界要到首次请求才锁定），
            // 那样空闲一天会写入约 4300 条占位样本，把真实样本挤出 maxSamples 上限。
            if last.percent == s.percent { return false }
        }
        list.append(s)
        state.samples[label] = list
        return true
    }

    private func appendPointIfChanged(label: String, _ s: PointSample) -> Bool {
        var table = state.points ?? [:]
        var list = table[label] ?? []
        if let last = list.last {
            // 点数只增不减地累积，回落即窗口重置或上游重算，此时照常追加：
            // `observe` 见到 used 回落会清空挂起，不会把跨界的支出配进来。
            if s.at - last.at < Self.pointMinInterval { return false }
            if s.used == last.used && s.budget == last.budget && s.resetAt == last.resetAt { return false }
        }
        list.append(s)
        table[label] = list
        state.points = table
        return true
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.retention).timeIntervalSince1970
        for (k, v) in state.samples {
            var kept = v.filter { $0.at >= cutoff }
            if kept.count > Self.maxSamples { kept.removeFirst(kept.count - Self.maxSamples) }
            state.samples[k] = kept
        }
        let pointCutoff = Date().addingTimeInterval(-Self.pointRetention).timeIntervalSince1970
        if var table = state.points {
            for (k, v) in table {
                var kept = v.filter { $0.at >= pointCutoff }
                if kept.count > Self.maxPointSamples {
                    kept.removeFirst(kept.count - Self.maxPointSamples)
                }
                table[k] = kept
            }
            state.points = table
        }
    }

    // MARK: 估算

    /// `budget` 是该窗口当前的预算点数。点数样本自带采集当时的预算点，上游改档后
    /// 旧样本的取值即失效：每点美元不受影响（点是绝对量），乘上去的预算点必须是当前值。
    /// 实测 08-26 23:16 的 7 天窗口滚动把 5h 预算点由 156800 降到 39200，
    /// 沿用旧样本的预算点会把满额抬高四倍。取不到当前值时退回最后一条样本自带的。
    /// `group` 给定时只计该模型档位组的支出，用于 modelScoped 窗口
    /// （其点数只累计特定档位的模型，配上全机支出会把每点美元抬高数十倍）。
    func estimate(label: String, ledger: CostLedger, budget: Double? = nil,
                  group: String? = nil) -> Calibration.Estimate? {
        let byPoints = estimateByPoints(label: label, ledger: ledger, budget: budget, group: group)
        guard let byPercent = estimateByPercent(label: label, ledger: ledger, group: group)
        else { return byPoints }
        guard let byPoints else { return byPercent }
        // 点数口径跨预算点变更可比、分辨率也更高，同等置信时优先。点数样本刚起步时
        // 置信不足，此时不该把已经收敛的百分比口径挤掉。
        return byPoints.confidence.rank >= byPercent.confidence.rank ? byPoints : byPercent
    }

    /// 一个采样点上的累计量，两个口径共用配对逻辑。
    private struct Step {
        let at: Double
        let value: Double
        let resetAt: Double
    }

    /// 点数口径：`支出 ÷ 点数增量 × 预算点`。
    private func estimateByPoints(label: String, ledger: CostLedger,
                                  budget: Double?, group: String?) -> Calibration.Estimate? {
        lock.lock()
        let samples = state.points?[label] ?? []
        // 换账号与同账号内换档位都会换掉预算点，两者取晚的那个作退路的下界。
        let switchedAt = [state.accountSince, state.planSince].compactMap { $0 }.max()
        lock.unlock()
        // 退回样本自带的预算点时须确认那条样本属于当前账号与当前档位：两者任一变化
        // 都会换掉预算点，端点尚未恢复时最后一条样本仍带旧档位的取值，此时宁可不给数，
        // 让上层退到「支出 ÷ 百分比」的兜底。传进来的预算点取自当帧，一律可用。
        let stored: Double? = samples.last.flatMap { last in
            if let switchedAt, last.at < switchedAt { return nil }
            return last.budget
        }
        guard samples.count >= 2, let budget = budget ?? stored, budget > 0
        else { return nil }

        let steps = samples.map { Step(at: $0.at, value: $0.used, resetAt: $0.resetAt) }
        let observations = observe(steps, ledger: ledger, group: group)
        guard !observations.isEmpty else { return nil }
        let used = trimOutliers(observations)
        let totalCost = used.reduce(0) { $0 + $1.cost }
        let totalUnit = used.reduce(0) { $0 + $1.unit }
        guard totalUnit > 0, totalCost > 0 else { return nil }

        // 覆盖度折成百分比，与百分比口径同一把尺，置信度判据可以共用。
        let covered = totalUnit / budget * 100
        return Calibration.Estimate(fullUSD: totalCost / totalUnit * budget,
                                    confidence: confidence(observations: used.count, covered: covered),
                                    observations: used.count,
                                    coveredPercent: covered,
                                    basis: .points)
    }

    /// 百分比口径：`支出 ÷ 百分比增量 × 100`。只用当前套餐档位、最后一个断点之后的样本。
    private func estimateByPercent(label: String, ledger: CostLedger,
                                   group: String?) -> Calibration.Estimate? {
        lock.lock()
        let current = state.plan
        // 无标签样本只在从未观测到档位时才可用：`adoptPlan` 一见到档位就回填，
        // 此后仍无标签的样本来自解不出 login 的帧，档位归属不明，不能与当前档位混算。
        let all = (state.samples[label] ?? []).filter { current == nil || $0.plan == current }
        lock.unlock()
        // 断点先算一次：写进 filter 闭包会对每个元素重跑一遍，样本上千时退化成平方级。
        let cut = epochStart(all)
        let samples = all.filter { $0.at >= cut }
        guard samples.count >= 2 else { return nil }

        let steps = samples.map { Step(at: $0.at, value: $0.percent, resetAt: $0.resetAt) }
        let observations = observe(steps, ledger: ledger, group: group)
        guard !observations.isEmpty else { return nil }
        let used = trimOutliers(observations)
        let totalCost = used.reduce(0) { $0 + $1.cost }
        let totalUnit = used.reduce(0) { $0 + $1.unit }
        guard totalUnit > 0, totalCost > 0 else { return nil }

        return Calibration.Estimate(fullUSD: totalCost / totalUnit * 100,
                                    confidence: confidence(observations: used.count, covered: totalUnit),
                                    observations: used.count,
                                    coveredPercent: totalUnit,
                                    basis: .percent)
    }

    /// 上游改动预算点或重算配额时百分比会整体跳变，跨断点的样本不同尺度。
    /// 判据是「`resetAt` 不变却大幅回落」：窗口正常重置时 `resetAt` 必变。
    /// 返回最后一个断点的时刻，之前的样本一概不用。
    private func epochStart(_ samples: [Sample]) -> Double {
        var cut = 0.0
        for (a, b) in zip(samples, samples.dropFirst())
        where b.resetAt == a.resetAt && a.percent - b.percent >= Self.epochDrop {
            cut = b.at
        }
        return cut
    }

    /// 逐对配对出 (支出, 增量) 观测。两侧都挂起：增量不动时支出累积，
    /// 支出未落账时增量累积。后者不可省——账本按请求完成时刻计费，
    /// 有请求在途时增量先涨、美元后落，丢掉这些增量会少算分母，
    /// 实测在 5 小时窗口上丢掉 91/270 步、12.7 个百分点，满额因此高估约三成。
    private func observe(_ steps: [Step], ledger: CostLedger,
                         group: String?) -> [(cost: Double, unit: Double)] {
        var observations: [(cost: Double, unit: Double)] = []
        var pendingCost = 0.0
        var pendingUnit = 0.0
        // 「有增量、无支出」的起始时刻，仅用于超时判定。
        var unitSince: Double?
        for (a, b) in zip(steps, steps.dropFirst()) {
            // 窗口滚动：重置时刻变化或累计量回落，跨界的支出无法归属，丢弃。
            if b.resetAt != a.resetAt || b.value < a.value {
                pendingCost = 0
                pendingUnit = 0
                unitSince = nil
                continue
            }
            let cost = ledger.spent(from: Date(timeIntervalSince1970: a.at),
                                    to: Date(timeIntervalSince1970: b.at), group: group)
            // 挂起的增量超时即弃，不看本对是否带支出：他人占用推高百分比后
            // 长期平稳，下一个样本恰与本机请求同至时，带支出的解决对若能绕过超时，
            // 陈旧的外部增量就配进了本机美元，拉低满额。本对自身的增量在丢弃之后
            // 照常累加，与本对的支出合法配对。龄期两端都取增量可见的时刻（b.at）。
            if let since = unitSince, b.at - since > Self.carryTimeout {
                pendingUnit = 0
                unitSince = nil
            }
            pendingCost += cost
            pendingUnit += b.value - a.value
            if pendingCost > 0, pendingUnit > 0 {
                observations.append((pendingCost, pendingUnit))
                pendingCost = 0
                pendingUnit = 0
                unitSince = nil
            } else if pendingUnit > 0, unitSince == nil {
                unitSince = b.at
            }
        }
        return observations
    }

    /// 按逐对隐含单价裁掉两端各 10%。上游重算配额会造成增量跳变，
    /// 这类样本的隐含单价畸低，需要剔除以免拉低整体估计。
    private func trimOutliers(_ obs: [(cost: Double, unit: Double)]) -> [(cost: Double, unit: Double)] {
        guard obs.count >= 10 else { return obs }
        let sorted = obs.sorted { $0.cost / $0.unit < $1.cost / $1.unit }
        let drop = max(1, sorted.count / 10)
        return Array(sorted[drop..<(sorted.count - drop)])
    }

    private func confidence(observations: Int, covered: Double) -> Calibration.Confidence {
        if covered >= 20 && observations >= 15 { return .high }
        if covered >= 5 && observations >= 5 { return .medium }
        return .low
    }

    func sampleCount(label: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return state.samples[label]?.count ?? 0
    }

    func pointSampleCount(label: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return state.points?[label]?.count ?? 0
    }

    /// 供 CLI 自检使用。
    func debugDump(label: String, ledger: CostLedger, budget: Double? = nil,
                   group: String? = nil) -> String {
        guard let e = estimate(label: label, ledger: ledger, budget: budget, group: group)
        else { return "\(label): 样本不足" }
        return String(format: "%@: 满额 $%.0f  观测 %d  覆盖 %.1f%%  置信 %@  口径 %@",
                      label, e.fullUSD, e.observations, e.coveredPercent,
                      e.confidence.label, e.basis.label)
    }
}
