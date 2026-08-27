import Foundation

/// 单个额度窗口的实时状态，取自 Mirasim 的 relay 帧。
struct QuotaWindow: Sendable, Equatable {
    let label: String
    let usedPercent: Double
    let resetAt: Date
    /// 该窗口是否只计特定模型档位的用量（实测 `7d_fable`）。
    var modelScoped: Bool = false

    /// 模型档位组名，取窗口名下划线之后的部分（`7d_fable` → `fable`）。
    static func modelGroup(of label: String) -> String? {
        guard let idx = label.lastIndex(of: "_") else { return nil }
        let group = label[label.index(after: idx)...].lowercased()
        return group.isEmpty ? nil : String(group)
    }

    var modelGroup: String? { modelScoped ? Self.modelGroup(of: label) : nil }

    /// 窗口长度，由标签解析（"5h" / "7d" / "7d Opus"）。
    var duration: TimeInterval? {
        let scan = Scanner(string: label)
        guard let n = scan.scanDouble() else { return nil }
        guard let unit = scan.scanCharacters(from: .letters)?.lowercased() else { return nil }
        switch unit {
        case "m": return n * 60
        case "h": return n * 3600
        case "d": return n * 86400
        case "w": return n * 604800
        default: return nil
        }
    }

    var startAt: Date? { duration.map { resetAt.addingTimeInterval(-$0) } }
}

/// relay 帧快照。
struct RelaySnapshot: Sendable {
    let windows: [QuotaWindow]
    let capturedAt: Date
    let host: String
    /// cloud / local / smart
    let mode: String
    /// ok / invalid / unknown
    let relayStatus: String
    /// relay 自带的百分比环形缓冲，用于冷启动时补充校准样本。
    let history: [HistoryPoint]
    /// 账号身份判据，带来源前缀（见 `AccountTag`）。换账号时套餐可能不同，
    /// 百分比口径的标定样本随之不可比；帧未给出可用字段时为 nil。
    let accountTag: String?
    /// 当前套餐档位，取自帧内 `login.plan`（实测取值 plus / max）。
    let plan: String?

    struct HistoryPoint: Sendable {
        let at: Date
        let fiveHour: Double?
        let sevenDay: Double?
    }

    func window(_ label: String) -> QuotaWindow? {
        windows.first { $0.label.caseInsensitiveCompare(label) == .orderedSame }
    }

    /// 取某窗口的历史百分比序列，供界面画趋势。
    func trend(for label: String) -> [Double] {
        let key = label.lowercased()
        let pick: (HistoryPoint) -> Double? =
            key == "5h" ? { $0.fiveHour } : (key == "7d" ? { $0.sevenDay } : { _ in nil })
        return history.sorted { $0.at < $1.at }.compactMap(pick)
    }
}

// MARK: - 通道状态

/// 数据通道所处的降级层级。四级依次退让，任何一级都仍有可读的输出。
enum ChannelState: Sendable, Equatable {
    /// 正在建立与 Mirasim 的连接。
    case connecting
    /// 路由端口的 `/v1/limits` 可读，已用与总额都是原始值，无需反推。
    case exact
    /// relay 帧持续到达，百分比为实测值。
    case live
    /// 连接尚在但帧已停更，显示最后一次实测值。参数为数据龄期。
    case stale(TimeInterval)
    /// Mirasim 不可达，以最后一次窗口锚点滚动推算。参数为锚点龄期。
    case reckoned(TimeInterval)
    /// 无任何锚点，退到本地滚动窗口，只报支出不报百分比。
    case local
    /// 连上了但帧无法解析，通常意味着 Mirasim 改了协议。
    case mismatch(String)

    var isMeasured: Bool {
        switch self {
        case .exact, .live, .stale: return true
        default: return false
        }
    }

    /// 机器可读的状态键。界面按它选颜色，不按中文标签匹配（标签改字不应牵动配色）。
    var key: String {
        switch self {
        case .connecting: return "connecting"
        case .exact: return "exact"
        case .live: return "live"
        case .stale: return "stale"
        case .reckoned: return "reckoned"
        case .local: return "local"
        case .mismatch: return "mismatch"
        }
    }

