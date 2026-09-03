import Foundation

struct ModelPrice: Sendable {
    /// 美元 / 百万 token
    let input, output, cacheRead, cacheWrite: Double
}

/// 价目表。优先读 Mirasim 的 models.dev 缓存，缺失时回退到内置表。
///
/// 账本按 Anthropic 公开价目折算，与 Mirasim「流量监控」页的估算成本同口径。上游扣点对各模型另有倍率：
/// 以 Mirasim 网关账本对 `7d_fable` 点序列做 10 分钟分箱回归（2026-09-03 晚 247 次调用、104 箱，R² 0.998），
/// Fable 5.1 的输入、输出、缓存读、缓存写四类均按价目的 2 倍扣点（整体倍率拟合 1.97×）；Opus 5 在全部截点为
/// 195–214 点/美元，按价目扣点。故 Fable 用量占比高时主行（点数 × 官方每点美元）约为账本的 2 倍，
/// 这是口径差而非计算误差。曾把账本改按扣点倍率折算，因与 Mirasim 页面不再可比而回退。
///
/// 绝对金额受未建模的长上下文溢价影响，但校准与计量共用同一张表，
/// 比例一致，故占比结论不受该偏差影响。
struct Pricing: Sendable {
    private let table: [String: ModelPrice]
    let source: String

    private static let builtin: [String: ModelPrice] = [
        "claude-opus-5":     ModelPrice(input: 5,  output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-8":   ModelPrice(input: 5,  output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-7":   ModelPrice(input: 5,  output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-6":   ModelPrice(input: 5,  output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-5":   ModelPrice(input: 5,  output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-fable-5":    ModelPrice(input: 10, output: 50, cacheRead: 1.0, cacheWrite: 12.5),
        "claude-sonnet-5":   ModelPrice(input: 2,  output: 10, cacheRead: 0.2, cacheWrite: 2.5),
        "claude-sonnet-4-6": ModelPrice(input: 3,  output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-sonnet-4-5": ModelPrice(input: 3,  output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-haiku-4-5":  ModelPrice(input: 1,  output: 5,  cacheRead: 0.1, cacheWrite: 1.25),
        // Codex 经 Mirasim 的 openai-responses 记录使用这些模型名。
        // 价目表缓存有更完整的版本；这里保留实测到的三种，避免缓存暂时缺失时
        // OpenAI 请求被整条漏掉。
        "gpt-5.6-sol":       ModelPrice(input: 4,  output: 20, cacheRead: 0.4, cacheWrite: 5),
        "gpt-5.6-terra":     ModelPrice(input: 2,  output: 12, cacheRead: 0.2, cacheWrite: 2.5),
        "gpt-5.6-luna":      ModelPrice(input: 0.2, output: 1.2, cacheRead: 0.02, cacheWrite: 0.25),
    ]

    init(cachePath: URL = Paths.modelsCache) {
        if let loaded = Self.load(cachePath), loaded.count >= 5 {
            table = Self.builtin.merging(loaded) { _, fresh in fresh }
            source = "models.dev cache"
        } else {
            table = Self.builtin
            source = "builtin"
        }
    }

    private static func load(_ url: URL) -> [String: ModelPrice]? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["data"] as? [String: Any] else { return nil }

        var out: [String: ModelPrice] = [:]
        // 只合并实际计入本项目的两种上游。其它 provider 的同名模型可能有
        // 不同价格，不能因为缓存里出现它们就改变 OpenAI/Anthropic 的口径。
        for providerName in ["anthropic", "openai"] {
            guard let provider = providers[providerName] as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { continue }
            for (id, raw) in models {
                guard let m = raw as? [String: Any], let c = m["cost"] as? [String: Any],
                      let i = number(c["input"]), let o = number(c["output"]) else { continue }
                out[id] = ModelPrice(input: i, output: o,
                                     cacheRead: number(c["cache_read"]) ?? i * 0.1,
                                     cacheWrite: number(c["cache_write"]) ?? i * 1.25)
            }
        }
        return out.isEmpty ? nil : out
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// 归一化模型标识：剥掉 `[1m]` 一类的上下文后缀与日期后缀。
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let bracket = s.firstIndex(of: "[") { s = String(s[s.startIndex..<bracket]) }
        // 某些网关会把模型写成 `openai/gpt-5.6-sol` 或
        // `anthropic/claude-opus-5`，价目表缓存使用裸模型名。
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        return s
    }

    /// 查价。未收录的标识按系列前缀归档，避免整条记录被丢弃造成低估。
    func price(for rawModel: String) -> ModelPrice? {
        let id = Self.normalize(rawModel)
        if let hit = table[id] { return hit }

        // 带日期后缀：claude-opus-5-20260101 → claude-opus-5
        var parts = id.split(separator: "-")
        while parts.count > 2 {
            parts.removeLast()
            if let hit = table[parts.joined(separator: "-")] { return hit }
        }

        // 系列兜底。Claude 的族名沿用原有逻辑；OpenAI 只对已知的
        // Codex 模型族兜底，未知模型仍记为未定价，避免把价格猜错。
        for (family, key) in [("opus", "claude-opus-5"), ("fable", "claude-fable-5"),
                              ("sonnet", "claude-sonnet-5"), ("haiku", "claude-haiku-4-5")] {
            if id.contains(family) { return table[key] }
        }
        for (family, key) in [("gpt-5.6-sol", "gpt-5.6-sol"),
                              ("gpt-5.6-terra", "gpt-5.6-terra"),
                              ("gpt-5.6-luna", "gpt-5.6-luna")] {
            if id == family || id.hasPrefix(family + "-") { return table[key] }
        }
        return nil
    }

    func cost(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double? {
        guard let p = price(for: model) else { return nil }
        return (Double(input) * p.input + Double(output) * p.output
                + Double(cacheRead) * p.cacheRead + Double(cacheWrite) * p.cacheWrite) / 1_000_000
    }
}
