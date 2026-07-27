import Testing
import Foundation
@testable import DailyReport

/// R32-D：IntArrayJSON 是 WorkEntryRecord / MeetingRecord 的 recurrenceWeekdays / recurrenceMonthDays
/// 持久化通道，每次插入/更新都走。R23-G 加了 encode/decode 失败兜底（返 "[]" / []）+ error log，
/// 但失败路径无测试钉死。手改（如换 JSONEncoder 配置、改 storage 列类型）时容易引入静默丢数据回归。
/// helper 都是 enum 静态方法，直接调用无需 fixture
@Suite struct IntArrayJSONTests {

    @Test func encodeDecodeRoundTripPreservesValues() {
        let original = [1, 2, 3, 7, 15, 31]
        let encoded = IntArrayJSON.encode(original)
        let decoded = IntArrayJSON.decode(encoded)
        #expect(decoded == original)
    }

    @Test func encodeEmptyArray() {
        // 空数组是合法且常见的「无周期」表达，必须能正确往返
        let encoded = IntArrayJSON.encode([])
        let decoded = IntArrayJSON.decode(encoded)
        #expect(encoded == "[]")
        #expect(decoded == [])
    }

    @Test func decodeNilReturnsEmpty() {
        // DB 列允许 NULL（旧数据 / 未填字段）；nil 必须兜底为 []，不 crash
        #expect(IntArrayJSON.decode(nil) == [])
    }

    @Test func decodeMalformedJSONReturnsEmpty() {
        // 坏 JSON（外部编辑、转码错误、版本兼容）必须兜底为 []，不抛错破坏读取流程
        #expect(IntArrayJSON.decode("not json") == [])
        #expect(IntArrayJSON.decode("[1, 2,") == [])   // 截断
        #expect(IntArrayJSON.decode("[\"a\"]") == [])  // 类型错
    }
}
