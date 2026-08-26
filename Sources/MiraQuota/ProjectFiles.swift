import Foundation

/// `~/.claude/projects` 下会话文件的枚举缓存。
///
/// 目录树不止一层：主会话落在 `<项目>/*.jsonl`，子代理与工作流落在
/// `<项目>/subagents/**/*.jsonl`。本机 2523 个 `.jsonl` 里只有 330 个在第一层，
/// 只列一层会把子代理的调用整体漏出账本。
///
/// 逐轮全量取属性是常驻开销的主要来源：心跳 5 秒一轮，账本与速度各扫一遍。
/// 这里按两级判新收敛：
///
/// - 目录 mtime 在增删条目时变化（已有文件增长不会），据此发现新会话与新子目录；
/// - 近期活跃过的文件单独重取属性，据此发现增长；
/// - 全量递归枚举退为 5 分钟一次的兜底，兼作首轮的全量建账。
///
/// 消费者按 `changed` 增量取用，未变化的文件不再重复打开。字节游标本就落在各消费者自己
/// 手里（账本在 `ledger.json`、速度在内存），跳过未变化的文件与逐轮重读等价。
final class ProjectFiles {
    struct Entry {
        let url: URL
        let size: Int
        let mtime: Date
        /// 位于 `<项目>` 下更深一层，即子代理或工作流的会话。
        let nested: Bool
    }

    /// 全量兜底间隔。目录 mtime 与活跃集覆盖不到的情形（如系统时钟回拨、
    /// 目录 mtime 未随写入更新）由它兜住。
    private static let fullSweep: TimeInterval = 300
    /// 活跃期：这段时间内写过的文件每轮重取属性。
    private static let hotSpan: TimeInterval = 900

    private var known: [String: Entry] = [:]
    /// 已展开过的目录（含各层子目录）→ 上次见到的 mtime。缺键即未展开过。
    private var dirSeen: [String: Date] = [:]
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

    /// 按 mtime 倒序的活跃文件，只含主会话。子代理并发跑几十个请求，
    /// 掺进来会把「生成中几条」与 tok/s 的口径搅成前后台混合，速度卡要的是前台观感。
    func recent(limit: Int, activeSince: Date) -> [Entry] {
        let sorted = known.values.filter { !$0.nested }.sorted { $0.mtime > $1.mtime }
        let active = Array(sorted.prefix(while: { $0.mtime > activeSince }).prefix(limit))
        return active.count >= 4 ? active : Array(sorted.prefix(4))
    }

    // MARK: 扫描

    private func full(now: Date) {
        lastFull = now
        var fresh: [String: Entry] = [:]
        var diff: [String: Entry] = [:]
        dirSeen = [:]
        walk(Paths.claudeProjects, depth: 0, into: &fresh, diff: &diff)
        // 一个文件都没枚举到时视为读取失败，保留旧缓存，避免把整棵树当成新增重扫一遍。
        if fresh.isEmpty && !known.isEmpty { changed = []; return }
        known = fresh
        changed = Array(diff.values)
    }

    /// 递归收集 `.jsonl`，同时登记每层目录的 mtime 供增量轮使用。
    private func walk(_ dir: URL, depth: Int, into fresh: inout [String: Entry],
                      diff: inout [String: Entry]) {
        let m = mtime(of: dir)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
        else { return }
        if let m { dirSeen[dir.path] = m }
        for item in items {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                walk(item, depth: depth + 1, into: &fresh, diff: &diff)
            } else if item.pathExtension == "jsonl" {
                guard let e = entry(item, nested: depth > 1) else { continue }
                fresh[item.path] = e
                if known[item.path]?.mtime != e.mtime { diff[item.path] = e }
            }
        }
    }

    private func incremental(now: Date) {
        var diff: [String: Entry] = [:]
        // 根目录也在 dirSeen 里，新项目目录由它的 mtime 变化带出。
        for (path, seen) in dirSeen {
            let dir = URL(fileURLWithPath: path)
            guard let m = mtime(of: dir) else { dirSeen[path] = nil; continue }
            if seen == m { continue }
            expand(dir, into: &diff)
        }
        // 已有文件增长不会顶起目录 mtime，故活跃集单独重取属性。
        let hot = now.addingTimeInterval(-Self.hotSpan)
        for (path, old) in known where old.mtime >= hot {
            // 目录枚举预取过属性并缓存在 URL 上，重取必须换一个新 URL 才拿得到新值。
            guard let e = entry(URL(fileURLWithPath: path), nested: old.nested) else { known[path] = nil; continue }
            if e.mtime != old.mtime { diff[path] = e }
            known[path] = e
        }
        changed = Array(diff.values)
    }

    /// 展开一层：新出现的 `.jsonl` 入账，新子目录顺带展开，
    /// 否则一次工作流新建的目录要等到全量兜底才被发现。
    private func expand(_ dir: URL, into diff: inout [String: Entry]) {
        let m = mtime(of: dir)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
        else { return }
        if let m { dirSeen[dir.path] = m }
        // 与 walk 同一口径：`<项目>` 本身深度为 1，其直属文件算主会话。
        let depth = dir.pathComponents.count - Paths.claudeProjects.pathComponents.count
        for item in items {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if dirSeen[item.path] == nil { expand(item, into: &diff) }
            } else if item.pathExtension == "jsonl" {
                guard let e = entry(item, nested: depth > 1) else { continue }
                if known[item.path]?.mtime != e.mtime { diff[item.path] = e }
                known[item.path] = e
            }
        }
    }

    private func entry(_ url: URL, nested: Bool) -> Entry? {
        guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let m = v.contentModificationDate, let size = v.fileSize else { return nil }
        return Entry(url: url, size: size, mtime: m, nested: nested)
    }

    private func mtime(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
