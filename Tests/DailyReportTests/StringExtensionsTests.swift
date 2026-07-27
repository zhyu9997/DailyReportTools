import Testing
import Foundation
@testable import DailyReport

/// String.isBlank / String.trimmed 单元测试。
/// R34-C：这两个 helper 在 25+ 处写入路径作「字段有效性」判定与清洗（commit guard / toRecord 清洗），
/// 是核心卡口却零测试覆盖。原版注释明确提到「一半用 .whitespaces 一半用 .whitespacesAndNewlines」
/// 的历史不一致，需用测试钉死「统一 .whitespacesAndNewlines（多拒换行）」语义防回退。
@Suite struct StringExtensionsTests {
    // MARK: - isBlank
    @Test func isBlankTrueForEmptyString() {
        #expect("".isBlank)
    }

    @Test func isBlankTrueForPureSpaces() {
        #expect("   ".isBlank)
        #expect("\t".isBlank)
    }

    @Test func isBlankTrueForNewlinesAndMixedWhitespace() {
        // 与原版 .whitespaces 的关键差异：换行也算空白
        #expect("\n".isBlank)
        #expect("\r\n\t  \n".isBlank)
    }

    @Test func isBlankFalseForContentWithSurroundingWhitespace() {
        #expect(!"  x  ".isBlank)
        #expect(!"a".isBlank)
    }

    // MARK: - trimmed
    @Test func trimmedStripsBothEnds() {
        #expect("  hello  ".trimmed == "hello")
    }

    @Test func trimmedStripsNewlinesAndTabs() {
        // 与原版 .whitespaces 的关键差异：换行也清掉
        #expect("\n\t  hi \r\n".trimmed == "hi")
    }

    @Test func trimmedPreservesInnerWhitespace() {
        #expect("  foo bar  ".trimmed == "foo bar")
    }

    @Test func trimmedEmptyStaysEmpty() {
        #expect("   ".trimmed == "")
        #expect("".trimmed == "")
    }
}
