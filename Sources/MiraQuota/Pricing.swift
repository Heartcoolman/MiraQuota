import Foundation

struct ModelPrice: Sendable {
    /// 美元 / 百万 token
    let input, output, cacheRead, cacheWrite: Double
    /// 长上下文分档：提示 token（输入 + 缓存读 + 缓存写）超过 `threshold` 时整次请求改按该档计价。
    var longContext: ContextTier? = nil
    /// 促销分档：调用时刻不晚于 `until`（UTC 当日末）时按该档计价。
    var promo: PromoTier? = nil
}

struct ContextTier: Sendable {
    let threshold: Int
    let input, output, cacheRead, cacheWrite: Double
}

struct PromoTier: Sendable {
    /// unix 秒，`until` 日期当天 23:59:59 UTC。
    let until: Int
    let input, output, cacheRead, cacheWrite: Double
}

/// 价目表。依次取 Mirasim 模型花名册（`~/.mirasim/setting.json` 的 `modelRosterCache`，
/// 即中继的 `/v1/model-roster`）、Mirasim 的 models.dev 缓存、内置表。
///
/// 花名册是 Mirasim「流量监控」页估算成本的依据，账本以它为准才与该页逐项同口径。
/// 花名册只给价目，不给扣点倍率；各模型每美元扣多少点由 `PointRates` 按本机数据实测。
/// 缓存写取 5 分钟价：网关账本不拆 5m/1h，Mirasim 自己也按 5m 价折算；
/// Opus 5.5 的扣点回归同样落在 5m 价（09-25 实测 $5.00/MTok）。
struct Pricing: Sendable {
    /// 花名册，按 id 长度降序：匹配规则是「等于 id 或以 `/id`、`.id` 结尾」，长 id 优先才不被短 id 截胡。
    private let roster: [(id: String, price: ModelPrice)]
    private let table: [String: ModelPrice]
    let source: String
    /// 花名册与价目表内容的指纹。账本只存金额，价格一变已落账的金额就不再同口径，据此触发重建。
    let signature: String
    /// 花名册标记为 Claude 默认的模型，`PointRates` 以它为锚点。
    let rosterDefault: String?
    var hasRoster: Bool { !roster.isEmpty }
    var rosterIds: [String] { roster.map { Self.aliases[$0.id] ?? $0.id } }

