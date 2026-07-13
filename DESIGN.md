# DailyReport 详细设计方案

> 一份覆盖「每个功能 → 每张表 → 每个字段 → 每个视图 → 每个服务」的实现说明书。
> README.md 面向使用者，本文档面向维护者。

## 1. 产品概述

**DailyReport** 是一款 macOS 菜单栏日报助手，定位为「常驻菜单栏的轻量个人日报工具」。

- **运行形态**：`LSUIElement = true`，纯菜单栏应用，不占 Dock、不出现在 Cmd+Tab 应用切换器
- **目标用户**：需要每日记录工作内容、跟踪计划、复盘会议、生成周报的个人开发者 / 知识工作者
- **核心价值闭环**：
  - **随手记** — 菜单栏图标 → 弹出面板 → 三秒落一条
  - **全局看** — 主窗口五 Tab：概要 / 时间线 / 会议纪要 / 周报 / 待办（待办内嵌）
  - **自动汇总** — 周期推进（会议 + 计划任务）+ 周报导出（XLSX，按星期组织）
- **设计原则**：
  - 零第三方依赖（XLSX 自己写、ZIP 自己拼、备份 JSON 自己序列化）
  - 单条滚动记录（周期性会议/计划原地推进，不克隆历史；只有「完成」走克隆路径留痕）
  - 个人本地工具（不做多用户、不做云同步；数据安全靠 JSON 快照 + 自动备份兜底）

## 2. 整体架构

### 2.1 三 Scene 共享 ModelContainer

App 由三个 SwiftUI Scene 组成，共享同一个 `ModelContainer`：

```
@main DailyReportApp
├── MenuBarExtra                ← 菜单栏图标 ✅ checklist + 弹出面板（MenuPanelView）
│   .menuBarExtraStyle(.window) ← 系统托管窗口，点外部自动收起
├── Window("DailyReport", id: AppState.mainWindowID)
│   └── MainTabView             ← 主窗口五 Tab
└── Settings
    └── SettingsView            ← 系统设置窗
```

三 Scene 的根视图统一挂 `.preferredColorScheme(colorScheme)`，由 `@AppStorage(AppState.Key.appearance)` 驱动（跟随系统 / 浅色 / 深色），保证菜单栏面板、主窗口、设置窗三处外观一致。

### 2.2 启动流程

`DailyReportApp.init()`：

1. **创建 ModelContainer**（schema 列出全部 6 个模型）
   - 失败（典型为 schema 不兼容）→ `wipeDefaultStore()`：
     - 先对旧 store URL 临时开一个只读 container 抓快照、写 JSON 到 `backups/auto-*.json`
     - 删除 `default.store{,-wal,-shm}`
     - 重建空 container
   - 仍失败 → `fatalError`（极端情况）
2. **启动 sweep**：
   - `RecurrenceService.sweepMeetings(in: container.mainContext)` — 周期会议推进
   - `RecurrenceService.sweepWorkEntries(in: container.mainContext)` — 周期计划任务推进
3. **注册跨日监听** `NSCalendarDayChanged`：菜单栏 app 常开数天，午夜跨日时再触发一次双 sweep（避免过了零点还看到「昨天」的周期项卡在逾期）
   - `MainActor.assumeIsolated` 包裹闭包，满足 Swift 6 严格并发

### 2.3 数据流

- 所有视图通过 `@Query` + `@Environment(\.modelContext)` 访问 SwiftData，无 ViewModel 中间层
- SwiftData `@Model` 自动 conform `PersistentModel / Identifiable / Hashable / Observable`，`@Bindable` 可直接用
- 状态变量 `@State` 仅用于输入栏草稿、选中标签、折叠状态等 UI 局部状态

## 3. 技术栈

| 层 | 技术 | 说明 |
|---|---|---|
| 语言 | Swift 6（严格并发） | `swift-tools-version: 6.0` |
| UI | SwiftUI（macOS 14+） | `platforms: [.macOS(.v14)]` |
| 持久化 | SwiftData `@Model` | 默认 store（`~/Library/Application Support/default.store`），轻量迁移 |
| 通知 | UserNotifications | `UNCalendarNotificationTrigger` 重复触发每日提醒 |
| 开机自启 | ServiceManagement `SMAppService.mainApp` | 注册登录项，首次开启系统授权一次 |
| 构建 | SwiftPM + `scripts/build-app.sh` | release 构建 + 打包 `.app` + ad-hoc 签名 |
| 第三方依赖 | **无** | XLSX / ZIP / JSON 备份全自写 |

## 4. 目录结构

```
Sources/DailyReport/
├── DailyReportApp.swift           # @main，三 Scene + 启动 sweep + 跨日监听 + wipe 兜底
├── AppState.swift                 # 常量、UserDefaults Key、AppearanceMode 枚举
├── NavigationCoordinator.swift    # 主窗口 Tab 选中态 + 跨页跳转请求
├── Models/                        # SwiftData @Model
│   ├── DailyReport.swift          # 日报元数据（备注/标签）+ getOrCreate
│   ├── WorkEntry.swift            # 工作任务（核心）+ 4 个枚举 + spawnNextRecurrence
│   ├── Meeting.swift              # 会议 + Review（同文件）
│   ├── Review.swift               # （注：实现在 Meeting.swift）
│   ├── Tag.swift                  # 多对多标签（4 个反向关系）
│   ├── TodoItem.swift             # 独立待办
│   └── Recurrence.swift           # 周期计算纯函数（无 Model）
├── Views/
│   ├── MainTabView.swift          # 4 Tab（概要/时间线/会议/周报），环境注入 coordinator
│   ├── TodayView.swift            # 概要：统计条 + 今日记录 + 计划列表 + 会议
│   ├── HistoryView.swift          # 时间线三列看板 + 搜索 + 拖拽 + 优先级/状态分组
│   ├── TodoListView.swift         # 待办 + 计划任务统一操作
│   ├── MeetingView.swift          # 会议列表 + 卡片 + 新增/编辑表单（ReviewDraft）
│   ├── WeeklyReportView.swift     # 周报：按归属日分天 + 统计卡 + XLSX 导出
│   ├── MenuPanelView.swift        # 菜单栏弹出面板
│   └── SettingsView.swift         # 设置：通用/提醒/数据/快捷键/关于
├── Components/
│   ├── WorkSummaryView.swift      # WorkEntryCard（编辑/拖拽）+ WorkSummaryView（只读汇总）
│   ├── TagPicker.swift            # 完整版 + 紧凑版 + ColorSwatchPicker
│   ├── KindPicker.swift           # 完成/计划/问题 三色胶囊
│   ├── RecurrenceEditor.swift     # 周期编辑（开关 + 单位 + 上下文选项）
│   ├── FlowLayout.swift           # 自定义 Layout，标签自动换行
│   ├── EmptyStateView.swift       # 大图标 + 标题 + 副标题
│   └── SharedExtensions.swift     # Color(hex) / Date helpers / Calendar helpers
└── Services/
    ├── RecurrenceService.swift    # sweepMeetings + sweepWorkEntries + markDone
    ├── BackupService.swift        # Snapshot DTO + JSON 序列化 + 自动备份 + 恢复
    ├── ExportService.swift        # 周报 XLSX + Markdown（旧路径，已不在 UI 暴露）
    ├── XLSXWriter.swift           # 单表 XLSX 写入 + ZipBuilder（stored 无压缩）
    └── ReminderService.swift      # 单例，UNUserNotificationCenter 包装
scripts/build-app.sh                # swift build -c release + 打包 + ad-hoc codesign + touch
Resources/Info.plist.template       # LSUIElement=true / CFBundleIdentifier=com.zhyu.dailyreport
```

