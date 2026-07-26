import Testing
import Foundation
@testable import DailyReport

/// AppLogger.rollIfNeeded 文件滚动测试
/// 直接调 rollIfNeeded(url:maxBytes:keepCount:) 参数化入口，
/// 不触碰生产 logFileURL（避免污染真实日志目录）
@Suite struct AppLoggerTests {

    private static func makeTmpDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyReportLoggerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    // MARK: - 不滚动场景

    @Test func rollNoOpWhenUnderLimit() throws {
        let dir = Self.makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("app.log")
        try Self.write(Data(repeating: 0x41, count: 500), to: logURL)  // 500 bytes

        AppLogger.rollIfNeeded(url: logURL, maxBytes: 1024, keepCount: 3)

        // 文件不变，无 .1 副本
        #expect(Self.fileSize(logURL) == 500)
        #expect(!FileManager.default.fileExists(atPath: logURL.path + ".1"))
    }

    @Test func rollNoOpWhenFileMissing() throws {
        let dir = Self.makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("app.log")  // 不创建

        AppLogger.rollIfNeeded(url: logURL, maxBytes: 1, keepCount: 3)
        // 不应抛错；也不应误创建任何文件
        #expect(!FileManager.default.fileExists(atPath: logURL.path))
        #expect(!FileManager.default.fileExists(atPath: logURL.path + ".1"))
    }

    // MARK: - 滚动场景

    @Test func rollCreatesDot1AndClearsOriginal() throws {
        let dir = Self.makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("app.log")
        let payload = Data(repeating: 0x42, count: 2_000)  // > 1KB
        try Self.write(payload, to: logURL)

        AppLogger.rollIfNeeded(url: logURL, maxBytes: 1_024, keepCount: 3)

        // 原文件被 move 走 → 不再存在；.1 出现且内容 = 原 payload
        #expect(!FileManager.default.fileExists(atPath: logURL.path))
        let dot1 = URL(fileURLWithPath: logURL.path + ".1")
        #expect(FileManager.default.fileExists(atPath: dot1.path))
        #expect(Self.fileSize(dot1) == 2_000)
        let readBack = try Data(contentsOf: dot1)
        #expect(readBack == payload)
    }

    @Test func rollShiftsExistingBackups() throws {
        // keepCount=3 意味着总共保留 3 份：app.log + app.log.1 + app.log.2
        let dir = Self.makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("app.log")
        let dot1 = URL(fileURLWithPath: logURL.path + ".1")
        let dot2 = URL(fileURLWithPath: logURL.path + ".2")

        // 预置：app.log（大）+ app.log.1 + app.log.2（保留窗口已满）
        try Self.write(Data(repeating: 0x01, count: 2_000), to: logURL)
        try Self.write(Data(repeating: 0x11, count: 100), to: dot1)
        try Self.write(Data(repeating: 0x22, count: 100), to: dot2)

        AppLogger.rollIfNeeded(url: logURL, maxBytes: 1_024, keepCount: 3)

        // 删除 oldest=app.log.2（keepCount-1）；app.log.1 → app.log.2；app.log → app.log.1
        #expect(!FileManager.default.fileExists(atPath: logURL.path))
        #expect(Self.fileSize(dot1) == 2_000)                // 来自主文件
        let dot2Data = try Data(contentsOf: dot2)
        #expect(dot2Data.first == 0x11)                       // 来自旧 .1；旧 .2 的 0x22 应被丢弃
    }

    @Test func rollDropsOldestWhenAllSlotsFull() throws {
        // 同上语义：保留窗口已满 + 主文件超限 → 最老一份内容应被丢弃
        let dir = Self.makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("app.log")
        let dot1 = URL(fileURLWithPath: logURL.path + ".1")
        let dot2 = URL(fileURLWithPath: logURL.path + ".2")

        try Self.write(Data(repeating: 0xAA, count: 100), to: dot1)
        try Self.write(Data(repeating: 0xBB, count: 100), to: dot2)
        try Self.write(Data(repeating: 0xFF, count: 2_000), to: logURL)

        AppLogger.rollIfNeeded(url: logURL, maxBytes: 1_024, keepCount: 3)

        #expect(!FileManager.default.fileExists(atPath: logURL.path))
        #expect(Self.fileSize(dot1) == 2_000)                // 来自主文件
        let dot2Data = try Data(contentsOf: dot2)
        #expect(dot2Data.first == 0xAA)                       // 来自旧 .1；旧 .2 的 0xBB 应被丢弃
    }

    // MARK: - 边界：maxBytes = 0 / keepCount = 1

    @Test func rollTriggersImmediatelyWhenMaxBytesZero() throws {
        let dir = Self.makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("app.log")
        try Self.write(Data(repeating: 0x01, count: 1), to: logURL)  // 1 byte 即触发

        AppLogger.rollIfNeeded(url: logURL, maxBytes: 0, keepCount: 3)

        #expect(!FileManager.default.fileExists(atPath: logURL.path))
        #expect(FileManager.default.fileExists(atPath: logURL.path + ".1"))
    }

    @Test func rollWithKeepCount1DirectlyRemovesOriginal() throws {
        // keepCount=1：只有 app.log，没有 .1/.2...；超限时应直接删掉原文件（无归档可挪）
        let dir = Self.makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("app.log")
        try Self.write(Data(repeating: 0x01, count: 2_000), to: logURL)

        AppLogger.rollIfNeeded(url: logURL, maxBytes: 1_024, keepCount: 1)

        // 现状：stride(from: -1, through: 1, by: -1) 是空区间；先删 .0（实际为 .0 不存在），
        // 然后第一份 .1 也算不存在，主文件直接 move 到 .1；
        // 但 keepCount=1 意味着 .1 是最老，先被删 → 主文件 move 到 .1
        // 所以最终：原文件不存在，.1 存在，内容 = 原内容
        #expect(!FileManager.default.fileExists(atPath: logURL.path))
        let dot1 = URL(fileURLWithPath: logURL.path + ".1")
        #expect(FileManager.default.fileExists(atPath: dot1.path))
        #expect(Self.fileSize(dot1) == 2_000)
    }
}
