import Foundation

/// 成本账本：增量扫描 Claude Code 的 transcript 与 Mirasim 的网关账本，
/// 把每次调用的 token 折算成 API 等价美元，按分钟聚合。
///
/// 两个来源都不完备，故取并集。Anthropic 的 Claude 请求用 transcript 与网关账本
/// 的 request id 跨源去重（transcript 的 `requestId` 即网关账本的
/// `providerCallId`）；OpenAI Codex 请求没有对应的本地 transcript，直接以网关账本
/// 的请求 id 计入。
///
/// - transcript 的 token 完整、可回溯全部历史，但只记录写回会话的助手消息。
///   标题生成、被丢弃的响应、文件已被清理的子代理会话都不在其中，本机实测
///   这部分占网关所见支出的约 18%。
/// - 网关账本记下每一次经中继的请求，与中继自报的额度百分比拟合最紧
///   （30 分钟分块回归 R² 0.85/0.99，仅 transcript 为 0.80/0.82），
///   但 token 由 relay 回填、只重扫尾部窗口，早于窗口的记录取不回。
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

    /// 账本的折算口径版本。桶与账目只存金额、不留 token，价目口径一变，已落账的金额无法
    /// 原地改算，只能清掉游标与账目从磁盘重建（transcript 可回溯全部历史，网关账本首扫整读）。
    /// 1：API 价目；2、3：曾按上游扣点倍率折算（Fable 5.1 × 2，已回退）；4：回到 API 价目。
    static let pricingVersion = 4

    private struct Persisted: Codable {
        /// 落盘时的折算口径，缺省即版本 1。理由同 `booked`，必须是 Optional。
        var pricingVersion: Int? = nil
        var cursors: [String: Cursor] = [:]
        /// unix 分钟 → 美元
        var buckets: [String: Double] = [:]
        /// 账目键 → 入桶的 unix 分钟。跨文件与跨来源去重都靠它
        /// （fork / resume 会复制历史消息；同一次调用两侧各记一次）。
        var seen: [String: Int] = [:]
        /// 账目键 → 已计入的美元。同一次调用先被看到的那次可能是残缺值：
        /// transcript 的流式中间行只带部分 output，网关账本的 token 由 relay 事后回填。
        /// 记下已计金额，再见到更大的值时只补差额，桶归属留在首见的分钟。
        /// 必须是 Optional：合成 Codable 只对 Optional 走 decodeIfPresent，
        /// 旧 ledger.json 缺该键时非可选会让整个状态解码失败被静默清空。
        var booked: [String: Double]? = nil
        /// 旧版按账本行 id 单独存的网关账目，只在 `load` 里并进 `seen` 与 `booked`。
        var gateway: [String: GatewayEntry]? = nil
        /// 模型档位分桶，键为 `组名|unix 分钟`。`/v1/limits` 的 modelScoped 窗口
        /// （实测 `7d_fable`）只计特定模型的用量，其支出必须与全局分开，
        /// 否则该窗口会挂上全机支出而窗口用量为零。必须是 Optional，理由同 `booked`。
        var scoped: [String: Double]? = nil
        /// 组名 → 该组开始分桶的 unix 分钟。桶只存金额、不留模型，启用之前的支出
        /// 无从回溯，窗口起点早于此值时该组的支出偏低，由 `scopedComplete` 判定。
        var scopedSince: [String: Int]? = nil
    }

    private var state = Persisted()
    private let pricing: Pricing

    /// 各账本文件上次扫描时的修改时刻，未变则本轮跳过。
    /// 不能按 size 判断：回填是同长度的原地改写。
    private var gatewayScanned: [String: Date] = [:]
    /// 本会话已计过数的 id。网关账本每轮重扫，不去重会把同一行反复累进计数器。
    private var countedUnpriced: Set<String> = []
    private var countedLedger: Set<String> = []
    /// 本进程是否已整读过网关账本。
    private var fullGatewayScanDone = false

    /// 分钟桶的有序前缀和。标定一次会调用 `spent` 成百上千次，
    /// 逐次全表扫描并解析字符串键，开销随「样本数 × 桶数」成平方级增长。
    /// 桶变动时置空，下次查询惰性重建。
    private var index: (minutes: [Int], prefix: [Double])?
    /// 各模型档位组的前缀和，按需构建。
    private var scopedIndex: [String: (minutes: [Int], prefix: [Double])] = [:]
    /// 当前需要单独分桶的模型档位组，小写。取自 `/v1/limits` 的 modelScoped 窗口名。
    private var scopedGroups: [String] = []

    private(set) var transcriptRecords = 0
    private(set) var ledgerRecords = 0
    private(set) var unpricedRecords = 0

    init(pricing: Pricing) {
        self.pricing = pricing
        load()
        // 没有状态文件时 load 直接返回，这里兜住：账目表为 nil 时下面所有
        // `state.booked?[key] = …` 都会静默丢弃，两侧的补差额随之失效。
        if state.booked == nil { state.booked = [:] }
        if state.pricingVersion == nil { state.pricingVersion = Self.pricingVersion }
    }

    // MARK: 持久化

    private func load() {
        guard let data = try? Data(contentsOf: Paths.ledgerState),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        state = p
        if state.booked == nil { state.booked = [:] }
        if (state.pricingVersion ?? 1) != Self.pricingVersion { rebuild() }
        // 已声明过的档位组从盘面恢复：`refresh` 先于 `adoptScopedGroups` 运行，进程启动后
        // 第一轮解析的记录若不知道分组就永远进不了档位桶（游标随即落盘）。常驻实例与
        // --once/--doctor 每次启动都漏一段，实测 7d_fable 的档位支出因此低四成。
        scopedGroups = (state.scopedSince ?? [:]).keys.sorted()
        // 旧状态的网关账目按账本行 id 记账，并入统一的账目键，升级后不重复计入。
        for (id, entry) in state.gateway ?? [:] where state.booked?[id] == nil {
            state.seen[id] = entry.minute
            state.booked?[id] = entry.usd
        }
        state.gateway = nil
    }

    /// 折算口径变更后清掉全部金额与游标，保留档位组声明，下一轮 `refresh` 从磁盘重建。
    /// 重建时档位组自始已知，分桶覆盖整个保留期，故各组的起点一并前移到保留期起点。
    private func rebuild() {
        let since = (Int(Date().timeIntervalSince1970) - Int(Self.retention)) / 60
        var fresh = Persisted()
        fresh.pricingVersion = Self.pricingVersion
        fresh.booked = [:]
        fresh.scoped = [:]
        fresh.scopedSince = (state.scopedSince ?? [:]).mapValues { _ in since }
        state = fresh
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

    /// 首扫读整个文件，保留窗口由 `parseGatewayLine` 的 cutoff 判定。
    /// 不能沿用尾部窗口：账本每行约 700 字节，4 MB 只回溯到一天多以前，
    /// 新装或长期未运行时 7d 窗口的前半段会整段缺失。
    private static let gatewayFirstScan = Int.max
    private static let gatewayRescan = 1 << 20

    /// 网关账本**不是**追加型：token 由 relay 回填、原地改写历史行，
    /// 字节游标越过的行再也读不回，token 未回填就被首读的行会以 $0 永久定格。
    /// 故不用游标，每轮重扫尾部窗口，按 id 记账，回填到达时补差额（见 parseGatewayLine）。
    private func scanGatewayLedger(cutoff: Int) -> Bool {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Paths.mirasimInsights,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return false }
        // 每次启动先整读一遍：停机期间的记录与升级前漏掉的记录都在这一遍补齐，
        // 之后按尾部窗口重扫。重复入账由账目键拦下，整读只是多解析几万行。
        let window = fullGatewayScanDone ? Self.gatewayRescan : Self.gatewayFirstScan
        fullGatewayScanDone = true
        var changed = false
        for file in files where file.lastPathComponent.hasPrefix("usage-") && file.pathExtension == "ndjson" {
            let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = attrs?.fileSize else { continue }
            if let m = attrs?.contentModificationDate, gatewayScanned[file.path] == m { continue }
            gatewayScanned[file.path] = attrs?.contentModificationDate
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let offset = window >= size ? 0 : size - window
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
                Self.gatewayProviderNeedle.withUnsafeBufferPointer { pat in
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
    /// 网关账本同时包含 Anthropic、OpenAI 和其它请求；先按 provider 预筛，
    /// 再由 `parseGatewayLine` 只接受本项目支持的两类上游。
    private static let gatewayProviderNeedle = Array("\"provider\"".utf8)

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
        // 已计过且知道金额：一次响应会写成多行（思考、工具调用、正文各一行），
        // 靠前的行只带部分 output，取最大值补差额，否则整段输出按残值定格。
        if let rid = requestId, state.booked?[rid] == nil, state.seen[rid] != nil { return }

        let model = (message["model"] as? String) ?? ""
        guard let usd = pricing.cost(model: model,
                                     input: int(usage["input_tokens"]),
                                     output: int(usage["output_tokens"]),
                                     cacheRead: int(usage["cache_read_input_tokens"]),
                                     cacheWrite: int(usage["cache_creation_input_tokens"])) else {
            unpricedRecords += 1
            return
        }
        guard let rid = requestId else {
            add(minute: minute, usd: usd, model: model)
            transcriptRecords += 1
            return
        }
        if let prior = state.booked?[rid] {
            guard usd > prior else { return }
            add(minute: state.seen[rid] ?? minute, usd: usd - prior, model: model)
            state.booked?[rid] = usd
            return
        }
        state.seen[rid] = minute
        state.booked?[rid] = usd
        add(minute: minute, usd: usd, model: model)
        transcriptRecords += 1
    }

    /// 返回是否有新的美元入桶（含回填差额）。
    private func parseGatewayLine(_ line: Data, cutoff: Int) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let ts = root["ts"] as? String,
              let epoch = fastEpochSeconds(ts), epoch >= cutoff,
              let provider = root["provider"] as? String,
              provider == "anthropic" || provider == "openai" || provider.hasPrefix("openai-") else { return false }
        guard let id = root["id"] as? String else { return false }

        // 账目键优先取 providerCallId：它与 transcript 的 requestId 同值，
        // 同一次调用两侧谁先落账都记在同一个键上，另一侧据此补差额而非重复计入。
        // 旧状态按账本行 id 认领过的行仍按 id 走，否则升级后会再计一遍。
        let providerCallId = root["providerCallId"] as? String
        let key = state.seen[id] != nil ? id : (providerCallId ?? id)
        let prior = state.booked?[key]
        if prior == nil {
            // 有 seen 无金额：旧版按字节游标入过账，无从补差，跳过防止重复计入。
            if state.seen[key] != nil { return false }
            // Anthropic 的 Claude 行缺 providerCallId 时无法与 transcript 对齐，
            // 仍按旧口径交给 transcript 覆盖，宁可漏计也不重复计。OpenAI Codex
            // 没有对应 transcript，必须保留其无 providerCallId 的网关行。
            let agent = (root["agent"] as? String) ?? ""
            if provider == "anthropic", providerCallId == nil,
               agent == "claude" || agent == "codex" { return false }
        }

        let model = (root["model"] as? String) ?? ""
        let input = int(root["input"])
        let output = int(root["output"])
        let cacheRead = int(root["cacheRead"])
        let cacheWrite = int(root["cacheWrite"])
        let hasTokens = input > 0 || output > 0 || cacheRead > 0 || cacheWrite > 0
        // OpenAI 的早期 `openai-chat` 记录可能没有模型和 token（只代表一次
        // 请求尝试，不是可计费调用），跳过且不把它们误报成未定价。
        guard !model.isEmpty else {
            if hasTokens, countedUnpriced.insert(id).inserted { unpricedRecords += 1 }
            return false
        }
        let usd = pricing.cost(model: model, input: input, output: output,
                               cacheRead: cacheRead, cacheWrite: cacheWrite)
        // cost 对零 token 的已知模型返回 0.0 而非 nil——token 未回填的行
        // 此刻既不入账也不记已见，等回填后重读，这正是旧游标口径丢钱的病根。
        guard let usd, usd > 0 else {
            if hasTokens, countedUnpriced.insert(id).inserted { unpricedRecords += 1 }
            return false
        }
        if let prior {
            guard usd > prior else { return false }
            // 回填把金额补大了：差额记回首见的分钟，桶归属不漂移。
            add(minute: state.seen[key] ?? epoch / 60, usd: usd - prior, model: model)
            state.booked?[key] = usd
        } else {
            let minute = epoch / 60
            state.seen[key] = minute
            state.booked?[key] = usd
            add(minute: minute, usd: usd, model: model)
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
    private func add(minute: Int, usd: Double, model: String = "") {
        let key = String(minute)
        state.buckets[key, default: 0] += usd
        index = nil
        guard !scopedGroups.isEmpty, !model.isEmpty else { return }
        let lower = model.lowercased()
        for group in scopedGroups where lower.contains(group) {
            state.scoped?[group + "|" + key, default: 0] += usd
            scopedIndex[group] = nil
        }
    }

    /// 声明需要单独分桶的模型档位组。组名取自 modelScoped 窗口名下划线之后的部分
    /// （`7d_fable` → `fable`），模型名含该子串即归入该组。
    /// 新组从声明时刻起累积：桶只存金额，此前的支出无从追认。
    func adoptScopedGroups(_ groups: [String]) {
        let normalized = groups.map { $0.lowercased() }.filter { !$0.isEmpty }.sorted()
        guard normalized != scopedGroups else { return }
        scopedGroups = normalized
        if state.scoped == nil { state.scoped = [:] }
        var since = state.scopedSince ?? [:]
        let now = Int(Date().timeIntervalSince1970) / 60
        var dirty = false
        for group in normalized where since[group] == nil {
            since[group] = now
            dirty = true
        }
        if dirty {
            state.scopedSince = since
            save()
        }
    }

    /// 该组的分桶是否已覆盖到给定时刻。未覆盖时其支出偏低，展示需据此让位。
    func scopedComplete(group: String, from: Date) -> Bool {
        guard let since = state.scopedSince?[group.lowercased()] else { return false }
        return since <= Int(from.timeIntervalSince1970) / 60
    }

    private func prune(cutoff: Int) {
        let minCutoff = cutoff / 60
        let before = state.buckets.count
        state.buckets = state.buckets.filter { (Int($0.key) ?? 0) >= minCutoff }
        if let scoped = state.scoped {
            state.scoped = scoped.filter { key, _ in
                (key.split(separator: "|").last.flatMap { Int($0) } ?? 0) >= minCutoff
            }
            scopedIndex.removeAll()
        }
        state.seen = state.seen.filter { $0.value >= minCutoff }
        // 金额账目与 seen 同生共死：键一致，靠 seen 的分钟判龄。
        state.booked = state.booked.map { $0.filter { state.seen[$0.key] != nil } }
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
    /// `group` 给定时只计该模型档位组的支出，用于 modelScoped 窗口。
    func spent(from: Date, to: Date, includeOpenMinute: Bool = false,
               group: String? = nil) -> Double {
        let table: (minutes: [Int], prefix: [Double])?
        if let group = group?.lowercased() {
            if scopedIndex[group] == nil { buildScopedIndex(group) }
            table = scopedIndex[group]
        } else {
            if index == nil { buildIndex() }
            table = index
        }
        guard let table, !table.minutes.isEmpty else { return 0 }
        let lo = lowerBound(table.minutes, Int(from.timeIntervalSince1970) / 60)
        let hi = lowerBound(table.minutes,
                            Int(to.timeIntervalSince1970) / 60 + (includeOpenMinute ? 1 : 0))
        return table.prefix[hi] - table.prefix[lo]
    }

    private func buildIndex() {
        index = Self.prefixSums(state.buckets.compactMap { key, value in
            Int(key).map { ($0, value) }
        })
    }

    private func buildScopedIndex(_ group: String) {
        let head = group + "|"
        scopedIndex[group] = Self.prefixSums((state.scoped ?? [:]).compactMap { key, value in
            guard key.hasPrefix(head), let minute = Int(key.dropFirst(head.count)) else { return nil }
            return (minute, value)
        })
    }

    private static func prefixSums(_ entries: [(Int, Double)]) -> (minutes: [Int], prefix: [Double]) {
        let sorted = entries.sorted { $0.0 < $1.0 }
        var prefix = [Double](repeating: 0, count: sorted.count + 1)
        for (i, entry) in sorted.enumerated() { prefix[i + 1] = prefix[i] + entry.1 }
        return (sorted.map { $0.0 }, prefix)
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
