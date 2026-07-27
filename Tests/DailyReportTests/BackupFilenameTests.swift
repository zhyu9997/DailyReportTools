import Testing
import Foundation
@testable import DailyReport

/// BackupService.backupFilename(prefix:stamp:suffix:) 单元测试。
/// R47-B：备份文件名拼接的纯函数核心（<prefix>-<stamp>[-suffix].json 两/三段式）。
/// 原内联在 writeBackup 零覆盖，抽 static 后可钉死格式契约。
/// 改坏会让 enumerateBackups 的 hasPrefix 匹配失效，weekly 去重/月清理全部静默失效
@MainActor
@Suite struct BackupFilenameTests {

    // MARK: - 两段式（无 suffix，boot/manual/salvage 路径）

    @Test func noSuffixProducesTwoSegmentName() {
        // boot-2024-06-15T12-30-00.json（不含第三段 suffix）
        let name = BackupService.backupFilename(prefix: "boot", stamp: "2024-06-15T12-30-00", suffix: nil)
        #expect(name == "boot-2024-06-15T12-30-00.json")
    }

    @Test func manualPrefixWithoutSuffix() {
        let name = BackupService.backupFilename(prefix: "manual", stamp: "2024-01-01T00-00-00", suffix: nil)
        #expect(name == "manual-2024-01-01T00-00-00.json")
    }

    // MARK: - 三段式（有 suffix，weekly 含 weekKey 路径）

    @Test func suffixProducesThreeSegmentName() {
        // weekly-2024-06-15T12-30-00-2024-W24.json（含 weekKey 作 suffix）
        let name = BackupService.backupFilename(prefix: "weekly",
                                                  stamp: "2024-06-15T12-30-00",
                                                  suffix: "2024-W24")
        #expect(name == "weekly-2024-06-15T12-30-00-2024-W24.json")
    }

    // MARK: - 格式契约

    @Test func alwaysEndsWithJsonExtension() {
        // 必须以 .json 结尾（不能省略，否则 NSFileEnumerator 匹配失效）
        let a = BackupService.backupFilename(prefix: "boot", stamp: "x", suffix: nil)
        let b = BackupService.backupFilename(prefix: "weekly", stamp: "x", suffix: "y")
        #expect(a.hasSuffix(".json"))
        #expect(b.hasSuffix(".json"))
    }

    @Test func usesHyphenAsSeparatorBetweenSegments() {
        // 段间用「-」分隔（不能用「_」或「.」，会破坏 enumerateBackups 的 dropLast 解析）
        let name = BackupService.backupFilename(prefix: "weekly", stamp: "2024-06-15", suffix: "2024-W24")
        // 三段被「-」连接，最后跟 .json
        #expect(name == "weekly-2024-06-15-2024-W24.json")
        #expect(!name.contains("_"))
    }

    @Test func emptyStringSuffixStillProducesThreeSegment() {
        // suffix 为空字符串（不是 nil）→ 仍走三段式路径（末尾多一个「-」）
        // 这是边界场景：调用方应保证 suffix 非空，但函数本身不能 crash
        let name = BackupService.backupFilename(prefix: "weekly", stamp: "x", suffix: "")
        #expect(name == "weekly-x-.json")
    }
}