## 5. 数据模型（详细字段说明）

### 5.1 实体关系总览

```
DailyReport 1───* Tag *───* WorkEntry
                           *───* Meeting 1───* Review
                           *───* TodoItem
```

- **Tag** 是中心枢纽，通过 4 条 `@Relationship(inverse:)` 与 DailyReport / WorkEntry / Meeting / TodoItem 建立多对多
- **Meeting → Review** 一对多，`deleteRule: .cascade`（会议删除连带评审）
- **DailyReport** 仅存元数据，任务汇总由 `WorkEntry` 按「归属日」动态聚合，**不冗余存储**
- 所有 `@Model` 仅 `@Attribute(.unique) var id: UUID` 一个唯一约束，没有 `VersionedSchema` / `.originalName`（个人工具避免样板）

### 5.2 WorkEntry（核心实体：工作任务）

文件：`Models/WorkEntry.swift`。时间线/概要/周报/待办均围绕此模型。

| 字段 | 类型 | 默认 | 用途 |
|---|---|---|---|
| `id` | `UUID` | 新建 | 唯一标识，drag-and-drop 用 `uuidString` 传递 |
| `title` | `String` | 必填 | 任务标题（去空格后非空才能提交） |
| `detail` | `String` | `""` | 详情，可选，多行 |
| `timestamp` | `Date` | `Date()` | 发生/记录时间，时间线排序与「问题归属日」用 |
| `kindRaw` | `String` (私有) | `"完成"` | `WorkKind` 的 raw 值；通过 computed `kind` 读写 |
| `tags` | `[Tag]` | `[]` | 多对多标签 |
| `createdAt` | `Date` | `Date()` | 创建时刻（不变） |
| `finishDate` | `Date?` | `nil` | 完成/计划完成日（语义见下） |
| `helper` | `String?` | `nil` | 问题类的「求助人」 |
| `blockerStatusRaw` | `String` (私有) | `"Ongoing"` | `BlockerStatus` raw 值 |
| `priorityRaw` | `String` (私有) | `"Medium"` | `Priority` raw 值 |
| `isRecurring` | `Bool` | `false` | 是否周期性计划（仅 `.planned` 有意义） |
| `recurrenceUnitRaw` | `String` (私有) | `"每天"` | `RecurrenceUnit` raw 值 |
| `recurrenceInterval` | `Int` | `1` | 仅「每天」用，最小 1 |
| `recurrenceWeekdays` | `[Int]` | `[]` | Calendar weekday（1=周日 … 7=周六） |
| `recurrenceMonthDays` | `[Int]` | `[]` | 1…31 |

**Computed 属性**：

- `kind: WorkKind` — get/set 委托 `kindRaw`，fallback `.done`
- `blockerStatus / priority / recurrenceUnit` — 同上
- `isOverdue: Bool` — `kind == .planned && startOfDay(finishDate) < startOfDay(today)`，仅计划任务会逾期
- `recurrenceLabel: String` — 委托 `Recurrence.label(...)`，如「每周一三五」「每月1日、15日」
- `day: Date` — `startOfDay(timestamp)`，问题归属日

**关键方法**：

- `nextRecurrenceDate() -> Date` — 基于 `finishDate ?? Date()` 调 `Recurrence.nextFutureDate`
- `static spawnNextRecurrence(of:in:) -> WorkEntry?` — 克隆一条新的 `.planned`，新 `finishDate` 用 `entry.nextRecurrenceDate()`，**仅在 `markDone` 完成路径调用**

#### 5.2.1 配套枚举（同文件）

**`WorkKind: String, Codable, CaseIterable, Identifiable`**

| case | rawValue | icon | color |
|---|---|---|---|
| `done` | "完成" | `checkmark.circle.fill` | green |
| `planned` | "计划" | `calendar` | blue |
| `blocker` | "问题" | `exclamationmark.triangle.fill` | orange |

**`BlockerStatus: String, Codable, CaseIterable, Identifiable`**

| case | rawValue | 中文 | color |
|---|---|---|---|
| `ongoing` | "Ongoing" | 进行中 | orange |
| `monitor` | "Monitor" | 观察中 | blue |
| `closed` | "Closed" | 已关闭 | green |

**`RecurrenceUnit: String, Codable, CaseIterable, Identifiable`**

| case | rawValue |
|---|---|
| `daily` | "每天" |
| `weekly` | "每周" |
| `monthly` | "每月" |

**`Priority: String, Codable, CaseIterable, Identifiable`**

| case | rawValue | 中文 | color | sortOrder |
|---|---|---|---|---|
| `high` | "High" | 高 | red | 0 |
| `medium` | "Medium" | 中 | yellow | 1 |
| `low` | "Low" | 低 | gray | 2 |

> 所有枚举都用「私有 `*Raw` 字段 + computed 转换」的方式存到 SwiftData（SwiftData 对 enum 原生支持，但用 raw String 更利于备份 JSON 的前向兼容）。

### 5.3 Meeting（会议纪要）

文件：`Models/Meeting.swift`（与 `Review` 同文件）。

