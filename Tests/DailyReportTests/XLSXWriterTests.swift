import Testing
import Foundation
@testable import DailyReport

/// XLSXWriter.escape / columnLetter / ZipBuilder.crc32 三个纯函数的覆盖测试。
/// 这些函数原先全 private，输出 XLSX 一旦被 Excel/Numbers 报错很难定位；
/// 现抽为 static internal，专门为它们加单测（XML 转义、列号映射、CRC 校验和）。
@Suite struct XLSXWriterTests {

    // MARK: - escape（XML 1.0 实体转义 + 控制字符过滤）

    @Test func escapeAmpersand() {
        #expect(XLSXWriter.escape("a&b") == "a&amp;b")
    }

    @Test func escapeLessThan() {
        #expect(XLSXWriter.escape("a<b") == "a&lt;b")
    }

    @Test func escapeGreaterThan() {
        #expect(XLSXWriter.escape("a>b") == "a&gt;b")
    }

    @Test func escapeDoubleQuote() {
        #expect(XLSXWriter.escape(#"a"b"#) == "a&quot;b")
    }

    @Test func escapeAllEntitiesCombined() {
        let input = #"<a href="x">Tom & Jerry</a>"#
        let expected = #"&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry&lt;/a&gt;"#
        #expect(XLSXWriter.escape(input) == expected)
    }

    @Test func escapeEmptyString() {
        #expect(XLSXWriter.escape("") == "")
    }

    @Test func escapePreservesTabNewlineCR() {
        // XML 1.0 允许的三个控制字符必须保留
        #expect(XLSXWriter.escape("a\tb\nc\rd") == "a\tb\nc\rd")
    }

    @Test func escapeFiltersIllegalControlChars() {
        // 0x00 NUL / 0x01 / 0x0B vertical tab / 0x0C form feed / 0x1F unit separator
        // 都应被剔除，不影响其他字符
        let input = "a\u{00}b\u{01}c\u{0B}d\u{0C}e\u{1F}f"
        #expect(XLSXWriter.escape(input) == "abcdef")
    }

    @Test func escapePreservesUnicode() {
        // 中文 + emoji 不在 XML 1.0 非法范围（>= 0x20），应原样保留
        let input = "日报 🚀 日本語"
        #expect(XLSXWriter.escape(input) == input)
    }

    @Test func escapeDoesNotTouchSingleQuote() {
        // ' 不是 XML 1.0 预定义实体，escape 不应改它
        #expect(XLSXWriter.escape("it's") == "it's")
    }

    // MARK: - columnLetter（1 索引 → Excel 列字母）

    @Test func columnLetterSingleDigits() {
        #expect(XLSXWriter.columnLetter(1) == "A")
        #expect(XLSXWriter.columnLetter(2) == "B")
        #expect(XLSXWriter.columnLetter(25) == "Y")
        #expect(XLSXWriter.columnLetter(26) == "Z")
    }

    @Test func columnLetterDoubleDigits() {
        #expect(XLSXWriter.columnLetter(27) == "AA")
        #expect(XLSXWriter.columnLetter(28) == "AB")
        #expect(XLSXWriter.columnLetter(52) == "AZ")
        #expect(XLSXWriter.columnLetter(53) == "BA")
        #expect(XLSXWriter.columnLetter(78) == "BZ")
        #expect(XLSXWriter.columnLetter(79) == "CA")
    }

    @Test func columnLetterTripleDigits() {
        // 26 + 26*26 = 702 是 ZZ；703 起进入三位 AAA
        #expect(XLSXWriter.columnLetter(702) == "ZZ")
        #expect(XLSXWriter.columnLetter(703) == "AAA")
        #expect(XLSXWriter.columnLetter(728) == "AAZ")   // 703 + 25
        #expect(XLSXWriter.columnLetter(729) == "ABA")   // 703 + 26，第二位进位
        #expect(XLSXWriter.columnLetter(730) == "ABB")
    }

    @Test func columnLetterRejectsZeroOrNegative() {
        // 实现不校验入参，0 / 负数返回空串（while 循环根本不进）
        #expect(XLSXWriter.columnLetter(0) == "")
        #expect(XLSXWriter.columnLetter(-1) == "")
    }

    // MARK: - crc32（IEEE 802.3，与 zlib/PNG 一致）

    @Test func crc32EmptyData() {
        // 空输入：0xFFFFFFFF ^ 0xFFFFFFFF = 0
        #expect(ZipBuilder.crc32(Data()) == 0)
    }

    @Test func crc32CanonicalVector() {
        // 经典测试向量 "123456789" → 0xCBF43926（zlib / PNG / zip 文档通用）
        let data = Data("123456789".utf8)
        #expect(ZipBuilder.crc32(data) == 0xCBF43926)
    }

    @Test func crc32Deterministic() {
        // 相同输入两次调用必须相同
        let data = Data("Hello, World!".utf8)
        let a = ZipBuilder.crc32(data)
        let b = ZipBuilder.crc32(data)
        #expect(a == b)
        #expect(a != 0)
    }

    @Test func crc32DetectsSingleBitFlip() {
        // 任意 1 bit 翻转后 CRC 必不相同（CRC32 的核心保证）
        let original = Data([0x01, 0x02, 0x03, 0x04])
        let flipped = Data([0x01, 0x02, 0x03, 0x05])
        #expect(ZipBuilder.crc32(original) != ZipBuilder.crc32(flipped))
    }

    @Test func crc32OrderMatters() {
        // 同字节不同顺序 → 不同 CRC（CRC 对顺序敏感）
        let a = Data([1, 2, 3])
        let b = Data([3, 2, 1])
        #expect(ZipBuilder.crc32(a) != ZipBuilder.crc32(b))
    }
}
