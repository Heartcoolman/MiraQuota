import Foundation

/// 一个模型每美元（价目）扣多少额度点。
struct ModelRate: Sendable {
    enum Source: String, Sendable {
        /// 近 72 小时点数样本实测。
        case measured
        /// 存档里的实测值，锚点模型的扣点率此后未明显变化。
        case lastMeasured
        /// 由存档按锚点变化换算，或由历史百分比样本回归出的相对倍率推算。
        case estimated
        /// 无任何数据。
        case unknown
    }

    let key: String
    let pointsPerUSD: Double?
    let source: Source
    /// 来源说明：方法、时段与证据，供悬浮提示与自检。
    let note: String
    let measuredAt: Date?
    let evidenceUSD: Double
    let evidencePoints: Double
    let bins: Int
    let relErr: Double?

    var name: String { Pricing.displayName(key) }
    var tag: String? {
        switch source {
        case .estimated: return "估"
        case .unknown: return "待测"
        default: return nil
        }
    }

    static func unknown(_ key: String) -> ModelRate {
        ModelRate(key: key, pointsPerUSD: nil, source: .unknown, note: "无数据", measuredAt: nil,
                  evidenceUSD: 0, evidencePoints: 0, bins: 0, relErr: nil)
    }
}

/// 额度窗口的分族树：`/v1/limits` 的档位窗口按名字包含关系嵌套（实测 fable ⊂ claude ⊂ 7d）。
/// 每个节点的「格」是只属于该节点、不属于任何子节点的模型，格内点数 = 本窗口已用 − 子窗口已用，
/// 是上游直接给出的分族扣点，不需要回归。
struct QuotaTree: Sendable {
    struct Node: Sendable {
        let label: String
        /// 档位组名，根节点为 nil（匹配全部模型）。
        let group: String?
        let children: [String]
    }

    let root: String
    let nodes: [String: Node]
    let resetAt: Date

    /// 以最长的非档位窗口为根，挂上与它同一重置时刻的档位窗口。
    /// 子集判定看已知模型键：A 的成员全都匹配 B 且 B 严格更大，则 A 挂在 B 下。
    init?(limits: LimitsSnapshot, knownKeys: Set<String>) {
        let scoped = limits.windows.filter { $0.modelScoped && $0.modelGroup != nil }
        guard let rootWindow = limits.windows
            .filter({ w in !w.modelScoped && scoped.contains { $0.resetAt == w.resetAt } })
            .max(by: { $0.budget < $1.budget }) else { return nil }
        let members = scoped.filter { $0.resetAt == rootWindow.resetAt }
        func matching(_ group: String) -> Set<String> { knownKeys.filter { $0.contains(group) } }
        var parent: [String: String] = [:]
        for a in members {
            let setA = matching(a.modelGroup!)
            let host = members.filter { b in
                guard b.label != a.label else { return false }
                let setB = matching(b.modelGroup!)
                return !setA.isEmpty && setA.isSubset(of: setB) && setB.count > setA.count
            }.min { $0.budget < $1.budget }
            parent[a.label] = host?.label ?? rootWindow.label
        }
        var nodes: [String: Node] = [:]
        nodes[rootWindow.label] = Node(label: rootWindow.label, group: nil,
                                       children: members.filter { parent[$0.label] == rootWindow.label }.map(\.label))
        for m in members {
            nodes[m.label] = Node(label: m.label, group: m.modelGroup,
                                  children: members.filter { parent[$0.label] == m.label }.map(\.label))
        }
        root = rootWindow.label
        self.nodes = nodes
        resetAt = rootWindow.resetAt
    }

    /// 模型所在的格：从根往下走到最深的匹配节点。
    func cell(of key: String) -> String {
        var label = root
        while let next = nodes[label]?.children.first(where: { c in
            nodes[c]?.group.map { key.contains($0) } ?? false
        }) { label = next }
        return label
    }