| 字段 | 类型 | 默认 | 用途 |
|---|---|---|---|
| `id` | `UUID` | 新建 | |
| `topic` | `String` | 必填 | 会议主题（去空格非空才能保存） |
| `summary` | `String` | `""` | 会议概要，多行 |
| `timestamp` | `Date` | `Date()` | 会议时间（也作周期推进锚点） |
| `createdAt` | `Date` | `Date()` | |
| `reviews` | `[Review]` | `[]` | 一对多，`deleteRule: .cascade` |
| `tags` | `[Tag]` | `[]` | 多对多 |
| `isRecurring` | `Bool` | `false` | 周期性会议 |
| `recurrenceUnitRaw` | `String` (私有) | `"每天"` | |
| `recurrenceInterval` | `Int` | `1` | |
| `recurrenceWeekdays` | `[Int]` | `[]` | |
| `recurrenceMonthDays` | `[Int]` | `[]` | |

**Computed**：

- `recurrenceUnit: RecurrenceUnit` — raw 转换
- `recurrenceLabel: String` — 同 WorkEntry
- `orderedReviews: [Review]` — 按 `order` 升序
- `day: Date` — `startOfDay(timestamp)`

**方法**：

- `nextFutureOccurrence(from now: Date = Date()) -> Date` — 委托 `Recurrence.nextFutureDate(after: timestamp, now: now)`，**注意锚点是 `timestamp` 而非 `now`**，用于 sweep 推进时算「下一期」

### 5.4 Review（评审意见）

文件：`Models/Meeting.swift`。

| 字段 | 类型 | 默认 | 用途 |
|---|---|---|---|
| `id` | `UUID` | 新建 | |
| `reviewer` | `String` | 必填（或 opinion 非空） | 评审人姓名 |
| `opinion` | `String` | `""` | 评审意见 |
| `meeting` | `Meeting?` | `nil` | 反向关系，所属会议 |
| `order` | `Int` | `0` | 在会议中的顺序（前端用 `orderedReviews` 排序） |
| `createdAt` | `Date` | `Date()` | |

### 5.5 Tag（多对多枢纽）

文件：`Models/Tag.swift`。

| 字段 | 类型 | 默认 | 用途 |
|---|---|---|---|
| `id` | `UUID` | 新建 | |
| `name` | `String` | 必填 | |
| `colorHex` | `String` | `"#4A90D9"` | `#RRGGBB` |
| `createdAt` | `Date` | `Date()` | |
| `reports` | `[DailyReport]` | `[]` | 反向关系 |
| `todos` | `[TodoItem]` | `[]` | 反向关系 |
| `entries` | `[WorkEntry]` | `[]` | 反向关系 |
| `meetings` | `[Meeting]` | `[]` | 反向关系 |

**Computed**：`swiftUIColor: Color` — `Color(hex: colorHex) ?? .accentColor`

> 4 个反向关系声明在 Tag 一侧，`inverse:` 指向 DailyReport/TodoItem/WorkEntry/Meeting 的 `tags` 数组。删除 Tag 时，SwiftData 自动从所有 `tags` 数组里移除该引用。

### 5.6 DailyReport（日报元数据）

文件：`Models/DailyReport.swift`。

| 字段 | 类型 | 默认 | 用途 |
|---|---|---|---|
| `id` | `UUID` | 新建 | |
| `date` | `Date` | 归一化 0:00 | 当天标识（init 时 `startOfDay`） |
| `note` | `String` | `""` | 手写备注 |
| `tags` | `[Tag]` | `[]` | 日报级标签 |
| `createdAt` | `Date` | `Date()` | |
| `updatedAt` | `Date` | `Date()` | |

**类方法**：`static getOrCreate(for date: Date, in context: ModelContext) -> DailyReport` — 按 `[startOfDay, startOfDay+1day)` 谓词查，无则插入。TodayView `.task` 阶段调用，保证打开页面就有 `report`。

> 任务汇总**不**存在 DailyReport 上，由 `WorkEntry` 按「归属日」动态聚合，避免双写不一致。

### 5.7 TodoItem（独立待办）

文件：`Models/TodoItem.swift`。

| 字段 | 类型 | 默认 | 用途 |
|---|---|---|---|
| `id` | `UUID` | 新建 | |
| `title` | `String` | 必填 | |
| `notes` | `String` | `""` | |
| `isDone` | `Bool` | `false` | |
| `dueDate` | `Date?` | `nil` | 截止日期 |
| `tags` | `[Tag]` | `[]` | |
| `createdAt` | `Date` | `Date()` | |
| `completedAt` | `Date?` | `nil` | 完成时刻 |

**Computed**：`isOverdue: Bool` — `dueDate < Date() && !isDone`

> 待办页同时显示独立 TodoItem + 来自时间线的「计划」WorkEntry，但两者是不同模型，互不转换。

### 5.8 Recurrence（纯函数工具）

文件：`Models/Recurrence.swift`。非 `@Model`，无状态。

- `weekdayDisplayOrder = [2,3,4,5,6,7,1]` — 中文习惯：一 二 三 四 五 六 日
- `nextFutureDate(unit:interval:weekdays:monthDays:after:now:)`：
  - **daily**：从 `base` 起按 `interval` 天累加，直到 `> now`（保留 base 的时分）
  - **weekly**：从 `startOfDay(now)` 起日历日 +1 扫描，命中 `weekdays` 且 `candidate > now` 即返回；扫到 366 天上限为止
  - **monthly**：同 weekly，按月份日匹配 `monthDays`
  - `weekdays` / `monthDays` 为空返回 `nil`（用户没选具体哪天）
- `label(unit:interval:weekdays:monthDays:)`：
  - 每天 / 每 N 天
  - 每周一三五（按中文顺序）
  - 每月1日、15日（升序）

## 6. 核心业务语义

### 6.1 任务归属日（最关键，贯穿概要/周报）

一个任务「属于哪一天」由 `kind` 决定：

| kind | 归属日 | 语义 |
|---|---|---|
| `done` | `finishDate ?? timestamp` | 实际完成那天 |
| `planned` | `finishDate ?? timestamp` | 计划完成那天 |
| `blocker` | `timestamp` | 问题发生那天 |

> WeeklyReportView 的 `belongDate(_:)`、TodayView 的 `todayEntries`、概要计划列表 `isTodayPlanned` 判定**都遵循此语义**。配合 `markDone` 完成时把 `finishDate` 改成 `Date()`，提前完成的任务会落到「实际完成那天」而非「计划那天」。

### 6.2 今日判定（todayEntries）

`TodayView.todayEntries(for:)` 与 `MenuPanelView.todayEntries` 一致。设 `start = 0:00 today`，`end = start + 1 day`：