    var label: String {
        switch self {
        case .connecting: return "连接中"
        case .exact: return "精确"
        case .live: return "实时"
        case .stale: return "已过期"
        case .reckoned: return "推算"
        case .local: return "本地"
        case .mismatch: return "协议不符"
        }
    }

    /// 面板上的一句话解释，说明当前数字从哪来、可信到什么程度。
    var detail: String? {
        switch self {
        case .connecting:
            return "正在寻找 Mirasim 的本地端口"
        case .exact:
            return nil
        case .live:
            return "路由端口的 /v1/limits 不可读，百分比取自 relay 帧（分辨率 0.1%）"
        case .stale(let age):
            return "Mirasim 已 \(Formatting.age(age))未回传，显示最后一次实测值"
        case .reckoned(let age):
            return "Mirasim 未运行，按 \(Formatting.age(age))前的窗口锚点推算，未计入他人占用"
        case .local:
            return "无窗口锚点，仅按本机滚动窗口统计支出"
        case .mismatch(let why):
            return "Mirasim 回传的帧无法解析（\(why)），可能已更新协议"
        }
    }
}

// MARK: - 结论

/// 一个窗口算完后的完整结论，直接喂给界面。
struct WindowReport: Sendable {
    let label: String
    let usedPercent: Double
    let spentUSD: Double
    let fullUSD: Double?
    let confidence: Calibration.Confidence
    let sampleCount: Int
    let resetAt: Date?
    /// 窗口时间进度，0–100。
    let pacePercent: Double?
    /// 百分比是否为本地推算而非 relay 实测。
    let inferred: Bool
    /// 历史百分比序列，用于趋势图。
    let trend: [Double]
    /// 额度点的原始已用与总额，仅在 `/v1/limits` 可读时有值。
    let points: PointBalance?
    /// 按点数口径折算的已用美元：`满额 × 用量百分比`。与进度条、百分比同分母，
    /// 三者在卡面上互相自洽。本机账本支出（`spentUSD`）与它的差值反映当前窗口的
    /// 用量构成与标定期不同（各窗口点数计价不同，5h 上实测差到 1.5 倍），
    /// 故账本值降为副行而不是弃用。百分比本身由推算得出时（`inferred`）两者同义，为 nil。
    var scaledSpentUSD: Double? = nil
    /// 按近 1 小时点增速外推的打满秒数，无消耗或观测不足时为 nil。
    var etaSeconds: Double? = nil
    /// 剩余可用的美元估计：满额 ×（100 − 已用百分比），满额未知时为 nil。
    var remainingUSD: Double? = nil
    /// 该窗口只计某一模型档位的用量时的档位组名（实测 `fable`），通用窗口为 nil。
    /// 这类窗口的 `spentUSD` 只含同档位模型的支出，与全机支出不同口径。
    var modelGroup: String? = nil

    /// 用量进度减时间进度：正数表示快于均速。
    var paceDelta: Double? { pacePercent.map { usedPercent - $0 } }
}

/// 额度点余额。单位是 Mirasim 自己的计量单位，不是美元。
struct PointBalance: Sendable {
    let used: Double
    let budget: Double
}

// MARK: - 速度

/// 单个模型的速度估计：首 token 取保留期内的回归值，出字速度只取最近几次请求。
struct SpeedRow: Sendable {
    /// 去掉 `claude-` 前缀的短名。
    let model: String
    /// 参与出字速度计算的最近请求数。
    let samples: Int
    /// 首 token 等待，秒。无法逐次测量，取保留期内的回归截距；样本不足时为 nil。
    let ttft: Double?
    /// 出字速度，tok/s，不含首字等待。最近几次请求的逐条中位数。
    let rate: Double?
    /// 端到端速率：最近几次请求的输出量除以总时长，含首字等待。
    let endToEnd: Double
    /// 保留期内回归出的出字速度，作为「当下 vs 常态」的对照基准。
    let baselineRate: Double?
    /// 该模型最近一次请求的时刻。
    let latestAt: Date
    /// 本行来自逐请求实测（Claude Code OTel trace）而非回归估计。
    /// 实测行的首 token 不带 `≈`：它是测量值的中位数，不是截距。
    var measured: Bool = false
    /// 该模型归属的额度档位组（实测 `fable`），对应 modelScoped 窗口。
    /// 不属于任何档位窗口的模型为 nil，其用量计入通用窗口。
    var modelGroup: String? = nil
    /// 界面显示的偏离。闸门带迟滞（进 25% / 出 18%），由 SpeedStats 判定后填入：
    /// 纯阈值在边界附近会随每轮微小变动反复出现与消失。
    var notableDrift: Double? = nil

