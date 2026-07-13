# DailyReport 详细设计方案

## 1. 概述

**DailyReport** 是一款 macOS 菜单栏日报助手，帮助个人快速记录每日工作、跟踪计划、汇总周报。

- **定位**：常驻菜单栏的轻量个人日报工具，`LSUIElement=true`，不占 Dock
- **目标用户**：需要每日记录工作内容、复盘计划、生成周报的个人开发者/知识工作者
- **核心价值**：随手记（菜单栏）+ 全局看（主窗口）+ 自动汇总（周期推进 + 周报导出）

## 2. 整体架构

App 由三个 SwiftUI Scene 组成，共享同一 `ModelContainer`：

```
@main DailyReportApp
├── MenuBarExtra          ← 菜单栏图标 + 弹出面板（MenuPanelView）
├── Window("main-window") ← 主窗口（MainTabView：概要/时间线/待办/会议/周报）
└── Settings              ← 设置窗（SettingsView）
```

启动流程：
1. 创建 `ModelContainer`（schema 不兼容则 wipe + 备份）
2. `RecurrenceService.sweepMeetings/sweepWorkEntries` 推进过期周期项
3. 注册 `NSCalendarDayChanged` 监听，跨日时再次 sweep + 周报回本周

三个 Scene 根视图统一挂 `.preferredColorScheme(colorScheme)`，由 `@AppStorage(appearance)` 驱动。

## 3. 技术栈

| 层 | 技术 |
|---|---|
| 语言 | Swift 6（严格并发） |
| UI | SwiftUI（macOS 14+） |
| 持久化 | SwiftData `@Model`，默认 store，轻量迁移 |
| 通知 | UserNotifications（每日提醒） |
| 开机自启 | ServiceManagement `SMAppService.mainApp` |
| 构建 | SwiftPM + `scripts/build-app.sh` 打包（ad-hoc 签名） |
| 第三方依赖 | 无 |

## 4. 模块划分

```
Sources/DailyReport/
├── DailyReportApp.swift        # @main，三 Scene + 启动 sweep + 跨日监听
├── AppState.swift              # 常量、UserDefaults Key、AppearanceMode
├── NavigationCoordinator.swift # 主窗口 Tab 选中态
├── Models/                     # SwiftData 模型
│   ├── DailyReport.swift       # 一天的元数据（备注/标签）
│   ├── WorkEntry.swift         # 工作任务（核心实体）+ WorkKind/BlockerStatus/Priority/RecurrenceUnit
│   ├── Meeting.swift           # 会议 + Review（嵌入评审）
│   ├── Review.swift            # 单条评审意见
│   ├── Tag.swift               # 多对多标签（贯穿日报/任务/会议/待办）
│   ├── TodoItem.swift          # 独立待办
│   └── Recurrence.swift        # 周期计算纯函数
├── Views/
│   ├── MainTabView.swift       # 5 Tab
│   ├── TodayView.swift         # 概要（统计条 + 今日记录 + 计划列表 + 会议）
│   ├── HistoryView.swift       # 时间线三列看板 + 搜索 + 拖拽
│   ├── TodoListView.swift      # 待办 + 计划任务统一操作
│   ├── MeetingView.swift       # 会议纪要 + 评审
│   ├── WeeklyReportView.swift  # 周报（归属日分天 + XLSX 导出）
│   ├── MenuPanelView.swift     # 菜单栏弹出面板
│   └── SettingsView.swift      # 设置
├── Components/                 # 复用组件
│   ├── WorkSummaryView.swift   # 任务卡片 + 编辑器（含 WorkEntryCard）
│   ├── TagPicker.swift         # 标签选择（compact / full）
│   ├── KindPicker.swift        # 完成/计划/问题 彩色胶囊切换
│   ├── RecurrenceEditor.swift  # 周期编辑
│   ├── FlowLayout.swift        # 标签流式布局
│   ├── EmptyStateView.swift
│   └── SharedExtensions.swift  # Date / Color / Calendar 扩展
└── Services/
    ├── RecurrenceService.swift # 周期推进 + 统一完成路径 markDone
    ├── BackupService.swift     # JSON 快照 / 导入导出 / 自动备份
    ├── ExportService.swift     # 周报 XLSX / Markdown
    ├── XLSXWriter.swift        # 零依赖 XLSX 写入 + ZipBuilder
    └── ReminderService.swift   # 本地通知
```

