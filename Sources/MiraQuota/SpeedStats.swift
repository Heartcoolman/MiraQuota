import Foundation

/// 出字速度与首 token 等待的估计。
///
/// 网关账本只记录每次请求的总时长，没有首字节时刻。同一模型上总时长与输出量近似线性：
/// `时长 ≈ 首 token 等待 + 输出量 ÷ 出字速度`。
///
/// 两个尺度分工：**首 token** 无法逐次测量，只能由保留期内的全部样本回归得出，
/// 是慢变量；**出字速度**取最近几次请求的逐条值，反映当下而非均值——
/// 按整个 5 小时窗口做中位数时，几百条样本会把新数据完全淹没，界面看上去不动。
/// 混合模型会显著偏移，两者都分模型统计。
final class SpeedStats {
    private struct Sample {
        let id: String
        let at: Int
        var out: Int
        var ms: Int
        let model: String
        /// diag 的 callId，用于取即时时长。
        let callId: String
        /// transcript 的 requestId，用于取即时 token。
        let requestId: String
    }

    /// 首次读取的回溯上限。账本按月一个文件，这个量足够覆盖数天。
    private static let firstReadCap = 4 << 20
    /// 账本尾部重扫窗口。回填只改近期记录，扫尾部即可，无需整文件。
    private static let rescanWindow = 1 << 20
    /// transcript 尾部重扫窗口。只需要最近若干请求的 token，不必回读整个会话文件。
    private static let transcriptWindow = 512 << 10
    /// 样本保留时长。5 小时窗口之外还要供退化提示使用，留两天余量。
    private static let retention: TimeInterval = 48 * 3600

    /// 过短的请求既没有稳定的出字速度，也会把截距拉偏。
    private static let minDuration = 200
    private static let minOutput = 32
    /// 配对两端的输出量差，太近则斜率被噪声主导。
    private static let minSeparation = 32
    /// 给出斜率所需的最少配对数，即最少 12 条样本。
    private static let minPairs = 6
    /// 单个模型成行所需的最少样本数。
    private static let minRow = 2
    /// 出字速度取最近这么多次请求。取小才跟手，取大才平稳。
    /// 3 次时实测显示值在 145 秒内于 67–83 tok/s 间摆动、偏离提示反复翻转；
    /// 取 5 次并叠一层显示平滑（见 `rateSmoothing`）后仍能跟上新请求。
    private static let recentCount = 5
    /// 显示值的一阶平滑系数。原始值随最近样本进出摆动，逐轮直显会让
    /// 「快 / 慢 x%」的文字与颜色在无实质变化时反复出现。
    private static let rateSmoothing = 0.35
    /// 与上次显示值的相对差超过该值时判为工况切换，直接跳到新值而不平滑，
    /// 免得真实变化被平滑拖上几十轮。
    private static let rateJump = 0.6
    /// 超过这个时长没有请求就不再成行，避免把昨天的速度当成当下的。
    private static let recencyLimit: TimeInterval = 2 * 3600
    /// 扣掉首 token 后剩余的出字时间下限，防止短请求把速度算到天上。
    private static let minStreamSeconds = 0.25
    /// 实测对照保留的事件数。
    private static let measuredKeep = 20

    private var samples: [Sample] = []
    /// 在途请求：callId → 开始时刻（epoch 秒）。begin 事件在请求发出瞬间落盘，
    /// end 到达即移除；中断的请求不发 end，按时长上限清理。
    private var flights: [String: Int] = [:]
    /// 在途条目的保留上限。已闭合请求 95 分位 46 秒、最长 383 秒，
    /// 超过 10 分钟的 begin 基本是被中断的请求泄漏，不再当作在途。
    private static let flightCap = 600

