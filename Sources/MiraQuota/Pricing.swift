import Foundation

struct ModelPrice: Sendable {
    /// 美元 / 百万 token
    let input, output, cacheRead, cacheWrite: Double
}

/// 价目表。优先读 Mirasim 的 models.dev 缓存，缺失时回退到内置表。
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
              let providers = root["data"] as? [String: Any],
              let anthropic = providers["anthropic"] as? [String: Any],
              let models = anthropic["models"] as? [String: Any] else { return nil }

        var out: [String: ModelPrice] = [:]
        for (id, raw) in models {
            guard let m = raw as? [String: Any], let c = m["cost"] as? [String: Any],
                  let i = c["input"] as? Double, let o = c["output"] as? Double else { continue }
            out[id] = ModelPrice(input: i, output: o,
                                 cacheRead: c["cache_read"] as? Double ?? i * 0.1,
                                 cacheWrite: c["cache_write"] as? Double ?? i * 1.25)
        }
        return out.isEmpty ? nil : out
    }

    /// 归一化模型标识：剥掉 `[1m]` 一类的上下文后缀与日期后缀。
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let bracket = s.firstIndex(of: "[") { s = String(s[s.startIndex..<bracket]) }
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

        // 系列兜底
        for (family, key) in [("opus", "claude-opus-5"), ("fable", "claude-fable-5"),
                              ("sonnet", "claude-sonnet-5"), ("haiku", "claude-haiku-4-5")] {
            if id.contains(family) { return table[key] }
        }
        return nil
    }

    func cost(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double? {
        guard let p = price(for: model) else { return nil }
        return (Double(input) * p.input + Double(output) * p.output
                + Double(cacheRead) * p.cacheRead + Double(cacheWrite) * p.cacheWrite) / 1_000_000
    }
}
