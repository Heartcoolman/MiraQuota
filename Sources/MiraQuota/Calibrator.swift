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
    }

    struct Estimate: Sendable {
        let fullUSD: Double
        let confidence: Confidence
        let observations: Int
        /// 标定累计覆盖的百分比跨度，是置信度的主要依据。
        let coveredPercent: Double
    }
}

/// 满额自校准。
///
/// 额度百分比与 API 等价支出在观测窗口内呈线性关系，故满额可由
/// 「一段时间的支出 ÷ 同期百分比增量」反推。百分比只精确到 0.1%，
/// 支出与百分比增量两侧都会挂起到对面也非零时才成为一次观测：
/// 只挂起支出会低估满额，只挂起百分比会高估（见 `estimate`）。
final class Calibrator {
    private struct Sample: Codable {
        let at: Double
        let percent: Double
        let resetAt: Double
    }

    private struct Persisted: Codable {
        var samples: [String: [Sample]] = [:]
    }

    /// 样本保留时长。
    static let retention: TimeInterval = 14 * 86400
    /// 单窗口样本上限，防止长期运行后无界增长。
    static let maxSamples = 4000
    /// 挂起的百分比增量等待本机支出的上限。超过此时长仍无支出，
    /// 判为账号池中他人的占用，不能记到本机美元上。实测归属滞后均在 4 分钟内消解。
    static let carryTimeout: TimeInterval = 600

    private var state = Persisted()
    private let lock = NSLock()

    init() { load() }

    // MARK: 持久化

    private func load() {
        guard let data = try? Data(contentsOf: Paths.calibState),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
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
        if let data = try? Data(contentsOf: Paths.calibState),
           let disk = try? JSONDecoder().decode(Persisted.self, from: data) {
            for (label, diskSamples) in disk.samples {
                var byTime: [Int: Sample] = [:]
                for s in diskSamples { byTime[Int(s.at)] = s }
                for s in state.samples[label] ?? [] { byTime[Int(s.at)] = s }
                state.samples[label] = byTime.values.sorted { $0.at < $1.at }
            }
        }
        prune()
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Paths.calibState, options: .atomic)
    }

    // MARK: 采样

    /// 记录一次观测。百分比未变时不追加，使支出自然累积到下一个变化点。
    func record(_ snapshot: RelaySnapshot) {
        lock.lock(); defer { lock.unlock() }
        var dirty = false
        for w in snapshot.windows {
            let s = Sample(at: snapshot.capturedAt.timeIntervalSince1970,
                           percent: w.usedPercent,
                           resetAt: w.resetAt.timeIntervalSince1970)
            if appendIfChanged(label: w.label, s) { dirty = true }
        }
        if dirty { save() }
    }

    /// 冷启动时导入 relay 自带的百分比环形缓冲，缩短首次标定等待。
    func seed(from snapshot: RelaySnapshot) {
        lock.lock(); defer { lock.unlock() }
        var dirty = false
        for w in snapshot.windows {
            let key = w.label.lowercased()
            let pick: (RelaySnapshot.HistoryPoint) -> Double? =
                key == "5h" ? { $0.fiveHour } : (key == "7d" ? { $0.sevenDay } : { _ in nil })
            guard let start = w.startAt else { continue }
            for point in snapshot.history.sorted(by: { $0.at < $1.at }) {
                guard point.at >= start, let p = pick(point) else { continue }
                let s = Sample(at: point.at.timeIntervalSince1970, percent: p,
                               resetAt: w.resetAt.timeIntervalSince1970)
                if appendIfChanged(label: w.label, s) { dirty = true }
            }
        }
        if dirty { save() }
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

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.retention).timeIntervalSince1970
        for (k, v) in state.samples {
            var kept = v.filter { $0.at >= cutoff }
            if kept.count > Self.maxSamples { kept.removeFirst(kept.count - Self.maxSamples) }
            state.samples[k] = kept
        }
    }

    // MARK: 估算

    func estimate(label: String, ledger: CostLedger) -> Calibration.Estimate? {
        lock.lock()
        let samples = state.samples[label] ?? []
        lock.unlock()
        guard samples.count >= 2 else { return nil }

        // (支出, 百分比增量) 观测。两侧都挂起：百分比不动时支出累积，
        // 支出未落账时百分比累积。后者不可省——账本按请求完成时刻计费，
        // 有请求在途时百分比先涨、美元后落，丢掉这些增量会少算分母，
        // 实测在 5 小时窗口上丢掉 91/270 步、12.7 个百分点，满额因此高估约三成。
        var observations: [(cost: Double, percent: Double)] = []
        var pendingCost = 0.0
        var pendingPercent = 0.0
        // 「有百分比、无支出」的起始时刻，仅用于超时判定。
        var percentSince: Double?
        for (a, b) in zip(samples, samples.dropFirst()) {
            // 窗口滚动：重置时刻变化或百分比回落，跨界的支出无法归属，丢弃。
            if b.resetAt != a.resetAt || b.percent < a.percent {
                pendingCost = 0
                pendingPercent = 0
                percentSince = nil
                continue
            }
            let cost = ledger.spent(from: Date(timeIntervalSince1970: a.at),
                                    to: Date(timeIntervalSince1970: b.at))
            // 挂起的百分比增量超时即弃，不看本对是否带支出：他人占用推高百分比后
            // 长期平稳，下一个样本恰与本机请求同至时，带支出的解决对若能绕过超时，
            // 陈旧的外部增量就配进了本机美元，拉低满额。本对自身的增量在丢弃之后
            // 照常累加，与本对的支出合法配对。龄期两端都取增量可见的时刻（b.at）。
            if let since = percentSince, b.at - since > Self.carryTimeout {
                pendingPercent = 0
                percentSince = nil
            }
            pendingCost += cost
            pendingPercent += b.percent - a.percent
            if pendingCost > 0, pendingPercent > 0 {
                observations.append((pendingCost, pendingPercent))
                pendingCost = 0
                pendingPercent = 0
                percentSince = nil
            } else if pendingPercent > 0, percentSince == nil {
                percentSince = b.at
            }
        }
        guard !observations.isEmpty else { return nil }

        let used = trimOutliers(observations)
        let totalCost = used.reduce(0) { $0 + $1.cost }
        let totalPercent = used.reduce(0) { $0 + $1.percent }
        guard totalPercent > 0, totalCost > 0 else { return nil }

        let full = totalCost / totalPercent * 100
        return Calibration.Estimate(fullUSD: full,
                                    confidence: confidence(observations: used.count, covered: totalPercent),
                                    observations: used.count,
                                    coveredPercent: totalPercent)
    }

    /// 按逐对隐含满额裁掉两端各 10%。账号池共享会造成百分比跳变，
    /// 这类样本的隐含满额畸低，需要剔除以免拉低整体估计。
    private func trimOutliers(_ obs: [(cost: Double, percent: Double)]) -> [(cost: Double, percent: Double)] {
        guard obs.count >= 10 else { return obs }
        let sorted = obs.sorted { $0.cost / $0.percent < $1.cost / $1.percent }
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

    /// 供 CLI 自检使用。
    func debugDump(label: String, ledger: CostLedger) -> String {
        guard let e = estimate(label: label, ledger: ledger) else { return "\(label): 样本不足" }
        return String(format: "%@: 满额 $%.0f  观测 %d  覆盖 %.1f%%  置信 %@",
                      label, e.fullUSD, e.observations, e.coveredPercent, e.confidence.label)
    }
}
