import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var claudeProjects: URL { home.appending(path: ".claude/projects") }
    static var mirasimInsights: URL { home.appending(path: ".mirasim/insights") }
    static var mirasimAnalytics: URL { home.appending(path: ".mirasim/analytics") }
    static var mirasimDiag: URL { home.appending(path: ".mirasim/diag") }
    static var modelsCache: URL { home.appending(path: ".mirasim/models-dev-cache.json") }
    static var mirasimSetting: URL { home.appending(path: ".mirasim/setting.json") }

    static var stateDir: URL { home.appending(path: ".miraquota") }
    static var ledgerState: URL { stateDir.appending(path: "ledger.json") }
    static var calibState: URL { stateDir.appending(path: "calibration.json") }
    static var calibLock: URL { stateDir.appending(path: "calibration.lock") }
    static var anchorState: URL { stateDir.appending(path: "anchor.json") }
    static var feedToken: URL { stateDir.appending(path: "feed.token") }
    static var config: URL { stateDir.appending(path: "config.json") }

    static func ensureStateDir() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }
}

/// 单实例锁。登录自启与手动打开会同时存在两份，菜单栏出现两个图标。
/// 文件锁随进程退出自动释放，崩溃后不会残留。
enum InstanceLock {
    private static var fd: Int32 = -1

    /// launchd 重启本进程时，旧实例可能还在退出途中占着锁。
    /// 立即放弃会导致一个实例都不剩（退出码 0 不触发 KeepAlive 重启），故重试数秒。
    static func acquire(retries: Int = 10, interval: TimeInterval = 0.3) -> Bool {
        Paths.ensureStateDir()
        fd = open(Paths.stateDir.appending(path: "instance.lock").path, O_CREAT | O_RDWR, 0o644)
        // 锁文件建不出来时不阻断启动：功能可用比互斥更重要。
        guard fd >= 0 else { return true }
        for attempt in 0...retries {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
            if attempt < retries { Thread.sleep(forTimeInterval: interval) }
        }
        return false
    }
}

/// ISO-8601（UTC）前 19 字符转 unix 秒。热路径上避免 DateFormatter。
@inline(__always)
func fastEpochSeconds<S: StringProtocol>(_ s: S) -> Int? {
    let u = Array(s.utf8)
    guard u.count >= 19 else { return nil }
    @inline(__always) func d(_ i: Int) -> Int { Int(u[i]) &- 48 }
    let y = d(0) * 1000 + d(1) * 100 + d(2) * 10 + d(3)
    let mo = d(5) * 10 + d(6)
    let da = d(8) * 10 + d(9)
    let h = d(11) * 10 + d(12)
    let mi = d(14) * 10 + d(15)
    let se = d(17) * 10 + d(18)
    guard y > 1970, y < 3000, mo >= 1, mo <= 12, da >= 1, da <= 31,
          h < 24, mi < 60, se < 62 else { return nil }
    return daysFromCivil(y, mo, da) * 86400 + h * 3600 + mi * 60 + se
}

/// Howard Hinnant 的 days_from_civil。
func daysFromCivil(_ year: Int, _ m: Int, _ d: Int) -> Int {
    let y = year - (m <= 2 ? 1 : 0)
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

/// 诊断输出，由 MIRAQUOTA_DEBUG=1 打开。
enum Diag {
    static let enabled = ProcessInfo.processInfo.environment["MIRAQUOTA_DEBUG"] == "1"
    /// 强制离线，用于在 Mirasim 正常运行时验证降级路径是否可用。
    static let forceOffline = ProcessInfo.processInfo.environment["MIRAQUOTA_OFFLINE"] == "1"
    /// 屏蔽 /v1/limits，用于验证退回 relay 帧那一级是否可用。
    static let noLimits = ProcessInfo.processInfo.environment["MIRAQUOTA_NO_LIMITS"] == "1"
    /// 覆盖速度统计的窗口长度（秒），用于验证样本不足时的退化分支。
    static let speedSpan: TimeInterval? = {
        guard let raw = ProcessInfo.processInfo.environment["MIRAQUOTA_SPEED_SPAN"],
              let seconds = Double(raw), seconds > 0 else { return nil }
        return seconds
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data(("[diag] " + message() + "\n").utf8))
    }
}
