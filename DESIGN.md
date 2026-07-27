# DailyReport 详细设计方案

> 一份覆盖「每个功能 → 每张表 → 每个字段 → 每个视图 → 每个服务」的实现说明书。
> README.md 面向使用者，本文档面向维护者。

## 1. 产品概述

**DailyReport** 是一款 macOS 菜单栏日报助手，定位为「常驻菜单栏的轻量个人日报工具」。

- **运行形态**：`LSUIElement = true`，纯菜单栏应用，不占 Dock、不出现在 Cmd+Tab 应用切换器
- **目标用户**：需要每日记录工作内容、跟踪计划、复盘会议、生成周报的个人开发者 / 知识工作者
- **核心价值闭环**：
  - **随手记** — 菜单栏图标 → 弹出面板 → 三秒落一条
  - **全局看** — 主窗口四 Tab：概要 / 时间线 / 会议纪要 / 周报（R19 已删独立的待办 Tab，TodoItem 模型保留作为后续扩展）
  - **自动汇总** — 周期推进（会议 + 计划任务）+ 周报导出（XLSX，按星期组织）
- **设计原则**：
  - 极简第三方依赖（仅 GRDB.swift；XLSX / ZIP / JSON 备份 / 日志全自写）
  - 单条滚动记录（周期性会议/计划原地推进，不克隆历史；只有「完成」走克隆路径留痕）
  - 个人本地工具（不做多用户、不做云同步；数据安全靠 JSON 快照 + 自动备份兜底）
  - 错误显式反馈（R14-R20：所有写操作走 view 内 `write { try ... }` helper + `WriteErrorAlertModifier` 统一暴露失败，杜绝 `store?.run` 吞 throws 导致 UI 假成功）

## 2. 整体架构

### 2.1 三 Scene 共享 AppStore

App 由三个 SwiftUI Scene 组成，共享同一个 `AppStore`（持有 GRDB `DatabaseQueue` 的 `@Observable @MainActor` 单例）：

```
@main DailyReportApp
├── MenuBarExtra                ← 菜单栏图标 ✅ checklist + 弹出面板（MenuPanelView）
│   .menuBarExtraStyle(.window) ← 系统托管窗口，点外部自动收起
├── Window("DailyReport", id: AppState.mainWindowID)
│   └── MainTabView             ← 主窗口四 Tab
└── Settings
    └── SettingsView            ← 系统设置窗
```

三个 Scene 的根视图均挂 `.environment(\.appStore, store)` 注入同一个 `AppStore` 实例，并统一挂 `.preferredColorScheme(colorScheme)`，由 `@AppStorage(AppState.Key.appearance)` 驱动（跟随系统 / 浅色 / 深色），保证菜单栏面板、主窗口、设置窗三处外观一致。

### 2.2 启动流程

`DailyReportApp.init()`（顺序至关重要，每步失败都不阻断后续）：

1. **`AppLogger.migrateFromLegacyIfNeeded()`** — 一次性把日志从 `db/logs/` 迁到 app 同级 `logs/`（旧目录已空时一并删除）
2. **`AppDatabase.openOrRecover()`** — 打开 / 迁移 GRDB 主库（三级容错链路，详见 9.6）
   - 主库 `db/db.sqlite` 能打开 → 跑 `AppMigrator` 迁移（v1_initial + v2_unique_daily_report_date + v4_unique_tag_name + v5_unique_review_meeting_order）→ 返回 `OpenResult(recovered: false)`
   - 主库失败 → `archiveCorruptedDB` 把 `db.sqlite{,-wal,-shm}` 整体移到 `db/corrupted/<ISO>/` → `snapshotToBackup` 用只读 GRDB 打开归档文件抢救 JSON（`salvage-*.json`）→ 主路径空库重建
   - 主路径仍失败 → 切到 `db/db.fallback.sqlite`（最后兜底）
   - 全部失败 → `fatalError`（极端情况）
3. **`AppDatabase.pruneCorruptedArchives(keepCount: 5)`** — 清理 `db/corrupted/` 下旧归档，按 ISO 目录名字典序倒序保留最近 5 份
4. **创建 `AppStore(dbQueue:)`** — 持有 `DatabaseQueue`，初始化只读快照（`reloadAll` 拉全表 + 关系映射）
5. **启动 sweep**：
   - `RecurrenceService.sweepAll(in: store)` — 单事务推进周期会议 + 计划任务（R17 合并：原版分两次 `transactional` 调用存在「会议推进成功 + 计划失败」的部分提交风险，合并后任一失败整体回滚）
6. **周备份 + 启动备份**：
   - `BackupService.weeklyBackupIfDue(in:)` — 周五~周日窗口：先清理上月 + 硬上限 12 份，再按「本周一」weekKey 写 `weekly-*.json`（已写过则跳过）
   - `BackupService.bootBackup(in:)` — 今日已写 weekly 时跳过；否则删今天的 `boot-*.json` 后重写一份
7. **注册跨日监听** `NSCalendarDayChanged`：菜单栏 app 常开数天，午夜跨日时再触发一次 sweep + `weeklyBackupIfDue`（避免过了零点还看到「昨天」的周期项卡在逾期）
   - `MainActor.assumeIsolated` 包裹闭包，满足 Swift 6 严格并发
8. **`warnIfLegacyDataRemains()`** — 检测 `~/Library/Application Support/com.zhyu.dailyreport/default.store` 是否残留旧 SwiftData 库；首次告警后写 `logs/.swiftdata_warned` 标志位，避免每次启动重复噪音（不自动删，提醒用户手动清理）

### 2.3 数据流

- 所有视图通过 `@Environment(\.appStore)` 拿到 `AppStore`，直接读其只读快照属性（`entries / meetings / tags / ...` + 关系映射 `tagsByEntry / reviewsByMeeting / ...`），无 ViewModel 中间层
- `AppStore` 是 `@Observable @MainActor`，快照属性 `private(set)`，外部只读；`reloadAll()` 后 SwiftUI 自动刷新
- 写入统一走 `AppStore`：`insertXxx / updateXxx / deleteXxx / setXxxTags / markEntryDone / ...`。每个写方法内部调 `writeOrThrow` → `dbQueue.write`（同步事务）→ `reloadAll()` 触发 @Observable → UI 刷新
- **View 层写入口模式**（R14-R20 演进）：所有写操作在 view 内定义 `private func write(_ block: (AppStore) throws -> Void)` helper（或返回 Bool 的 `writeForDrop`），失败时把 `error.localizedDescription` 写入 `@State var writeError: String?`；body 末尾挂 `.writeErrorAlert($writeError)`（统一弹「写入失败」alert）。需要拿到返回值或精确错误处理的场景（如 `getOrCreateReport` / Settings 的 restore）仍直接走 throws API
- 内联编辑（会议概要等）使用本地 `@State` 草稿 + `.onChange` guard + `.onDisappear` 三重保险写回 store（GRDB 无 SwiftData autosave，必须显式调用 store 写方法）；`MenuPanelView` 面板额外监听 `NSApplication.willResignActiveNotification` 兜底 flush（面板隐藏 ≠ view onDisappear）
- 状态变量 `@State` 用于输入栏草稿、选中标签、折叠状态、内联编辑草稿等 UI 局部状态
- **reloadAll 失败语义**（R21-B）：原版只 `AppLogger.error` 不清空内存快照，与「杜绝假成功」哲学相悖——reload 失败后内存与磁盘已脱节，UI 继续显示陈旧数据等于假数据。改为：失败时把 6 个实体数组 + 5 个关系映射全部置空，UI 显示空状态而非误导。配合 `writeErrorAlert` 形成完整的「写失败 / 读失败」反馈链路


## 3. 技术栈

| 层 | 技术 | 说明 |
|---|---|---|
| 语言 | Swift 6（严格并发） | `swift-tools-version: 6.0` |
| UI | SwiftUI（macOS 14+） | `platforms: [.macOS(.v14)]` |
| 持久化 | GRDB.swift 6.29+ | SQLite（`db/db.sqlite` + WAL），`Database/` 目录封装 6 主表 + 4 中间表 + AppStore |
| 通知 | UserNotifications | `UNCalendarNotificationTrigger` 重复触发每日提醒 |
| 开机自启 | ServiceManagement `SMAppService.mainApp` | 注册登录项，首次开启系统授权一次 |
| 构建 | SwiftPM + `scripts/build-app.sh`（纯 CLT 即可） | release 构建 + 打包 `.app` + ad-hoc 签名 |
| 第三方依赖 | GRDB.swift（唯一） | XLSX / ZIP / JSON 备份 / 日志全自写 |

## 4. 目录结构

```
Sources/DailyReport/
├── DailyReportApp.swift           # @main，三 Scene + 启动 sweep + 跨日监听 + 容错链路
├── AppState.swift                 # 常量、UserDefaults Key、AppearanceMode 枚举
├── NavigationCoordinator.swift    # 主窗口 Tab 选中态（AppTab enum）+ 跨页跳转请求
├── Database/                      # GRDB 持久层（6 文件）
│   ├── Records.swift              # 6 主表 struct + 4 中间表 struct + 4 枚举 DatabaseValueConvertible + IntArrayJSON + 草稿（NewXxx）
│   ├── Migrator.swift             # AppMigrator（v1_initial + v2/v4/v5 去重 + UNIQUE 索引）
│   ├── AppDatabase.swift          # 三级容错：openOrRecover / archiveCorruptedDB / snapshotToBackup / pruneCorruptedArchives
│   ├── AppStore.swift             # @Observable @MainActor，持有 dbQueue，只读快照 + 集中写入口 + markEntryDone + truncateAll
│   ├── RecordQueries.swift        # JOIN helper：fetchTagMap / fetchReviewsByMeeting
│   └── AppStoreEnvironment.swift  # EnvironmentKey（\.appStore）+ View.appStore(_:) 便捷注入
├── Models/
│   ├── WorkEntry.swift            # 4 个枚举（WorkKind/BlockerStatus/RecurrenceUnit/Priority）
│   └── Recurrence.swift           # 周期计算纯函数 + RecurrenceCapable 协议（R24-D，WorkEntryRecord/MeetingRecord 共享 recurrenceLabel）
├── Views/
│   ├── MainTabView.swift          # 4 Tab（概要/时间线/会议/周报），环境注入 coordinator
│   ├── TodayView.swift            # 概要：统计条 + 今日记录 + 计划列表 + 会议（含 todayMeetingRow 内联概要编辑）
│   ├── HistoryView.swift          # 时间线三列看板 + 搜索 + 拖拽 + 优先级/状态分组
│   ├── MeetingView.swift          # 会议列表 + 卡片 + 新增/编辑表单（ReviewDraft）
│   ├── WeeklyReportView.swift     # 周报：按归属日分天 + 统计卡 + XLSX 导出
│   ├── MenuPanelView.swift        # 菜单栏弹出面板（含 MeetingPanelRow 内联概要编辑）
│   └── SettingsView.swift         # 设置：通用/提醒/数据/快捷键/关于
├── Components/
│   ├── WorkEntryCard.swift        # 任务卡片（编辑/CRUD/拖拽源，R23-I 从 WorkSummaryView 拆出）
│   ├── WorkSummaryView.swift      # 只读汇总（按 kind 分组，R23-I 拆出后仅 83 行）
│   ├── BadgeChip.swift            # 统一胶囊徽章（Priority/Blocker/Overdue/Recurrence/Tag，R23-E 13+ 处去重）
│   ├── TagPicker.swift            # 完整版 + 紧凑版 + ColorSwatchPicker
│   ├── TagFilterMenu.swift        # 顶部标签筛选下拉菜单（R19 从 HistoryView 抽出复用）
│   ├── WriteErrorAlert.swift      # ViewModifier：统一 .writeErrorAlert（R26-E 加 title 参数）+ 共享 performWrite helper（R20/R23-D）
│   ├── NewEntryDraft.swift        # @Bindable 草稿：HistoryView/MenuPanelView 共用（R19 抽出）
│   ├── InlineSummaryEditor.swift  # 会议概要内联编辑器（R21-C 抽出，3 处复用，Style 参数化样式）
│   ├── KindPicker.swift           # 完成/计划/问题 三色胶囊
│   ├── RecurrenceEditor.swift     # 周期编辑（开关 + 单位 + 上下文选项）
│   ├── FlowLayout.swift           # 自定义 Layout，标签自动换行
│   ├── EmptyStateView.swift       # 大图标 + 标题 + 副标题
│   ├── DaySlice.swift             # 「某天的时间切片」过滤辅助（R24-B 抽出，TodayView/MenuPanelView 共用）
│   ├── CrossMidnightTick.swift    # 跨午夜 Timer+NSCalendarDayChanged ViewModifier（R25-E 抽出，3 处复用）
│   ├── CollapsiblePrioritySection.swift  # 可折叠优先级分组（R25-B 抽出，HistoryView planned/blocker 列共用）
│   └── SharedExtensions.swift     # Color(hex) / Date helpers / Calendar helpers / String.isBlank+trimmed（R24-E）
└── Services/
    ├── RecurrenceService.swift    # sweepAll（单事务：sweepMeetings + sweepWorkEntries）
    ├── BackupService.swift        # DTO + Snapshot + encode/decode + restore（R23-H 拆分主文件）
    ├── BackupService+Snapshot.swift # snapshotAtomic + record→DTO 映射 + 容错抢救（R23-H）
    ├── BackupService+Files.swift  # boot/manual/weekly 触发 + 文件名约定 + prune 策略（R23-H）
    ├── AppLogger.swift            # error/warn/info/debug + 文件滚动 + NSLock + os.Logger 镜像
    ├── ExportService.swift        # 周报 XLSX + Markdown（旧路径，已不在 UI 暴露）
    ├── XLSXWriter.swift           # 单表 XLSX 写入 + ZipBuilder（stored 无压缩）
    └── ReminderService.swift      # 单例，UNUserNotificationCenter 包装
scripts/build-app.sh                # swift build -c release + 打包 + ad-hoc codesign + touch（纯 CLT）
Resources/Info.plist.template       # LSUIElement=true / CFBundleIdentifier=com.zhyu.dailyreport
Tests/DailyReportTests/             # Swift Testing 套件，453 tests / 44 suites（详见 14.测试）
```