## 5. 数据模型

### 5.1 实体关系

```
DailyReport 1───* Tag *───* WorkEntry
                           *───* Meeting 1───* Review
                           *───* TodoItem
```

- **Tag** 通过 4 条 `@Relationship(inverse:)` 与 DailyReport / WorkEntry / Meeting / TodoItem 建立多对多
- **Meeting → Review** 为一对多（`deleteRule: .cascade`，会议删除连带评审）
- **DailyReport** 仅存当天元数据（备注、标签），任务汇总由 `WorkEntry` 按"归属日"动态聚合，不冗余存储

### 5.2 核心实体字段

**WorkEntry**（任务，最核心）
- `id / title / detail / timestamp / createdAt`
- `kind`（done/planned/blocker）、`finishDate`（完成或计划完成日）
- `blockerStatus`、`helper`（问题类专用）
- `priority`（high/medium/low，计划专用）
- `isRecurring / recurrenceUnit / recurrenceInterval / recurrenceWeekdays / recurrenceMonthDays`
- 派生：`isOverdue`（planned 且 finishDate 早于今天）、`recurrenceLabel`

**Meeting**（会议）
- `id / topic / summary / timestamp`
- `reviews: [Review]`、`tags: [Tag]`
- 周期字段同 WorkEntry
- `nextFutureOccurrence(from:)`：从指定时间算下一次

**Tag**（标签）
- `id / name / colorHex`
- 4 个反向关系数组

**DailyReport**（日报元数据）
- `id / date`（0:00 归一化）/ `note / tags`
- `getOrCreate(for:in:)`：按天取或建

**TodoItem**（独立待办）
- `id / title / notes / isDone / dueDate / completedAt / tags`

**Review**（评审意见）
- `id / reviewer / opinion / order / meeting?`

## 6. 核心业务语义

### 6.1 任务归属日（关键）

一个任务"属于哪一天"由 `kind` 决定，这是概要/周报分天的统一依据：

| kind | 归属日 | 语义 |
|---|---|---|
| done | `finishDate ?? timestamp` | 实际完成那天 |
| planned | `finishDate ?? timestamp` | 计划完成那天 |
| blocker | `timestamp` | 问题发生那天 |

> 周报 `belongDate(_:)`、概要 `todayEntries`、计划列表 `isTodayPlanned` 均遵循此语义，保证跨天完成、提前完成都能落到正确的天。

### 6.2 今日判定（todayEntries）

概要里"今日记录"的筛选规则（`start..<end` 为今日 0:00 到次日 0:00）：

- **done**：`finishDate ?? timestamp ∈ [start, end)`
- **planned**：`finishDate <= start`（计划日是今天或已逾期未完成）或无 finishDate 且 `timestamp ∈ [start, end)`
- **blocker**：`timestamp ∈ [start, end)`

### 6.3 计划列表 vs 今日记录去重

概要的"计划列表"显示**非今日**的计划任务，避免与"今日记录·计划组"重复：

```swift
private static func isTodayPlanned(_ e, start, end) -> Bool {
    if let f = e.finishDate { return startOfDay(f) <= start }
    return e.timestamp >= start && e.timestamp < end
}
// plannedList = kind == .planned && !isTodayPlanned(...)
```

### 6.4 周期性推进

两套独立 sweep，均在启动 + 跨日触发：

- **sweepMeetings**：`isRecurring && timestamp < startOfToday` 的会议原地推进到 `nextFutureOccurrence(from: startOfToday)`；含 8 天窗口内的"过度推进回拉"恢复（pattern 命中今天则拉回今天）
- **sweepWorkEntries**：逾期未完成的周期性 planned 任务原地推进 `finishDate` 到下一次

> 原地推进不克隆、不留历史（与会议一致）；用户若想留下"这期做完了"的痕迹，走完成路径。

### 6.5 统一完成路径 markDone

所有"标记完成"入口（菜单栏完成按钮、概要计划列表完成、时间线拖到完成列、待办完成）统一走：

