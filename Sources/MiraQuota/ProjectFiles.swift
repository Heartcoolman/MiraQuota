import Foundation

/// `~/.claude/projects` 下会话文件的枚举缓存。
///
/// 该目录在本机有 51 个会话目录、2038 个 `.jsonl`。逐轮全量取属性是常驻开销的主要来源：
/// 心跳 5 秒一轮，账本与速度各扫一遍，合计约 4000 次属性读取。这里按两级判新收敛：
///
/// - 目录 mtime 在新增文件时变化（已有文件增长不会），据此发现新会话；
/// - 近期活跃过的文件单独重取属性，据此发现增长；
/// - 全量枚举退为 5 分钟一次的兜底，兼作首轮的全量建账。
///
/// 消费者按 `changed` 增量取用，未变化的文件不再重复打开。字节游标本就落在各消费者自己
/// 手里（账本在 `ledger.json`、速度在内存），跳过未变化的文件与逐轮重读等价。
final class ProjectFiles {
    struct Entry {
        let url: URL
        let size: Int
        let mtime: Date
    }

    /// 全量兜底间隔。目录 mtime 与活跃集覆盖不到的情形（如系统时钟回拨、
    /// 目录 mtime 未随写入更新）由它兜住。
    private static let fullSweep: TimeInterval = 300
    /// 活跃期：这段时间内写过的文件每轮重取属性。
    private static let hotSpan: TimeInterval = 900

    private var known: [String: Entry] = [:]
    private var dirSeen: [String: Date?] = [:]
    private var lastFull = Date.distantPast
    private var lastRefresh = Date.distantPast

    /// 上一次 `refresh` 发现的变化。同一轮里账本与速度都读它，故不做消费即清。
    private(set) var changed: [Entry] = []

    /// 每轮调用一次。1 秒内的重复调用复用上次结果，让多个消费者各自调用而不重复扫描。
    func refresh(now: Date = Date()) {
        guard now.timeIntervalSince(lastRefresh) >= 1 else { return }
        lastRefresh = now
        if now.timeIntervalSince(lastFull) >= Self.fullSweep {
            full(now: now)
        } else {
            incremental(now: now)
        }
    }

    /// 按 mtime 倒序的活跃文件。冷清时保底给 4 个，与并行会话数无关。
    func recent(limit: Int, activeSince: Date) -> [Entry] {
        let sorted = known.values.sorted { $0.mtime > $1.mtime }
        let active = Array(sorted.prefix(while: { $0.mtime > activeSince }).prefix(limit))
        return active.count >= 4 ? active : Array(sorted.prefix(4))
    }

    // MARK: 扫描

    private func full(now: Date) {
        lastFull = now
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.claudeProjects,
                                                    includingPropertiesForKeys: [.contentModificationDateKey])
        else { changed = []; return }
        var fresh: [String: Entry] = [:]
        var diff: [String: Entry] = [:]
        for dir in dirs {
            dirSeen[dir.path] = mtime(of: dir)
            guard let items = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for file in items where file.pathExtension == "jsonl" {
                guard let e = entry(file) else { continue }
                fresh[file.path] = e
                if known[file.path]?.mtime != e.mtime { diff[file.path] = e }
            }
        }
        known = fresh
        changed = Array(diff.values)
    }

    private func incremental(now: Date) {
        let fm = FileManager.default
        var diff: [String: Entry] = [:]
        if let dirs = try? fm.contentsOfDirectory(at: Paths.claudeProjects,
                                                 includingPropertiesForKeys: [.contentModificationDateKey]) {
            for dir in dirs {
                let m = mtime(of: dir)
                // 首次见到的目录（dirSeen 无键）也要展开，否则新会话目录等到全量才被发现。
                if let seen = dirSeen[dir.path], seen == m { continue }
                dirSeen[dir.path] = m
                guard let items = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
                for file in items where file.pathExtension == "jsonl" {
                    guard let e = entry(file) else { continue }
                    if known[file.path]?.mtime != e.mtime { diff[file.path] = e }
                    known[file.path] = e
                }
            }
        }
        // 已有文件增长不会顶起目录 mtime，故活跃集单独重取属性。
        let hot = now.addingTimeInterval(-Self.hotSpan)
        for (path, old) in known where old.mtime >= hot {
            // 目录枚举预取过属性并缓存在 URL 上，重取必须换一个新 URL 才拿得到新值。
            guard let e = entry(URL(fileURLWithPath: path)) else { known[path] = nil; continue }
            if e.mtime != old.mtime { diff[path] = e }
            known[path] = e
        }
        changed = Array(diff.values)
    }

    private func entry(_ url: URL) -> Entry? {
        guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let m = v.contentModificationDate, let size = v.fileSize else { return nil }
        return Entry(url: url, size: size, mtime: m)
    }

    private func mtime(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