    /// 某格的点数：节点已用减去各子节点已用。
    func cellPoints(_ label: String, used: (String) -> Double?) -> Double? {
        guard let node = nodes[label], let own = used(label) else { return nil }
        var sum = own
        for c in node.children {
            guard let v = used(c) else { return nil }
            sum -= v
        }
        return max(0, sum)
    }

    var cells: [String] { Array(nodes.keys).sorted() }
}

/// 扣点率估计。代码里不写任何模型的倍率，一律由本机数据求得：
/// 1. 实测：近 72 小时的点数样本按 10 分钟分箱，逐格对点数增量与各模型支出拟合。
/// 2. 上次实测：`rates.json` 存档。锚点模型的扣点率此后变化超过 25%，按存档时的相对倍率换算，标「估」。
/// 3. 历史推算：保留 14 天的百分比样本里该模型与同期锚点族模型各自的「增量 ÷ 支出」之比 × 锚点当前扣点率，标「估」。
/// 4. 待测。
///
/// 锚点取花名册的 Claude 默认模型（现为 Opus 5.5），它用量最大，扣点率最稳。
final class PointRates {
    private struct Stored: Codable {
        var rate: Double
        var at: Double
        var usd: Double
        var points: Double
        var anchorAtMeasure: Double?
        var method: String
    }

    private struct Persisted: Codable {
        var v: Int = 1
        var models: [String: Stored] = [:]
    }

    /// 分箱宽度与右端余量：token 由中继事后回填，最近几分钟的支出尚未落账。
    static let binSeconds = 600
    static let settle = 300
    static let span: TimeInterval = 72 * 3600
    static let halfLife: TimeInterval = 24 * 3600

    private(set) var table: [String: ModelRate] = [:]
    private(set) var tree: QuotaTree?
    private(set) var anchorKey = "claude-opus-5-5"
    private(set) var anchorRate: Double?
    private var stored = Persisted()
    private var lastRun: Date?
    private var lastSave: Date?
    private var savedRates: [String: Double] = [:]

    init() {
        if let data = try? Data(contentsOf: Paths.rateState),
           let p = try? JSONDecoder().decode(Persisted.self, from: data) { stored = p }
        savedRates = stored.models.mapValues(\.rate)
    }

    func rate(_ key: String) -> ModelRate { table[key] ?? .unknown(key) }

    /// 同一格内按支出加权的扣点率，未知成员不计。供档位窗口的满额退路使用。
    func groupRate(_ group: String?, spend: [String: Double]) -> Double? {
        var usd = 0.0, pts = 0.0
        for (key, s) in spend where group.map({ key.contains($0) }) ?? true {
            guard let r = table[key]?.pointsPerUSD else { continue }
            usd += s
            pts += s * r
        }
        return usd > 0 ? pts / usd : nil
    }

    // MARK: 刷新

    func refresh(limits: LimitsSnapshot, calibrator: Calibrator, ledger: CostLedger,
                 pricing: Pricing, now: Date = Date()) {
        if let lastRun, now.timeIntervalSince(lastRun) < 60, tree != nil { return }
        lastRun = now
        anchorKey = pricing.rosterDefault.map(pricing.key(for:)) ?? anchorKey
        let spendAll = ledger.spendByModel(from: now.addingTimeInterval(-CostLedger.retention), to: now,
                                           includeOpenMinute: true)
        let known = Set(spendAll.keys).union(pricing.rosterIds).union(stored.models.keys).union([anchorKey])
        guard let tree = QuotaTree(limits: limits, knownKeys: known) else { return }
        self.tree = tree

        let fresh = measure(tree: tree, calibrator: calibrator, ledger: ledger, now: now)
        let anchorStored = stored.models[anchorKey].flatMap { now.timeIntervalSince1970 - $0.at <= 30 * 86400 ? $0 : nil }
        anchorRate = fresh[anchorKey]?.pointsPerUSD ?? anchorStored?.rate

        var out: [String: ModelRate] = [:]
        for key in known {
            if let f = fresh[key] { out[key] = f; continue }
            if let s = fromStore(key, now: now) { out[key] = s; continue }
            out[key] = (spendAll[key] ?? 0) > 0
                ? ModelRate(key: key, pointsPerUSD: nil, source: .unknown, note: "有用量，但实测与历史推算均未达证据门槛",
                            measuredAt: nil, evidenceUSD: spendAll[key] ?? 0, evidencePoints: 0, bins: 0, relErr: nil)
                : .unknown(key)
        }
        // 历史推算只补前两步都没有的模型，且要有锚点当前扣点率可乘。
        if let anchorRate, let label = limits.windows.filter({ !$0.modelScoped }).min(by: { $0.budget < $1.budget })?.label {
            for key in known where out[key]?.source == .unknown && key != anchorKey {
                if let h = historical(key, label: label, calibrator: calibrator, pricing: pricing,
                                      anchorNow: anchorRate, now: now) {
                    out[key] = h
                }
            }
        }
        table = out
        persist(fresh: fresh, now: now)
    }

