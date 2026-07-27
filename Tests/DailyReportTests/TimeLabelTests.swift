import Testing
import Foundation
@testable import DailyReport

/// SettingsView.timeLabel(_ mins: Int) 单元测试。
/// R42-D：把分钟数（0...1439）格式化为 "HH:mm" 的纯函数，设置页提醒时间显示用。
/// 原为 private 实例方法零覆盖。改坏会让用户设的 18:30 显示成 06:05 等（除法/取模顺序错位）。
/// 抽成 static internal 后可直接覆盖边界
@Suite struct TimeLabelTests {

    @Test func zeroMinutesFormatsAsMidnight() {
        #expect(SettingsView.timeLabel(0) == "00:00")
    }

    @Test func lastMinuteOfDayFormatsAsLateEvening() {
        #expect(SettingsView.timeLabel(1439) == "23:59")
    }

    @Test func ninetyMinutesFormatsAsHalfPastOne() {
        #expect(SettingsView.timeLabel(90) == "01:30")
    }

    @Test func wholeHourFormatsWithoutTrailingMinutes() {
        #expect(SettingsView.timeLabel(600) == "10:00")
        #expect(SettingsView.timeLabel(60) == "01:00")
    }
}
