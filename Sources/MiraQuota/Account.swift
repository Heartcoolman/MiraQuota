import Foundation

/// 账号身份判据的取值，带来源前缀。
///
/// 唯一可用的判据是 `login.userId`，它随账号恒定。relay 令牌的尾号 `tokenTail`
/// 曾作退路，现已弃用：令牌有效期约 1 小时、到期即换，用它判账号会把每次轮换
/// 误判成换账号，反复把样本下界抬到当下。前缀保留是为了识别旧盘面里的尾号取值
/// （`t:` 或无前缀），它们与 userId 不可互比。
enum AccountTag {
    static func user(_ id: String) -> String { "u:" + id }

    /// 取值的来源标记。前缀缺失时按令牌尾号处理，那是本版本之前落盘的形态。
    static func source(_ tag: String) -> Character {
        let head = tag.prefix(2)
        return head == "u:" || head == "t:" ? tag.first! : "t"
    }
}

/// 一组半开区间 [from, to)，按起点升序且互不相交。空集表示不设限。
struct PlanWindows: Sendable, Equatable {
    struct Span: Sendable, Equatable {
        let from: Double
        let to: Double
    }

    let spans: [Span]

    static let unbounded = PlanWindows(spans: [])

    func contains(_ at: Double) -> Bool {
        guard !spans.isEmpty else { return true }
        return spans.contains { at >= $0.from && at < $0.to }
    }

    /// 最早的可用时刻，供扫描裁剪用。不设限时为 0。
    var earliest: Double { spans.first?.from ?? 0 }
}

/// 账号身份、套餐档位与两者的变更时刻。
///
/// 换账号会同时换掉套餐与上游服务的账号池，切换前的样本一概不可比，只留下界。
/// 同账号内升降套餐时 `userId` 不变，预算点与上游服务质量却都会变：百分比口径
/// 因预算点改变而不可比，首 token 与出字速度也可能整体平移。这类变更按区间记录，
/// 各档位的样本各自保留，切回原档位即复用其历史样本。
///
/// 切换时刻必须落盘。速度样本来自网关账本与 transcript，两者都在磁盘上，
/// 只把下界留在内存里的话，provider 重启后会把切换前的请求重新扫回来。
final class AccountStore {
    /// 一段套餐区间的起点，终点由下一段的起点给出。
    struct PlanSpan: Codable, Sendable {
        var plan: String
        var since: Double
    }

    /// 一次采纳所触发的变更。两者的处置不同：换账号只设下界，换套餐分区间。
    struct Change: OptionSet, Sendable {
        let rawValue: Int
        static let account = Change(rawValue: 1)
        static let plan = Change(rawValue: 2)
    }

    /// 状态版本。1 及以下的 `since` 可能来自令牌尾号判据下的轮换误判，
    /// 升级时归 0——留着会继续把样本下界压在一个并非切换的时刻上。
    static let version = 2

    private struct Persisted: Codable {
        var tag: String
        var since: Double
        /// 必须是 Optional，理由同 `plans`：旧文件缺该键时非可选会让整个状态解码失败。
        var v: Int? = nil
        /// 套餐区间，按起点升序。必须是 Optional：合成 Codable 只对 Optional 走
        /// decodeIfPresent，旧 account.json 缺该键时非可选会让整个状态解码失败被静默清空。
        var plans: [PlanSpan]? = nil
    }

    private var state: Persisted?
    private let lock = NSLock()

    init() {
        guard let data = try? Data(contentsOf: Paths.accountState),
              var loaded = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        if (loaded.v ?? 1) < Self.version {
            loaded.since = 0
            loaded.v = Self.version
            state = loaded
            persist(loaded)
            return
        }
        state = loaded
    }

    /// 最后一次换账号的时刻，unix 秒。从未观测到切换时为 0，表示不设下界。
    var since: Double {
        lock.lock(); defer { lock.unlock() }
        return state?.since ?? 0
    }