- **done**：`(finishDate ?? timestamp) ∈ [start, end)` — 完成日是今天
- **planned**：
  - 有 `finishDate`：`startOfDay(finishDate) <= start` — 计划日是今天**或已逾期未完成**
  - 无 `finishDate`：`timestamp ∈ [start, end)` — 当天随手建的
- **blocker**：`timestamp ∈ [start, end)`

> 关键：逾期未完成的计划任务仍然显示在「今日记录 · 计划组」里，直到被完成或 sweep 推进。

### 6.3 计划列表 vs 今日记录去重

概要页有两个区域都可能显示计划任务，必须去重：

- **今日记录 · 计划组**：见 6.2 planned 判定
- **计划列表**：`kind == .planned && !isTodayPlanned(...)` — 仅显示**非今日**计划

```swift
private static func isTodayPlanned(_ e: WorkEntry, start: Date, end: Date) -> Bool {
    if let f = e.finishDate {
        return Calendar.current.startOfDay(for: f) <= start  // 计划日是今天或已逾期
    }
    return e.timestamp >= start && e.timestamp < end           // 当天建的
}
```

`plannedListBase`（不依赖 `selectedTag`，用于稳定填充标签栏）+ `plannedList`（在 base 上叠加标签筛选 + 优先级/时间排序）。

### 6.4 周期性推进（sweep）

两套独立 sweep，均在 **App 启动** + **NSCalendarDayChanged 跨日** 触发：

**`sweepMeetings`**

1. `isRecurring && timestamp < startOfToday` 的会议 → `timestamp = nextFutureOccurrence(from: startOfToday)`
   - **按天判定**（不计具体时刻）：今天的周期性会议无论时间是否已过都留在今日
   - **推进目标按天算**（`from: startOfToday`），确保「下一期就是今天」时落在今天而非跳到明天
2. **过度推进回拉**：旧逻辑用 `<= now` 可能错把今天的周期会议推到未来。对 `timestamp ∈ (endOfToday, +8天]` 且 `patternMatchesToday == true` 的会议拉回今天（保留原时分）
   - 8 天窗口覆盖 daily(1) / weekly(7)；月度跨月不处理
3. **残留清理**：与某周期会议同主题、自身非周期、无评审、无概要的旧版「克隆+降级」逻辑残留空副本 → 删除

**`sweepWorkEntries`**

- `isRecurring && kind == .planned && startOfDay(finishDate) < today` 的任务 → `finishDate = Recurrence.nextFutureDate(after: f, now: Date()) ?? f`
- **原地推进，不克隆**（与会议语义一致）。用户若想留「这期做完了」的痕迹，走完成路径

### 6.5 统一完成路径（markDone）

所有「标记完成」入口（菜单栏完成按钮、概要计划列表完成、时间线拖到完成列、待办完成按钮）统一走：