    // MARK: 1. 实测

    private struct Bin {
        let y: Double
        let x: [String: Double]
        let w: Double
    }

    /// 以样本时刻为箱边界：样本只在数值变化时追加，相邻样本之间的增量只能配同一区间的支出。
    /// 固定网格在 MiraQuota 停机后会把停机期间累积的点数压进恢复后的一箱，而支出散在整段停机里。
    /// 相邻样本合并到不短于 10 分钟；跨窗口重置不合并。`breaks` 为额外的断点判据（如预算点变更）。
    private static func edges(_ times: [Double], series: [String: [Calibrator.SeriesPoint]],
                              breaks: (Calibrator.SeriesPoint, Calibrator.SeriesPoint) -> Bool = { _, _ in false })
        -> [(t0: Double, t1: Double)] {
        var out: [(Double, Double)] = []
        var i = 0
        while i < times.count - 1 {
            var j = i + 1
            while j < times.count - 1, times[j] - times[i] < Double(binSeconds),
                  !crosses(series, times[j], times[j + 1], breaks: breaks) { j += 1 }
            if !crosses(series, times[i], times[j], breaks: breaks) { out.append((times[i], times[j])) }
            i = j
        }
        return out
    }

    private static func crosses(_ series: [String: [Calibrator.SeriesPoint]], _ a: Double, _ b: Double,
                                breaks: (Calibrator.SeriesPoint, Calibrator.SeriesPoint) -> Bool) -> Bool {
        let va = values(series, at: a), vb = values(series, at: b)
        return series.keys.contains { k in
            guard let x = va[k], let y = vb[k] else { return true }
            return x.resetAt != y.resetAt || breaks(x, y)
        }
    }

    private func measure(tree: QuotaTree, calibrator: Calibrator, ledger: CostLedger,
                         now: Date) -> [String: ModelRate] {
        let series = Dictionary(uniqueKeysWithValues: tree.nodes.keys.map { ($0, calibrator.pointSeries($0)) })
        guard let firstCommon = series.values.compactMap({ $0.first?.at }).max() else { return [:] }
        let from = max(now.timeIntervalSince1970 - Self.span, firstCommon)
        let to = now.timeIntervalSince1970 - Double(Self.settle)
        // 根窗口包含全部模型，任一格有变化根都会追加样本，其样本时刻即全部边界。
        let times = (series[tree.root] ?? []).map(\.at).filter { $0 >= from && $0 <= to }
        guard times.count >= 2 else { return [:] }

        let keys = ledger.spendByModel(from: Date(timeIntervalSince1970: from), to: Date(timeIntervalSince1970: to)).keys
        let cellOf = Dictionary(uniqueKeysWithValues: keys.map { ($0, tree.cell(of: $0)) })
        let unpriced = ledger.unpricedCalls.map { (minute: $0.minute, cell: tree.cell(of: $0.key)) }

        var bins: [String: [Bin]] = [:]
        for (t0, t1) in Self.edges(times, series: series) {
            let a = Self.values(series, at: t0), b = Self.values(series, at: t1)
            let w = pow(0.5, (now.timeIntervalSince1970 - t1) / Self.halfLife)
            let d0 = Date(timeIntervalSince1970: t0), d1 = Date(timeIntervalSince1970: t1)
            for cell in tree.cells {
                guard let p0 = tree.cellPoints(cell, used: { a[$0]?.value }),
                      let p1 = tree.cellPoints(cell, used: { b[$0]?.value }) else { continue }
                let dy = p1 - p0
                guard dy >= -1 else { continue }
                let m0 = Int(t0) / 60, m1 = Int(t1) / 60
                if unpriced.contains(where: { $0.cell == cell && $0.minute >= m0 && $0.minute < m1 }) { continue }
                var x: [String: Double] = [:]
                for (key, c) in cellOf where c == cell {
                    let v = ledger.spent(from: d0, to: d1, model: key)
                    if v > 0 { x[key] = v }
                }
                bins[cell, default: []].append(Bin(y: max(0, dy), x: x, w: w))
            }
        }

        var out: [String: ModelRate] = [:]
        for (_, list) in bins {
            let kept = Self.dropOffLedgerRuns(list)
            for r in fit(kept, now: now, span: (from, to)) { out[r.key] = r }
        }
        return out
    }