    /// diag 给出的即时时长：callId → durationMs。
    private var diagDurations: [String: Int] = [:]
    /// transcript 给出的即时 token：requestId → output_tokens。
    private var transcriptTokens: [String: Int] = [:]
    private var analyticsCursors: [String: Int] = [:]
    private var measured: [Double] = []
    /// 网关账本各文件上次重扫时的 mtime，用于跳过未变化的文件。
    private var ledgerMtime: [String: Date] = [:]
    /// transcript 各文件上次读取时的 mtime，同上。
    private var transcriptRead: [String: Date] = [:]
    /// 会话文件枚举缓存。CostLedger 另持一份，两者游标与判新状态互不相干。
    private let projectFiles = ProjectFiles()
    /// 显示用的出字速度，按模型短名保留上一次的值，供一阶平滑使用。
    private var shownRate: [String: Double] = [:]
    /// 当前正在显示偏离提示的模型。闸门带迟滞：进 25%、出 18%，
    /// 否则偏离贴着阈值时提示会逐轮出现与消失（实测 -32% 一段里仍闪了一次）。
    private var driftShown: Set<String> = []

    private static let durationNeedle = Array("\"durationMs\"".utf8)
    private static let turnNeedle = Array("\"turn.finish\"".utf8)
    private static let modelEventNeedle = Array("\"kind\":\"model.".utf8)
    private static let usageNeedle = Array("\"usage\"".utf8)

    // MARK: 采集

    func refresh(now: Date = Date()) {
        let cutoff = Int(now.addingTimeInterval(-Self.retention).timeIntervalSince1970)
        scanLedger(cutoff: cutoff)
        scanAnalytics()
        scanDiag()
        // 账本的 token 要等 relay 回填，时长也可能先落一个粗值；
        // transcript 与 diag 都是请求完成即写，用它们补齐才能反映当下。
        backfillFromTranscripts()
        for i in samples.indices {
            if let ms = diagDurations[samples[i].callId], ms > 0 { samples[i].ms = ms }
        }
        samples.removeAll { $0.at < cutoff }
        let flightCutoff = Int(now.timeIntervalSince1970) - Self.flightCap
        flights = flights.filter { $0.value >= flightCutoff }
        // 两张关联表只服务当前样本与在途集合，随保留期一同修剪；
        // 不修剪的话常驻数周会无界增长（end 事件连 count_tokens 一类的探测对也入表）。
        let callIds = Set(samples.map(\.callId)).union(flights.keys)
        diagDurations = diagDurations.filter { callIds.contains($0.key) }
        let requestIds = Set(samples.map(\.requestId))
        transcriptTokens = transcriptTokens.filter { requestIds.contains($0.key) }
        // mtime 闸门表按活跃文件裁剪：会话文件数以千计，常驻数周不裁会无界增长。
        let live = Set(projectFiles.recent(limit: 64, activeSince: Date(timeIntervalSinceNow: -Self.retention))
                        .map(\.url.path))
        transcriptRead = transcriptRead.filter { live.contains($0.key) }
    }

    /// 账本**不是**追加型：token 由 relay 稍后回填，历史行会被原地改写
    /// （实测同长度前缀的 md5 在数秒内就变）。单向游标越过的行再也读不到，
    /// 于是刚完成的请求（落盘时 output=0）永远进不了样本集，界面上表现为速度停在几十分钟前。
    /// 故这里每轮重扫尾部窗口，按 `id` 去重、以最新一次读到的值为准。
    private func scanLedger(cutoff: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.mirasimInsights,
                                                     includingPropertiesForKeys: [.fileSizeKey]) else { return }
        var seen: [String: Sample] = [:]
        for s in samples { seen[s.id] = s }

