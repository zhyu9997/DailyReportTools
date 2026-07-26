import Foundation
import os

/// 轻量日志：落地到 `<appDir>/logs/app.log`（与 DailyReport.app 同级，方便整包携带/排查），
/// 同时镜像到 `os.Logger`（subsystem = com.zhyu.dailyreport，可在 Console.app 查看）。
///
/// 单文件超过 `maxBytes`（默认 1 MB）自动滚动为 `app.log.1/.2/...`，保留最近 `keepCount` 份。
/// 写入串行化（NSLock），防止跨线程并发 append 交叉损坏。
enum AppLogger {
    private static let subsystem = "com.zhyu.dailyreport"
    private static let osLogger = Logger(subsystem: subsystem, category: "app")
    private static let maxBytes: Int64 = 1 * 1024 * 1024
    private static let keepCount = 5

    /// 日志目录：app 同级 `logs/`（thread-safe lazy init，仅创建一次）
    private static let logDirectory: URL = {
        let fm = FileManager.default
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let dir = appDir.appendingPathComponent("logs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var logFileURL: URL {
        logDirectory.appendingPathComponent("app.log")
    }

    /// 跨线程写入互斥（os_unfair_lock 包装为类属性更顺手）
    private static let writeLock = NSLock()

    /// 时间戳格式化样式（R21-D：原版用 nonisolated(unsafe) ISO8601DateFormatter，
    /// invariant「仅 writeLock 内访问 timestamp()」靠口头约束易破。改为
    /// Date.ISO8601FormatStyle：值类型 + Sendable，编译期线程安全，无并发顾虑）
    private static let timestampStyle: Date.ISO8601FormatStyle = .iso8601
        .year().month().day()
        .time(includingFractionalSeconds: true)

    /// 一次性迁移：把旧位置 `db/logs/app.log*` 搬到新位置 `<appDir>/logs/`
    /// 新目录已存在 app.log / 旧目录不存在 / 旧目录为空时直接跳过
    static func migrateFromLegacyIfNeeded() {
        let fm = FileManager.default
        let oldDir = AppDatabase.rootDirectory.appendingPathComponent("logs", isDirectory: true)
        let newDir = logFileURL.deletingLastPathComponent()
        guard fm.fileExists(atPath: oldDir.path) else { return }
        guard let oldFiles = try? fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil) else { return }
        // 新目录已存在 app.log 视为已迁移
        if fm.fileExists(atPath: logFileURL.path) { return }
        for src in oldFiles where src.lastPathComponent.hasPrefix("app.log") {
            let dst = newDir.appendingPathComponent(src.lastPathComponent)
            if !fm.fileExists(atPath: dst.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }
        // 旧目录若已空则删掉，保持 db/ 整洁
        let remaining = (try? fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil)) ?? []
        if remaining.isEmpty {
            try? fm.removeItem(at: oldDir)
        }
    }

    static func error(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
        write(level: "ERROR", message: message, file: file, function: function, line: line)
        osLogger.error("\(message, privacy: .public)")
    }

    static func warn(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
        write(level: "WARN", message: message, file: file, function: function, line: line)
        osLogger.warning("\(message, privacy: .public)")
    }

    static func info(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
        write(level: "INFO", message: message, file: file, function: function, line: line)
        osLogger.info("\(message, privacy: .public)")
    }

    /// DEBUG 日志：开发期写文件 + os.Logger；release build 完全 no-op（message 用 @autoclosure，
    /// 不求值即不执行字符串拼接，零开销；release 排查用 info/warn/error 即可）
    static func debug(_ message: @autoclosure () -> String, file: String = #fileID, function: String = #function, line: Int = #line) {
        #if DEBUG
        let msg = message()
        write(level: "DEBUG", message: msg, file: file, function: function, line: line)
        osLogger.debug("\(msg, privacy: .public)")
        #else
        // release: no-op；@autoclosure 不求值
        #endif
    }

    // MARK: - Private

    private static func write(level: String, message: String, file: String, function: String, line: Int) {
        writeLock.lock()
        defer { writeLock.unlock() }

        let location = "\(file):\(line) \(function)"
        let line = "\(timestamp()) [\(level)] [\(location)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = logFileURL
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            rollIfNeeded(url: url, maxBytes: maxBytes, keepCount: keepCount)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 滚动检查：文件超过 maxBytes 时，把 app.log → app.log.1，依次后挪；最老的删除
    /// 参数化以便单测（生产路径用 static let 默认值；测试可传小的 maxBytes 立即触发滚动）
    nonisolated static func rollIfNeeded(url: URL, maxBytes: Int64, keepCount: Int) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64, size > maxBytes else { return }
        // 保留 app.log + app.log.1 .. app.log.(keepCount-1)，最老的直接删除
        let oldest = URL(fileURLWithPath: url.path + ".\(keepCount - 1)")
        try? fm.removeItem(at: oldest)
        for i in stride(from: keepCount - 2, through: 1, by: -1) {
            let cur = URL(fileURLWithPath: url.path + ".\(i)")
            let nxt = URL(fileURLWithPath: url.path + ".\(i + 1)")
            if fm.fileExists(atPath: cur.path) {
                try? fm.moveItem(at: cur, to: nxt)
            }
        }
        let first = URL(fileURLWithPath: url.path + ".1")
        try? fm.moveItem(at: url, to: first)
    }

    private static func timestamp() -> String {
        Date.now.formatted(timestampStyle)
    }
}