    /// 连续 3 箱以上「有点数、无支出」多是账本看不到的消耗（另一台设备、未入账的调用），整段剔出拟合。
    /// 单独一两箱多为调用跨箱完成的滞后，保留，靠比值之和吸收。
    private static func dropOffLedgerRuns(_ list: [Bin]) -> [Bin] {
        var keep = [Bool](repeating: true, count: list.count)
        var i = 0
        while i < list.count {
            guard list[i].y > 0, list[i].x.isEmpty else { i += 1; continue }
            var j = i
            while j < list.count, list[j].y > 0, list[j].x.isEmpty { j += 1 }
            if j - i >= 3 { for k in i..<j { keep[k] = false } }
            i = j
        }
        return zip(list, keep).filter(\.1).map(\.0)
    }

    private func fit(_ bins: [Bin], now: Date, span: (Double, Double)) -> [ModelRate] {
        var raw: [String: Double] = [:], active: [String: Int] = [:]
        for b in bins {
            for (k, v) in b.x { raw[k, default: 0] += v; active[k, default: 0] += 1 }
        }
        let total = raw.values.reduce(0, +)
        let material = raw.filter { $0.value >= max(0.10, 0.03 * total) }.keys.sorted()
        guard !material.isEmpty else { return [] }
        let range = Self.dayRange(span.0, span.1)

        if material.count == 1, let m = material.first {
            // 小额成员有已知扣点率就先扣掉它们的点，否则并进分母（视同本模型的扣点率）。
            var sy = 0.0, sx = 0.0
            for b in bins {
                sy += b.w * b.y
                for (k, v) in b.x {
                    if k == m { sx += b.w * v } else if let r = prior(k) { sy -= b.w * v * r } else { sx += b.w * v }
                }
            }
            guard sx > 0 else { return [] }
            let r = max(0, sy / sx)
            let usd = raw[m] ?? 0, pts = r * usd, n = active[m] ?? 0
            guard usd >= 0.5, pts >= 50, n >= 2 else { return [] }
            return [ModelRate(key: m, pointsPerUSD: r, source: .measured,
                              note: String(format: "实测 · %@ · $%.2f · %.0f 点 · %d 箱", range, usd, pts, n),
                              measuredAt: now, evidenceUSD: usd, evidencePoints: pts, bins: n, relErr: nil)]
        }

        // 多成员：带先验约束的非负最小二乘。先验取存档或历史回归的当前最佳值，无先验的不加约束。
        // 小额成员不进回归：有已知扣点率的先从点数里扣掉，没有的份额在 3% 以下，忽略。
        let rows = bins.map { b in
            let minor = b.x.reduce(0.0) { acc, kv in
                material.contains(kv.key) ? acc : acc + kv.value * (prior(kv.key) ?? 0)
            }
            return (y: max(0, b.y - minor), x: material.map { b.x[$0] ?? 0 }, w: b.w)
        }
        let priors = material.map(prior)
        let meanSq = material.indices.map { j in rows.reduce(0) { $0 + $1.w * $1.x[j] * $1.x[j] } }
        let lambda = 0.05 * meanSq.reduce(0, +) / Double(material.count)
        guard let sol = LinearFit.solve(rows: rows, priors: priors, lambda: lambda) else { return [] }
        var out: [ModelRate] = []
        for (j, m) in material.enumerated() {
            let r = sol.coef[j], usd = raw[m] ?? 0, pts = r * usd, n = active[m] ?? 0
            let rel = sol.se[j].map { r > 0 ? $0 / r : .infinity }
            guard usd >= 2, pts >= 200, n >= 4, let rel, rel <= 0.15 else { continue }
            out.append(ModelRate(key: m, pointsPerUSD: r, source: .measured,
                                 note: String(format: "回归 · %@ · $%.2f · %.0f 点 · %d 箱 · ±%.0f%%",
                                              range, usd, pts, n, rel * 100),
                                 measuredAt: now, evidenceUSD: usd, evidencePoints: pts, bins: n, relErr: rel))
        }
        return out
    }

