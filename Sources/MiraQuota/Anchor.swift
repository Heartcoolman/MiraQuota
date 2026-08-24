import Foundation

/// 窗口锚点。
///
/// 额度窗口是固定窗口：一旦知道任意一次的重置时刻，之后每个窗口的边界都可由
/// 「重置时刻 + 整数倍窗口长度」推出，无需再问 Mirasim。把最后一次实测的重置时刻
/// 落盘，即便 Mirasim 关闭，也能定出当前窗口的起点，配合本地账本给出可用的估算。
///
/// 推算值只反映本机支出。云端线路下额度由 relay 账号池共享，他人的占用在本机不可见，
/// 故推算出的百分比是下界，恢复实时后通常会跳高。
struct Anchor: Codable, Sendable {
    let label: String
    /// 最后一次实测的重置时刻。
    let resetAt: Double
    /// 窗口长度，秒。
    let duration: Double
    /// 该锚点的采集时刻。
    let capturedAt: Double
    /// 采集时的实测百分比，用于判断推算是否明显偏离。
    let usedPercent: Double

    /// 窗口边界尚未锁定。5h 窗口在零用量时段报的 resetAt 等于「采集时刻 + 窗口长度」，
    /// 随时钟逐次滚动，要到窗口内第一次请求才锁定为真实边界。这类取值不值得反复落盘，
    /// 离线推算时也只是下界。
    var isProvisional: Bool { resetAt - capturedAt >= duration - 30 }

    /// 把锚点滚动到覆盖 `now` 的那个窗口，返回其起止时刻。
    func window(at now: Date) -> (start: Date, end: Date)? {
        guard duration > 0 else { return nil }
        let t = now.timeIntervalSince1970
        var end = resetAt
        if end <= t {
            // 向前滚动整数个窗口。
            let steps = ((t - end) / duration).rounded(.down) + 1
            end += steps * duration
        } else if end - duration > t {
            // 锚点在未来太远（时钟回拨或数据异常），向后滚动。
            let steps = ((end - duration - t) / duration).rounded(.up)
            end -= steps * duration
        }
        return (Date(timeIntervalSince1970: end - duration), Date(timeIntervalSince1970: end))
    }
}

/// 最近一次成功采集的全部可复用信息。
struct LastKnown: Codable, Sendable {
    var anchors: [Anchor] = []
    var capturedAt: Double = 0
    var mode: String = "-"
    var host: String = "-"
    var relayStatus: String = "-"

    var capturedDate: Date { Date(timeIntervalSince1970: capturedAt) }
}

/// 锚点的落盘与读取。写入用原子替换，读取失败一律当作无锚点，不影响启动。
final class AnchorStore {
    private var cache: LastKnown
    private let lock = NSLock()

    init() {
        if let data = try? Data(contentsOf: Paths.anchorState),
           let v = try? JSONDecoder().decode(LastKnown.self, from: data) {
            cache = v
        } else {
            cache = LastKnown()
        }
    }

    var lastKnown: LastKnown {
        lock.lock(); defer { lock.unlock() }
        return cache
    }

    /// 实测快照到达时更新锚点。只在重置时刻真正变化时落盘，避免高频写。
    func update(from snapshot: RelaySnapshot) {
        let fresh: [Anchor] = snapshot.windows.compactMap { w in
            guard let d = w.duration else { return nil }
            return Anchor(label: w.label, resetAt: w.resetAt.timeIntervalSince1970,
                          duration: d, capturedAt: snapshot.capturedAt.timeIntervalSince1970,
                          usedPercent: w.usedPercent)
        }
        guard !fresh.isEmpty else { return }

        lock.lock()
        // 未锁定的取值不覆盖已有条目：零用量时段的 resetAt 随时钟滚动，
        // 让它经内存缓存与龄期刷新落盘，离线推算就会拿浮动边界起算。
        // 已有条目即最后一次锁定的边界；同标签只在新值锁定后才替换。
        let byLabel = Dictionary(cache.anchors.map { ($0.label, $0) }) { _, last in last }
        let merged: [Anchor] = fresh.map { a in
            if a.isProvisional, let kept = byLabel[a.label] { return kept }
            return a
        }
        let changed = cache.anchors.count != merged.count
            || zip(cache.anchors.sorted { $0.label < $1.label },
                   merged.sorted { $0.label < $1.label })
                .contains { $0.label != $1.label || $0.resetAt != $1.resetAt }
        cache = LastKnown(anchors: merged,
                          capturedAt: snapshot.capturedAt.timeIntervalSince1970,
                          mode: snapshot.mode, host: snapshot.host,
                          relayStatus: snapshot.relayStatus)
        let toWrite = cache
        lock.unlock()

        // 重置时刻未变时仍每 10 分钟刷一次龄期，便于重启后判断数据新鲜度。
        if changed || Date().timeIntervalSince1970 - lastWrite > 600 {
            persist(toWrite)
        }
    }

    private var lastWrite: Double = 0

    private func persist(_ v: LastKnown) {
        lastWrite = Date().timeIntervalSince1970
        Paths.ensureStateDir()
        guard let data = try? JSONEncoder().encode(v) else { return }
        try? data.write(to: Paths.anchorState, options: .atomic)
    }
}