        for file in files where file.lastPathComponent.hasPrefix("usage-") && file.pathExtension == "ndjson" {
            let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            // 回填改写的是同一个文件，mtime 必变；未变时尾部内容与上轮逐字节相同，
            // 重读 1 MB 再逐行 JSON 解析没有产出。样本已在上面并入 seen，跳过不丢数据。
            // 与 CostLedger 的网关账本闸门同形：判 mtime 而不判 size（回填不改长度）。
            if let m = attrs?.contentModificationDate, ledgerMtime[file.path] == m { continue }
            ledgerMtime[file.path] = attrs?.contentModificationDate
            guard let size = attrs?.fileSize,
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let offset = max(0, size - Self.rescanWindow)
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
                Self.durationNeedle.withUnsafeBufferPointer { pat in
                    while i < n {
                        guard bytes[i] == 0x0A else { i += 1; continue }
                        let length = i - start
                        if !(skipFirst && firstLine), length > 2,
                           memmem(bytes + start, length, pat.baseAddress, pat.count) != nil,
                           let sample = Self.parseUsage(Data(bytes: bytes + start, count: length),
                                                        cutoff: cutoff) {
                            seen[sample.id] = sample
                        }
                        firstLine = false
                        start = i + 1
                        i += 1
                    }
                }
            }
        }
        samples = seen.values.sorted { $0.at < $1.at }
    }

    private func scanAnalytics() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.mirasimAnalytics,
                                                     includingPropertiesForKeys: [.fileSizeKey]) else { return }
        let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "ndjson" }
        // 文件缩小意味着游标重置、尾部重读。清空须在读之前：consume 先把重读的
        // 事件追加进 measured 再返回重置标记，读后再清会把刚读回的一并抹掉，
        // 对照值要空等到新事件才恢复。
        for file in sorted {
            if let known = analyticsCursors[file.path],
               let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               known > size {
                measured.removeAll()
                break
            }
        }
        for file in sorted {
            _ = consume(file, needle: Self.turnNeedle, cursors: &analyticsCursors, parse: parseTurn)
        }
        if measured.count > Self.measuredKeep {
            measured.removeFirst(measured.count - Self.measuredKeep)
        }
    }

    /// Mirasim 的诊断事件流按小时一个文件，`model.begin` 在请求发出瞬间写入，
    /// 是本机唯一能实时看到「请求在途」的地方。只扫最新两个文件，跨小时的 end 也接得上。
    private var diagCursors: [String: Int] = [:]

    private func scanDiag() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.mirasimDiag,
                                                     includingPropertiesForKeys: [.fileSizeKey]) else { return }
        let recent = files
            .filter { $0.lastPathComponent.hasPrefix("ev-") && $0.pathExtension == "ndjson" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .suffix(2)
        for file in recent {
            _ = consume(file, needle: Self.modelEventNeedle, cursors: &diagCursors, parse: parseModelEvent)
        }
    }

    /// 从 Claude Code 的 transcript 尾部取 token。transcript 是追加型、请求完成即写，
    /// 不依赖 relay 回填，是「当下」token 的唯一即时来源。
    /// 关联键：账本的 `providerCallId` 就是 transcript 的 `requestId`（实测逐条相等）。
    private func backfillFromTranscripts() {
        let wanted = Set(samples.filter { $0.out < Self.minOutput && !$0.requestId.isEmpty }
                                .map(\.requestId))
        if !wanted.isEmpty {
            scanTranscripts(for: wanted)
        }
        for i in samples.indices where samples[i].out < Self.minOutput {
            if let n = transcriptTokens[samples[i].requestId], n > 0 { samples[i].out = n }
        }
    }

    /// token 与时长的下限在这里统一把关：账本落盘时 token 为 0，
    /// 预筛已挪后，凡进入估计的样本都必须过这道门。
    private var usable: [Sample] {
        samples.filter { $0.out >= Self.minOutput && $0.ms >= Self.minDuration }
    }

    private func scanTranscripts(for wanted: Set<String>) {
        projectFiles.refresh()
        // 固定取 4 个会在超过 4 个会话并行写入时把目标文件挤出扫描集，
        // 其 token 迟迟补不上；改按活跃度取，冷清时仍保底 4 个。
        let recent = projectFiles.recent(limit: 12, activeSince: Date(timeIntervalSinceNow: -1800))

        for e in recent {
            // transcript 是追加型：一行写进去 mtime 必变。未变的文件里没有新 requestId，
            // 512 KB 尾部重读与逐行解析没有产出。首轮 transcriptRead 为空，仍是全读。
            if transcriptRead[e.url.path] == e.mtime { continue }
            transcriptRead[e.url.path] = e.mtime
            let file = e.url
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let offset = max(0, size - Self.transcriptWindow)
            try? handle.seek(toOffset: UInt64(offset))
            guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }
            let skipFirst = offset > 0
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let n = raw.count
                var start = 0, i = 0
                var firstLine = true
                Self.usageNeedle.withUnsafeBufferPointer { pat in
                    while i < n {
                        guard bytes[i] == 0x0A else { i += 1; continue }
                        let length = i - start
                        if !(skipFirst && firstLine), length > 2,
                           memmem(bytes + start, length, pat.baseAddress, pat.count) != nil {
                            parseTranscriptUsage(Data(bytes: bytes + start, count: length), wanted: wanted)
                        }
                        firstLine = false
                        start = i + 1
                        i += 1
                    }
                }
            }
        }
    }

    private func parseTranscriptUsage(_ line: Data, wanted: Set<String>) {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let rid = root["requestId"] as? String, wanted.contains(rid),
              let message = root["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let out = Self.int(usage["output_tokens"]), out > 0 else { return }
        // fork / resume 会复制同一条记录，取较大值即可（同一请求的值本就相同）。
        transcriptTokens[rid] = max(transcriptTokens[rid] ?? 0, out)
    }

    private func parseModelEvent(_ line: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let kind = root["kind"] as? String,
              let callId = root["callId"] as? String else { return }
        switch kind {
        case "model.begin":
            // 只认生成请求。count_tokens 与 /v1/limits 的探测也会产生事件对，不算在途。
            // split 对空串或全 '?' 返回空数组，强制下标会崩溃且 diag 游标在内存，
            // 重启后重读毒行变成崩溃循环，须走 first。
            guard (root["method"] as? String) == "POST",
                  let path = root["path"] as? String,
                  path.split(separator: "?").first == "/v1/messages",
                  let ts = root["ts"] as? String,
                  let at = fastEpochSeconds(ts) else { return }
            flights[callId] = at
        case "model.end":
            flights[callId] = nil
            if let ms = Self.int(root["durationMs"]), ms > 0 { diagDurations[callId] = ms }
        default:
            break
        }
    }

    /// 从游标处读入新增字节并逐行解析，返回游标是否因文件缩小而重置。
    /// 首次读取从文件尾部回溯，起点多半落在半行中间，故跳过第一行。
    private func consume(_ file: URL, needle: [UInt8], cursors: inout [String: Int],
                         parse: (Data) -> Void) -> Bool {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        let known = cursors[file.path]
        var reset = false
        var offset = known ?? max(0, size - Self.firstReadCap)
        if let known, known > size {
            offset = max(0, size - Self.firstReadCap)
            reset = true
        }
        let skipPartial = (known == nil || reset) && offset > 0

        guard size > offset else {
            cursors[file.path] = offset
            return reset
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return reset }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return reset }

        var consumed = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let n = raw.count
            var start = 0
            var i = 0
            var firstLine = true
            needle.withUnsafeBufferPointer { pat in
                while i < n {
                    guard bytes[i] == 0x0A else { i += 1; continue }
                    let length = i - start
                    if !(skipPartial && firstLine), length > 2,
                       memmem(bytes + start, length, pat.baseAddress, pat.count) != nil {
                        parse(Data(bytes: bytes + start, count: length))
                    }
                    firstLine = false
                    start = i + 1
                    consumed = start
                    i += 1
                }
            }
        }
        // 尾部不完整的行留待下次。
        cursors[file.path] = offset + consumed
        return reset
    }

    /// 账本记录落盘是即时的，但 token 要等 relay 回填（落盘时 `output` 为 0）。
    /// 故这里不按 token 筛，只取关联键；token 与时长随后由 transcript 与 diag 补齐。
    private static func parseUsage(_ line: Data, cutoff: Int) -> Sample? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (root["status"] as? Int) == 200,
              let ts = root["ts"] as? String,
              let at = fastEpochSeconds(ts), at >= cutoff,
              let ms = int(root["durationMs"]),
              let model = root["model"] as? String, !model.isEmpty else { return nil }
        let id = (root["id"] as? String) ?? ts
        return Sample(id: id, at: at, out: int(root["output"]) ?? 0, ms: ms, model: model,
                      callId: id.split(separator: ":").last.map(String.init) ?? "",
                      requestId: (root["providerCallId"] as? String) ?? "")
    }

    /// Mirasim 自己测的整轮首字节。口径是整轮而非单次请求，只作量级对照。
    private func parseTurn(_ line: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (root["name"] as? String) == "turn.finish",
              let props = root["props"] as? [String: Any],
              let ttfb = Self.int(props["ttfbMs"]), ttfb > 0 else { return }
        measured.append(Double(ttfb) / 1000)
    }

    @inline(__always)
    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    // MARK: 估计

    /// 按模型给出「最近几次」的速度。账本里一条样本都没有时返回 nil，界面据此整卡隐藏。
    func report(now: Date = Date()) -> SpeedReport? {
        let pool = usable
        guard !pool.isEmpty || !flights.isEmpty else { return nil }
        let horizon = Diag.speedSpan ?? Self.recencyLimit
        let fresh = Int(now.addingTimeInterval(-horizon).timeIntervalSince1970)

        var byModel: [String: [Sample]] = [:]
        for s in pool { byModel[s.model, default: []].append(s) }

        let rows = byModel.values
            .compactMap { estimate($0, fresh: fresh) }
            .sorted { $0.latestAt > $1.latestAt }
            .prefix(3)

        return SpeedReport(
            rows: Array(rows),
            recentCount: Self.recentCount,
            sampleTotal: pool.filter { $0.at >= fresh }.count,
            inflightSince: flights.values.sorted()
                .map { Date(timeIntervalSince1970: Double($0)) },
            measuredTurnTTFB: Self.median(measured).map {
                SpeedReport.Measured(median: $0, count: measured.count)
            }
        )
    }

    /// `group` 是某个模型保留期内的全部样本：回归取全部，出字速度只取最近几次。
    /// 最近一次请求早于 `fresh` 的模型不成行。
    private func estimate(_ group: [Sample], fresh: Int) -> SpeedRow? {
        let byTime = group.sorted { $0.at < $1.at }
        guard let newest = byTime.last, newest.at >= fresh else { return nil }
        let recent = Array(byTime.suffix(Self.recentCount)).filter { $0.at >= fresh }
        guard recent.count >= Self.minRow else { return nil }

        let (baselineRate, ttft) = regress(group)

        let out = recent.reduce(0) { $0 + $1.out }
        let ms = recent.reduce(0) { $0 + $1.ms }
        // 与出字速度同一口径（都按 token 加权），否则会出现「端到端比出字速度还快」的自相矛盾。
        let endToEnd = ms > 0 ? Double(out) / (Double(ms) / 1000) : 0

        // 首 token 无法逐次测量，故用回归值把它从每条请求的时长里扣掉，余下的才是出字时间。
        // 按 token 加权而不是取中位数：几十 token 的短请求里首 token 占了大半时长，
        // 逐条比值噪声极大，加权后长请求自然占主导，同时新样本一到就能推动结果。
        var rate: Double?
        if let ttft {
            let seconds = recent.reduce(0.0) { $0 + max(Double($1.ms) / 1000 - ttft, Self.minStreamSeconds) }
            if seconds > 0 {
                let r = Double(out) / seconds
                if r >= 5, r <= 1000 { rate = r }
            }
        }

        // 显示值平滑：与上次显示值相差在 rateJump 之内时按 rateSmoothing 收敛，
        // 超出则判为工况切换直接跳过去。平滑只作用于展示，回归基准不受影响。
        let key = Self.shortName(newest.model)
        if let raw = rate {
            if let prev = shownRate[key], prev > 0, abs(raw - prev) / prev <= Self.rateJump {
                rate = prev + (raw - prev) * Self.rateSmoothing
            }
            shownRate[key] = rate ?? raw
        } else {
            shownRate[key] = nil
        }

        var row = SpeedRow(model: key, samples: recent.count,
                           ttft: ttft, rate: rate, endToEnd: endToEnd,
                           baselineRate: baselineRate,
                           latestAt: Date(timeIntervalSince1970: Double(newest.at)))
        row.notableDrift = row.driftPasses(shown: driftShown.contains(key))
        if row.notableDrift == nil { driftShown.remove(key) } else { driftShown.insert(key) }
        return row
    }

    /// 保留期内全部样本的回归：斜率给出字速度基准，截距给首 token。
    ///
    /// 确定性的 Theil–Sen 变体：按输出量排序后取跨半程配对的斜率中位数，
    /// 对重试、网络抖动一类的离群时长不敏感，也不需要随机数。
    /// 输出量相同的样本按时长再排一次：Swift 的排序不保证稳定，
    /// 只按输出量排会让并列样本的配对顺序随运行变化，中位数随之漂移数个百分点。
    private func regress(_ group: [Sample]) -> (rate: Double?, ttft: Double?) {
        let sorted = group.sorted { $0.out != $1.out ? $0.out < $1.out : $0.ms < $1.ms }
        let half = sorted.count / 2
        var slopes: [Double] = []
        for i in 0..<half {
            let dx = sorted[i + half].out - sorted[i].out
            guard dx >= Self.minSeparation else { continue }
            slopes.append(Double(sorted[i + half].ms - sorted[i].ms) / Double(dx))
        }
        guard slopes.count >= Self.minPairs, let b = Self.median(slopes), b > 0 else { return (nil, nil) }
        let rate = 1000 / b
        guard rate >= 5, rate <= 1000 else { return (nil, nil) }
        // 截距为负说明线性关系在这批样本上不成立，此时不给首 token。
        guard let a = Self.median(sorted.map { Double($0.ms) - b * Double($0.out) }), a >= 0 else {
            return (rate, nil)
        }
        return (rate, a / 1000)
    }

    private static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }

    /// 展示名：去掉 `claude-` 前缀与快照日期后缀，族名首字母大写，版本号用点连接。
    /// `claude-opus-5` → `Opus 5`，`claude-opus-4-8` → `Opus 4.8`，
    /// `claude-haiku-4-5-20251001` → `Haiku 4.5`。
    /// 版本段不是纯数字时（`gpt-5.6-sol`、`deepseek-v4-flash` 一类）原样保留：
    /// 宁可显示原名，也不按猜测拼出一个错名。
    private static func shortName(_ model: String) -> String {
        guard !model.isEmpty else { return "未知" }
        var name = model
        // 可能带 provider 前缀（`anthropic/claude-opus-5`）。
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if name.hasPrefix("claude-") { name = String(name.dropFirst(7)) }
        // 只剩前缀时（`claude-`）退回原名，不给出空名字。
        guard !name.isEmpty else { return model }
        var parts = name.split(separator: "-").map(String.init)
        // 快照日期后缀，如 `-20251001`。
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first, !family.isEmpty else { return name }
        let version = parts.dropFirst()
        guard !version.isEmpty, version.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return name }
        return family.prefix(1).uppercased() + family.dropFirst() + " " + version.joined(separator: ".")
    }
}