    /// 非实测的当前最佳值：存档（含换算）优先，其次历史回归，用作多成员拟合的先验与小额成员的扣除。
    private func prior(_ key: String) -> Double? {
        if let s = fromStore(key, now: Date()) { return s.pointsPerUSD }
        return table[key]?.pointsPerUSD
    }

    // MARK: 2. 上次实测

    private func fromStore(_ key: String, now: Date) -> ModelRate? {
        guard let s = stored.models[key] else { return nil }
        let age = now.timeIntervalSince1970 - s.at
        guard age <= 30 * 86400 else { return nil }
        let at = Date(timeIntervalSince1970: s.at)
        let day = Self.dayRange(s.at, s.at)
        if let anchor = anchorRate, let then = s.anchorAtMeasure, then > 0, key != anchorKey {
            let drift = anchor / then
            if age > 14 * 86400 || abs(drift - 1) > 0.25 {
                return ModelRate(key: key, pointsPerUSD: s.rate * drift, source: .estimated,
                                 note: String(format: "存档换算 · %@ 实测 %.1f 点/$，锚点其后变化 ×%.2f", day, s.rate, drift),
                                 measuredAt: at, evidenceUSD: s.usd, evidencePoints: s.points, bins: 0, relErr: nil)
            }
        } else if age > 14 * 86400 {
            return ModelRate(key: key, pointsPerUSD: s.rate, source: .estimated,
                             note: String(format: "存档 · %@ 实测，已逾 14 天", day),
                             measuredAt: at, evidenceUSD: s.usd, evidencePoints: s.points, bins: 0, relErr: nil)
        }
        return ModelRate(key: key, pointsPerUSD: s.rate, source: .lastMeasured,
                         note: String(format: "上次实测 · %@ · $%.2f · %.0f 点", day, s.usd, s.points),
                         measuredAt: at, evidenceUSD: s.usd, evidencePoints: s.points, bins: 0, relErr: nil)
    }

    // MARK: 3. 历史推算

    /// 百分比样本的历史推算：取预算最小的通用窗口（5h，0.1% 分辨率折合的点数最少），
    /// 以样本时刻分箱，只用「单一模型占该箱支出 ≥ 90%」的箱，逐模型求「Σ百分比增量 ÷ Σ支出」。
    /// 混用的箱无从拆分，直接不用；支出为零的箱不进任何模型，停机或他处的消耗因此不会被错配。
    /// 同一预算时期内（重置时刻不变却回落 ≥ 5 个点即预算变更，另起一段）两个模型的比值与预算点无关。
    /// 相对倍率取该模型与同段内锚点族（Opus）支出最多的模型之比，通常就是锚点本身，再乘锚点当前扣点率。
    /// 隐含「该模型自上次观测以来未调价」的假设；曾试过只取锚点以外的同期 Opus 作参照，
    /// 其证据太薄（09-26 实测 Opus 5 仅 5 箱、±45%），推不出任何模型。一律标「估」，用到后即被实测替换。
    private struct Ratio {
        var y = 0.0, x = 0.0, n = 0
        var pairs: [(Double, Double)] = []
        var value: Double { x > 0 ? y / x : 0 }
        /// 比值和的相对标准误。
        var relErr: Double? {
            guard n >= 2, value > 0 else { return nil }
            let r = value
            let sse = pairs.reduce(0) { $0 + ($1.0 - r * $1.1) * ($1.0 - r * $1.1) }
            return (sse * Double(n) / Double(n - 1)).squareRoot() / x / r
        }
    }