    /// 当下相对常态的偏离，百分比。基准缺失时为 nil。诊断输出用它，界面用 `notableDrift`。
    var drift: Double? {
        guard let rate, let baselineRate, baselineRate > 0 else { return nil }
        return (rate - baselineRate) / baselineRate * 100
    }

    /// 偏离是否够格显示。三个闸门：样本 ≥3、幅度过线、当下值不超过基准三倍。
    /// 幅度阈值分进出两档（迟滞），三倍上限挡掉样本构成突变
    /// （实测出现过 150 tok/s 对基准 79）。
    func driftPasses(shown: Bool) -> Double? {
        guard samples >= 3, let d = drift,
              let rate, let baselineRate, rate <= baselineRate * 3 else { return nil }
        return abs(d) >= (shown ? 18 : 25) ? d : nil
    }
}

/// 单个 Claude Code 会话（窗口）的速度估计。只有实测路径可得：
/// OTel span 自带 `session.id`，网关账本没有会话身份。
/// 状态栏据此按窗口取数，多窗口并行时互不串行。
struct SessionSpeedRow: Sendable {
    /// Claude Code 的会话 UUID，与 transcript 文件名一致。
    let session: String
    /// 会话内最近一次请求的模型短名。
    let model: String
    let samples: Int
    let ttft: Double?
    let rate: Double?
    let latestAt: Date
}

/// 速度结论。近期无请求时 `rows` 为空，属常态而非异常。
struct SpeedReport: Sendable {
    /// Mirasim 自己测的整轮首字节，只作量级对照。
    struct Measured: Sendable {
        let median: Double
        let count: Int
    }

    let rows: [SpeedRow]
    /// 按会话分行，供状态栏按窗口取数。近期无实测样本时为空。
    let sessions: [SessionSpeedRow]
    /// 每行最多取的最近请求数。
    let recentCount: Int
    /// 近期时间范围内通过筛选的请求数，含未成行的模型。
    let sampleTotal: Int
    /// 在途请求的开始时刻，旧的在前。来自诊断事件流，请求发出瞬间即可见。
    let inflightSince: [Date]
    let measuredTurnTTFB: Measured?
}

/// 引擎每轮刷新的产出。
struct QuotaReport: Sendable {
    let windows: [WindowReport]
    let capturedAt: Date
    let state: ChannelState
    let mode: String
    let host: String
    let relayStatus: String
    /// 本进程启动以来新解析的记录数，非账本总量。
    let newRecords: Int
    /// 账本中的分钟桶数量，反映保留期内的数据量。
    let bucketCount: Int
    /// 窗口内的出字速度与首 token 估计，账本无样本时为 nil。
    let speed: SpeedReport?
    /// 每额度点折算的美元，由「窗口内账本支出 ÷ 已用额度点」得出。
    let unitPriceUSD: Double?
    /// 兜底单价停用的原因（账本与点数不自洽），可用时为 nil。
    let unitPriceNotice: String?
    /// 账号状态提示（暂停 / 不计量 / 上游降级），正常时为 nil。
    let accountNotice: String?

    static func placeholder(_ state: ChannelState) -> QuotaReport {
        QuotaReport(windows: [], capturedAt: Date(), state: state, mode: "-", host: "-",
                    relayStatus: "-", newRecords: 0, bucketCount: 0, speed: nil,
                    unitPriceUSD: nil, unitPriceNotice: nil, accountNotice: nil)
    }
}
