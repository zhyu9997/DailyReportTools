import Foundation
import os

/// 轻量日志：落地到 `~/Library/Application Support/com.zhyu.dailyreport/logs/app.log`，
/// 同时镜像到 `os.Logger`（subsystem = com.zhyu.dailyreport，可在 Console.app 查看）。
///
/// 单文件超过 `maxBytes`（默认 1 MB）自动滚动为 `app.log.1/.2/...`，保留最近 `keepCount` 份。
enum AppLogger {
    private static let subsystem = "com.zhyu.dailyreport"
    private static let osLogger = Logger(subsystem: subsystem, category: "app")
    private static let maxBytes: Int64 = 1 * 1024 * 1024
    private static let keepCount = 5

    static var logFileURL: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent(subsystem, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }

    static func error(_ message: String) {
        write(level: "ERROR", message: message)
        osLogger.error("\(message, privacy: .public)")
    }

    static func info(_ message: String) {
        write(level: "INFO", message: message)
        osLogger.info("\(message, privacy: .public)")
    }

    // MARK: - Private

    private static func write(level: String, message: String) {
        let line = "\(timestamp()) [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = logFileURL
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            rollIfNeeded(url: url)
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

    private static func rollIfNeeded(url: URL) {
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
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