```swift
static func markDone(_ entry, in context) {
    let wasPlanned = entry.kind == .planned
    if entry.isRecurring && wasPlanned {
        WorkEntry.spawnNextRecurrence(of: entry, in: context)  // 先克隆（用旧 finishDate 当锚点）
    }
    entry.kind = .done
    if wasPlanned || entry.finishDate == nil {
        entry.finishDate = Date()  // 计划→完成：finishDate 从「计划日」更新为「实际完成日」
    }
}
```

关键点：克隆必须在改 finishDate 之前（用计划完成日当锚点推下一次），再覆盖 finishDate 为实际完成时间——这让提前完成的任务在周报里落回实际完成那天。

## 7. 关键流程

### 7.1 添加任务
菜单栏 `addBar` / 时间线 `addBar` → `add()` → `context.insert(WorkEntry(...))` → 重置输入（含 `newFinishDate = Date()`，下次默认今天）

### 7.2 完成计划任务
点击完成圆圈 / 拖到完成列 / 右键标记完成 → `RecurrenceService.markDone` → 周期性克隆下一期 + kind=done + finishDate=now → 该任务从计划列表消失，落入今日记录完成组

### 7.3 跨日推进
系统发 `NSCalendarDayChanged` → DailyReportApp 触发 sweep；WeeklyReportView 同时监听该通知，把 `weekAnchor` 重置为今天（周报自动回本周）

### 7.4 数据导入（容错）
设置页选 JSON → 弹确认 → `BackupService.restore`：
1. 先对当前数据写一份 `pre-import-*.json` 快照
2. 逐实例删除所有表（避免批量删除 metatype 推断错误）
3. 用 `[UUID: Tag]` / `[UUID: Meeting]` 映射表重建关系
4. 失败时留有 pre-import 快照可手动恢复

### 7.5 Schema 迁移失败容错
`ModelContainer` 创建失败 → `wipeDefaultStore`：
1. 对旧 store URL 临时开 container 抓 JSON 备份（`autoBackup`）
2. 删除 `default.store{,-wal,-shm}`
3. 重建空 container
4. 用户可从设置页「打开备份文件夹」恢复

## 8. 数据安全

- **自动备份目录**：`~/Library/Application Support/com.zhyu.dailyreport/backups/`
- **触发点**：导入前、schema 迁移失败 wipe 前
- **保留策略**：每个前缀（`auto` / `pre-import`）保留最近 10 份
- **格式**：JSON（`Snapshot` 含扁平化的 DTO，关系用 UUID 数组表达，恢复时按映射重建）

## 9. 设置项

设置窗 `SettingsView` 分组：

| 组 | 项 |
|---|---|
| 通用 | 外观（跟随系统/浅色/深色）、开机自启（SMAppService） |
| 每日提醒 | 启用、时间、请求通知权限 |
| 数据 | 导出 JSON、导入 JSON、打开备份文件夹 |
| 快捷键 | 说明 |
| 关于 | 版本、最低系统、作者 |

## 10. 构建与签名

```bash
bash scripts/build-app.sh
```

脚本流程：
1. `export DEVELOPER_DIR=/Applications/Xcode.app/...`（CLT 缺 SwiftData 宏插件，必须完整 Xcode）
2. `swift build -c release`
3. 拷贝二进制 + Info.plist 到 `DailyReport.app/Contents/{MacOS,Resources}/`
4. `codesign --force --deep --sign -`（ad-hoc 签名，`SMAppService` 注册登录项的必要条件）
5. `touch`（注册 LaunchServices）

`Info.plist` 关键键：`LSUIElement=true`（纯菜单栏）、`CFBundleIdentifier=com.zhyu.dailyreport`。

## 11. 已知限制

- **SourceKit 诊断误报**：在非 Xcode 环境（VS Code + SourceKit）索引时，`@Model` 宏生成的 `PersistentModel/Identifiable` conform 不被识别，显示大量红色诊断；`swift build` 编译实际正常。需用完整 Xcode 环境索引。
- **SMAppService 签名要求**：ad-hoc 签名在大多数 macOS 版本能注册登录项，个别版本可能拒绝；失败时开关自动回滚 + 蜂鸣，回退到系统设置手动加登录项。
- **周报过度推进回拉窗口**：仅对 8 天内的过度推进做恢复，月度会议跨更长时间不恢复。
- **导出**：当前仅保留周报 XLSX（带星期列，按完成日排序），概要/时间线的历史导出入口已移除。