## 5. 数据模型（详细字段说明）

### 5.1 实体关系总览

```
DailyReport 1───* Tag *───* WorkEntry     （通过 tag_daily_report / tag_work_entry 中间表）
                           *───* Meeting 1───* Review
                           *───* TodoItem  （通过 tag_meeting / tag_todo 中间表）
```

- **Tag** 是中心枢纽，通过 4 张中间表与 DailyReport / WorkEntry / Meeting / TodoItem 建立多对多（复合主键 + 双向 `ON DELETE CASCADE`）
- **Meeting → Review** 一对多，`review.meetingId` 外键 + `ON DELETE CASCADE`（会议删除连带评审）
- **DailyReport.date 加 UNIQUE 约束**（v2 迁移）：杜绝 `getOrCreateReport` 多窗口并发时的 TOCTOU 竞态产生重复行
- 所有 Record 都是 `struct : FetchableRecord, MutablePersistableRecord, Identifiable`，主键 `id` 存为 `TEXT`（`UUID.uuidString`）。没有 `VersionedSchema`（GRDB 用 `DatabaseMigrator`，当前 `v1_initial` + `v2_unique_daily_report_date` + `v4_unique_tag_name` + `v5_unique_review_meeting_order`，无 v3）
- 关系不直接持有：Record 里没有 `tags: [TagRecord]` / `reviews: [ReviewRecord]` 字段，而是由 `AppStore` 在 `reloadAll()` 时通过 `RecordQueries` 一次性 JOIN 拉取，暴露为 `tagsByEntry / reviewsByMeeting` 等关系映射字典
- **CASCADE 在迁移期不生效**：GRDB `DatabaseMigrator.foreignKeysEnabled` 默认 false（防 schema 变更被 FK 拦截），任何依赖 CASCADE 的 migration 必须显式 DELETE 子表关系（v2 即如此）

### 5.2 WorkEntryRecord（核心实体：工作任务）

文件：`Database/Records.swift`（`struct WorkEntryRecord`）。时间线/概要/周报/待办均围绕此 Record。

| 字段（DB 列） | SQLite 类型 | Swift 类型 | 默认 | 用途 |
|---|---|---|---|---|
| `id` | TEXT (PK) | `UUID`（存 `uuidString`） | 新建 | 唯一标识，drag-and-drop 用 `uuidString` 传递 |
| `title` | TEXT NOT NULL | `String` | 必填 | 任务标题（去空格后非空才能提交） |
| `detail` | TEXT NOT NULL | `String` | `""` | 详情，可选，多行 |
| `timestamp` | DATETIME NOT NULL | `Date` | `Date()` | 发生/记录时间，时间线排序与「问题归属日」用 |
| `kindRaw` | TEXT NOT NULL | `String` | `"完成"` | `WorkKind` 的 raw 值；通过 computed `kind` 读写 |
| `finishDate` | DATETIME | `Date?` | `nil` | 完成/计划完成日（语义见下） |
| `helper` | TEXT | `String?` | `nil` | 问题类的「求助人」 |
| `blockerStatusRaw` | TEXT NOT NULL | `String` | `"Ongoing"` | `BlockerStatus` raw 值 |
| `priorityRaw` | TEXT NOT NULL | `String` | `"Medium"` | `Priority` raw 值 |
| `isRecurring` | BOOLEAN NOT NULL | `Bool` | `false` | 是否周期性计划（仅 `.planned` 有意义） |
| `recurrenceUnitRaw` | TEXT NOT NULL | `String` | `"每天"` | `RecurrenceUnit` raw 值 |
| `recurrenceInterval` | INTEGER NOT NULL | `Int` | `1` | 仅「每天」用，最小 1 |
| `recurrenceWeekdays` | TEXT NOT NULL | `[Int]`（JSON via `IntArrayJSON`） | `"[]"` | Calendar weekday（1=周日 … 7=周六） |
| `recurrenceMonthDays` | TEXT NOT NULL | `[Int]`（JSON via `IntArrayJSON`） | `"[]"` | 1…31 |
| `createdAt` | DATETIME NOT NULL | `Date` | `Date()` | 创建时刻（不变） |

> 标签关系不在 Record 里持有：`AppStore.tagsByEntry[entryId]` 返回 `[TagRecord]`，中间表 `tag_work_entry` 维护映射。

**Computed 属性**：

- `kind: WorkKind` — get/set 委托 `kindRaw`，fallback `.done`
- `blockerStatus / priority / recurrenceUnit` — 同上
- `isOverdue: Bool` — `kind == .planned && startOfDay(finishDate) < startOfDay(today)`，仅计划任务会逾期
- `recurrenceLabel: String` — 委托 `Recurrence.label(...)`，如「每周一三五」「每月1日、15日」
- `day: Date` — `startOfDay(timestamp)`，问题归属日

**关键方法**：

- `nextRecurrenceDate() -> Date` — 基于 `finishDate ?? Date()` 调 `Recurrence.nextFutureDate`
- 完成时的克隆逻辑由 `AppStore.markEntryDone(_:)` 统一处理（事务内克隆下一次 + 原地降级为 done，详见 6.5）

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

> 所有枚举都用「`*Raw` 字段 + computed 转换」的方式存到 GRDB。四个枚举均 conform `DatabaseValueConvertible`（沿用 rawValue 字符串），由 GRDB 直接序列化到 TEXT 列；raw String 更利于备份 JSON 的前向兼容。

### 5.3 MeetingRecord（会议纪要）

文件：`Database/Records.swift`（`struct MeetingRecord`）。

| 字段（DB 列） | SQLite 类型 | Swift 类型 | 默认 | 用途 |
|---|---|---|---|---|
| `id` | TEXT (PK) | `UUID` | 新建 | |
| `topic` | TEXT NOT NULL | `String` | 必填 | 会议主题（去空格非空才能保存） |
| `summary` | TEXT NOT NULL | `String` | `""` | 会议概要，多行 |
| `timestamp` | DATETIME NOT NULL | `Date` | `Date()` | 会议时间（也作周期推进锚点） |
| `createdAt` | DATETIME NOT NULL | `Date` | `Date()` | |
| `isRecurring` | BOOLEAN NOT NULL | `Bool` | `false` | 周期性会议 |
| `recurrenceUnitRaw` | TEXT NOT NULL | `String` | `"每天"` | |
| `recurrenceInterval` | INTEGER NOT NULL | `Int` | `1` | |
| `recurrenceWeekdays` | TEXT NOT NULL | `[Int]`（JSON） | `"[]"` | |
| `recurrenceMonthDays` | TEXT NOT NULL | `[Int]`（JSON） | `"[]"` | |

> 评审关系通过 `ReviewRecord.meetingId` 外键（`ON DELETE CASCADE`）；标签关系通过 `tag_meeting` 中间表。`AppStore.reviewsByMeeting[meetingId]` / `tagsByMeeting[meetingId]` 返回关系数组。

**Computed**：

- `recurrenceUnit: RecurrenceUnit` — raw 转换
- `recurrenceLabel: String` — 同 WorkEntryRecord
- `day: Date` — `startOfDay(timestamp)`

**方法**：

- `nextFutureOccurrence(from now: Date = Date()) -> Date` — 委托 `Recurrence.nextFutureDate(after: timestamp, now: now)`，**注意锚点是 `timestamp` 而非 `now`**，用于 sweep 推进时算「下一期」

### 5.4 ReviewRecord（评审意见）

文件：`Database/Records.swift`（`struct ReviewRecord`）。

| 字段（DB 列） | SQLite 类型 | Swift 类型 | 默认 | 用途 |
|---|---|---|---|---|
| `id` | TEXT (PK) | `UUID` | 新建 | |
| `reviewer` | TEXT NOT NULL | `String` | 必填（或 opinion 非空） | 评审人姓名 |
| `opinion` | TEXT NOT NULL | `String` | `""` | 评审意见 |
| `order` | INTEGER NOT NULL | `Int` | `0` | 在会议中的顺序（`AppStore.reviewsByMeeting` 已按 `order` 升序） |
| `createdAt` | DATETIME NOT NULL | `Date` | `Date()` | |
| `meetingId` | TEXT | `UUID?` | `nil` | 外键 → `meeting.id`，`ON DELETE CASCADE` |

> 索引：`on_review_meetingId` 加速按会议查询。

### 5.5 TagRecord（多对多枢纽）

文件：`Database/Records.swift`（`struct TagRecord`，表名 `tag`）。

| 字段（DB 列） | SQLite 类型 | Swift 类型 | 默认 | 用途 |
|---|---|---|---|---|
| `id` | TEXT (PK) | `UUID` | 新建 | |
| `name` | TEXT NOT NULL | `String` | 必填 | |
| `colorHex` | TEXT NOT NULL | `String` | `"#4A90D9"` | `#RRGGBB` |
| `createdAt` | DATETIME NOT NULL | `Date` | `Date()` | |

**Computed**：`swiftUIColor: Color` — `Color(hex: colorHex) ?? .accentColor`

> 多对多关系全部通过 4 张中间表维护（`tag_daily_report` / `tag_todo` / `tag_work_entry` / `tag_meeting`），每张表都是 `(tagId, ownerId)` 复合主键 + 双向 `ON DELETE CASCADE`：删 Tag 时中间表行自动级联删，删 Owner 时 likewise。`AppStore` 在 `reloadAll()` 时用 `RecordQueries.fetchTagMap` 一次性 JOIN 拉取，暴露为 `tagsByReport / tagsByTodo / tagsByEntry / tagsByMeeting`。

### 5.6 DailyReportRecord（日报元数据）

文件：`Database/Records.swift`（`struct DailyReportRecord`，表名 `daily_report`）。

| 字段（DB 列） | SQLite 类型 | Swift 类型 | 默认 | 用途 |
|---|---|---|---|---|
| `id` | TEXT (PK) | `UUID` | 新建 | |
| `date` | DATETIME NOT NULL | `Date` | 归一化 0:00 | 当天标识（init 时 `startOfDay`） |
| `note` | TEXT NOT NULL | `String` | `""` | 手写备注 |
| `createdAt` | DATETIME NOT NULL | `Date` | `Date()` | |
| `updatedAt` | DATETIME NOT NULL | `Date` | `Date()` | |

> 标签关系通过 `tag_daily_report` 中间表，`AppStore.tagsByReport[reportId]` 返回。

**方法（在 AppStore）**：`getOrCreateReport(for date: Date) throws -> DailyReportRecord` — 按 `isDate(inSameDayAs:)` 在内存快照查，无则 insert。TodayView `.task` 阶段调用，保证打开页面就有 `report`。

> 任务汇总**不**存在 DailyReport 上，由 `WorkEntry` 按「归属日」动态聚合，避免双写不一致。

### 5.7 TodoItemRecord（独立待办）

> **注**：R19 已删除「待办」Tab，`TodoListView.swift` 同步删除。表与 Record 保留作为后续扩展占位，当前无 UI 调用方；`AppStore.todos / tagsByTodo` 仍会加载（保留数据，便于未来恢复）。

文件：`Database/Records.swift`（`struct TodoItemRecord`，表名 `todo_item`）。

| 字段（DB 列） | SQLite 类型 | Swift 类型 | 默认 | 用途 |
|---|---|---|---|---|
| `id` | TEXT (PK) | `UUID` | 新建 | |
| `title` | TEXT NOT NULL | `String` | 必填 | |
| `notes` | TEXT NOT NULL | `String` | `""` | |
| `isDone` | BOOLEAN NOT NULL | `Bool` | `false` | |
| `dueDate` | DATETIME | `Date?` | `nil` | 截止日期 |
| `createdAt` | DATETIME NOT NULL | `Date` | `Date()` | |
| `completedAt` | DATETIME | `Date?` | `nil` | 完成时刻 |

> 标签关系通过 `tag_todo` 中间表，`AppStore.tagsByTodo[todoId]` 返回。

**Computed**：`isOverdue: Bool` — `dueDate < Date() && !isDone`

### 5.8 Recurrence（纯函数工具）

文件：`Models/Recurrence.swift`。无状态纯函数（不对应任何表）。

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