```swift
static func markDone(_ entry: WorkEntry, in context: ModelContext) {
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

**执行顺序至关重要**：

1. 先克隆（`spawnNextRecurrence` 内用 `entry.nextRecurrenceDate()`，依赖**原计划 finishDate** 当锚点推下一期）
2. 再改 `kind`
3. 最后覆盖 `finishDate` 为实际完成时间

提前完成的任务在周报里落回实际完成那天，而下一期计划克隆仍指向正确的未来日期。

### 6.6 跨日监听

`DailyReportApp.init()` 注册 `NSCalendarDayChanged`：

```swift
NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated {
        RecurrenceService.sweepMeetings(in: strongContainer.mainContext)
        RecurrenceService.sweepWorkEntries(in: strongContainer.mainContext)
    }
}
```

WeeklyReportView 另挂一个 `.onReceive(...)` 把 `weekAnchor = Date()`，让周报自动回本周。

## 7. 视图层（每个 Tab / 面板详解）

### 7.1 MenuPanelView（菜单栏弹出面板）

固定尺寸 `380 × 540`，垂直布局 `header / Divider / addBar / Divider / todayList / Divider / footer`。

**Header**：标题「今日日报」+ `Date().friendlyDay` + 右侧 `todayEntries.count` 条。

**addBar**（快速添加）：

- `KindPicker`（三色胶囊）— 切换 `newKind`
- TextField「刚做了什么？回车添加」+ `plus.circle.fill` 按钮
- `extraFieldRow`（按 kind 分支）：
  - `.done`：完成时间 DatePicker（date only）+ 紧凑 TagPicker
  - `.planned`：计划完成 DatePicker + 优先级 segmented Picker + RecurrenceEditor
  - `.blocker`：求助人 TextField + 状态 segmented Picker + 紧凑 TagPicker

**todayList**（ScrollView，分区显示）：

- 三组 `todayEntries`（按 kind 分组，组内按 timestamp 倒序）— 每组带 `sectionHeader`（图标 + 文字 + 计数胶囊）
- 「计划列表」区（非今日计划，按优先级 → 时间排序）
- 「今日会议」区（按 timestamp 升序）：每条由 `MeetingPanelRow` 渲染（见下）

**entryRow(_:)** — 一行任务：

- `.planned` 显示完成圆圈按钮（逾期用 `exclamationmark.circle` 红色，否则 `circle` 灰色）→ 点击调 `RecurrenceService.markDone`
- 其他 kind 显示左侧 3pt 宽彩色竖条（颜色由 kind / blockerStatus 决定）
- 标题 + 逾期/优先级/状态/周期胶囊 + 右侧时间

**footer**：「打开主窗口」+ 设置齿轮 + 退出。

**add()** 重置：`newTitle / selectedTags / newHelper / newFinishDate = Date() / isRecurring / recurrenceWeekdays / recurrenceMonthDays / newBlockerStatus / newPriority` —— 每次添加后下次默认今天。

**MeetingPanelRow**（菜单栏会议行，文件内 `private struct`）：紧凑单行（紫色竖条 + 图标 + 主题 + 周期胶囊 + 时间 + chevron）；**点击整行切换展开**，展开后在下方嵌入紧凑 `TextEditor`（minHeight 28）绑定 `$meeting.summary`，placeholder「点这里写会议概要…」。SwiftData autosave 跨页面同步到概要页 / 会议纪要页。

### 7.2 MainTabView

4 Tab（`TabView(selection: $coordinator.selectedTab)`）：

| tag | 标签 | 图标 | 视图 |
|---|---|---|---|
| 0 | 概要 | `sun.max.fill` | TodayView |
| 1 | 时间线 | `clock.arrow.circlepath` | HistoryView |
| 2 | 会议纪要 | `person.3` | MeetingView |
| 3 | 周报 | `doc.text.magnifyingglass` | WeeklyReportView |

> 待办没有独立 Tab，从时间线或菜单栏进入。`.environment(coordinator)` 注入到所有子视图。

### 7.3 TodayView（概要）

`.task` 阶段 `DailyReport.getOrCreate(for: Date(), in: context)` 取当日 `report`。

**布局**（ScrollView + VStack）：

1. **大标题**：「概要」+ `Date().friendlyDay`
2. **statBar**：4 个 statChip + 完成率
   - 完成（green `checkmark.circle.fill`）
   - 计划（blue `calendar`）
   - 问题（orange `exclamationmark.triangle.fill`）
   - 会议（purple `person.3.fill`）
   - 完成率（`done / (done + planned + blocker)`，百分比）
   - **跟随当前标签筛选**：statBar 接收的是 filteredEntries / filteredMeetings
3. **今日记录**（`WorkSummaryView`，按 kind 分组只读展示）
   - 标题栏右侧：「N 条」或「filtered / total 条」
   - `tagFilterBar`（横向 ScrollView）：「全部」chip + 所有 `usedTags` chips（点击 toggle 选中）
   - `usedTags` 由 `entries + meetings + plannedListBase` 三处的标签聚合（保证只有计划任务才用到的标签也能出现）
4. **计划列表**（仅 `plannedList` 非空时显示）
   - `plannedRow`：完成圆圈按钮 + 标题 + 优先级/逾期/周期胶囊 + 右侧日期
   - `contextMenu`：标记完成 / 删除（删除走 `pendingDeleteEntry` alert 二次确认）
5. **今日会议**（仅 `filteredMeetings` 非空时显示）
   - `todayMeetingRow`：紫色主题，主题 + 周期胶囊 + **内联概要编辑器** + 标签 chips
   - 概要区改为 `TextEditor` 直接绑定 `$m.summary`（`@Bindable`），始终显示，空时 placeholder「点这里写会议概要…」；无需打开「编辑」表单即可改概要

**alert**：「删除这条计划任务？」— `pendingDeleteEntry` 触发。

### 7.4 HistoryView（时间线三列看板）

**BoardItem enum**：把 WorkEntry 和 Meeting 统一成一种看板项；`sortDate` 任务用 `finishDate ?? timestamp`，会议用 `timestamp`。

**布局**（VStack）：

1. **addBar**：KindPicker + TextField + 完成按钮 + extraFieldRow（同 MenuPanelView 但更宽）
2. **filterBar**：`TagFilterMenu` + 清除筛选
3. **board**：`HStack(alignment: .top)` 三列，**每列独立 ScrollView**（外层无 ScrollView，三列可分别滚动）
4. `.searchable(text: $searchText, placement: .toolbar)` — 搜索标题 / 详情 / 会议主题

**column(_ kind:)**：

- 列头：图标 + 文字 + 计数胶囊
- 卡片列表：
  - `.planned` → `plannedSections`（按优先级高/中/低分组，组头可折叠，整组作 drop 目标，命中后设 `kind=.planned + priority`）
  - `.blocker` → `blockerSections`（**双层嵌套**：外层按优先级高/中/低可折叠，整组作 drop 目标命中后设 `kind=.blocker + priority`；内层按状态「进行中 / 观察中 / 已关闭」**不折叠**，仅当非空时渲染，整子组作 drop 目标命中后同时设 `kind=.blocker + priority + blockerStatus`）
  - `.done` → 平铺
- 列整体作 drop 目标：拖到「完成」走 `markDone`，其他列直接 `target.kind = kind`
- 背景/边框：默认淡色填充，drop target 时加深 + 加粗描边
- 折叠状态分列隔离：`collapsedPriorities`（计划列）、`collapsedBlockerPriorities`（问题列外层），互不影响
- drop target hint 也分列隔离：`dropTargetPriority`（计划列）、`dropTargetBlockerPriority`（问题列外层）、`dropTargetStatus`（问题列内层）

**会议并入看板**：周期性会议**不进看板**（仅作模板），非周期会议按 timestamp 在未来 → 计划列，否则 → 完成列。`MeetingBoardCard` 紧凑卡片，点击 → `coordinator.openMeetingEdit(meeting)` 跳到会议 Tab。

**WorkEntryCard**（`Components/WorkSummaryView.swift`）：

- 只读态：标题 + 优先级徽章（**`.planned` 与 `.blocker` 都显示**，和问题列双层分组对齐）+ 详情 + metaRow（完成日 / 计划日+周期 / 状态+求助人）+ tagRow + 编辑/删除按钮
- 编辑态：标题/详情 TextField + 标签多选 Menu + extraEditRow + 优先级 segmented + 取消/保存
- `.draggable(entry.id.uuidString)` 提供拖拽数据
- 标签行支持右键移除；标签 Menu 支持「新建标签…」popover

### 7.5 TodoListView（待办）

**布局**：

1. **filterBar**：TagFilterMenu + 清除筛选
2. **content**：空态 or todoList
3. **toolbar**：「含已完成」checkbox Toggle

**todoList**（List）：

- **Section「计划任务（来自时间线）」**：所有 `kind == .planned` 的 WorkEntry
  - `plannedRow`：`calendar.badge.clock` 完成按钮（调 `markDone`）+ 标题 + 相对时间 + 删除按钮（pendingDeleteEntry alert）
- **Section「待办」**：所有 TodoItem（按 selectedTag / showCompleted 筛选）
  - `TodoRow`：完成圆圈按钮（toggle `isDone / completedAt`）+ 标题（完成时划线）+ 截止日 + 标签 chips

两 Section 都支持 `.onDelete` 滑动删除。

### 7.6 MeetingView（会议纪要）

**布局**（NavigationStack + ScrollView）：

- 空态：`EmptyStateView("还没有会议纪要")`
- 列表：`LazyVStack` of `MeetingCard`
- toolbar：「+」新增按钮 → `.sheet` 弹 `MeetingFormView`
- `.sheet(item: $editing)` 编辑现有
- `.onChange(of: coordinator.meetingRequest?.id)`：跨页跳转请求 → 设 `editing`

**MeetingCard**：

- 标题 + 周期胶囊 + 相对时间
- **概要内联编辑器**（`summaryEditor` computed）：`@Bindable` + `TextEditor` 绑定 `$meeting.summary`，始终显示，空时 placeholder「点这里写概要…」；SwiftData autosave 自动持久化，无需打开「编辑」表单
- 标签 chips
- 评审区：`validReviews` 计数 + 每条评审（评审人 + 意见引号块）+ 内联新增评审
- 底部：「评审」按钮（展开 inlineAddReviewer）+ 「编辑」按钮（用于改主题/时间/标签/周期/评审等其它字段）

> 会议概要的「随时填写」体验在三个场景一致：`MeetingCard`（会议纪要页）、`todayMeetingRow`（概要页）、`MeetingPanelRow`（菜单栏面板）—— 同一条 `Meeting.summary` 字段，autosave 跨页面同步。

**MeetingFormView**（width: 560）：

- 主题（必填）+ 时间 DatePicker + RecurrenceEditor + 概要 TextEditor + TagPicker
- 评审列表（`reviewDrafts: [ReviewDraft]`，非托管对象）— 可增删，评审人 + 意见 TextEditor
- 底部：取消 + 添加/保存
- `save()`：清洗 drafts（trim 后过滤空）→ 编辑模式先删旧评审再插新的；新建模式直接插

### 7.7 WeeklyReportView（周报）

**周计算**：

```swift
weekRange = (monday(for: weekAnchor).startOfDay, +6 day)
weekEntries = entries.filter { belongDate ∈ [start, end+1day) }.sorted { belongDate asc }
```

**布局**（NavigationStack + ScrollView + VStack）：

1. **header**：`weekTitle`（「周报 yyyy-MM-dd ~ yyyy-MM-dd」）+ 任务总数
2. **summary**：两个 statCard（任务数 / 已完成）
3. **7 个 dayBlock**（周一到周日）：
   - `day.friendlyDay` + 今天标记
   - `WorkSummaryView(entries: dayData.entries)` 只读展示
   - 如有备注，显示「备注」+ 内容
4. **toolbar**：
   - 上一周 / 本周 / 下一周
   - 「导出周报」按钮 → `ExportService.shared.exportWeekDoneXLSX(weekEntries, title: weekTitle)`
5. `.onReceive(NSCalendarDayChanged)` → `weekAnchor = Date()`（跨日自动回本周）

**belongDate(_:)**：done/planned → `finishDate ?? timestamp`，blocker → `timestamp`。

### 7.8 SettingsView（设置）

宽度 460 的 Form，5 个 Section：

| Section | 内容 |
|---|---|
| 通用 | 外观 Picker（跟随系统/浅色/深色，`@AppStorage(appearance)`）+ 开机自启 Toggle（`SMAppService.mainApp.register/unregister`，失败回滚 + beep） |
| 每日提醒 | 启用 Toggle + 时间 Picker（15 分钟粒度）+ 请求通知权限按钮 + 授权状态 |
| 数据 | 导出全部 JSON（NSSavePanel）/ 从 JSON 导入（NSOpenPanel + 二次确认 + restore）/ 打开备份文件夹 |
| 快捷键 | 文字说明（点击菜单栏图标 → 打开主窗口） |
| 关于 | 版本 1.0.0 / 最低系统 macOS 14.0 / 作者 zhyu |

**两个 alert**：

- 「导入会清空当前数据」二次确认
- 「导入失败」错误展示

**.task**：从 `SMAppService.mainApp.status` 初始化 `launchAtLogin`，从 `ReminderService` 拉授权状态。

## 8. 组件库

### 8.1 WorkEntryCard / WorkSummaryView（`Components/WorkSummaryView.swift`）

- **WorkEntryCard**：单条任务卡片，支持只读/编辑切换、拖拽、删除二次确认、右键标签管理、新建标签 popover。详见 7.4。
- **WorkSummaryView**：把一批任务按 kind 分组只读展示（概要页今日记录 / 周报每日块用），每组带 `section(_:_:)` 渲染图标+计数标题 + 列表（含详情、优先级、状态、周期、标签胶囊、逾期标记）。

### 8.2 TagPicker（`Components/TagPicker.swift`）

两种模式：

- **完整版 `fullBody`**：标题「标签」+ 「新建」按钮（popover）+ `FlowLayout` 渲染所有标签 chip（选中填充色，未选中淡背景）
- **紧凑版 `compactBody`**：图标按钮 + 计数 → 点击弹 popover → `compactGrid`（颜色选择器 + 输入框回车建 + LazyVGrid of checkChip）

**新建标签**：

- `ColorSwatchPicker` 8 色预设板（`#4A90D9 / #7BBD5B / #E8743B / #D34A4A / #9B59B6 / #F2C037 / #1AB5A4 / #555555`）
- 名称输入框，回车即建
- 颜色默认 `nextDefaultColor()`（优先选未被使用的预设色）