    /// 当前套餐档位。从未观测到时为 nil。
    var currentPlan: String? {
        lock.lock(); defer { lock.unlock() }
        return state?.plans?.last?.plan
    }

    /// 当前套餐的可用样本区间，已与换账号的下界求交。
    /// 未观测到套餐或只有一段时退化为「下界之后一律可用」。
    func currentWindows() -> PlanWindows {
        lock.lock(); defer { lock.unlock() }
        let floor = state?.since ?? 0
        guard let plans = state?.plans, let current = plans.last?.plan else {
            return floor > 0 ? PlanWindows(spans: [.init(from: floor, to: .infinity)]) : .unbounded
        }
        var spans: [PlanWindows.Span] = []
        for (i, span) in plans.enumerated() where span.plan == current {
            let end = i + 1 < plans.count ? plans[i + 1].since : Double.infinity
            let from = max(span.since, floor)
            if from < end { spans.append(.init(from: from, to: end)) }
        }
        // 相邻区间接在一起时合并，判定与扫描裁剪都少一次比较。
        var merged: [PlanWindows.Span] = []
        for s in spans.sorted(by: { $0.from < $1.from }) {
            if let last = merged.last, s.from <= last.to {
                merged[merged.count - 1] = .init(from: last.from, to: max(last.to, s.to))
            } else {
                merged.append(s)
            }
        }
        if merged.count == 1, merged[0].from <= floor, merged[0].to == .infinity {
            return floor > 0 ? PlanWindows(spans: merged) : .unbounded
        }
        return PlanWindows(spans: merged)
    }

    /// 采纳一次观测到的账号标识与套餐档位，返回本次发生的变更。
    ///
    /// 首次记录不算切换：那是升级到本版本或首次运行，此前的样本仍属同一账号与档位，
    /// 故 `since` 记 0 而非当下——记当下会把在用账号的历史样本一并判为过期。
    ///
    /// 判据来源改变同样不算切换：那是升级到以 userId 判账号，或 login 字段暂缺
    /// 退回令牌尾号，两个命名空间的取值不可比。此时 `since` 一并归 0——令牌尾号
    /// 判据下记的下界来自轮换误判，留着会继续压制本可用的样本。
    @discardableResult
    func adopt(_ tag: String?, plan: String? = nil, now: Date = Date()) -> Change {
        guard let tag, !tag.isEmpty else { return [] }
        lock.lock()
        var change: Change = []
        var next = state ?? Persisted(tag: tag, since: 0, v: Self.version)
        next.v = Self.version

        if next.tag != tag || state == nil {
            let switched = state.map { AccountTag.source($0.tag) == AccountTag.source(tag) } ?? false
            next.tag = tag
            next.since = switched ? now.timeIntervalSince1970 : 0
            if switched {
                // 换账号后套餐时间线从头记：旧账号的区间对新账号没有意义，
                // 而切换下界已经卡住了更早的样本，新的首段不必再设界。
                next.plans = plan.map { [PlanSpan(plan: $0, since: 0)] }
                change.insert(.account)
            }
        }

        if let plan, !plan.isEmpty {
            var plans = next.plans ?? []
            if plans.last?.plan != plan {
                // 首段记 0：此前的样本属于同一档位，记当下会把它们一并判为过期。
                plans.append(PlanSpan(plan: plan, since: plans.isEmpty ? 0 : now.timeIntervalSince1970))
                next.plans = plans
                if !change.contains(.account), plans.count > 1 { change.insert(.plan) }
            }
        }

        let dirty = change.rawValue != 0 || state == nil || next.tag != state?.tag
            || next.plans?.count != state?.plans?.count
        state = next
        lock.unlock()
        if dirty { persist(next) }
        return change
    }

    private func persist(_ v: Persisted) {
        Paths.ensureStateDir()
        guard let data = try? JSONEncoder().encode(v) else { return }
        try? data.write(to: Paths.accountState, options: .atomic)
    }
}