> WeeklyReportView 的 `belongDate(_:)`、TodayView 的 `todayEntries`、概要计划列表 `isTodayPlanned` 判定**都遵循此语义**。配合 `AppStore.markEntryDone` 完成时把 `finishDate` 改成 `Date()`，提前完成的任务会落到「实际完成那天」而非「计划那天」。

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
private static func isTodayPlanned(_ e: WorkEntryRecord, start: Date, end: Date) -> Bool {
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

1. `isRecurring && timestamp < startOfToday` 的会议 → `try store.updateMeeting(m.id) { $0.timestamp = nextFutureOccurrence(from: startOfToday) }`
   - **按天判定**（不计具体时刻）：今天的周期性会议无论时间是否已过都留在今日
   - **推进目标按天算**（`from: startOfToday`），确保「下一期就是今天」时落在今天而非跳到明天
2. **残留清理**：与某周期会议同主题、自身非周期、无评审、无概要的旧版「克隆+降级」逻辑残留空副本 → `store.deleteMeeting`

**`sweepWorkEntries`**

- `isRecurring && kind == .planned && startOfDay(finishDate) < today` 的任务 → `try store.updateEntry(e.id) { $0.finishDate = Recurrence.nextFutureDate(after: f, now: Date()) ?? f }`
- **原地推进，不克隆**（与会议语义一致）。用户若想留「这期做完了」的痕迹，走完成路径（`AppStore.markEntryDone`）

### 6.5 统一完成路径（AppStore.markEntryDone）

所有「标记完成」入口（菜单栏完成按钮、概要计划列表完成、时间线拖到完成列、待办完成按钮）统一走 `AppStore.markEntryDone(_:)`，整个流程在单个 `dbQueue.write` 事务里完成：

```swift
@discardableResult
func markEntryDone(_ id: UUID) throws -> WorkEntryRecord? {
    guard let original = entries.first(where: { $0.id == id }) else { return nil }
    let wasPlanned = (original.kind == .planned)
    var spawned: WorkEntryRecord?
    try writeOrThrow { db in
        // 1) 若 isRecurring && wasPlanned：克隆下一次（用原 finishDate 当锚点推下一期）
        if original.isRecurring && wasPlanned {
            var next = WorkEntryRecord(... kindRaw: .planned, finishDate: original.nextRecurrenceDate(), ...)
            try next.insert(db)
            // 复制 tag 关系（中间表）
            ...
            spawned = next
        }
        // 2) 原地降级为 done
        guard var rec = try WorkEntryRecord.fetchOne(db, key: id.uuidString) else { return }
        rec.kindRaw = WorkKind.done.rawValue
        // 3) 计划→完成 或 finishDate 为空：finishDate 更新为实际完成日
        if wasPlanned || rec.finishDate == nil { rec.finishDate = Date() }
        try rec.update(db)
    }
    return spawned   // 返回克隆的下一期（若有），供调用方做后续 UI 处理
}
```

**执行顺序至关重要**（单事务内）：

1. 先克隆（用 `original.nextRecurrenceDate()`，依赖**原计划 finishDate** 当锚点推下一期）；克隆体同时复制 tag 关系到 `tag_work_entry`
2. 再把原记录 `kindRaw` 改为 `done`
3. 最后覆盖原记录 `finishDate` 为实际完成时间

提前完成的任务在周报里落回实际完成那天，而下一期计划克隆仍指向正确的未来日期。事务保证三步要么全成功要么全回滚。

### 6.6 跨日监听

`DailyReportApp.init()` 注册 `NSCalendarDayChanged`：

```swift
NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated {
        Self.sweepOnce(appStore)                       // sweepMeetings + sweepWorkEntries
        BackupService.weeklyBackupIfDue(in: appStore)  // 跨午夜后检查是否进入周备份窗口
    }
}
```

WeeklyReportView 另挂一个 `.onReceive(...)` 把 `weekAnchor = Date()`，让周报自动回本周。

## 7. 视图层（每个 Tab / 面板详解）

### 7.1 MenuPanelView（菜单栏弹出面板）

固定尺寸 `380 × 540`，垂直布局 `header / Divider / addBar / Divider / todayList / Divider / footer`。

**Header**：标题「今日日报」+ `Date().friendlyDay` + 右侧 `todayEntries.count` 条。

**addBar**（快速添加）：草稿统一用 `@State private var draft = NewEntryDraft()`（`Components/NewEntryDraft.swift`），与 `HistoryView` 共用，避免两份近 20 个 `@State` 重复。

- `KindPicker`（三色胶囊）— 切换 `draft.kind`
- TextField「刚做了什么？回车添加」+ `plus.circle.fill` 按钮（disabled 当 `!draft.canSubmit`）
- `extraFieldRow`（按 `draft.kind` 分支）：
  - `.done`：完成时间 DatePicker（date only）+ 紧凑 TagPicker
  - `.planned`：计划完成 DatePicker + 优先级 segmented Picker + RecurrenceEditor
  - `.blocker`：求助人 TextField + 状态 segmented Picker + 紧凑 TagPicker
- `add()`：`guard draft.canSubmit` → `draft.consume()` → `store?.run { try $0.insertEntry(entry) }` → `draft.reset()`

**todayList**（ScrollView，分区显示）：

- 三组 `todayEntries`（按 kind 分组，组内按 timestamp 倒序）— 每组带 `sectionHeader`（图标 + 文字 + 计数胶囊）
- 「计划列表」区（非今日计划，按优先级 → 时间排序）
- 「今日会议」区（按 timestamp 升序）：每条由 `MeetingPanelRow` 渲染（见下）

**entryRow(_:)** — 一行任务：

- `.planned` 显示完成圆圈按钮（逾期用 `exclamationmark.circle` 红色，否则 `circle` 灰色）→ 点击调 `store.markEntryDone`
- 其他 kind 显示左侧 3pt 宽彩色竖条（颜色由 kind / blockerStatus 决定）
- 标题 + 逾期/优先级/状态/周期胶囊 + 右侧时间

**footer**：「打开主窗口」+ 设置齿轮 + 退出。

**add()** 重置：`newTitle / selectedTags / newHelper / newFinishDate = Date() / isRecurring / recurrenceWeekdays / recurrenceMonthDays / newBlockerStatus / newPriority` —— 每次添加后下次默认今天。

**MeetingPanelRow**（菜单栏会议行，文件内 `private struct`）：紧凑单行（紫色竖条 + 图标 + 主题 + 周期胶囊 + 时间 + chevron）；**点击整行切换展开**，展开后在下方嵌入紧凑 `TextEditor`（minHeight 28），placeholder「点这里写会议概要…」。编辑用本地 `@State` 草稿，`.onChange` + `.onDisappear` 写回 `store.updateMeeting`；store 是 `@Observable` 单例，写回后概要页 / 会议纪要页自动刷新。

### 7.2 MainTabView

4 Tab（`TabView(selection: $coordinator.selectedTab)`）：

| tag | 标签 | 图标 | 视图 |
|---|---|---|---|
| 0 | 概要 | `sun.max.fill` | TodayView |
| 1 | 时间线 | `clock.arrow.circlepath` | HistoryView |
| 2 | 会议纪要 | `person.3` | MeetingView |
| 3 | 周报 | `doc.text.magnifyingglass` | WeeklyReportView |

> 待办没有独立 Tab，从时间线或菜单栏进入。`.environment(coordinator)` 注入到所有子视图。
>
> `selectedTab` 持久化到 `UserDefaults`（key `com.zhyu.dailyreport.selectedTab`）：`NavigationCoordinator.init()` 读出（合法范围 0..3，越界兜底回 0），`didSet` 写回。冷启动回到上次看的 Tab；程序化跳转（`openMeetingEdit` 设为 2）也写回。所有 UserDefaults key 都加 `com.zhyu.dailyreport.` 前缀（避免与其它工具撞名互覆盖）；`AppState.Key.migrateLegacyKeysIfNeeded()` 一次性把 R7 之前的裸 key 拷到带前缀的新 key。

### 7.3 TodayView（概要）

`.task` 阶段 `store.getOrCreateReport(for: Date())` 取当日 `report`。

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
   - 概要区改为 `TextEditor` 始终显示（本地 `@State` 草稿 + `.onChange`/`.onDisappear` 写回 `store.updateMeeting`），空时 placeholder「点这里写会议概要…」；无需打开「编辑」表单即可改概要

**alert**：「删除这条计划任务？」— `pendingDeleteEntry` 触发。

### 7.4 HistoryView（时间线三列看板）

**BoardItem enum**：把 WorkEntry 和 Meeting 统一成一种看板项；`sortDate` 任务用 `finishDate ?? timestamp`，会议用 `timestamp`。

**布局**（VStack）：

1. **addBar**：`@State private var draft = NewEntryDraft()`（与 MenuPanelView 共用，详见 7.1）；KindPicker + TextField + 完成按钮 + extraFieldRow（更宽版本）
2. **filterBar**：`TagFilterMenu` + 清除筛选
3. **board**：`HStack(alignment: .top)` 三列，**每列独立 ScrollView**（外层无 ScrollView，三列可分别滚动）
4. `.searchable(text: $searchText, placement: .toolbar)` — 搜索标题 / 详情 / 会议主题

**column(_ kind:)**：

- 列头：图标 + 文字 + 计数胶囊
- 卡片列表：
  - `.planned` → `plannedSections`（按优先级高/中/低分组，组头可折叠，整组作 drop 目标，命中后设 `kind=.planned + priority`）
  - `.blocker` → `blockerSections`（**双层嵌套**：外层按优先级高/中/低可折叠，整组作 drop 目标命中后设 `kind=.blocker + priority`；内层按状态「进行中 / 观察中 / 已关闭」**不折叠**，仅当非空时渲染，整子组作 drop 目标命中后同时设 `kind=.blocker + priority + blockerStatus`）
  - `.done` → 平铺
- 列整体作 drop 目标：拖到「完成」走 `store.markEntryDone`，其他列直接 `store.updateEntry { $0.kind = kind }`
- 背景/边框：默认淡色填充，drop target 时加深 + 加粗描边
- 折叠状态分列隔离：`collapsedPriorities`（计划列）、`collapsedBlockerPriorities`（问题列外层），互不影响
- drop target hint 也分列隔离：`dropTargetPriority`（计划列）、`dropTargetBlockerPriority`（问题列外层）、`dropTargetStatus`（问题列内层）

**会议并入看板**：周期性会议**不进看板**（仅作模板），非周期会议按 timestamp 在未来 → 计划列，否则 → 完成列。`MeetingBoardCard` 紧凑卡片，点击 → `coordinator.openMeetingEdit(meeting)` 跳到会议 Tab。

**WorkEntryCard**（`Components/WorkSummaryView.swift`）：

- 只读态：标题 + 优先级徽章（**`.planned` 与 `.blocker` 都显示**，和问题列双层分组对齐）+ 详情 + metaRow（完成日 / 计划日+周期 / 状态+求助人）+ tagRow + 编辑/删除按钮
- 编辑态：标题/详情 TextField + 标签多选 Menu + extraEditRow + 优先级 segmented + 取消/保存
- `.draggable(entry.id.uuidString)` 提供拖拽数据
- 标签行支持右键移除；标签 Menu 支持「新建标签…」popover

### 7.5 TodoListView（已删除 R19）

R19 合并了「待办」与「时间线」：独立待办 Tab 删除，`TodoListView.swift` 同步移除。原计划的「计划任务 Section」由 `TodayView.plannedList` + `HistoryView` 看板列承载；`TodoItemRecord` 表保留供未来扩展。

### 7.6 MeetingView（会议纪要）

**布局**（NavigationStack + ScrollView）：

- 空态：`EmptyStateView("还没有会议纪要")`
- 列表：`LazyVStack` of `MeetingCard`
- toolbar：「+」新增按钮 → `.sheet` 弹 `MeetingFormView`
- `.sheet(item: $editing)` 编辑现有
- `.onChange(of: coordinator.meetingRequest?.id)`：跨页跳转请求 → 设 `editing`

**MeetingCard**：

- 标题 + 周期胶囊 + 相对时间
- **概要内联编辑器**（`summaryEditor` computed，**按时间分支**）：
  - **未来会议**（`meeting.timestamp > Date()`）：本地 `@State` 草稿 + `TextEditor`，空时 placeholder「点这里写概要…」；`.onChange` + `.onDisappear` 写回 `store.updateMeeting`
  - **已完成会议**（`meeting.timestamp ≤ Date()`）：概要回退为只读 `Text` 显示（避免误改历史纪要）；空概要不渲染该区域
  - 无论何时，仍可通过底部「编辑」按钮打开 `MeetingFormView` 修改概要 / 主题 / 时间 / 标签 / 周期 / 评审
- 标签 chips
- 评审区：`validReviews` 计数 + 每条评审（评审人 + 意见引号块）+ 内联新增评审
- 底部：「评审」按钮（展开 inlineAddReviewer）+ 「编辑」按钮（用于改主题/时间/标签/周期/评审等其它字段）

> 会议概要的「随时填写」体验：`MeetingCard`（会议纪要页）按时间分支——未来可内联编辑、已完成只读；`todayMeetingRow`（概要页）与 `MeetingPanelRow`（菜单栏面板）只承载「今日会议」，始终可内联编辑。三个视图各自维护本地 `@State` 草稿，`.onChange`/`.onDisappear` 时写回 `store.updateMeeting`；`AppStore` 是 `@Observable` 单例，任一视图写入后其它两处自动刷新。

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

### 8.1 WorkEntryCard / WorkSummaryView（R23-I 拆为两文件：`Components/WorkEntryCard.swift` + `Components/WorkSummaryView.swift`）

- **WorkEntryCard**：单条任务卡片，支持只读/编辑切换、拖拽、删除二次确认、右键标签管理、新建标签 popover。详见 7.4。
- **WorkSummaryView**：把一批任务按 kind 分组只读展示（概要页今日记录 / 周报每日块用），每组带 `section(_:_:)` 渲染图标+计数标题 + 列表（含详情、优先级、状态、周期、标签胶囊、逾期标记）。
- **BadgeChip**（`Components/BadgeChip.swift`，R23-E 抽出）：统一胶囊徽章，覆盖 Priority / BlockerStatus / 逾期 / 周期 / 标签 五类，原版散落在 5 个文件 13+ 处重复样式。两种 size（`.regular` / `.compact`），便捷构造器 `BadgeChip.priority(_:)` / `.blockerStatus(_:)` / `.overdue()` / `.recurrence(_:color:)` / `.tag(_:)`。

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

每个 segment 带 `.accessibilityLabel(kind.rawValue)` + `.accessibilityValue(isSelected ? "已选中" : "未选中")` + `.accessibilityAddTraits(isSelected ? .isSelected : [])`，VoiceOver 用户可听到「完成，已选中 / 计划，未选中」。TagPicker 的 chip / checkChip 与 `ColorSwatchPicker` 色板同理。

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
- `Calendar`：`monday(for:)`

### 8.8 InlineSummaryEditor（`Components/InlineSummaryEditor.swift`）

R21-C 抽出。会议概要的内联编辑器，原本散落在 `TodayView.TodayMeetingRow` / `MenuPanelView.MeetingPanelRow` / `MeetingView.MeetingCard` 三处各写一份 30 行的 onChange(debounce) + onAppear load + onDisappear flush + onChange(meeting.id) reset + onChange(meeting.summary) 外部同步 五件套（≈ 90 行重复）。改一处（如 debounce 时长）必然漏改其他两处。

抽成共享 view 后参数化为 `Style` 枚举：

| Style | 字号 | 高度 | 圆角 | 用途 |
|---|---|---|---|---|
| `.compact` | caption | 28 | 6 | 概要页今日会议行 |
| `.panel` | caption | 28 | 4 | 菜单栏面板（视觉更轻） |
| `.standard` | subheadline | 36 | 6 | 会议详情卡（主窗口里更醒目） |

特殊参数 `flushOnResignActive: Bool`：菜单栏面板专用兜底。MenuBarExtra 的 window 隐藏 ≠ view 拆除，`onDisappear` 不触发，需监听 `NSApplication.willResignActiveNotification` 兜底立即 flush 草稿。

写回机制：本地 `@State summaryDraft` + 0.3s debounce `Task.sleep` + `onDisappear` flush + `onChange(meeting.id)` reset + `onChange(meeting.summary)` 外部同步。失败走 `.writeErrorAlert($writeError)`（与各 view 写操作统一反馈）。

> debounce 时长 `debounceMs: Int = 300` 是抽出的常量（R21-D），未来想统一调整只改一处。300ms 是经验值：够缓冲连续输入，又不会让用户感觉延迟。

## 9. 服务层

### 9.1 RecurrenceService（`Services/RecurrenceService.swift`）

`@MainActor enum RecurrenceService`（无实例），2 个静态方法：

- `sweepMeetings(in store: AppStore)` — 周期会议推进 + 残留克隆清理（详见 6.4）。所有推进 + 清理合并到 `store.transactional { db in ... }` 单事务，循环内直接 `MeetingRecord.fetchOne` + `rec.update(db)` / `MeetingRecord.deleteOne`，事务结束 `reloadAll` 一次。启动若有 N 条逾期，IO 不随 N 线性放大
- `sweepWorkEntries(in store: AppStore)` — 周期计划任务原地推进 finishDate，同上批量化到 `store.transactional` 单事务

> 完成路径（`markDone`）已合并到 `AppStore.markEntryDone(_:)`，不再放在 RecurrenceService（因为需要单事务里 clone + 降级 + 复制 tag 关系，AppStore 持有 dbQueue 才能保证原子性）。

### 9.2 BackupService（R23-H 拆为 3 文件：`Services/BackupService.swift` + `+Snapshot.swift` + `+Files.swift`）

`@MainActor enum BackupService`（无实例），负责 JSON 全量备份/恢复。
- 主文件 `BackupService.swift`：DTO 定义 + Snapshot + encode/decode + restore 单事务
- `BackupService+Snapshot.swift`：snapshotAtomic（事务内读 6 表 + 5 关系，read 失败兜底内存快照）+ record→DTO 映射 + 容错链路抢救（snapshotFromDBQueueIfPossible）
- `BackupService+Files.swift`：boot/manual/weekly 触发 + 文件名约定（`<prefix>-<ISO>[-suffix].json`）+ prune 策略（同日去重、月清理、最近 N 份硬上限）

**Snapshot DTO**（`currentSchemaVersion = 1`，`nonisolated` 常量；改 DTO 字段类型/语义需 +1）：

| DTO | 字段 |
|---|---|
| `TagDTO` | id / name / colorHex / createdAt |
| `ReportDTO` | id / date / note / createdAt / updatedAt / tagIds |
| `TodoDTO` | id / title / notes / isDone / dueDate / createdAt / completedAt / tagIds |
| `EntryDTO` | id / title / detail / timestamp / kind / finishDate / helper / blockerStatus / priority / isRecurring / recurrenceUnit / recurrenceInterval / recurrenceWeekdays / recurrenceMonthDays / createdAt / tagIds |
| `MeetingDTO` | id / topic / summary / timestamp / createdAt / isRecurring / recurrenceUnit / recurrenceInterval / recurrenceWeekdays / recurrenceMonthDays / tagIds / reviewIds |
| `ReviewDTO` | id / reviewer / opinion / order / createdAt / meetingId? |

**快照方法**：

- `snapshotAtomic(in store:) -> Snapshot` — 在单个 `store.read` 事务里读 6 主表 + 4 关系映射，避免备份中途用户写入读到半完成状态；read 失败时降级用 `snapshotFromMemory`（从 AppStore 内存快照兜底）
- `snapshotFromMemory(in:)` — 不走事务，直接读 AppStore 内存属性（只在 atomic 失败时用）
- `snapshotFromDBQueueIfPossible(_)` — 给容错链路用：从只读 `DatabaseQueue`（归档文件）读出 Snapshot，写 `salvage-*.json`
- `encode(_:) -> Data` / `decode(_:) -> Snapshot` — ISO8601 日期，pretty + sortedKeys；decode 时校验 `schemaVersion > currentSchemaVersion` 打 warn 日志

**restore**：

- `restore(_ s: Snapshot, in store:) throws`：
  1. 先写 pre-import 快照：`writeBackup(snapshot: snapshotAtomic(in: store), prefix: "pre-import")`
  2. `store.transactional { db in AppStore.truncateAll(in: db); insertSnapshot(s, into: db) }` — **单事务**：truncate + 重建合并；重建阶段抛错 → 整事务回滚（清空也回滚）→ 现有数据保留
  3. `store.vacuum()` — **VACUUM 回收 sqlite 空闲页**：`DELETE FROM ...` 不会收缩 db.sqlite 文件，多次 restore 后会持续膨胀；VACUUM 把空闲页还给文件系统（SQLite 限制 VACUUM 不能在事务里，故独立用 `writeWithoutTransaction`）；失败仅 warn，不影响数据正确性
  4. `insertSnapshot` 按 `Tag → DailyReport → TodoItem → WorkEntry → Meeting → Review` 顺序 insert，同时往 4 张中间表插关系行（UUID 直接来自 DTO，保留原 id）

**备份方法**：

- `writeBackup(snapshot:prefix:suffix:) -> URL?` — 写到 `dbbackup/<prefix>-<ISO8601>[-<suffix>].json`，写完调 `pruneOldBackups(prefix:)`
- `bootBackup(in:) -> URL?` — 今日已写 weekly 时跳过；否则 `removeSameDayBoots` 删今天的 `boot-*.json` 后重写一份
- `weeklyBackupIfDue(in:) -> Bool` — 周五~周日窗口：先 `prunePrecedingMonthWeeklyBackups` + `pruneOldWeeklyBackups(keepCount: 12)`，再按「本周一」weekKey 查 `weeklyBackupExists`，不存在则写 `weekly-<ISO>-<weekKey>.json`
- `manualBackup(in:) -> URL?` — 用户手动触发（prefix: manual）
- `pruneOldBackups(prefix:)` — 按 prefix 仅保留最近 10 个，**按文件名 ISO 时间戳倒序**（与其他 prune 函数一致；旧版用 `creationDate` 在 cp/tar 解压后会误判）
- `pruneOldWeeklyBackups(keepCount:)` — 按文件名 ISO 时间戳倒序保留前 keepCount 个（默认 12）
- `prunePrecedingMonthWeeklyBackups(now:)` — 按用户本地时区年月判断，删除上月及更早的 `weekly-*.json`
- `backupDirectory: URL` — app 同级 `dbbackup/`（thread-safe lazy init）

### 9.3 ExportService（`Services/ExportService.swift`）

`@MainActor final class ExportService`，单例 `shared`。

**当前 UI 暴露的方法**：

- `exportWeekDoneXLSX(_ entries: [WorkEntryRecord], title: String)` — 仅 `.done`，按 `finishDate ?? timestamp` 升序，列 `[星期, 日期, 标题, 详情]`

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
- `currentAuthorization() async -> Bool` — 含 `.provisional`；`.denied` / `.notDetermined` / `.ephemeral` 视为未授权
- `currentAuthorizationStatus() async -> UNAuthorizationStatus` — 暴露原始枚举，让 UI 区分「未决定」与「已拒绝」（Settings 页对 `.denied` 显示「打开系统通知设置…」按钮直达通知面板）。SettingsView 监听 `NSApplication.didBecomeActiveNotification` 重拉一次：用户从系统设置改完授权回到 app 后立刻显示新状态，不必手动开关窗口
- `openSystemNotificationSettings()` — 打开 `x-apple.systempreferences:com.apple.Notifications-Settings.extension`（macOS 14+）
- `reschedule(enabled:hour:minute:)` — 先 `removePendingNotificationRequests([id])`，enabled 时建 `UNCalendarNotificationTrigger(repeats: true)` + `UNNotificationRequest` add
- 通知文案固定：「该写日报啦 ✍️」/「花两分钟记录今天的工作吧。」
- identifier `daily-report-reminder`

### 9.6 AppDatabase 与 BackupService 的协作（主库容错链路）

`AppDatabase.openOrRecover()` 三级容错（详见 10.5 流程图）：

1. 主库 `db/db.sqlite` 打开 + 迁移 + **PRAGMA integrity_check** 通过 → 正常路径
   - 完整性检查返回非 `"ok"` 也视为容错触发条件（结构损坏但能打开的库避免持续被读写）
   - 错误类型 `IntegrityError.failed(message:label:)`（CustomStringConvertible，日志可读）
2. 主库打开/完整性失败：
   - `archiveCorruptedDB(primaryURL)` 把 `db.sqlite{,-wal,-shm}` 移到 `db/corrupted/<ISO>/`（保留现场 + 写 README.txt）
   - `snapshotToBackup(archivedURL)` 用只读 GRDB 打开归档文件 → `BackupService.snapshotFromDBQueueIfPossible` → 写 `dbbackup/salvage-*.json`（归档文件连 GRDB 都打不开就跳过，数据本就救不回）
   - 主路径空库重建（`openAndMigrate(at: primaryURL)`，新空库 integrity_check 必过）
3. 主路径仍失败 → 切 `db/db.fallback.sqlite`（也跑 integrity_check）→ 全部失败 `fatalError`

启动后 `AppDatabase.pruneCorruptedArchives(keepCount: 5)` 清理旧归档。用户可从设置页「打开备份文件夹」手动恢复 `salvage-*.json` / `pre-import-*.json`。

### 9.7 AppLogger（`Services/AppLogger.swift`）

`enum AppLogger`（无实例），轻量日志：落地到 `<appDir>/logs/app.log`（与 DailyReport.app 同级），同时镜像到 `os.Logger`（subsystem `com.zhyu.dailyreport`，可在 Console.app 查看）。

**4 个 level**：`error(_:)` / `warn(_:)` / `info(_:)` / `debug(_:)`，分别对应 `os.Logger` 的 error/warning/info/debug。

**特性**：

- **日志格式**：`<ISO8601 毫秒> [<LEVEL>] [<file>:<line> <function>] <message>`，level 之后带源位置上下文（`#fileID` / `#function` / `#line` 由编译器自动注入），定位错误现场无需 grep
- 单文件超过 `maxBytes`（1 MB）自动滚动为 `app.log.1/.2/...`，保留最近 `keepCount`（5）份。`rollIfNeeded(url:maxBytes:keepCount:)` 已参数化（`nonisolated static`），单测可注入小 `maxBytes` 立即触发滚动；生产路径用静态默认值
- 写入串行化（`NSLock`），防止跨线程并发 append 交叉损坏
- **`timestampFormatter` 缓存**：`ISO8601DateFormatter` 非 Sendable，用 `nonisolated(unsafe) static let` 缓存一份；写入由 `writeLock` 串行化，安全
- **`debug` 在 release build 不写文件**：用 `#if DEBUG` 包裹，避免高频调试输出污染用户日志（`os.Logger` 仍接收，可在 Console.app 查看）
- `logFileURL` 暴露给 `DailyReportApp.warnIfLegacyDataRemains` 写 `.swiftdata_warned` 标志位
- `migrateFromLegacyIfNeeded()` 一次性把日志从 `db/logs/` 迁到 app 同级 `logs/`（旧目录已空时一并删除）

## 10. 关键流程图解

### 10.1 添加任务

```
菜单栏 addBar / 时间线 addBar
  → add()
    → trim title 非空校验
    → 按 kind 决定 finishDate / helper / recurring
    → store.insertEntry(NewWorkEntry(...))   ← dbQueue.write 单事务 + reloadAll
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
store.markEntryDone(entry.id)   ← 单事务（dbQueue.write）
  → 若 isRecurring && wasPlanned：
      新建 WorkEntryRecord(.planned, finishDate: entry.nextRecurrenceDate())
      + 复制 tag 关系到 tag_work_entry
  → 原 entry.kindRaw = .done
  → 若 wasPlanned || finishDate == nil：
      原 entry.finishDate = Date()
    ↓
AppStore.markEntryDone 内部 dbQueue.write 同步事务 + reloadAll → @Observable 刷新 UI
    ↓
原任务从「计划列表」消失，落入「今日记录·完成组」
下一期克隆出现在「计划列表」（如果是周期性）
```

### 10.3 跨日推进

```
系统发 NSCalendarDayChanged
    ↓
DailyReportApp 监听闭包（.main 队列 + MainActor.assumeIsolated）
  → RecurrenceService.sweepMeetings(in: store)  (推进会议 + 残留清理)
  → RecurrenceService.sweepWorkEntries(in: store)  (推进周期计划 finishDate)
  → BackupService.weeklyBackupIfDue(in: store)  (进入周五~周日窗口时补写周备份)
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
      → BackupService.decode(data) -> Snapshot（校验 schemaVersion ≤ currentSchemaVersion）
      → BackupService.restore(snap, in: store)
          1. writeBackup(snapshot: snapshotAtomic(当前数据), prefix: "pre-import")  ← 先留快照
          2. store.transactional { db in truncateAll(db); insertSnapshot(snap, db) }  ← 单事务
             重建阶段抛错 → 整事务回滚（清空也回滚）→ 现有数据保留
      → 成功 beep / 失败 restoreError alert
```

### 10.5 GRDB 主库打开失败容错

```
DailyReportApp.init()
  → AppDatabase.openOrRecover()
      1. try openAndMigrate(at: primaryURL)   ← 正常路径：打开 + 跑 AppMigrator
         成功 → OpenResult(recovered: false)
      2. 主库失败（打开或迁移抛错）：
         a. archiveCorruptedDB(primaryURL)   ← 把 db.sqlite{,-wal,-shm} 移到 db/corrupted/<ISO>/
         b. snapshotToBackup(archivedURL)    ← 只读 GRDB 打开归档 → BackupService 写 salvage-*.json
         c. try openAndMigrate(at: primaryURL)   ← 主路径空库重建
            成功 → OpenResult(recovered: true)
         d. try openAndMigrate(at: fallbackURL)   ← db/db.fallback.sqlite 兜底
            成功 → OpenResult(recovered: true)
            失败 → fatalError（极端情况）
  → AppDatabase.pruneCorruptedArchives(keepCount: 5)   ← 清理旧归档
```

## 11. 数据安全策略

**存储位置**（全部与 `DailyReport.app` 同级，方便整包携带 / 排查）：

| 路径 | 用途 |
|---|---|
| `db/db.sqlite` (+ `-wal` / `-shm`) | GRDB 主库（WAL 模式） |
| `db/db.fallback.sqlite` | 主路径持续失败时的兜底库 |
| `db/corrupted/<ISO>/` | 启动时无法打开的主库归档（保留最近 5 份） |
| `dbbackup/` | JSON 备份目录 |
| `logs/app.log` (+ `.1` … `.4`) | 运行日志（单文件 1 MB 滚动，保留 5 份） |

**备份策略**（全部写到 `dbbackup/`）：

| 触发点 | 前缀 | 保留 | 说明 |
|---|---|---|---|
| 启动（boot） | `boot-` | 同日只留 1 份（覆盖当日），prefix 总数最近 10 | 今日已写 weekly 时跳过，避免双写 |
| 周备份（周五~周日窗口） | `weekly-<ISO>-<weekKey>` | 上月及更早全删 + 硬上限 12 份 | weekKey = 本周一 `yyyy-MM-dd`，跨周五~周日指向同一周 |
| GRDB 主库打开失败抢救 | `salvage-` | prefix 总数最近 10 | 从 `db/corrupted/<ISO>/db.sqlite` 只读抢救 |
| JSON 导入前 | `pre-import-` | prefix 总数最近 10 | 清空前先留快照，导入失败可手动恢复 |
| 用户手动备份 | `manual-` | prefix 总数最近 10 | 设置页触发 |
| 用户手动导出 | 用户选择（NSSavePanel） | — | 单次导出 |

- 格式：JSON（`Snapshot` 含扁平化 DTO，关系用 UUID 数组表达）
- 编码：ISO8601 日期、pretty + sortedKeys（diff 友好）
- 解码校验：`schemaVersion > currentSchemaVersion` 时打 warn 日志（前向兼容提醒）
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
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0")
    ],
    targets: [
        .executableTarget(
            name: "DailyReport",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/DailyReport"
        )
    ]
)
```

### 13.2 scripts/build-app.sh 流程

1. `swift build -c release`（纯 Command Line Tools 即可，无需完整 Xcode；GRDB 无宏依赖，CLT 的 swift 编译器直接支持）
2. 拷贝二进制 + `Info.plist.template` 到 `DailyReport.app/Contents/{MacOS,Resources}/`
3. **注入构建版本号**：`plutil -replace CFBundleVersion -string "<git提交数>.<short sha>"`，方便从用户的「关于」/ 崩溃日志 / `app.log` 启动行反查到具体提交（`Resources/Info.plist.template` 里 `CFBundleVersion=1` 只是占位）
4. **注入 marketing 版本号**：取最近一个 git tag（`git describe --tags --abbrev=0`），若符合 `vX.Y.Z` / `X.Y.Z` 格式则 `plutil -replace CFBundleShortVersionString`；不符合或无 tag 时保留 template 默认（`1.0.0`），避免把任意字符串塞进 plist。预发布后缀（如 `1.2.3-rc1`）取前 3 段
5. `codesign --force --deep --sign - "$APP"`（ad-hoc 签名，`SMAppService` 注册登录项的必要条件；失败时打警告但不阻断）
6. `touch`（注册 LaunchServices）

### 13.3 Info.plist 关键键

- `LSUIElement = true` — 纯菜单栏，不占 Dock
- `CFBundleIdentifier = com.zhyu.dailyreport`
- `CFBundleName = DailyReport`
- `CFBundleVersion` — 由 build-app.sh 在打包时注入 `<git 提交数>.<short sha>`（如 `14.b1cb70c`）；`DailyReportApp.init` 启动日志会打印 version+build 便于排查
- `CFBundleShortVersionString` — 由 build-app.sh 在打包时尝试用最近 git tag 注入（如 tag `v1.2.3` → `1.2.3`）；SettingsView「关于」section 显示 `<ver> (<build>)` 便于排查

### 13.4 常用命令

```bash
# 构建 + 重启
pkill -f DailyReport.app; sleep 1
bash scripts/build-app.sh && open DailyReport.app