**删除标签**：右键 chip → 「删除标签」→ alert 二次确认 → 从所有任务/会议/日报移除。

### 8.3 KindPicker（`Components/KindPicker.swift`）

三色胶囊 HStack：选中填充分类色（`swiftUIColor`）+ 白字，未选中淡灰背景 + 主色字。点击切换 `selection: WorkKind`。

### 8.4 RecurrenceEditor（`Components/RecurrenceEditor.swift`）

5 个 Binding（`isOn / unit / interval / weekdays / monthDays`）。

- Toggle「周期性」checkbox
- 开启后：单位 segmented Picker（每天/每周/每月）+ 上下文选项：
  - `.daily`：Stepper 1...30 天
  - `.weekly`：7 个周几 chip（按 `weekdayDisplayOrder` 中文顺序 一二三四五六日）
  - `.monthly`：7 列 × 5 行网格，1...31 号多选

### 8.5 FlowLayout（`Components/FlowLayout.swift`）

自定义 `Layout`，标签 chip 自动换行。`spacing` 默认 6。`arrange` 遍历 subviews，超宽则换行累计 y。

### 8.6 EmptyStateView（`Components/EmptyStateView.swift`）

大图标（42pt secondary）+ 标题（headline）+ 副标题（subheadline secondary），居中铺满。

### 8.7 SharedExtensions（`Components/SharedExtensions.swift`）

- `Color(hex:)` — `#RRGGBB` 解析；`hexString` 反向
- `Date`：`startOfDay / isToday / friendlyDay / isoDay / shortTime / friendlyDate / relativeTime`
- `Calendar`：`monday(for:) / monthStart(for:)`

## 9. 服务层

### 9.1 RecurrenceService（`Services/RecurrenceService.swift`）

`enum RecurrenceService`（无实例），3 个静态方法：