    private static let builtin: [String: ModelPrice] = [
        "claude-opus-5-5":   ModelPrice(input: 4,  output: 20, cacheRead: 0.2, cacheWrite: 5),
        "claude-opus-5":     ModelPrice(input: 5,  output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-8":   ModelPrice(input: 5,  output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-7":   ModelPrice(input: 5,  output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-6":   ModelPrice(input: 5,  output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-5":   ModelPrice(input: 5,  output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-fable-5-1":  ModelPrice(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5),
        "claude-fable-5":    ModelPrice(input: 10, output: 50, cacheRead: 1.0, cacheWrite: 12.5),
        "claude-sonnet-5":   ModelPrice(input: 2,  output: 10, cacheRead: 0.2, cacheWrite: 2.5),
        "claude-sonnet-4-6": ModelPrice(input: 3,  output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-sonnet-4-5": ModelPrice(input: 3,  output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-haiku-4-5":  ModelPrice(input: 1,  output: 5,  cacheRead: 0.1, cacheWrite: 1.25),
        // 花名册与 models.dev 缓存都缺失时的兜底，取值同花名册 2026-09-24.v6。
        "gpt-5.6-sol":       ModelPrice(input: 4,  output: 20, cacheRead: 0.4, cacheWrite: 0),
        "gpt-5.6-terra":     ModelPrice(input: 2,  output: 12, cacheRead: 0.2, cacheWrite: 0),
        "gpt-5.6-luna":      ModelPrice(input: 0.2, output: 1.2, cacheRead: 0.02, cacheWrite: 0),
        "gpt-6-astra":       ModelPrice(input: 10, output: 50, cacheRead: 1, cacheWrite: 0),
        "kimi-k3":           ModelPrice(input: 3,  output: 15, cacheRead: 0.3, cacheWrite: 0.3),
        "glm-5.3-flash":     ModelPrice(input: 0.15, output: 0.5, cacheRead: 0.03, cacheWrite: 0),
        "deepseek-flash":    ModelPrice(input: 0.3, output: 1.2, cacheRead: 0.006, cacheWrite: 0),
    ]

    /// 同一模型在花名册里的别名，账本与扣点率按同一个键归并。
    private static let aliases = ["kimi-code/k3": "kimi-k3"]

    init(cachePath: URL = Paths.modelsCache, settingPath: URL = Paths.mirasimSetting) {
        let (rosterTable, version, defaultId) = Self.loadRoster(settingPath)
        roster = rosterTable.sorted { $0.key.count > $1.key.count }.map { ($0.key, $0.value) }
        rosterDefault = defaultId
        var merged = Self.builtin
        let loaded = Self.loadModelsDev(cachePath)
        if let loaded {
            merged.merge(loaded.primary) { _, fresh in fresh }
            merged.merge(loaded.extra) { kept, _ in kept }
        }
        table = merged
        var parts: [String] = []
        if let version { parts.append("花名册 \(version)") }
        parts.append(loaded == nil ? "内置表" : "models.dev")
        source = parts.joined(separator: " + ")
        signature = Self.fingerprint(roster: roster, table: table)
    }

    // MARK: 加载

    private static func loadRoster(_ url: URL) -> ([String: ModelPrice], String?, String?) {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = root["modelRosterCache"] as? [String: Any],
              let models = cache["models"] as? [String: Any] else { return ([:], nil, nil) }
        var out: [String: ModelPrice] = [:]
        for (id, raw) in models {
            guard let p = (raw as? [String: Any])?["pricing"] as? [String: Any],
                  let base = rosterPrice(p) else { continue }
            var price = base
            if let long = p["long"] as? [String: Any], let over = number(long["overTokens"]), over > 0,
               let t = rosterPrice(long) {
                price.longContext = ContextTier(threshold: Int(over), input: t.input, output: t.output,
                                                cacheRead: t.cacheRead, cacheWrite: t.cacheWrite)
            }
            if let promo = p["promo"] as? [String: Any], let until = endOfDay(promo["until"] as? String),
               let t = rosterPrice(promo) {
                price.promo = PromoTier(until: until, input: t.input, output: t.output,
                                        cacheRead: t.cacheRead, cacheWrite: t.cacheWrite)
            }
            out[id.lowercased()] = price
        }
        let claude = ((cache["agents"] as? [String: Any])?["claude"] as? [[String: Any]]) ?? []
        let defaultId = (claude.first { ($0["default"] as? Bool) == true } ?? claude.first)?["id"] as? String
        return (out, cache["version"] as? String, defaultId?.lowercased())
    }

    private static func rosterPrice(_ p: [String: Any]) -> ModelPrice? {
        guard let i = number(p["input"]), let o = number(p["output"]) else { return nil }
        return ModelPrice(input: i, output: o, cacheRead: number(p["cacheRead"]) ?? 0,
                          cacheWrite: number(p["cacheWrite5m"]) ?? number(p["cacheWrite"]) ?? 0)
    }

    private static func endOfDay(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces),
              raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let day = fastEpochSeconds(raw + "T23:59:59Z") else { return nil }
        return day
    }

    /// models.dev 缓存。`primary` 为 Anthropic 与 OpenAI，覆盖内置表；`extra` 为 Kimi、智谱、DeepSeek
    /// 的官方供应商条目，只补缺不覆盖。其它转售商的同名模型价格各异，一概不读。
    private static func loadModelsDev(_ url: URL) -> (primary: [String: ModelPrice], extra: [String: ModelPrice])? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["data"] as? [String: Any] else { return nil }
        func read(_ names: [String]) -> [String: ModelPrice] {
            var out: [String: ModelPrice] = [:]
            for name in names {
                guard let models = (providers[name] as? [String: Any])?["models"] as? [String: Any] else { continue }
                for (id, raw) in models {
                    guard let c = (raw as? [String: Any])?["cost"] as? [String: Any],
                          let i = number(c["input"]), let o = number(c["output"]) else { continue }
                    let cacheRead = number(c["cache_read"]) ?? i * 0.1
                    let cacheWrite = number(c["cache_write"]) ?? i * 1.25
                    let tier = (c["tiers"] as? [[String: Any]])?.first {
                        ($0["tier"] as? [String: Any])?["type"] as? String == "context"
                    }.flatMap { t -> ContextTier? in
                        guard let size = number((t["tier"] as? [String: Any])?["size"]),
                              let ti = number(t["input"]), let to = number(t["output"]) else { return nil }
                        return ContextTier(threshold: Int(size), input: ti, output: to,
                                           cacheRead: number(t["cache_read"]) ?? cacheRead,
                                           cacheWrite: number(t["cache_write"]) ?? cacheWrite)
                    }
                    out[id.lowercased()] = ModelPrice(input: i, output: o, cacheRead: cacheRead,
                                                      cacheWrite: cacheWrite, longContext: tier)
                }
            }
            return out
        }
        let primary = read(["anthropic", "openai"])
        guard primary.count >= 5 else { return nil }
        return (primary, read(["moonshotai", "zhipuai", "deepseek"]))
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// FNV-1a 64 位，输入按 id 排序，跨进程稳定（Swift 的 `hashValue` 每次启动加盐，不可用）。
    private static func fingerprint(roster: [(id: String, price: ModelPrice)], table: [String: ModelPrice]) -> String {
        func row(_ id: String, _ p: ModelPrice) -> String {
            var s = "\(id):\(p.input)/\(p.output)/\(p.cacheRead)/\(p.cacheWrite)"
            if let t = p.longContext { s += "|L\(t.threshold):\(t.input)/\(t.output)/\(t.cacheRead)/\(t.cacheWrite)" }
            if let t = p.promo { s += "|P\(t.until):\(t.input)/\(t.output)/\(t.cacheRead)/\(t.cacheWrite)" }
            return s
        }
        let text = (roster.map { "R" + row($0.id, $0.price) }.sorted()
                    + table.map { row($0.key, $0.value) }.sorted()).joined(separator: "\n")
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    // MARK: 查价

    /// 归一化模型标识：剥掉 `[1m]` 一类的上下文后缀与 provider 前缀。
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let bracket = s.firstIndex(of: "[") { s = String(s[s.startIndex..<bracket]) }
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        return s
    }

    /// 解析出价目 id 与价格。先按 Mirasim 的规则匹配花名册，再按裸名、日期后缀与系列兜底查表。
    func resolve(_ rawModel: String) -> (id: String, price: ModelPrice)? {
        var s = rawModel.trimmingCharacters(in: .whitespaces).lowercased()
        if let bracket = s.firstIndex(of: "[") { s = String(s[s.startIndex..<bracket]) }
        if let hit = roster.first(where: { s == $0.id || s.hasSuffix("/" + $0.id) || s.hasSuffix("." + $0.id) }) {
            return hit
        }
        let id = Self.normalize(s)
        if let hit = table[id] { return (id, hit) }
        var parts = id.split(separator: "-")
        while parts.count > 2 {
            parts.removeLast()
            let key = parts.joined(separator: "-")
            if let hit = table[key] { return (key, hit) }
        }
        // 系列兜底只对 Claude 的族名：OpenAI、Kimi 等未知模型记为未定价，避免把价格猜错。
        for (family, key) in [("opus", "claude-opus-5"), ("fable", "claude-fable-5"),
                              ("sonnet", "claude-sonnet-5"), ("haiku", "claude-haiku-4-5")] {
            if id.contains(family), let hit = table[key] { return (key, hit) }
        }
        return nil
    }

    func price(for rawModel: String) -> ModelPrice? { resolve(rawModel)?.price }

    /// 账本与扣点率共用的模型键：价目 id（别名归并），查不到价时退回去掉后缀与日期的裸名。
    func key(for rawModel: String) -> String {
        if let id = resolve(rawModel)?.id { return Self.aliases[id] ?? id }
        var parts = Self.normalize(rawModel.lowercased()).split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        return parts.joined(separator: "-")
    }

    /// 计价，分档次序同 Mirasim：长上下文优先，其次促销（按调用时刻判是否过期），最后基础价。
    func cost(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int,
              at epoch: Int? = nil) -> Double? {
        guard let p = price(for: model) else { return nil }
        let rates: (Double, Double, Double, Double)
        if let t = p.longContext, input + cacheRead + cacheWrite > t.threshold {
            rates = (t.input, t.output, t.cacheRead, t.cacheWrite)
        } else if let t = p.promo, (epoch ?? Int(Date().timeIntervalSince1970)) <= t.until {
            rates = (t.input, t.output, t.cacheRead, t.cacheWrite)
        } else {
            rates = (p.input, p.output, p.cacheRead, p.cacheWrite)
        }
        return (Double(input) * rates.0 + Double(output) * rates.1
                + Double(cacheRead) * rates.2 + Double(cacheWrite) * rates.3) / 1_000_000
    }

    /// 界面上的模型名。Claude 与 GPT 沿用速度卡的短名；其余按连字符分词，品牌名按惯用大小写。
    static func displayName(_ key: String) -> String {
        if key.hasPrefix("claude-") || key.hasPrefix("gpt") { return SpeedStats.shortName(key) }
        let brands = ["glm": "GLM", "deepseek": "DeepSeek", "kimi": "Kimi"]
        return key.split(separator: "-").map { word in
            brands[String(word)] ?? (word.prefix(1).uppercased() + word.dropFirst())
        }.joined(separator: " ")
    }
}