# 跑测试（需 Xcode 工具链，CLT 不含 Swift Testing）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# 卸载
rm -rf DailyReport.app
```

## 14. 测试套件

`Tests/DailyReportTests/` 下用 Swift Testing 框架，453 tests / 44 suites 全绿。运行需 Xcode 工具链（纯 CLT 不带 Testing 模块）：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

### 14.1 各 Suite 职责

| Suite | 用例数 | 覆盖点 |
|---|---|---|
| `AppStoreTests` | 49 | Tag/DailyReport/TodoItem/WorkEntry/Meeting/Review 的 CRUD + 关系重建（4 张中间表）+ CASCADE + transactional 回滚 + unknown id 静默 no-op（update + delete 全覆盖，R27-F 补 deleteTag/Todo/Meeting）+ addReview FK 违规 + addReview order 事务内 MAX+1（R23-A）+ markEntryDone race 防御 + markEntryDone blocker→done 原地降级（R28-F）+ markEntryDone planned+非周期 原地降级（R29-B）+ vacuum + insert 路径的 tag/review 同步绑定（R21-A）+ getOrCreateTag 三分支（新名新建 / 同名复用 / 大小写不敏感）（R37-B）+ updateTag 选择性更新四分支（仅 name / 仅 colorHex / 两者 / 两者皆空 no-op）（R37-C）+ deleteEntries/deleteTodos 空数组早退 no-op（R38-I）+ truncateAll 4 张中间表参数化穷举（R38-B）+ setReportTags unknown id 路径（空 tagIds no-op / 非空 FK 违规抛错）（R39-F） |
| `MigratorTests` | 9 | v1→v2 dedup（保最早 createdAt、合并非空 note、迁移 tag 关系）+ UNIQUE 约束生效；no-op on clean v1；v3 扩展性 + 幂等性 + 索引回归；v4 tag.name dedup（保最早 createdAt、4 张中间表关系 INSERT OR IGNORE 迁移 + 显式清理 dangling）+ v4 no-op on clean database（R22-A）；v5 review UNIQUE(meetingId, order) 按 createdAt 升序 renumber + no-op on clean database（R23-A） |
| `BackupServiceTests` | 42 | weekKey 计算（周一锚点 + R25-G 补 Tue/Wed/Thu + 跨月/跨年边界）+ 各类 backup 文件存在性 + prune 策略 + decode 高版本/坏 JSON 拒绝 + Snapshot round-trip + decode 加固（payloadTooLarge / danglingTagReference 拒绝 + 自一致 snapshot 通过）（R22-A）+ parseISO8601 双分支（标准 / 带毫秒 / 损坏 / round-trip）（R36-A）+ enumerateBackups 边界（目录不存在 / 非 matching prefix/suffix / suffixLength 分支 / 无 suffix 分支）（R36-C）+ Snapshot 全字段 round-trip（6 主表 + recurrenceWeekdays/monthDays/reviewIds/meetingId/order 字段级断言，原 snapshotRoundTrip 仅覆盖 1 个 TagDTO）（R40-A） |
| `BackupServiceIntegrationTests` | 10 | snapshotAtomic 全实体 + restore round-trip + 空 snapshot 清库 + encode/decode 保留 recurrence 字段 + weeklyBackupIfDue 窗口判定（周四跳 / 周五写 / 同周幂等 / 写失败返回 false）（R24-G）+ snapshotFromMemory 降级路径（6 主表 + 关系映射与 snapshotAtomic 一致）（R39-C，snapshotFromMemory 从 private 改 internal）+ insertSnapshot 直接单测（隔离 restore 的 pre-import + truncate + VACUUM 包装层，直接调 insertSnapshot 钉死 DTO→Record 映射 + 2 张关键中间表 tag_work_entry / tag_meeting 关系）（R40-F，insertSnapshot 从 private 改 internal） |
| `AppDatabaseTests` | 9 | archiveCorruptedDB 三文件归档 + 缺源 no-op + 同秒碰撞后缀 + README 写入 + **corrupted/ 被占用为文件时的失败路径**（R26-F）；pruneCorruptedArchives 保留最近 N + 数量不足 no-op + 目录缺失 no-op（R23-C）+ IntegrityError.description 同时包含 label + message + 前缀（R38-J） |
| `RecurrenceServiceTests` | 15 | sweepMeetings/sweepWorkEntries 各场景（逾期推进 / 今天保留 / 一次性会议保留 / 同主题残留清理）+ markDone 克隆下一期 / blocker → done / 已 done 的 race no-op + 月度周期跨月边界（R21-A）+ cleanupExpiry 保留分支（summary 非空 / review 非空）（R25-F） |
| `RecurrenceTests` | 35 | daily/weekly/monthly 单元计算 + interval>1 跳跃 + 月末 component overflow 防御 + label 文案 + base 在未来时 interval 不影响返回（R29-D）+ weekdayLong 1...7 双字映射 + 越界返回 ? + 与 weekdaySymbol 同源数据一致性（R35-F）+ weekdaySymbol 越界直接覆盖（0/8/-1 返回 ?）+ 1...7 单字非空（R37-G，原仅靠 weekdayLong 间接覆盖）+ label 空 weekdays/monthDays 返回纯前缀分支（guard !isEmpty else { return prefix }，interval>1 仍走前缀分支不退化）（R40-D）+ label/nextFutureDate 的 interval ≤ 0 兜底为 1（属性等价测试：interval=0/-5 与 interval=1 返回完全相同，钉死 max(1,_) 防御不退化）（R42-B/C） |
| `XLSXWriterTests` | 22 | XML 转义（4 实体 + 边界）+ 列字母转换（A-Z / AA-ZZ / AAA-ZZZ）+ CRC32 标准向量 + dosDateTime 边界（year<1980 clamp + 正常位打包 + 1980-01-01 边界）（R37-F，原 private 改 internal 直覆边界分支） |
| `AppLoggerTests` | 7 | 日志滚动：未达上限 no-op / 创建 `.1` / 顺移现有文件 / 满槽删最旧 / maxBytes=0 立即滚 / keepCount=1 直删原文件 |
| `ExportServiceTests` | 26 | csvEscape（RFC 4180 三种触发条件）+ sanitizeSheetName（7 禁用字符 + 31 字符截断）+ sanitizeFilename + weekdayName + markdownForDay 分组排序 + tag 渲染 + report note 渲染（R21-A 测试发现并修复了「entries 为空时 note 不渲染」的提前 return bug）+ WorkKind.emoji 编译期覆盖所有 case + todoCSVRow 纯函数（nil 渲染空串 / isDone→"是" / tags 走 csvEscape）（R39-H，原 25 行 exportTodosCSV 抽出）+ doneEntriesSorted 过滤 + 归属日排序（done 通过 / planned+blocker 过滤掉 / finishDate ?? timestamp fallback）（R40-G，原 exportWeekDoneXLSX 内联 filter+sort 抽出）+ markdownForDay 三分支（缺失 kind 不输出标题 / 空 detail 不输出缩进行 / 无 tag 不输出 · 分隔符）（R41-A） |
| `NavigationCoordinatorTests` | 5 | 越界 rawValue 兜底回 .today + 负值兜底 + 合法值持久化 round-trip + openMeetingEdit 切 tab 并设 meetingRequest；`.serialized` 隔离 UserDefaults.standard 单例的并发串扰；`@MainActor` 标注匹配 R24-H 的 NavigationCoordinator 主线程隔离 |
| `ReminderServiceTests` | 7 | decision 三分支决策：enabled=false → removeOnly（无视 status）/ enabled=true + denied → none（保留旧 pending）/ enabled=true + 非 denied（authorized/provisional/notDetermined）→ removeAndAdd；Decision case 互斥性回归（R22-A，原 ReminderService 是唯一无测试 Service） |
| `NewEntryDraftTests` | 10 | canSubmit 拒空/拒纯空白 + consume 三分支（done/planned/blocker）的字段条件赋值（finishDate / helper / recurring / priority / blockerStatus）+ tagIds 映射 + reset 保留 kind/recurrenceUnit/recurrenceInterval（R24-F）+ consume 保留 selectedTags 顺序（防误改 `Set(...).map` 重排导致 UI/导出顺序乱）（R41-L） |
| `DaySliceTests` | 14 | contains(entry:) done 按 finishDate 归属 / planned 逾期归入今日 / planned 未来 finishDate 不归入 / contains(meeting:) 跨午夜边界（23:59 归今日、00:00 归次日）/ plannedSort 优先级 + finishDate 组合排序（R30-D，原 DaySlice 是 R24-B 抽出的核心组件，View/Store 共用，零测试覆盖）+ plannedSort 同优先级一侧 finishDate=nil fallback 到 timestamp + 两侧都 nil 纯 timestamp 比较（R40-E，原仅覆盖两侧都有 finishDate 的路径）+ contains(entry:) blocker 分支（今日归属 / 昨日排除）+ done finishDate=nil fallback timestamp（R41-D）+ isTodayPlanned finishDate=nil fallback timestamp（今日归属 / 昨日排除）（R41-E） |
| `AppStateTests` | 3 | migrateLegacyKeysIfNeeded 三分支：legacy 有值 + new 缺失 → 拷贝（5 对 key 类型保真：Bool/Int/Int/String/Int）/ new 已存在 → 不覆盖（保用户后续修改）/ 双方都没值 → 无副作用 no-op（R31-G，原启动期一次性迁移零覆盖，误改「总是覆盖」会丢用户设置） |
| `RecordQueriesTests` | 13 | fetchTagMap 三分支：空中间表返 [:] / 单 owner 多 tag 按中间表插入顺序保留（不重排为 createdAt）/ tagId 在传入 allTagsById 找不到时静默跳过（R32-C，原仅靠 AppStoreTests 集成间接覆盖，无直接断言钉死顺序与 dangling 兜底）+ insertTagLinks INSERT 路径参数化 4 个 TagLinkTable + 空 tagIds 幂等（R36-D）+ TagLinkTable.ownerColumn 直接覆盖（非空 + 互斥）（R38-C）+ fetchReviewsByMeeting 三分支（空表 / 多 review 按 order+createdAt 升序 / meetingId=nil 孤儿跳过）（R38-A）+ TagLinkTable.rawValue 与对应 Record.databaseTableName 一致性参数化（R39-K）+ replaceTagLinks DELETE+INSERT 原子性（replace ≠ append，先清后插）+ 空数组清空全部旧关系（R41-M） |
| `IntArrayJSONTests` | 4 | encode/decode round-trip + 空数组 / decode(nil) 返 [] / decode 坏 JSON（截断 / 类型错 / 完全非 JSON）返 []（R32-D，WorkEntryRecord/MeetingRecord 的 recurrenceWeekdays/recurrenceMonthDays 持久化通道，原 R23-G 加的兜底无回归测试） |
| `IsOverdueTests` | 8 | WorkEntryRecord.isOverdue：done/blocker/planned 无 finishDate 永远 false + planned 昨天 true + planned 今天 false（边界，按 startOfDay 严格 <）/ TodoItemRecord.isOverdue：isDone / dueDate nil / dueDate 过去三分支（R32-E，原 5+ 处 UI 视觉判断无测试钉死） |
| `ColorHexTests` | 12 | 6 位带 # / 6 位不带 # / 含空白被 trim → 成功；3 位短格式（CSS 标准 #FFF）/ 空串 / 仅 # / 非 hex 字符 / 错误长度（5/7 位）→ 失败（R32-F，TagRecord.swiftUIColor 与 ColorSwatchPicker 的核心解析，原零覆盖，钉死「3 位短格式不支持」语义防误改）+ hexString round-trip（defaultPalette 8 个 + 纯 RGB）+ TagPickerPalette 全可解析 + defaultHex=first 契约（R38-D/H） |
| `RecurrenceCapableTests` | 3 | RecurrenceCapable.recurrenceLabel 三分支：未开启 recurring 返回空串 / 单元 + interval 拼接（与 Recurrence.recurrenceLabel 静态函数对齐） / 月度按 monthDays 渲染（R33-A，原 protocol 默认实现零覆盖，调用方 WorkEntryRecord/MeetingRecord 共 2 处） |
| `StringExtensionsTests` | 8 | isBlank：空串 / 纯空格 / 纯换行（与原 .whitespaces 关键差异）/ 混合空白 / 内容不为空；trimmed：去首尾 / 去换行 Tab / 保留中间空白 / 空串稳定（R34-C，原 25+ 处写入路径作 guard 与清洗的核心 helper 零覆盖，钉死「统一 .whitespacesAndNewlines」语义防回退） |
| `CalendarMondayTests` | 5 | monday(for:) 五分支：输入即周一 / 周中 / 周日（系统 firstWeekday=1 仍归上一周周一，注释里踩过的坑）/ 跨月 / 跨年（R34-D，BackupService.weekKey 8 个测试已间接覆盖，但 monday(for:) 本身零测试钉死「强制 firstWeekday=2」语义） |
| `SpawnNextTests` | 3 | WorkEntryRecord.spawnNext 三分支：isRecurring=false → nil / kind != .planned → nil（done / blocker 两个 case）/ 正常克隆 14 字段 + 新 id + finishDate 推进（R35-A，markEntryDone 调用的核心纯函数零测试覆盖） |
| `BelongDateTests` | 5 | WeeklyReportView.belongDate 五分支：done/planned → finishDate ?? timestamp（finishDate 缺失走 timestamp 兜底）/ blocker → timestamp（即使有 finishDate 也不用，与 done/planned 的关键差异）（R35-B，周报聚合的核心判定零测试） |
| `SweepWorkEntriesTests` | 5 | RecurrenceService.sweepWorkEntries 四分支：未逾期 skip / 逾期推进（finishDate 不再逾期）/ 非 recurring skip / blocker 即使 recurring 也 skip（R35-H，sweepMeetings 已有 R25-F 测试，sweepWorkEntries 是对称分支却长期黑盒）+ recurring planned finishDate=nil skip（防误改成 timestamp 推进导致无 finishDate 任务原地循环推进）（R41-G） |
| `DateFormatTests` | 13 | Date.isoDay/startOfDay/isToday/shortTime/friendlyDay/friendlyDate/relativeTime 等格式化器直接单测，含同年省略年份 + 跨年显示年份 + 未来时间走 shortTime + 5 秒前返回「刚刚」（R36-B，原本零直接覆盖；ExportService 文件名 / WeeklyReportView 标题 / BackupService.weekKey fallback 全依赖这些派生属性）+ relativeTime 缺失分支补齐（分钟前 / 小时前 / 昨天 / 跨年，R38-F） |
| `EnumDisplayTests` | 15 | WorkKind icon/emoji 非空 + emoji 互斥 + blocker 时 color 委派 BlockerStatus；BlockerStatus localizedName 非空 + 互斥；Priority localizedName 非空 + 互斥 + sortOrder high→low；RecurrenceUnit rawValue 非空 + 互斥（R37-A，原 4 个 UI 数据源枚举的展示属性零覆盖，改错任一项 UI 静默错乱无编译期信号）+ WorkKind.color(status:) 全 9 组合参数化（blocker 委托 status，done/planned 忽略 status 参数契约）（R40-H） |
| `AppearanceModeTests` | 6 | colorScheme 三分支：system→nil（跟随系统）/ light→.light / dark→.dark；localizedName 非空 + 互斥；allCases 覆盖 system+light+dark（R37-D，原 Settings 页外观切换唯一数据源零覆盖，colorScheme 改错整个 app 深浅色错乱） |
| `AppTabTests` | 6 | 4 tab 的 title / systemImage 非空 + 互斥；allCases 覆盖 4 tab；rawValue 互斥 + 连续 0...3（UserDefaults 持久化 key 保真）（R37-E，原 MainTabView 标签数据源零覆盖，删 case UI 静默缺一项） |
| `RecordDerivedTests` | 2 | WorkEntryRecord.day / MeetingRecord.day = Calendar.current.startOfDay(for: timestamp)（按天聚合分组键，ExportService / DaySlice / WeeklyReportView 共依赖；R38-L，原零覆盖，改错会让所有按天聚合错位） |
| `InlineSummaryEditorTests` | 7 | InlineSummaryEditor.Style 6 派生属性（minHeight/cornerRadius/textPaddingH/placeholderPaddingH/placeholderPaddingV/font）显式 case 断言：compact/panel 共用 caption 字体 + 共享紧凑尺寸（minHeight=28/cornerRadius 6|4/textPaddingH=2/placeholder=6,5），standard 独用 subheadline + 放大尺寸（minHeight=36/cornerRadius=6/textPaddingH=4/placeholder=8,7）（R41-K，3 处调用点概要/菜单栏/会议详情卡的视觉一致性契约，原零覆盖） |
| `ConvertKindTests` | 7 | HistoryView.convertKind 6 个跨 kind 转换路径 + same-kind no-op：blocker→planned 清 helper+重置 status / done→planned 清 finishDate（防新 planned 因旧完成日立刻 isOverdue 飘红）/ planned→blocker 清 recurring+finishDate（防「周期性 blocker」怪胎 sweep 不推进却仍带 repeat 标记）/ done→blocker 同款清理 / planned→done 走 case .done break 保留字段 / extra 闭包在 kind 转换后执行（R42-A，dropDestination 核心副作用原为 private static 零覆盖） |
| `TimeLabelTests` | 4 | SettingsView.timeLabel 4 边界：0→"00:00" / 1439→"23:59" / 90→"01:30" / 整点 60→"01:00"、600→"10:00"（R42-D，原 private 实例方法零覆盖，改 static internal 抽出后可单测；改坏会让用户设的 18:30 显示成 06:05 等） |
| `DeleteMessageTests` | 2 | TodayView.deleteMessage：nil→"" 兜底（List.onDelete race 下可能传 nil）+ non-nil→"「<title>」将被删除。"（R42-E，原 private static 零覆盖，改 internal 抽出后 @MainActor suite 直接覆盖） |
| `MatchesSearchTests` | 7 | HistoryView.matchesSearch 搜索过滤 6 分支：空 key 放行 / 纯空白放行 / title 命中 / title 大小写不敏感 / detail 命中 / 全未命中 / entry(meeting) 共享逻辑对齐（R43-A，原两个 private 实例重载 WorkEntry/Meeting 零覆盖，抽共享 static `matchesSearch(title:detail:key:)` 后 WorkEntry/Meeting 共用一份逻辑） |
| `WeekRangeTests` | 5 | WeeklyReportView.weekRange/weekDays 周锚点归一化：周中锚点（周三→本周一...日）/ 周日锚点（firstWeekday=1 仍归上周一，R34-D 钉的契约）/ 区间正好 7 天 / 跨月（02-01 周四→01-29...02-04）/ weekDays 连续 7 天首尾间隔 1 天（R43-B，原 private 实例属性零覆盖，抽 static 后可单测；改坏会让整周聚合错位） |
| `SnapshotFromDBQueueTests` | 2 | BackupService.snapshotFromDBQueueIfPossible 容错路径：未迁移 schema 的 queue 触发 fetchAll 抛错→catch 分支 return 不写 salvage / 已迁移空 queue→buildSnapshotFromDB 返空 Snapshot→写出 salvage-*.json 可 decode 回空 Snapshot（R43-C，原两个 early-return 分支 read 失败 / snapshot nil 零覆盖，是主库损坏后「数据抢救」链路兜底） |
| `CollectUsedTagsTests` | 7 | TodayView.collectUsedTags 三段去重（entries + meetings + planned）：空输入 / 单源各段 / 跨源去重（同 tag 三段都有只出一次）/ 首次出现顺序保留（a→b→c 按段顺序）/ entry 缺失 tag 映射不 crash（R43-D，原 private 实例方法零覆盖，抽 static 接收 5 参数 entries/meetings/planned + tagsByEntry/tagsByMeeting；改坏会让标签栏重复或漏 tag） |
| `ValidReviewsTests` | 6 | MeetingCard.validReviews 过滤+排序：空输入 / 双空占位行被丢弃（reviewer+opinion 都空）/ 仅 reviewer 有值保留 / 仅 opinion 有值保留 / order 升序乱序验证（3,1,2→1,2,3）/ 同 order 兜底（R44-A，原 instance computed property 零覆盖，抽 `static func validReviews(from:)`；改坏会让卡片标题显示「评审（3）」但实际只有 1 条） |
| `SummaryStatsTests` | 5 | TodayView.summaryStats 概要统计：空输入 rate=0 防除零 / 三类计数各自独立 / 会议数不计入完成率 total / 完成率 = done/total / 全计划无完成时 rate=0（R44-B，原内联在 statBar ViewBuilder 零覆盖，抽 `static func summaryStats(entries:meetings:) -> SummaryStats`；改坏会除零 crash 或统计条数字与列表不一致） |
| `BoardItemTests` | 9 | HistoryView.BoardItem 派生属性：id（entry.id / meeting.id）/ sortDate（任务取 finishDate ?? timestamp，会议固定 timestamp）/ priorityOf（任务取自身 priority，会议固定 medium）/ statusOf（任务取自身 blockerStatus，会议固定 ongoing）三路派生参数化全 case（R44-C，原 private enum + private instance 方法零覆盖，BoardItem 改 internal + 两个 helper 改 static；改坏会让计划列分组错位或状态分组混入会议） |
| `PlannedColumnSortTests` | 5 | HistoryView.sortPlannedColumn 复合排序：空输入 / 优先级 sortOrder 升序（low/high/medium→high/medium/low）/ 同优先级按 sortDate 升序 / 优先级主导时间（高优晚时仍排前）/ 会议默认 medium 与 medium 任务同组按时间（R44-D，原内联在 columnItems 闭包零覆盖，抽 `static func sortPlannedColumn(_:)`；改坏会让高优先级沉底或逾期任务被掩盖） |
| `NextRecurrenceTests` | 5 | WorkEntryRecord.nextRecurrenceDate 三分支（finishDate 非 nil 用 finishDate / finishDate=nil fallback Date() / weekly+空 weekdays 返回 nil fallback Date() 不抛错）+ MeetingRecord.nextFutureOccurrence 两分支（daily 推进 / weekly+空 weekdays fallback timestamp 不抛错）（R39-A/B，RecurrenceService.sweepWorkEntries/sweepMeetings 的核心依赖，原仅间接覆盖） |
| `RecordMappingTests` | 11 | NewWorkEntry.toRecord / NewMeeting.toRecord 三分支（字段拷贝 / interval=0 钳为 1 / interval 负数钳为 1）+ 4 个派生属性 getter fallback（kind→.done / recurrenceUnit→.daily / blockerStatus→.ongoing / priority→.medium）（R39-D/E，DB 非法 rawValue 时 UI 不崩的兜底，原零覆盖）+ TagRecord.swiftUIColor 非法/空 hex fallback .accentColor + 合法 hex round-trip（R40-J，Color(hex:) ?? .accentColor 兜底分支原零覆盖） |

R36-A 在已有 `BackupServiceTests` 追加 4 用例（parseISO8601 标准格式 / 带毫秒容错 / 损坏返回 nil / round-trip），BackupServiceTests 用例数 33 → 37。
R36-C 在已有 `BackupServiceTests` 追加 4 用例（enumerateBackups 目录不存在 / 非 matching prefix/suffix 过滤 / suffixLength 分支 / 无 suffix 分支），BackupServiceTests 用例数 37 → 41。
R36-D 在已有 `RecordQueriesTests` 追加 2 用例（参数化 4 个 TagLinkTable 的 INSERT + 空 tagIds 幂等），RecordQueriesTests 用例数 3 → 5。TagLinkTable 加 `CaseIterable` 以支持参数化。

R35-F 在已有 `RecurrenceTests` 追加 3 用例（weekdayLong 1...7 双字映射 + 越界返回 ? + 与 weekdaySymbol 数据源一致性「周 + 单字 == 双字」），不新建 suite。RecurrenceTests 用例数 22 → 25。

R37-A 新建 `EnumDisplayTests` 12 用例（WorkKind / BlockerStatus / Priority / RecurrenceUnit 四个 UI 数据源枚举的展示属性）。
R37-B 在已有 `AppStoreTests` 追加 3 用例（getOrCreateTag 新名新建 / 同名复用 / 大小写不敏感），AppStoreTests 用例数 37 → 40。
R37-C 在已有 `AppStoreTests` 追加 4 用例（updateTag 仅 name / 仅 colorHex / 两者 / 两者皆空 no-op），AppStoreTests 用例数 40 → 44。
R37-D 新建 `AppearanceModeTests` 6 用例（colorScheme 三分支 + localizedName 非空/互斥 + allCases 覆盖）。
R37-E 新建 `AppTabTests` 6 用例（title/systemImage 非空/互斥 + allCases 4 tab + rawValue 连续 0...3）。
R37-F 在已有 `XLSXWriterTests` 追加 3 用例（dosDateTime year<1980 clamp + 正常位打包 + 1980-01-01 边界），XLSXWriterTests 用例数 19 → 22。`ZipBuilder.dosDateTime` 从 private 改 internal 以让单测能直接覆盖边界分支。
R37-G 在已有 `RecurrenceTests` 追加 2 用例（weekdaySymbol 越界直接覆盖 + 1...7 单字非空），RecurrenceTests 用例数 25 → 27。原 R35-F 只经 weekdayLong 间接覆盖，越界兜底分支（返回"?"）无直接断言。

R38-A 在已有 `RecordQueriesTests` 追加 3 用例（fetchReviewsByMeeting 空表 / 多 review 按 order+createdAt 升序 / meetingId=nil 孤儿跳过），与已补的 fetchTagMap 对称覆盖。
R38-B 在已有 `AppStoreTests` 追加参数化测试（4 个 TagLinkTable 全覆盖 truncateAll 清空），AppStoreTests 用例数 44 → 45（参数化展开为 4）。
R38-C 在已有 `RecordQueriesTests` 追加 2 用例（TagLinkTable.ownerColumn 非空 + 互斥），RecordQueriesTests 用例数 8 → 10。钉死「.dailyReport → reportId」等映射本身，防 switch 分支被改错。
R38-D 在已有 `ColorHexTests` 追加 2 用例（hexString round-trip defaultPalette + 纯 RGB），ColorHexTests 用例数 8 → 10。
R38-F 在已有 `DateFormatTests` 追加 4 用例（relativeTime 分钟前 / 小时前 / 昨天 / 跨年），DateFormatTests 用例数 9 → 13。原仅覆盖 future + 刚刚两分支。
R38-H 在已有 `ColorHexTests` 追加 2 用例（defaultPalette 全可解析 + defaultHex=first 契约），ColorHexTests 用例数 10 → 12。
R38-I 在已有 `AppStoreTests` 追加 2 用例（deleteEntries/deleteTodos 空数组 no-op），AppStoreTests 用例数 45 → 47。
R38-J 在已有 `AppDatabaseTests` 追加 1 用例（IntegrityError.description 同时含 label + message + 前缀），AppDatabaseTests 用例数 8 → 9。
R38-L 新建 `RecordDerivedTests` 2 用例（WorkEntryRecord.day / MeetingRecord.day = startOfDay(for: timestamp)），按天聚合分组键的契约钉死。

R39-A 新建 `NextRecurrenceTests` 3 用例（WorkEntryRecord.nextRecurrenceDate：finishDate 非 nil 用 finishDate / finishDate=nil fallback Date() / weekly+空 weekdays 返回 nil fallback Date()）。
R39-B 在 `NextRecurrenceTests` 追加 2 用例（MeetingRecord.nextFutureOccurrence：daily 推进 / weekly+空 weekdays fallback timestamp），NextRecurrenceTests 用例数 3 → 5。
R39-C 在已有 `BackupServiceIntegrationTests` 追加 1 用例（snapshotFromMemory 降级路径：6 主表 + 关系映射与 snapshotAtomic 一致），BackupServiceIntegrationTests 用例数 8 → 9。`snapshotFromMemory` 从 private 改 internal 以让单测能直接覆盖降级路径。
R39-D 新建 `RecordMappingTests` 3 用例（NewWorkEntry.toRecord 字段拷贝 + interval=0/-100 钳为 1 + NewMeeting.toRecord interval=0/-5 钳为 1）。
R39-E 在 `RecordMappingTests` 追加 5 用例（4 个派生属性 getter 的非法 rawValue fallback + 合法 rawValue round-trip），RecordMappingTests 用例数 3 → 8。
R39-F 在已有 `AppStoreTests` 追加 2 用例（setReportTags unknown reportId：空 tagIds no-op / 非空 tagIds FK 违规抛错），AppStoreTests 用例数 47 → 49。
R39-H 抽 `ExportService.todoCSVRow(title:isDone:dueDate:completedAt:createdAt:tags:)` 纯函数（原 25 行 exportTodosCSV 内联），在 `ExportServiceTests` 追加 3 用例（nil 渲染空串 / isDone→"是" / tags 含逗号走 csvEscape），ExportServiceTests 用例数 17 → 20。
R39-K 在已有 `RecordQueriesTests` 追加参数化测试（TagLinkTable.rawValue 与对应中间表 Record.databaseTableName 字符串相等，4 case），RecordQueriesTests 用例数 10 → 11。

R40-A 在已有 `BackupServiceTests` 追加 1 用例（Snapshot 全字段 round-trip：构造含 6 主表各 1 条 + recurrenceWeekdays/monthDays/reviewIds/meetingId/order 等之前未覆盖字段，encode→decode 后字段级断言），BackupServiceTests 用例数 41 → 42。原 snapshotRoundTrip 只覆盖 1 个 TagDTO，5 张表的字段从未走过 encode→decode。
R40-D 在已有 `RecurrenceTests` 追加 2 用例（label weekly+空 weekdays 返回 "每周" / "每2周" + monthly+空 monthDays 返回 "每月" / "每3月"），RecurrenceTests 用例数 27 → 29。钉死 label 内 `guard !isEmpty else { return prefix }` 分支。
R40-E 在已有 `DaySliceTests` 追加 2 用例（plannedSort 同优先级一侧 finishDate=nil fallback timestamp + 两侧都 nil 纯 timestamp 比较），DaySliceTests 用例数 6 → 8。原 plannedSort 测试两侧都给 finishDate，`?? timestamp` fallback 分支从未覆盖。
R40-F `BackupService.insertSnapshot` 从 private 改 internal，在已有 `BackupServiceIntegrationTests` 追加 1 用例（直接 queue.write + insertSnapshot，验证 6 主表 + 2 张关键中间表 tag_work_entry / tag_meeting 写入），BackupServiceIntegrationTests 用例数 9 → 10。原仅通过 restore 间接覆盖，失败时无法定位是 insertSnapshot 还是 truncate/VACUUM 包装层。
R40-G 抽 `ExportService.doneEntriesSorted(_:)` 纯函数（原 exportWeekDoneXLSX 内联 filter+sort），在已有 `ExportServiceTests` 追加 3 用例（done 通过 / planned+blocker 过滤 / finishDate ?? timestamp 升序 + nil fallback），ExportServiceTests 用例数 20 → 23。归属日语义是周报按完成日分天的核心，原绑死 NSSavePanel 无法单测。
R40-H 在已有 `EnumDisplayTests` 追加 3 参数化用例（blockerColorDelegatesToStatusForAllCases × 3 status + doneColorIgnoresStatusParameter × 3 + plannedColorIgnoresStatusParameter × 3），EnumDisplayTests 用例数 12 → 15。原 workKindColorDelegatesToBlockerStatusWhenBlocker 只覆盖 ongoing+closed 两个 status，done/planned 不传 status 无法验证「忽略」契约。
R40-J 在已有 `RecordMappingTests` 追加 3 用例（TagRecord.swiftUIColor 非法 hex fallback .accentColor + 空 hex fallback + 合法 hex round-trip 走 hexString），RecordMappingTests 用例数 8 → 11。`Color(hex:) ?? .accentColor` 兜底是 UI 不崩的关键，原零覆盖。

R41-A 在已有 `ExportServiceTests` 追加 3 用例（markdownForDay 缺失某 kind 不输出对应标题 / 空 detail 不输出 4 空格缩进行 / 无 tag 不输出 · 分隔符），ExportServiceTests 用例数 23 → 26。原测试覆盖了「分组排序」但 3 个渲染细节分支（kind 缺失 / detail 空 / tag 空）从未钉死。
R41-D 在已有 `DaySliceTests` 追加 2 用例（contains(entry:) blocker 分支：今日归属 / 昨日排除 + done finishDate=nil fallback timestamp 归属今日），DaySliceTests 用例数 8 → 10。原 done 分支只覆盖 finishDate 非 nil 路径，blocker 分支零覆盖。
R41-E 在已有 `DaySliceTests` 追加 2 用例（isTodayPlanned finishDate=nil fallback timestamp 今日归属 / 昨日 timestamp 排除），DaySliceTests 用例数 10 → 12。planned finishDate=nil 是「无截止日的计划任务」常见路径。
R41-G 在已有 `SweepWorkEntriesTests` 追加 1 用例（recurring planned finishDate=nil skip，不推进），SweepWorkEntriesTests 用例数 4 → 5。nextRecurrenceDate 对 nil finishDate fallback Date() 会导致每秒都「逾期」，sweepWorkEntries 守住 top-level skip 避免原地循环。
R41-K 新建 `InlineSummaryEditorTests` 7 用例（InlineSummaryEditor.Style 6 派生属性：minHeight/cornerRadius/textPaddingH/placeholderPaddingH/placeholderPaddingV/font，3 个 case 显式断言），InlineSummaryEditorTests 用例数 0 → 7。3 处调用点（概要 / 菜单栏面板 / 会议详情卡）共享 Style enum，改任一派生属性会让 3 处视觉同时错乱且无编译期信号。
R41-L 在已有 `NewEntryDraftTests` 追加 1 用例（consume 保留 selectedTags 顺序：UUID 字典序倒序传入 3 个 tag，结果保持传入顺序），NewEntryDraftTests 用例数 9 → 10。selectedTags.map(\.id) 一旦误改成 Set(...).map 会去重 + 乱序，UI/导出顺序不可预期。
R41-M 在已有 `RecordQueriesTests` 追加 2 用例（replaceTagLinks DELETE+INSERT 原子性：insert 3 → replace 2 → 只剩 2 不是 append 到 5 + 空数组清空全部旧关系），RecordQueriesTests 用例数 11 → 13。replace 不是 append 语义从未直接测，原仅靠 setEntryTags 间接路过。

R42-A 新建 `ConvertKindTests` 7 用例（HistoryView.convertKind 6 跨 kind 转换 + same-kind no-op + extra 闭包），ConvertKindTests 用例数 0 → 7。`convertKind` 从 private 改 internal static 让单测可覆盖（与 R25-F sweepMeetings / R35-B belongDate 同款抽法）。dropDestination 的核心副作用——跨 kind 拖拽时清理对方专属字段（防「周期性 blocker」「立刻 isOverdue 的 planned」等怪胎数据）——原为零覆盖。
R42-B 在已有 `RecurrenceTests` 追加 3 用例（label 三分支 interval=0/negative 兜底为 1），RecurrenceTests 用例数 29 → 32。原 label 测试 interval 都 ≥ 1，`let n = max(1, interval)` 防御分支从未覆盖。手改 plist / 历史脏数据可能写入非法 interval，display 不该出现「每0天」「每-3周」。
R42-C 在已有 `RecurrenceTests` 追加 3 用例（nextFutureDate 三分支 interval=0/negative 兜底为 1，用「与 interval=1 等价」属性测试避开 Calendar.current 时区差异），RecurrenceTests 用例数 32 → 35。nextFutureDate 内 `let n = max(1, interval)` 是防 division-by-zero 的关键（daily 用 stepSeconds=TimeInterval(n)*.day 算 jumps=Int(elapsed/stepSeconds)，n=0 会触发除零）。
R42-D 新建 `TimeLabelTests` 4 用例（SettingsView.timeLabel 边界），TimeLabelTests 用例数 0 → 4。`timeLabel` 从 private 实例方法改 static internal（与 R35-B belongDate 同款抽法）。设置页提醒时间显示用，改坏会让用户设的 18:30 显示成 06:05 等（除法/取模顺序错位）。
R42-E 新建 `DeleteMessageTests` 2 用例（TodayView.deleteMessage nil→"" + non-nil 文案），DeleteMessageTests 用例数 0 → 2。`deleteMessage` 从 private static 改 internal static。删除 alert 文案 helper，改坏会让 alert 显示 "「Optional(...)」将被删除。" 或空 alert。

R43-A 新建 `MatchesSearchTests` 7 用例（HistoryView.matchesSearch 搜索过滤 6 分支 + entry/meeting 共享逻辑），MatchesSearchTests 用例数 0 → 7。原两个 private 实例重载（WorkEntry / Meeting）零覆盖，抽共享 `static func matchesSearch(title:detail:key:)` 后 WorkEntry/Meeting 实例重载改为薄包装。改坏 `lowercased()` 或 `contains` 顺序会让看板搜索静默失效或假命中。
R43-B 新建 `WeekRangeTests` 5 用例（WeeklyReportView.weekRange/weekDays 周锚点归一化），WeekRangeTests 用例数 0 → 5。原 private 实例属性零覆盖，抽 `static func weekRange(anchor:)` + `static func weekDays(start:)` 后可单测。改坏会让整周聚合错位（任务算到错的周 / weekDays 少一天导致 UI 缺列）。`@MainActor` 标注匹配 SwiftUI View 主线程隔离。
R43-C 新建 `SnapshotFromDBQueueTests` 2 用例（BackupService.snapshotFromDBQueueIfPossible 容错路径），SnapshotFromDBQueueTests 用例数 0 → 2。用 `backupDirectoryOverride` 注入 tmp 目录隔离文件副作用。覆盖原两个 early-return 分支：未迁移 schema 的 queue 触发 fetchAll 抛错→catch return / 已迁移空 queue→写 salvage JSON 可 decode 回空 Snapshot。是主库损坏后「数据抢救」链路的兜底，原零覆盖。
R43-D 新建 `CollectUsedTagsTests` 7 用例（TodayView.collectUsedTags 三段去重），CollectUsedTagsTests 用例数 0 → 7。原 private 实例方法零覆盖，抽 `static func collectUsedTags(entries:meetings:planned:tagsByEntry:tagsByMeeting:)` 接收 5 参数。改坏会让今日页面标签栏重复显示 tag 或漏掉某个 tag。
R44-A 新建 `ValidReviewsTests` 6 用例（MeetingCard.validReviews 过滤+排序），ValidReviewsTests 用例数 0 → 6。原 instance computed property 零覆盖，抽 `static func validReviews(from:)` 后可单测。覆盖占位行过滤（reviewer+opinion 双空丢弃，仅一项有值保留）+ order 升序。改坏会让卡片标题显示「评审（3）」但实际只有 1 条（占位行污染）或顺序错乱。`@MainActor` 标注匹配 SwiftUI View 主线程隔离。
R44-B 新建 `SummaryStatsTests` 5 用例（TodayView.summaryStats 概要统计），SummaryStatsTests 用例数 0 → 5。原内联在 statBar ViewBuilder 里零覆盖，抽 `static func summaryStats(entries:meetings:) -> SummaryStats`（含具名 struct 让断言可读，避免依赖元组字面量顺序）后可单测。覆盖「total = done+planned+blocker（不含会议）/ rate = total > 0 ? done/total : 0」防除零契约。改坏会除零 crash 或统计条数字与列表不一致。
R44-C 新建 `BoardItemTests` 9 用例（HistoryView.BoardItem 派生属性），BoardItemTests 用例数 0 → 9。原 `private enum BoardItem` + 两个 `private func priorityOf/statusOf` 零覆盖，BoardItem 改 internal + 两个 helper 改 `static func`。覆盖 id/sortDate（finishDate ?? timestamp fallback / 会议固定 timestamp）/ priorityOf（任务取自身 priority 三档 / 会议固定 medium）/ statusOf（任务取自身 blockerStatus 三档 / 会议固定 ongoing）全 case。改坏会让计划列分组错位（高优先级跑到底部）或状态分组混入会议（ongoing 误归类）。
R44-D 新建 `PlannedColumnSortTests` 5 用例（HistoryView.sortPlannedColumn 复合排序），PlannedColumnSortTests 用例数 0 → 5。原内联在 columnItems 闭包 `items.sorted { ... }` 零覆盖，抽 `static func sortPlannedColumn(_:)` 后可单测。覆盖「优先级 sortOrder 升序 → sortDate 升序」复合契约（含会议默认 medium 与 medium 任务同组按时间排序）。改坏会让高优先级沉底（用户看不到最重要的待办）或逾期任务被远期任务掩盖。

### 14.2 测试模式约定

- **in-memory GRDB**：每个测试 `makeStore()` 起一份新的 `DatabaseQueue(configuration:) + AppMigrator.makeMigrator().migrate(queue)`，互不污染；`@MainActor` 标注符合 AppStore 主线程隔离
- **tmp 目录隔离文件系统测试**：`BackupServiceTests` 用 `FileManager.temporaryDirectory.appendingPathComponent("DailyReportTests-\(UUID())")` 每测一建一删
- **raw queue 测试不标 @MainActor**：`MigratorTests` 直接 `queue.write/read` 构造 v1 fixture，无 AppStore 包装；`@MainActor` 会让 `queue.write { }` 报 "expression is async"（GRDB 闭包跨 actor）
- **fixture 用 Date 而非 ISO8601 字符串**：GRDB `.datetime` 列内部用毫秒精度 ISO8601，与 `ISO8601DateFormatter` 字符串不等价；fixture INSERT 必须 `arguments: [day]`（Date），否则 `WHERE date = ?` 永远 miss

## 15. 已知限制

- **数据目录与 app 同级**：`db/` / `dbbackup/` / `logs/` 都在 `DailyReport.app` 旁边，整包移动即携带；但也意味着拖动 `.app` 到废纸篓不会自动清理这些目录，需手动删除。
- **SMAppService 签名要求**：ad-hoc 签名在大多数 macOS 版本能注册登录项，个别版本可能拒绝；失败时开关自动回滚 + 蜂鸣，回退到系统设置手动加登录项。
- **导出**：当前仅 UI 暴露周报 XLSX（带星期列，按完成日排序）。概要/时间线的历史 Markdown/CSV 导出入口已移除（代码路径保留，未在 UI 暴露）。
- **无云同步**：纯本地 GRDB SQLite；跨设备需手动 JSON 导出/导入。
- **无 VersionedSchema**：schema 变更通过 GRDB `DatabaseMigrator` 显式注册迁移（当前 `v1_initial` + `v2_unique_daily_report_date` + `v4_unique_tag_name` + `v5_unique_review_meeting_order`）；主库损坏靠归档 + JSON 抢救 + 空库重建兜底（个人工具的权衡）。

## 16. 未来可能扩展（未实现）

- iCloud 同步（CloudKit + NSPersistentCloudKitContainer / SwiftData cloud sync）
- AI 周报总结（基于周内 WorkEntry + Meeting summary 生成草稿）
- 全局快捷键唤起菜单栏面板
- 多账号 / 团队共享
- iOS 端只读查看（通过导出的 JSON）

## 17. 架构决策记录（ADR）

### 17.1 ValueObservation 改造评估（R22-C，结论：不实施）

**背景**：当前 `AppStore` 用 `dbQueue.write { } → reloadAll()` 模式，每次写都全量重读 6 主表 + 4 中间表 JOIN + reviews by meeting（约 11 条 SQL）。GRDB 提供 `ValueObservation` 可订阅表级变更，理论上能做细粒度异步刷新。

**评估结论**：当前规模下不实施。理由：

1. **数据规模远未达临界点**：个人工具月增百条级，5 年累积约 6000 条 entry + 几百个 meeting。`reloadAll` 整体耗时实测 < 5ms，与一次 SwiftUI body 重算开销相当。优化收益低于噪声
2. **关系映射是主要成本，observation 不能消除**：`tagsByEntry / tagsByMeeting / reviewsByMeeting` 仍需 JOIN 全表。即便主表订阅了变更，关系映射仍要重建。改 observation 只是「换个时机跑同样的 SQL」
3. **`@Observable` 已做属性级依赖追踪**：SwiftUI 只刷新读到了变更属性的视图。比如 `entries` 变更时，只读 `meetings` 的视图不会重算。ValueObservation 在 UI 刷新粒度上没有额外收益
4. **同步语义对用户体验更友好**：用户点「完成」→ `markEntryDone` → `reloadAll` 同步返回 → UI 立即反馈。改 observation 后写入异步触发刷新，用户能感知到延迟
5. **测试与并发复杂度**：observation 默认在后台 queue 派发，所有访问需要 `MainActor.assumeIsolated` 或 `await MainActor.run { }` 跳回主线程；143+ 现有测试需要全部加 async fixture。改动面巨大但收益不明确

**何时需要重新评估**：
- 单库 entry 数 > 50k（reloadAll 实测 > 50ms，开始能感知到卡顿）
- 引入跨进程 / 跨设备同步（observation 是必经之路）
- 多窗口同时编辑同一实体（observation 自动同步优于手动 reload）

**当前架构的留口**：`AppStore.reloadAll()` 是单方法入口，未来若切 ValueObservation，只需替换该方法内部实现（订阅 + 缓存 diff），所有调用方零改动。