- `sweepMeetings(in:)` — 周期会议推进 + 8 天过度推进回拉 + 残留克隆清理（详见 6.4）
- `sweepWorkEntries(in:)` — 周期计划任务原地推进 finishDate
- `markDone(_:in:)` — 统一完成路径（详见 6.5）

私有 `patternMatchesToday(_:cal:today:)` 判断周期模式是否命中今天（daily 总是 true，weekly 看 weekdays，monthly 看 monthDays）。

### 9.2 BackupService（`Services/BackupService.swift`）

`enum BackupService`（无实例），负责 JSON 全量备份/恢复。

**Snapshot DTO**（`schemaVersion = 1`）：

| DTO | 字段 |
|---|---|
| `TagDTO` | id / name / colorHex / createdAt |
| `ReportDTO` | id / date / note / createdAt / updatedAt / tagIds |
| `TodoDTO` | id / title / notes / isDone / dueDate / createdAt / completedAt / tagIds |
| `EntryDTO` | id / title / detail / timestamp / kind / finishDate / helper / blockerStatus / priority / isRecurring / recurrenceUnit / recurrenceInterval / recurrenceWeekdays / recurrenceMonthDays / createdAt / tagIds |
| `MeetingDTO` | id / topic / summary / timestamp / createdAt / isRecurring / recurrenceUnit / recurrenceInterval / recurrenceWeekdays / recurrenceMonthDays / tagIds / reviewIds |
| `ReviewDTO` | id / reviewer / opinion / order / createdAt / meetingId? |

**方法**：

- `snapshot(in:) -> Snapshot` — 6 个 `FetchDescriptor` 遍历，关系展平成 id 数组
- `encode(_:) -> Data` / `decode(_:) -> Snapshot` — ISO8601 日期，pretty + sortedKeys
- `restore(_:in:) throws`：
  1. **先写 pre-import 快照**（中途失败可手动恢复）
  2. 逐实例删除全部 6 张表（避免 batch delete 的元类型推断问题；顺序：Review → Meeting → WorkEntry → TodoItem → DailyReport → Tag）
  3. 按 `Tag → DailyReport → TodoItem → WorkEntry → Meeting → Review` 顺序插入
  4. 用 `[UUID: Tag]` / `[UUID: Meeting]` 字典重建关系；UUID 后置赋值（`id` 是 `var`）
- `autoBackup(in:) -> URL?` / `writeBackup(snapshot:prefix:) -> URL?` — 写到 `backups/<prefix>-<ISO8601>.json`
- `pruneOldBackups(prefix:)` — 按 prefix 仅保留最近 10 个
- `backupDirectory: URL` — `~/Library/Application Support/com.zhyu.dailyreport/backups/`（不存在则创建）

### 9.3 ExportService（`Services/ExportService.swift`）

`@MainActor final class ExportService`，单例 `shared`。

**当前 UI 暴露的方法**：

- `exportWeekDoneXLSX(_ entries: [WorkEntry], title: String)` — 仅 `.done`，按 `finishDate ?? timestamp` 升序，列 `[星期, 日期, 标题, 详情]`

**保留但 UI 未暴露**（历史路径，避免破坏代码）：

- `exportDay(_:)` / `exportWeek(_:title:filename:)` — Markdown
- `exportEntriesXLSX(_:)` — 全部任务 XLSX
- `exportTodosCSV(_:)` — 待办 CSV

**辅助**：

- `DayData` struct — `day / entries / report`，周报页 dayBlock 用
- `weekdayName(_:)` — Calendar weekday（1=周日 … 7=周六）→ 中文「周日…周六」
- `sanitizeSheetName / sanitizeFilename` — Excel 工作表名 ≤31 字符禁用字符 / 文件名禁用 `/` `:`
- `save(filename:content:)` / `writeXLSX(...)` — NSSavePanel + 写盘 + beep

### 9.4 XLSXWriter + ZipBuilder（`Services/XLSXWriter.swift`）

**XLSXWriter**：

- 单工作表，全部以 `inlineStr` 存字符串（不用 sharedStrings，简化）
- 5 个 XML 部件：`[Content_Types].xml` / `_rels/.rels` / `xl/workbook.xml` / `xl/_rels/workbook.xml.rels` / `xl/worksheets/sheet1.xml`
- `escape(_:)` 处理 XML 4 个保留字符 + 过滤 XML 1.0 非法控制字符（保留 `\t \n \r`）
- `columnLetter(_:)` 1→A, 26→Z, 27→AA

**ZipBuilder**：

- 仅 `stored` 无压缩（XLSX 部件本就小）
- Local file header + Central directory + End of central directory 三段
- `crc32(_:)` 标准实现（0xEDB88320 多项式）
- `dosDateTime(_:)` DOS 时间戳编码

### 9.5 ReminderService（`Services/ReminderService.swift`）

`@MainActor final class ReminderService`，单例 `shared`。

- `requestAuthorization() async -> Bool` — `requestAuthorization(options: [.alert, .sound])`
- `currentAuthorization() async -> Bool` — 查 `notificationSettings().authorizationStatus == .authorized`
- `reschedule(enabled:hour:minute:)` — 先 `removePendingNotificationRequests([id])`，enabled 时建 `UNCalendarNotificationTrigger(repeats: true)` + `UNNotificationRequest` add
- 通知文案固定：「该写日报啦 ✍️」/「花两分钟记录今天的工作吧。」
- identifier `daily-report-reminder`

### 9.6 BackupService 与 DailyReportApp 的协作（wipe 兜底）

`DailyReportApp.wipeDefaultStore()` 流程：

1. 列两个候选 store URL（`default.store` 与 `com.zhyu.dailyreport/default.store`）
2. 对存在的 store 调 `snapshotToBackup(storeURL:)`：临时开 container → `BackupService.autoBackup` → 写 `auto-*.json`
3. 删除 `default.store{,-wal,-shm}`
4. 重建空 container

无法打开（store 已损坏）就跳过备份 —— 数据本就救不回。用户可从设置页「打开备份文件夹」手动恢复。

## 10. 关键流程图解

### 10.1 添加任务

```
菜单栏 addBar / 时间线 addBar
  → add()
    → trim title 非空校验
    → 按 kind 决定 finishDate / helper / recurring
    → context.insert(WorkEntry(...))
    → 重置输入（newFinishDate = Date()，下次默认今天）
```

### 10.2 完成计划任务