    private var history: (at: Date, label: String, table: [Int: [String: Ratio]])?

    /// 网关账本的逐次调用（完成时刻、模型键、价目美元），秒级。历史推算以样本时刻为箱边界，
    /// 账本的分钟桶会把边界附近的调用归进相邻的箱，稀疏的模型受害最重：09-26 对照 Mirasim 90 天导出，
    /// 分钟取整复现出软件原先的 Opus 5 ×3.54 ±45%、Fable 5.1 ×3.31 ±24%，秒级则为 ×1.95 ±7%、×4.12 ±4%。
    /// 只取经中继的行，口径同 `CostLedger.parseGatewayLine`。
    private static func gatewayCalls(pricing: Pricing, since: Double) -> [(at: Double, key: String, usd: Double)] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: Paths.mirasimInsights,
                                                                       includingPropertiesForKeys: nil) else { return [] }
        var out: [(Double, String, Double)] = []
        for file in files where file.lastPathComponent.hasPrefix("usage-") && file.pathExtension == "ndjson" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let root = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let ts = root["ts"] as? String, let start = fastEpochSeconds(ts),
                      Double(start) >= since - 86400,
                      (root["viaRelay"] as? Bool) ?? ((root["upstreamHost"] as? String)?.contains("mirasim") ?? false),
                      let model = root["model"] as? String, !model.isEmpty else { continue }
                let ms = (root["durationMs"] as? Int) ?? 0
                let done = Double(start) + Double(ms) / 1000
                guard done >= since,
                      let usd = pricing.cost(model: model, input: (root["input"] as? Int) ?? 0,
                                             output: (root["output"] as? Int) ?? 0,
                                             cacheRead: (root["cacheRead"] as? Int) ?? 0,
                                             cacheWrite: (root["cacheWrite"] as? Int) ?? 0, at: start),
                      usd > 0 else { continue }
                out.append((done, pricing.key(for: model), usd))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    private func historyTable(_ label: String, calibrator: Calibrator, pricing: Pricing,
                              now: Date) -> [Int: [String: Ratio]] {
        // 历史只随新样本缓慢变化，每小时重算一次。
        if let h = history, h.label == label, now.timeIntervalSince(h.at) < 3600 { return h.table }
        let series = [label: calibrator.percentSeries(label)]
        let to = now.timeIntervalSince1970 - Double(Self.settle)
        let from = now.timeIntervalSince1970 - 14 * 86400
        let list = series[label]!.filter { $0.at >= from && $0.at <= to }
        let times = list.map(\.at)
        guard times.count >= 2 else { return [:] }
        let calls = Self.gatewayCalls(pricing: pricing, since: from)
        let callTimes = calls.map(\.at)
        // 预算变更：重置时刻不变而百分比回落 ≥ 5 个点（同 `Calibrator.epochDrop`）。
        let isBreak = { (a: Calibrator.SeriesPoint, b: Calibrator.SeriesPoint) in
            a.resetAt == b.resetAt && a.value - b.value >= Calibrator.epochDrop
        }
        var epoch = 0
        var table: [Int: [String: Ratio]] = [:]
        var lastEnd: Double?
        for (t0, t1) in Self.edges(times, series: series, breaks: isBreak) {
            let a = Self.values(series, at: t0)[label]!, b = Self.values(series, at: t1)[label]!
            if let e = lastEnd, let pe = Self.values(series, at: e)[label], isBreak(pe, a) { epoch += 1 }
            lastEnd = t1
            let dy = b.value - a.value
            guard dy >= -0.2 else { continue }
            var spend: [String: Double] = [:]
            let lo = Self.lowerBound(callTimes, t0), hi = Self.lowerBound(callTimes, t1)
            for c in calls[lo..<hi] { spend[c.key, default: 0] += c.usd }
            let total = spend.values.reduce(0, +)
            guard total > 0, let top = spend.max(by: { $0.value < $1.value }), top.value >= 0.9 * total else { continue }
            var r = table[epoch, default: [:]][top.key] ?? Ratio()
            r.y += max(0, dy); r.x += total; r.n += 1; r.pairs.append((max(0, dy), total))
            table[epoch, default: [:]][top.key] = r
        }
        history = (now, label, table)
        return table
    }

    private func historical(_ key: String, label: String, calibrator: Calibrator, pricing: Pricing,
                            anchorNow: Double, now: Date) -> ModelRate? {
        let family = Self.family(of: anchorKey)
        let table = historyTable(label, calibrator: calibrator, pricing: pricing, now: now)
        // 取该模型证据最多的一段；参照取同段里锚点族中支出最多的模型。
        let candidates = table.compactMap { (epoch, byModel) -> (Ratio, String, Ratio)? in
            guard let m = byModel[key], m.x >= 2, m.n >= 4 else { return nil }
            guard let ref = byModel.filter({ $0.key != key && Self.family(of: $0.key) == family
                                              && $0.value.x >= 2 && $0.value.n >= 4 })
                .max(by: { $0.value.x < $1.value.x }) else { return nil }
            return (m, ref.key, ref.value)
        }
        guard let (m, refKey, ref) = candidates.max(by: { $0.0.x < $1.0.x }),
              m.value > 0, ref.value > 0, let em = m.relErr, let er = ref.relErr else { return nil }
        let ratio = m.value / ref.value
        let rel = (em * em + er * er).squareRoot()
        guard rel <= 0.25 else { return nil }
        return ModelRate(key: key, pointsPerUSD: ratio * anchorNow, source: .estimated,
                         note: String(format: "历史推算 · %@ 百分比样本 · $%.2f · %d 箱 · 相对 %@ ×%.2f · ±%.0f%%",
                                      label, m.x, m.n, Pricing.displayName(refKey), ratio, rel * 100),
                         measuredAt: nil, evidenceUSD: m.x, evidencePoints: 0, bins: m.n, relErr: rel)
    }

    // MARK: 存档

    /// 只存实测值。扣点率变动超过 0.5% 或距上次写盘满 10 分钟才写，读-合并-写在 flock 下进行，
    /// 常驻实例与 `--once` / `--doctor` 同时写不会互相覆盖。
    private func persist(fresh: [String: ModelRate], now: Date) {
        guard !fresh.isEmpty else { return }
        let moved = fresh.contains { k, r in
            guard let old = savedRates[k], let v = r.pointsPerUSD else { return true }
            return abs(v / old - 1) > 0.005
        }
        guard moved || lastSave.map({ now.timeIntervalSince($0) >= 600 }) ?? true else { return }
        Paths.ensureStateDir()
        let fd = open(Paths.rateLock.path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        if let data = try? Data(contentsOf: Paths.rateState),
           let disk = try? JSONDecoder().decode(Persisted.self, from: data) {
            for (k, s) in disk.models where (stored.models[k]?.at ?? 0) < s.at { stored.models[k] = s }
        }
        for (k, r) in fresh {
            guard let v = r.pointsPerUSD else { continue }
            stored.models[k] = Stored(rate: v, at: now.timeIntervalSince1970, usd: r.evidenceUSD,
                                      points: r.evidencePoints, anchorAtMeasure: anchorRate,
                                      method: r.relErr == nil ? "exact" : "regression")
        }
        let floor = now.timeIntervalSince1970 - 30 * 86400
        stored.models = stored.models.filter { $0.value.at >= floor }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: Paths.rateState, options: .atomic)
        savedRates = stored.models.mapValues(\.rate)
        lastSave = now
    }

    // MARK: 工具

    /// 各窗口在时刻 t 的取值：样本只在变化时追加，取不晚于 t 的最后一个即为当时的值。
    private static func values(_ series: [String: [Calibrator.SeriesPoint]], at t: Double)
        -> [String: Calibrator.SeriesPoint] {
        var out: [String: Calibrator.SeriesPoint] = [:]
        for (label, list) in series {
            var lo = 0, hi = list.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if list[mid].at <= t { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { out[label] = list[lo - 1] }
        }
        return out
    }

    private static func lowerBound(_ a: [Double], _ target: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// 模型族：去掉版本号之后的前缀，`claude-opus-5-5` → `claude-opus`。
    static func family(of key: String) -> String {
        key.split(separator: "-").prefix { !($0.first?.isNumber ?? false) }.joined(separator: "-")
    }

    private static func dayRange(_ a: Double, _ b: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        let s = f.string(from: Date(timeIntervalSince1970: a)), e = f.string(from: Date(timeIntervalSince1970: b))
        return s == e ? s : "\(s)–\(e)"
    }
}

/// 小规模加权最小二乘（成员数 ≤ 十来个），带可选的岭约束与非负约束。
enum LinearFit {
    /// `priors[j]` 非空时加一行 √λ·(r_j − p_j)；解出负系数的成员固定为 0 后重解。
    /// 返回系数与标准误（残差自由度不足时标准误为 nil）。
    static func solve(rows: [(y: Double, x: [Double], w: Double)], priors: [Double?], lambda: Double)
        -> (coef: [Double], se: [Double?])? {
        let k = priors.count
        guard k > 0, rows.count >= k else { return nil }
        var free = Array(0..<k)
        var coef = [Double](repeating: 0, count: k)
        var inverse: [[Double]] = []
        for _ in 0..<k {
            let n = free.count
            guard n > 0 else { break }
            var a = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var b = [Double](repeating: 0, count: n)
            for r in rows {
                for (i, fi) in free.enumerated() {
                    b[i] += r.w * r.x[fi] * r.y
                    for (j, fj) in free.enumerated() { a[i][j] += r.w * r.x[fi] * r.x[fj] }
                }
            }
            for (i, fi) in free.enumerated() {
                guard let p = priors[fi], lambda > 0 else { continue }
                a[i][i] += lambda
                b[i] += lambda * p
            }
            guard let inv = invert(a) else { return nil }
            let sol = (0..<n).map { i in (0..<n).reduce(0) { $0 + inv[i][$1] * b[$1] } }
            coef = [Double](repeating: 0, count: k)
            for (i, fi) in free.enumerated() { coef[fi] = sol[i] }
            inverse = inv
            let negative = free.enumerated().filter { sol[$0.offset] < 0 }.map(\.element)
            if negative.isEmpty { break }
            free.removeAll { negative.contains($0) }
        }
        let n = free.count
        guard n > 0 else { return nil }
        var sse = 0.0
        for r in rows {
            let e = r.y - (0..<k).reduce(0) { $0 + coef[$1] * r.x[$1] }
            sse += r.w * e * e
        }
        let dof = rows.count - n
        var se = [Double?](repeating: nil, count: k)
        if dof > 0 {
            let sigma2 = sse / Double(dof)
            for (i, fi) in free.enumerated() { se[fi] = (sigma2 * max(0, inverse[i][i])).squareRoot() }
        }
        return (coef, se)
    }

    /// 高斯-约当求逆，主元过小即判奇异。
    private static func invert(_ m: [[Double]]) -> [[Double]]? {
        let n = m.count
        var a = m
        var inv = (0..<n).map { i in (0..<n).map { $0 == i ? 1.0 : 0.0 } }
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }),
                  abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)
            inv.swapAt(col, pivot)
            let d = a[col][col]
            for j in 0..<n { a[col][j] /= d; inv[col][j] /= d }
            for i in 0..<n where i != col {
                let f = a[i][col]
                guard f != 0 else { continue }
                for j in 0..<n { a[i][j] -= f * a[col][j]; inv[i][j] -= f * inv[col][j] }
            }
        }
        return inv
    }
}
