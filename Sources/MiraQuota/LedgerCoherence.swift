import Foundation

/// 账本美元与 `/v1/limits` 额度点的自洽性核算。
///
/// 兜底满额是「每点美元 × 预算点」，每点美元只能由本机账本反推，账本超算或点数漏计会把
/// 全部满额同倍放大，界面上只留一个 `~` 前缀，读不出偏了多少。窗口之间可互为交叉验证：
/// 5h 是 7d 的时间子集，两者反推的每点美元应同量级（同机实测跨窗口 $0.00235–0.00502），
/// 离散超阈值说明至少一侧失真而无从判定是哪一侧，此时不给美元。
enum LedgerCoherence {
    /// 单个窗口反推出的每点美元。
    struct Rate {
        let label: String
        let points: Double
        let usd: Double
        var perPoint: Double { usd / points }
    }

    struct Result {
        let rates: [Rate]
        /// 点数最多的窗口反推的每点美元；判为不自洽时为 nil。
        let perPoint: Double?
        /// 反推所用的窗口名。`perPoint` 为 nil 时仍保留，供自检显示。
        let basis: Rate?
        /// 最大与最小每点美元之比，参与交叉验证的窗口不足两个时为 nil。
        let spread: Double?
        var incoherent: Bool { spread.map { $0 > LedgerCoherence.maxSpread } ?? false }
    }

    /// 参与反推的最低已用点数。窗口刚重置时点数太少，比值失真。
    static let minPoints: Double = 200
    /// 参与交叉验证的最低已用点数，比 `minPoints` 高一档：几百点的窗口里一次高价请求
    /// 就能把比值拉开数倍，据此判不自洽会误伤刚重置的窗口。
    static let minPointsForCross: Double = 500
    /// 每点美元的跨窗口离散上限。同机实测跨 2.1 倍，取 4 倍留余量。
    static let maxSpread: Double = 4

    /// modelScoped 窗口不参与：其账本分桶自档位声明起才累积，支出系统性偏低。
    static func evaluate(_ limits: LimitsSnapshot, ledger: CostLedger, now: Date) -> Result {
        var rates: [Rate] = []
        for w in limits.windows {
            guard !w.modelScoped, w.used >= minPoints,
                  let start = w.quotaWindow.startAt else { continue }
            // 已用点数含开分钟内的消耗（快照是即时值），美元不含会系统性压低单价。
            let usd = ledger.spent(from: start, to: now, includeOpenMinute: true)
            guard usd > 0 else { continue }
            rates.append(Rate(label: w.label, points: w.used, usd: usd))
        }
        guard let best = rates.max(by: { $0.points < $1.points }) else {
            return Result(rates: rates, perPoint: nil, basis: nil, spread: nil)
        }
        let cross = rates.filter { $0.points >= minPointsForCross }.map(\.perPoint)
        var spread: Double?
        if let hi = cross.max(), let lo = cross.min(), cross.count >= 2, lo > 0 {
            spread = hi / lo
        }
        let bad = spread.map { $0 > maxSpread } ?? false
        return Result(rates: rates, perPoint: bad ? nil : best.perPoint,
                      basis: best, spread: spread)
    }

    /// 兜底停用的原因，供两个显示面与控件共用一套说法。自洽时为 nil。
    static func notice(_ result: Result) -> String? {
        guard result.incoherent, let spread = result.spread else { return nil }
        return String(format: "回归标定优先 · 兜底停用：账本与点数不自洽（离散 %.1f×）", spread)
    }
}