```
入口（任选其一）：
  - 菜单栏面板 entryRow 完成圆圈
  - 概要计划列表 plannedRow 完成圆圈 / 右键「标记完成」
  - 时间线拖到「完成」列
  - 待办页 plannedRow 完成按钮
    ↓
RecurrenceService.markDone(entry, in: context)
  → 若 isRecurring && wasPlanned：
      WorkEntry.spawnNextRecurrence(of: entry, in: context)
        （用 entry.finishDate 当锚点 → nextRecurrenceDate → 新建 .planned）
  → entry.kind = .done
  → 若 wasPlanned || finishDate == nil：
      entry.finishDate = Date()
    ↓
SwiftData autosave 持久化
    ↓
原任务从「计划列表」消失，落入「今日记录·完成组」
下一期克隆出现在「计划列表」（如果是周期性）
```

### 10.3 跨日推进

```
系统发 NSCalendarDayChanged
    ↓
DailyReportApp 监听闭包（.main 队列 + MainActor.assumeIsolated）
  → RecurrenceService.sweepMeetings (推进会议 + 回拉 + 残留清理)
  → RecurrenceService.sweepWorkEntries (推进周期计划 finishDate)
    ↓
WeeklyReportView 另一监听 → weekAnchor = Date()（周报自动回本周）
```

### 10.4 数据导入

```
设置页「从 JSON 导入…」
  → NSOpenPanel 选 .json
  → pendingRestore = data
  → alert「导入会清空当前数据」二次确认
    → confirmImport()
      → BackupService.decode(data) -> Snapshot
      → BackupService.restore(snap, in: context)
          1. writeBackup(snapshot: 当前数据, prefix: "pre-import")  ← 先留快照
          2. 逐实例删 6 张表
          3. 按 Tag → DailyReport → TodoItem → WorkEntry → Meeting → Review 插入
             （UUID 后置赋值；Tag/Meeting 用字典重建关系）
          4. try context.save()
      → 成功 beep / 失败 restoreError alert
```

### 10.5 Schema 迁移失败容错

```
DailyReportApp.init()
  → try ModelContainer(for: 6 模型)
  → catch:
    → wipeDefaultStore()
        1. snapshotToBackup(storeURL)
             → 临时只读 ModelContainer(url: 旧 store)
             → BackupService.autoBackup → auto-*.json
        2. 删 default.store{,-wal,-shm}
    → retry ModelContainer(for: 6 模型)
      → 成功 → 启动（用户从设置页「打开备份文件夹」恢复）
      → 失败 → fatalError
```

## 11. 数据安全策略

| 触发点 | 备份位置 | 前缀 | 保留 |
|---|---|---|---|
| Schema 迁移失败 wipe 前 | `~/Library/Application Support/com.zhyu.dailyreport/backups/` | `auto-` | 最近 10 |
| JSON 导入前 | 同上 | `pre-import-` | 最近 10 |
| 用户手动导出 | 用户选择（NSSavePanel） | — | — |

- 格式：JSON（`Snapshot` 含扁平化 DTO，关系用 UUID 数组表达）
- 编码：ISO8601 日期、pretty + sortedKeys（diff 友好）
- 恢复：UUID 保留（同一条数据导入后 id 不变）

## 12. 设置项一览

| 组 | 项 | 存储 | 默认 |
|---|---|---|---|
| 通用 | 外观 | `@AppStorage("appearance")` Int（AppearanceMode.rawValue） | 0（跟随系统） |
| 通用 | 开机自启 | `SMAppService.mainApp.status`（无 UserDefaults） | off |
| 每日提醒 | 启用 | `@AppStorage("reminderEnabled")` Bool | true |
| 每日提醒 | 时分 | `@AppStorage("reminderHour"/"reminderMinute")` Int | 18:30 |
| 每日提醒 | 授权 | 系统通知设置 | — |
| 数据 | 导出/导入 JSON | 文件系统 | — |
| 数据 | 打开备份夹 | Finder | — |

## 13. 构建与签名

### 13.1 Package.swift

```swift
// swift-tools-version: 6.0
let package = Package(
    name: "DailyReport",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "DailyReport", path: "Sources/DailyReport")]
)
```

### 13.2 scripts/build-app.sh 流程

1. `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`（CLT 缺 SwiftData 宏插件，必须完整 Xcode）
2. `swift build -c release`
3. 拷贝二进制 + Info.plist（从 template 渲染）到 `DailyReport.app/Contents/{MacOS,Resources}/`
4. `codesign --force --deep --sign - "$APP"`（ad-hoc 签名，`SMAppService` 注册登录项的必要条件）
5. `touch`（注册 LaunchServices）

### 13.3 Info.plist 关键键

- `LSUIElement = true` — 纯菜单栏，不占 Dock
- `CFBundleIdentifier = com.zhyu.dailyreport`
- `CFBundleName = DailyReport`

### 13.4 常用命令

```bash
# 构建 + 重启
pkill -f DailyReport.app; sleep 1
bash scripts/build-app.sh && open DailyReport.app

# 卸载
rm -rf DailyReport.app
```

## 14. 已知限制

- **SourceKit 诊断误报**：非 Xcode 环境（VS Code + SourceKit）索引时，`@Model` 宏生成的 `PersistentModel / Identifiable` conform 不被识别，显示大量红色诊断；`swift build` 编译实际正常。需用完整 Xcode 环境索引。
- **SMAppService 签名要求**：ad-hoc 签名在大多数 macOS 版本能注册登录项，个别版本可能拒绝；失败时开关自动回滚 + 蜂鸣，回退到系统设置手动加登录项。
- **周报过度推进回拉窗口**：仅对 8 天内的过度推进做恢复，月度会议跨更长时间不恢复。
- **导出**：当前仅 UI 暴露周报 XLSX（带星期列，按完成日排序）。概要/时间线的历史 Markdown/CSV 导出入口已移除（代码路径保留，未在 UI 暴露）。
- **无云同步**：纯本地 SwiftData store；跨设备需手动 JSON 导出/导入。
- **无 VersionedSchema**：schema 变更依赖 SwiftData 轻量迁移；迁移失败靠 wipe + auto-backup 兜底（个人工具的权衡）。

## 15. 未来可能扩展（未实现）

- iCloud 同步（CloudKit + NSPersistentCloudKitContainer / SwiftData cloud sync）
- AI 周报总结（基于周内 WorkEntry + Meeting summary 生成草稿）
- 全局快捷键唤起菜单栏面板
- 多账号 / 团队共享
- iOS 端只读查看（通过导出的 JSON）
