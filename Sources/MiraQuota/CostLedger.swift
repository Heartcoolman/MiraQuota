import Foundation

/// 成本账本：增量扫描 Claude Code 的 transcript 与 Mirasim 的网关账本，
/// 把每次调用的 token 折算成 API 等价美元，按分钟聚合。
///
/// 两个来源存在重叠：transcript 覆盖全部 Claude Code 调用且 token 完整，
/// 网关账本对 relay 未回填的记录留空。故 Claude Code 侧只认 transcript，
/// 账本只用于补齐 pi-gui 一类不经 Claude Code 的智能体。
final class CostLedger {
    /// 只保留该时长内的数据，覆盖 7d 窗口并留出余量。
    static let retention: TimeInterval = 8 * 86400

    /// 会话文件的枚举缓存。速度统计另持一份，两者的字节游标互不相干。
    private let files = ProjectFiles()

    private struct Cursor: Codable {
        var size: Int
        var offset: Int
    }

    /// 网关账本里一条已入桶记录的账目：回填补差额时要知道原分钟与已计金额。
    private struct GatewayEntry: Codable {
        var minute: Int
        var usd: Double
    }

    private struct Persisted: Codable {
        var cursors: [String: Cursor] = [:]
        /// unix 分钟 → 美元
        var buckets: [String: Double] = [:]
        /// requestId → unix 分钟，用于跨文件去重（fork / resume 会复制历史消息）
        var seen: [String: Int] = [:]
        /// 网关账本的按 id 账目。必须是 Optional：合成 Codable 只对 Optional 走
        /// decodeIfPresent，旧 ledger.json 缺该键时非可选会让整个状态解码失败被静默清空。
        var gateway: [String: GatewayEntry]? = nil
    }

    private var state = Persisted()
    private let pricing: Pricing

    /// 各账本文件上次扫描时的修改时刻，未变则本轮跳过。
    /// 不能按 size 判断：回填是同长度的原地改写。
    private var gatewayScanned: [String: Date] = [:]
    /// 本会话已计过数的 id。网关账本每轮重扫，不去重会把同一行反复累进计数器。
    private var countedUnpriced: Set<String> = []
    private var countedLedger: Set<String> = []

    /// 分钟桶的有序前缀和。标定一次会调用 `spent` 成百上千次，
    /// 逐次全表扫描并解析字符串键，开销随「样本数 × 桶数」成平方级增长。
    /// 桶变动时置空，下次查询惰性重建。
    private var index: (minutes: [Int], prefix: [Double])?

    private(set) var transcriptRecords = 0
    private(set) var ledgerRecords = 0
    private(set) var unpricedRecords = 0

    init(pricing: Pricing) {
        self.pricing = pricing
        load()
    }

    // MARK: 持久化

    private func load() {
        guard let data = try? Data(contentsOf: Paths.ledgerState),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        state = p
    }

    private func save() {
        Paths.ensureStateDir()
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Paths.ledgerState, options: .atomic)
    }

    // MARK: 扫描

    /// 增量扫描全部来源，返回是否有新数据落账。
    @discardableResult
    func refresh(now: Date = Date()) -> Bool {
        let cutoff = Int(now.addingTimeInterval(-Self.retention).timeIntervalSince1970)
        var changed = false
        changed = scanTranscripts(cutoff: cutoff) || changed
        changed = scanGatewayLedger(cutoff: cutoff) || changed
        prune(cutoff: cutoff)
        if changed { save() }
        return changed
    }

    /// 只读自上次以来 mtime 有变化的会话文件。字节游标落在 `ledger.json` 里，
    /// 未变化的文件读回来也只会推进零字节，逐轮重开 2038 个文件纯属浪费
    /// （枚举与判新交给 `ProjectFiles`，见其注释里的开销量级）。
    private func scanTranscripts(cutoff: Int) -> Bool {
        files.refresh()
        var changed = false
        let cutoffDate = Date(timeIntervalSince1970: Double(cutoff))
        // 整个文件都早于保留窗口时跳过，首次全量扫描因此只读近期会话。
        for e in files.changed where e.mtime >= cutoffDate {
            if consume(file: e.url, size: e.size, cutoff: cutoff,
                       needle: Self.usageNeedle, parse: parseTranscriptLine) { changed = true }
        }
        return changed
    }

    /// 首扫回溯上限与每轮重扫窗口，对齐 SpeedStats 对同一文件族的口径。
    private static let gatewayFirstScan = 4 << 20
    private static let gatewayRescan = 1 << 20

    /// 网关账本**不是**追加型：token 由 relay 回填、原地改写历史行，
    /// 字节游标越过的行再也读不回，token 未回填就被首读的行会以 $0 永久定格。
    /// 故不用游标，每轮重扫尾部窗口，按 id 记账，回填到达时补差额（见 parseGatewayLine）。
    private func scanGatewayLedger(cutoff: Int) -> Bool {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Paths.mirasimInsights,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return false }
        if state.gateway == nil { state.gateway = [:] }
        let window = state.gateway!.isEmpty ? Self.gatewayFirstScan : Self.gatewayRescan
        var changed = false
        for file in files where file.lastPathComponent.hasPrefix("usage-") && file.pathExtension == "ndjson" {
            let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = attrs?.fileSize else { continue }
            if let m = attrs?.contentModificationDate, gatewayScanned[file.path] == m { continue }
            gatewayScanned[file.path] = attrs?.contentModificationDate
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let offset = max(0, size - window)
            try? handle.seek(toOffset: UInt64(offset))
            guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }
            // 起点可能落在半行中间，跳过第一行。
            let skipFirst = offset > 0
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let n = raw.count
                var start = 0, i = 0
                var firstLine = true
                Self.anthropicNeedle.withUnsafeBufferPointer { pat in
                    while i < n {
                        guard bytes[i] == 0x0A else { i += 1; continue }
                        let length = i - start
                        if !(skipFirst && firstLine), length > 2,
                           memmem(bytes + start, length, pat.baseAddress, pat.count) != nil,
                           parseGatewayLine(Data(bytes: bytes + start, count: length), cutoff: cutoff) {
                            changed = true
                        }
                        firstLine = false
                        start = i + 1
                        i += 1
                    }
                }
            }
        }
        return changed
    }

    /// 行级预筛关键字。首次建账要过 1 GB 量级的 transcript，
    /// 只有命中的行才值得付 JSON 解析的代价。
    private static let usageNeedle = Array("\"usage\"".utf8)
    private static let anthropicNeedle = Array("\"anthropic\"".utf8)

    /// 从游标处读入新增字节并逐行解析。文件被截断时游标归零，
    /// 重复计入由 requestId 去重拦下。
    private func consume(file: URL, size: Int, cutoff: Int,
                         needle: [UInt8], parse: (Data, Int) -> Void) -> Bool {
        let key = file.path
        var cursor = state.cursors[key] ?? Cursor(size: 0, offset: 0)
        if size < cursor.size { cursor = Cursor(size: 0, offset: 0) }
        guard size > cursor.offset else {
            state.cursors[key] = Cursor(size: size, offset: cursor.offset)
            return false
        }

        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(cursor.offset))
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return false }

        var consumed = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let n = raw.count
            var start = 0
            var i = 0
            needle.withUnsafeBufferPointer { pat in
                while i < n {
                    guard bytes[i] == 0x0A else { i += 1; continue }
                    let length = i - start
                    if length > 2,
                       memmem(bytes + start, length, pat.baseAddress, pat.count) != nil {
                        parse(Data(bytes: bytes + start, count: length), cutoff)
                    }
                    start = i + 1
                    consumed = start
                    i += 1
                }
            }
        }
        // 尾部不完整的行留待下次，游标只前进到最后一个换行。
        state.cursors[key] = Cursor(size: size, offset: cursor.offset + consumed)
        return consumed > 0
    }

    // MARK: 逐行解析

    private func parseTranscriptLine(_ line: Data, cutoff: Int) {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let ts = root["timestamp"] as? String,
              let epoch = fastEpochSeconds(ts), epoch >= cutoff,
              let message = root["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }

        let minute = epoch / 60
        let requestId = (root["requestId"] as? String) ?? (message["id"] as? String)
        if let rid = requestId {
            if state.seen[rid] != nil { return }
            state.seen[rid] = minute
        }

        let model = (message["model"] as? String) ?? ""
        guard let usd = pricing.cost(model: model,
                                     input: int(usage["input_tokens"]),
                                     output: int(usage["output_tokens"]),
                                     cacheRead: int(usage["cache_read_input_tokens"]),
                                     cacheWrite: int(usage["cache_creation_input_tokens"])) else {
            unpricedRecords += 1
            return
        }
        add(minute: minute, usd: usd)
        transcriptRecords += 1
    }

    /// 返回是否有新的美元入桶（含回填差额）。
    private func parseGatewayLine(_ line: Data, cutoff: Int) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let ts = root["ts"] as? String,
              let epoch = fastEpochSeconds(ts), epoch >= cutoff,
              (root["provider"] as? String) == "anthropic" else { return false }

        // Claude Code 的调用由 transcript 全量覆盖，此处只补别的智能体。
        let agent = (root["agent"] as? String) ?? ""
        guard agent != "claude", agent != "codex" else { return false }

        guard let id = root["id"] as? String else { return false }
        // 旧版按字节游标入过账的行只有 seen 记录、没有金额，无从补差，跳过防止重复计入。
        if state.seen[id] != nil { return false }

        let model = (root["model"] as? String) ?? ""
        let usd = model.isEmpty ? nil : pricing.cost(model: model,
                                                     input: int(root["input"]),
                                                     output: int(root["output"]),
                                                     cacheRead: int(root["cacheRead"]),
                                                     cacheWrite: int(root["cacheWrite"]))
        // cost 对零 token 的已知模型返回 0.0 而非 nil——token 未回填的行
        // 此刻既不入账也不记已见，等回填后重读，这正是旧游标口径丢钱的病根。
        guard let usd, usd > 0 else {
            if countedUnpriced.insert(id).inserted { unpricedRecords += 1 }
            return false
        }
        let minute = epoch / 60
        if let entry = state.gateway?[id] {
            guard usd > entry.usd else { return false }
            // 回填把金额补大了：差额记回首见的分钟，桶归属不漂移。
            add(minute: entry.minute, usd: usd - entry.usd)
            state.gateway?[id] = GatewayEntry(minute: entry.minute, usd: usd)
        } else {
            state.gateway?[id] = GatewayEntry(minute: minute, usd: usd)
            add(minute: minute, usd: usd)
            if countedLedger.insert(id).inserted { ledgerRecords += 1 }
        }
        return true
    }

    @inline(__always)
    private func int(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return 0
    }

    @inline(__always)
    private func add(minute: Int, usd: Double) {
        let key = String(minute)
        state.buckets[key, default: 0] += usd
        index = nil
    }

    private func prune(cutoff: Int) {
        let minCutoff = cutoff / 60
        let before = state.buckets.count
        state.buckets = state.buckets.filter { (Int($0.key) ?? 0) >= minCutoff }
        state.seen = state.seen.filter { $0.value >= minCutoff }
        state.gateway = state.gateway.map { $0.filter { $0.value.minute >= minCutoff } }
        // 游标只对 transcript 有意义（网关账本走上面的重扫）；
        // 已删除文件的条目会随 save 永远写回，不清理则 ledger.json 无界增长。
        state.cursors = state.cursors.filter { key, _ in
            !key.hasPrefix(Paths.mirasimInsights.path)
                && FileManager.default.fileExists(atPath: key)
        }
        if state.buckets.count != before { index = nil }
    }

    // MARK: 查询

    /// 半开区间 [from, to) 内的等价支出。
    /// `includeOpenMinute` 把 `to` 所在的未完整分钟桶一并计入：展示路径以 now 为
    /// 上界，不含它会让刚落账的请求最多 60 秒不可见。标定的逐对查询不可用——
    /// 相邻样本对的半开分钟区间恰好平铺，计入开分钟会让边界分钟被两对重复计。
    func spent(from: Date, to: Date, includeOpenMinute: Bool = false) -> Double {
        if index == nil { buildIndex() }
        guard let index, !index.minutes.isEmpty else { return 0 }
        let lo = lowerBound(index.minutes, Int(from.timeIntervalSince1970) / 60)
        let hi = lowerBound(index.minutes,
                            Int(to.timeIntervalSince1970) / 60 + (includeOpenMinute ? 1 : 0))
        return index.prefix[hi] - index.prefix[lo]
    }

    private func buildIndex() {
        let sorted = state.buckets
            .compactMap { key, value in Int(key).map { ($0, value) } }
            .sorted { $0.0 < $1.0 }
        var prefix = [Double](repeating: 0, count: sorted.count + 1)
        for (i, entry) in sorted.enumerated() { prefix[i + 1] = prefix[i] + entry.1 }
        index = (sorted.map { $0.0 }, prefix)
    }

    /// 首个不小于 target 的下标。
    private func lowerBound(_ a: [Int], _ target: Int) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo &+ hi) >> 1
            if a[mid] < target { lo = mid &+ 1 } else { hi = mid }
        }
        return lo
    }

    var totalRecords: Int { transcriptRecords + ledgerRecords }
    var bucketCount: Int { state.buckets.count }
}
