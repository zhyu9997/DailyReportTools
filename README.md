# DailyReport — macOS 菜单栏日报助手

一个常驻菜单栏的轻量日报工具。点击菜单栏图标即可弹出面板随手记录，需要更多空间时打开完整主窗口。

> 详细设计方案见 [DESIGN.md](./DESIGN.md)（每功能、每张数据表、每个服务、每个测试套件均有详解）。

---

## 架构总览

三层架构 + 单一可信源（AppStore）：

```
┌──────────────────────────────────────────────────────────┐
│  View 层（SwiftUI）                                       │
│  MenuPanelView / MainTabView / TodayView / HistoryView / │
│  MeetingView / WeeklyReportView / SettingsView           │
│  Components/（TagPicker / KindPicker / RecurrenceEditor  │
│             / WorkEntryCard / InlineSummaryEditor ...）   │
└──────────────┬───────────────────────────────────────────┘
               │  @Environment(\.appStore)  只读快照 + 写入口
┌──────────────▼───────────────────────────────────────────┐
│  Service 层                                               │
│  AppStore（@Observable @MainActor，中心数据入口）         │
│  RecurrenceService（周期推进）/ BackupService（容灾快照）│
│  ExportService（XLSX/Markdown）/ XLSXWriter（ZipBuilder）│
│  ReminderService（UNUserNotification）/ AppLogger        │
└──────────────┬───────────────────────────────────────────┘
               │  DatabaseQueue.write { db in ... } 同步事务
┌──────────────▼───────────────────────────────────────────┐
│  Database 层（GRDB.swift 6.29）                           │
│  Records（6 主表 + 4 中间表 struct）                      │
│  Migrator（v1/v2/v4/v5）                                  │
│  AppDatabase（三级容错：归档 / JSON salvage / fallback）  │
│  RecordQueries（JOIN helper）                             │
└──────────────────────────────────────────────────────────┘
```

各层职责与设计决策详见 DESIGN.md：

- §2 整体架构（三 Scene 共享 AppStore / 启动流程 / 数据流）
- §5 数据模型（10 张表逐字段详解 + 中间表 + helper + 草稿类型）
- §6 核心业务语义（任务归属日 / 今日判定 / 周期推进 / 统一完成路径 / 跨日监听）
- §7 视图层（每个 Tab / 面板的功能、绑定、写回策略）
- §8 组件库（8 个复用组件）
- §9 服务层（AppStore API 总览 / RecordQueries / Migrator / 5 个 Service）
- §10 关键流程图解（添加任务 / 完成计划 / 跨日推进 / 导入 / 主库容错）
- §11 数据安全策略 / §13 构建与签名 / §14 测试套件（含 574 tests 全清单）

---

## 功能

### 入口与导航

- **菜单栏常驻** — 点击 ✅ checklist 图标弹出今日面板（快速记录 / 一览今日 / 今日会议）；菜单内「打开主窗口」进完整功能
- **三 Tab 主窗口** — 概要 / 时间线 / 会议纪要 + 独立周报窗口 + 独立设置窗
- **纯菜单栏运行** — `LSUIElement`，不占 Dock 位置
- **外观切换** — 跟随系统 / 浅色 / 深色（主窗口 / 菜单栏面板 / 设置窗统一）
- **开机自启** — `SMAppService` 注册登录项，首次开启系统授权一次

### 数据录入与编辑

- **菜单栏面板** — 快速添加任务（完成 / 计划 / 问题，彩色胶囊切换）、标签、优先级、周期；下方一览今日记录 / 计划列表（每条可一键完成）/ 今日会议
- **概要（TodayView）** — 顶部统计概览条（完成 / 计划 / 问题 / 会议计数 + 完成率）；今日记录按类聚合；计划列表可一键完成或删除；今日会议；标签栏覆盖「今日记录 + 会议 + 计划列表」联动筛选
- **时间线（HistoryView）** — 完成 / 计划 / 问题三列看板，三列各自独立滚动，拖拽改分类；计划列按优先级分组，问题列按「优先级 + 状态」双层嵌套分组；全文本搜索（标题 / 详情 / 会议主题），任务卡片可编辑 / 删除 / 打标签
- **会议纪要（MeetingView）** — 会议记录 + 评审意见；周期性会议逾期自动推进到下一期；**会议概要支持随时内联编辑**（概要 / 菜单栏面板对今日会议始终可写；会议纪要页对未开会议可写，已开会议只读防误改，仍可通过「编辑」表单修改）
- **周报（WeeklyReportView）** — 按周翻阅，任务按**归属日**分天（完成 / 计划按 finishDate，问题按发生日）；提前完成的任务落回实际完成那天；统计卡 + 导出 XLSX（带「星期」列，按完成日排序）

### 标签与周期性

- **标签** — 任务 / 日报 / 会议共享，自定义颜色（调色板轮选防撞色），回车即建，多对多关系（中间表 + `ON DELETE CASCADE`）
- **周期性** — 会议与计划任务逾期原地推进（daily / weekly / monthly，含 interval 跳跃 + 月末 overflow 防御）；计划任务完成时克隆下一次（保留滚动计划）

### 数据安全与容灾

- **三级容错链路** — GRDB 主库打开失败时：归档到 `corrupted/<ISO>/` → sqlite3 抢救快照为 JSON → 空库重建（或 `db.fallback.sqlite`）
- **自动备份** — 启动自动 boot 快照（同日去重，保留 10 份）+ 每周五触发 weekly 备份（周五没开自动在周六/周日补，月清理 + 硬上限 12 份）
- **导入保护** — 导入前自动留 pre-import 快照；JSON 全量导出 / 导入
- **写失败显式反馈** — 删除 / 保存 / 拖拽分类等所有写操作失败时弹「写入失败」alert（不再静默吞 throws 让 UI 假成功），写失败保留草稿让用户重试

### 其他

- **每日提醒** — 可设时间的本地通知（`UNUserNotification`），授权状态三分支决策
- **纯 CLT 编译** — 仅需 Command Line Tools（无需完整 Xcode），`bash scripts/build-app.sh` 一行打包

> 导出当前仅保留**周报 XLSX**（按星期几组织）。时间线 / 概要的历史导出入口已移除。

## 构建

需要 macOS 14+ 与 **Swift 6 / Command Line Tools**（无需完整 Xcode）。

```bash
bash scripts/build-app.sh
```

产物：`DailyReport.app`（ad-hoc 签名，与可执行文件同级的 `db/`、`dbbackup/`、`logs/` 目录会在首次启动自动创建）。

启动：

```bash
open DailyReport.app
```

卸载（数据目录一并删除）：

```bash
rm -rf DailyReport.app db dbbackup logs
```

## 测试

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

> Swift Testing 框架随 Xcode 提供（CLT 不带），需临时指定 `DEVELOPER_DIR`。**574 tests / 64 suites** 覆盖：

| Suite | 覆盖点 |
|---|---|
| `AppStoreTests` (49) | Tag/DailyReport/TodoItem/WorkEntry/Meeting/Review 的 CRUD + CASCADE + 关系重建 + unknown id 静默 no-op（update + delete 全覆盖）+ addReview FK 违规 + markEntryDone race + blocker→done 原地降级 + planned 非周期原地降级 + transactional 回滚 + vacuum + insert 路径的 tag/review 同步绑定 + getOrCreateTag 三分支 + updateTag 选择性更新四分支（R37-B/C）+ delete*空数组 no-op + truncateAll 4 表参数化（R38-B/I）+ setReportTags unknown id 路径（R39-F） |
| `MigratorTests` (9) | v1→v2 dedup 合并 + UNIQUE 约束；v3 扩展性 + 幂等性 + 索引回归；v4 tag.name dedup（保最早 createdAt + 4 张中间表关系 INSERT OR IGNORE 迁移 + dangling 残留显式清理）+ v4 clean no-op |
| `BackupServiceTests` (42) | weekKey（含跨月/跨年边界）+ 各 prefix backup 存在性 + prune 策略 + decode 拒绝高版本/坏 JSON + decode 加固（payloadTooLarge / danglingTagReference）+ Snapshot 全字段 round-trip（6 主表 + recurrenceWeekdays/monthDays/reviewIds/meetingId/order 全字段）（R40-A） |
| `BackupServiceIntegrationTests` (10) | snapshotAtomic 全实体 + restore round-trip + 空 snapshot 清库 + weeklyBackupIfDue 窗口判断（周五触发 / 同周幂等 / 窗口外跳过 / 写失败返回 false）+ insertSnapshot 直接单测（隔离 restore 包装层，钉死 DTO→Record 映射 + 中间表关系）（R40-F） |
| `RecurrenceServiceTests` (15) | sweep 推进 + markDone 克隆下一期 + race no-op + 月度周期跨月边界（含月末 overflow 31→非 2 月）+ cleanup 分支（保 summary / 保 review） |
| `RecurrenceTests` (35) | daily/weekly/monthly + interval 跳跃 + 月末 overflow 防御 + weekdayLong/weekdaySymbol 越界兜底（R35-F/R37-G）+ label 空 weekdays/monthDays 返回纯前缀分支（R40-D）+ label/nextFutureDate 的 interval ≤ 0 兜底为 1（属性等价测试，R42-B/C） |
| `XLSXWriterTests` (22) | XML 转义 + 列字母 + CRC32 + dosDateTime 边界（R37-F） |
| `EnumDisplayTests` (15) | WorkKind/BlockerStatus/Priority/RecurrenceUnit 展示属性非空 + 互斥 + sortOrder（R37-A）+ WorkKind.color(status:) 全 9 组合参数化（blocker 委托 status，done/planned 忽略 status）（R40-H） |
| `AppearanceModeTests` (6) | colorScheme 三分支 + localizedName 非空/互斥（R37-D） |
| `AppTabTests` (6) | 4 tab title/systemImage 非空/互斥 + rawValue 连续 0...3（R37-E） |
| `AppLoggerTests` (7) | 文件滚动各场景 |
| `ExportServiceTests` (26) | csvEscape / sanitizeSheetName / sanitizeFilename / weekdayName / markdownForDay 分组排序与 note 兜底（R21-A 测试发现并修复了「entries 为空时 note 不渲染」的 bug）+ WorkKind.emoji 编译期覆盖所有 case + doneEntriesSorted 过滤 + 归属日排序（finishDate ?? timestamp fallback）（R40-G）+ markdownForDay kind 分组（缺失 kind 不输出标题）+ 空 detail 不输出缩进行 + 无 tag 不输出 · 分隔符（R41-A） |
| `NavigationCoordinatorTests` (5) | 越界 rawValue 兜底回 .today + 持久化 round-trip + openMeetingEdit 切 tab（`.serialized` 隔离 UserDefaults 单例串扰） |
| `ReminderServiceTests` (7) | decision 三分支决策：disabled → removeOnly / enabled + denied → none（保旧 pending）/ enabled + 非 denied → removeAndAdd；Decision case 互斥性 |
| `NewEntryDraftTests` (10) | NewEntryDraft.canSubmit（标题空/分类非法）+ consume 三种 kind 派发 + reset 回默认 + consume 保留 selectedTags 顺序（UUID 字典序倒序传入不重排）（R41-L） |
| `AppDatabaseTests` (9) | archiveCorruptedDB 三件套归档 + 同秒冲突 -2 后缀 + README 含 reason + 源缺失 no-op；pruneCorruptedArchives 保留最新 N + 上限内 no-op + 目录缺失 no-op；IntegrityError.description 含 label + message + 前缀（R38-J） |
| `ConvertKindTests` (7) | HistoryView.convertKind 跨 kind 拖拽字段清理：same-kind no-op / blocker→planned 清 helper+重置 status / done→planned 清 finishDate（防新 planned 立刻 isOverdue）/ planned/done→blocker 清 recurring+finishDate（防「周期性 blocker」怪胎）/ planned→done case break 保留字段 / extra 闭包后执行（R42-A） |
| `TimeLabelTests` (4) | SettingsView.timeLabel 边界：0→"00:00" / 1439→"23:59" / 90→"01:30" / 整点无尾分钟（R42-D，原 private 实例方法零覆盖，改 static internal 抽出） |
| `DeleteMessageTests` (2) | TodayView.deleteMessage nil→空串兜底 + non-nil→"「<title>」将被删除。"（R42-E，原 private static 零覆盖，改 internal 抽出） |
| `MatchesSearchTests` (7) | HistoryView.matchesSearch 搜索过滤：空 key 放行 / title 命中 / detail 命中 / 大小写不敏感 / 全未命中 / entry 与 meeting 共享逻辑（R43-A，原两个 private 实例重载零覆盖，抽共享 static） |
| `WeekRangeTests` (5) | WeeklyReportView.weekRange/weekDays 周锚点归一化：周中锚点 / 周日归上周一（firstWeekday=1 仍锁周一）/ 区间正好 7 天 / 跨月 / weekDays 连续 7 天（R43-B，原 private 实例属性零覆盖） |
| `SnapshotFromDBQueueTests` (2) | BackupService.snapshotFromDBQueueIfPossible 容错路径：未迁移 schema 的 queue 触发 read 抛错→无 salvage / 已迁移空 queue→写出 salvage JSON 可 decode（R43-C，原两个 early-return 分支零覆盖） |
| `CollectUsedTagsTests` (7) | TodayView.collectUsedTags 三段去重（entries + meetings + planned）：空输入 / 单源 / 跨源去重 / 首次出现顺序 / 缺失 tag 映射不 crash（R43-D，原 private 实例方法零覆盖，抽 static 接收 5 参数） |
| `ValidReviewsTests` (6) | MeetingCard.validReviews 过滤+排序：空输入 / 双空占位行被丢弃 / 仅 reviewer 保留 / 仅 opinion 保留 / order 升序 / 同 order 兜底（R44-A，原 instance computed property 零覆盖） |
| `SummaryStatsTests` (5) | TodayView.summaryStats 概要统计：空输入 rate=0 防除零 / 三类计数 / 会议数不计入完成率 / 完成率 = done/total / 全计划无完成时 rate=0（R44-B，原内联在 statBar ViewBuilder 零覆盖） |
| `BoardItemTests` (9) | HistoryView.BoardItem 派生属性：id/sortDate（finishDate ?? timestamp / 会议 timestamp）/ priorityOf（任务取自身 / 会议固定 medium）/ statusOf（任务取自身 / 会议固定 ongoing）三路派生（R44-C，原 private enum + private instance 方法零覆盖） |
| `PlannedColumnSortTests` (5) | HistoryView.sortPlannedColumn 复合排序：空输入 / 优先级 sortOrder 升序 / 同优先级按 sortDate 升序 / 优先级主导时间 / 会议默认 medium 与 medium 任务同组（R44-D，原内联在 columnItems 闭包零覆盖） |
| `FindDroppedEntryTests` (6) | HistoryView.findDroppedEntry 拖放 payload 解析：空数组 / 非法 UUID / 合法 UUID 命中 / UUID 合法但 entry 不在 / 只看 first 元素 / entries 空不 crash（R45-A，原 private 实例方法零覆盖） |
| `WeekTitleTests` (5) | WeeklyReportView.weekTitle 标题格式：「周报 」前缀 / isoDay 双端 / 「 ~ 」分隔符 / 跨月区间 / start==end（R45-B，原 private 实例属性零覆盖） |
| `FilteredEntriesTests` (7) | HistoryView.filteredEntries 标签+搜索双重过滤：无 filterTag 放行 / 仅搜索过滤 / filterTag 关系过滤 / 缺失 tagsByEntry 映射不 crash / AND 语义 / 大小写不敏感 / 空输入（R45-C，原 private 实例属性零覆盖） |
| `KindColorTests` (6) | WorkEntryCard.kindColor 三路颜色派生：done 固定 green 忽略 priority+status / planned 用 priority 色忽略 status / blocker 用 status 色忽略 priority / 互斥性（R45-D，原 private 实例属性零覆盖） |
| `WeekEntriesTests` (6) | WeeklyReportView.weekEntries 半开区间过滤 + belongDate 排序：空输入 / 周一+周日纳入 / 上周日排除 / 下周一 00:00 排除（半开区间契约）/ belongDate 升序乱序验证 / blocker 用 timestamp（R46-A，原 private 实例属性零覆盖） |
| `DayDataTests` (6) | WeeklyReportView.dayData 单日分组：空输入 / 半开区间排除下一天 / 用 belongDate 而非 timestamp / isDate 匹配 report（精度漂移兜底）/ 无匹配返 nil report / tagsByEntry 透传（R46-B，原 private 实例方法零覆盖） |
| `NextDefaultColorTests` (6) | TagPicker.nextDefaultColor 调色板轮选：无使用返 palette[0] / 跳过已用色选下一个 / 跨多个已用色 / 非调色板色不影响 / 全用过按 count%len 轮转 / Set 去重（R46-C，原 private 实例方法零覆盖） |
| `ValidReviewCountTests` (4) | MeetingFormView.validReviewCount 草稿计数：空输入返 0 / 双空占位行被丢弃 / 仅 opinion 有值保留 / isBlank（非 isEmpty）判定纯空格行无效（R46-D，原 private 实例属性零覆盖） |
| `EntriesXLSXRowsTests` (6) | ExportService.entriesXLSXRows 全任务 XLSX 行映射：空输入 / 按 timestamp 升序 / 6 列顺序契约 / tags 用 "/" 拼接 / 缺失映射显空串（非 "nil"）/ kind.rawValue 中文原样输出（R47-A，原内联在 exportEntriesXLSX 绑死 NSSavePanel 零覆盖） |
| `BackupFilenameTests` (6) | BackupService.backupFilename 文件名拼接：两段式（boot/manual 无 suffix）/ 三段式（weekly 含 weekKey）/ .json 后缀 / 「-」分隔符 / 空字符串 suffix 边界（R47-B，原内联在 writeBackup 零覆盖，enumerateBackups 解析依赖此格式契约） |
| `ShiftWeekTests` (6) | WeeklyReportView.shift 周翻页：+1/+2 向前 / -1 向后 / 0 兜底不动 / 跨月 / 跨年 / 等价日期返回（R47-C，原 private 实例方法零覆盖） |
| `EntryDraftMappingTests` (8) | WorkEntryCard.syncDraft/applyDraft 字段对称契约：syncDraft 全字段拷贝 / nil finishDate 兜底 Date() / nil helper 兜底空串 / applyDraft done 写 finishDate / blocker 写 helper+status / 空格 helper 存 nil / planned 保留 recurrence / title trim（R47-D，引入 EntryDraft struct 让两端字段集可断言，原两个 private 实例方法零覆盖） |
| `WeekMarkdownTests` (5) | ExportService.weekMarkdown 周报 Markdown 拼装：空 days 仅标题 / 标题原样注入（不 trim/escape）/ 单日跟分隔符 / 多日各跟分隔符（计数 = days）/ 日内内容透传（R48-A，原内联在 exportWeek 绑死 NSSavePanel 零覆盖） |
| `TodosCSVBodyTests` (6) | ExportService.todosCSVBody 全 Todo→CSV 文本：空输入仅表头 / 表头 6 列顺序 / 单行追加 / 多行顺序 / tags 用「/」拼接 / 缺失映射空串兜底（R48-B，原内联在 exportTodosCSV 零覆盖） |
| `CleanReviewDraftsTests` (7) | MeetingFormView.cleanReviewDrafts 评审草稿清洗：空输入 / 全空过滤 / 仅 reviewer 保留 / 仅 opinion 保留 / trim 两字段 / filter 后 order 顺序重排（防跳号）（R48-C，原内联在 save() 5 步链零覆盖） |
| `MeetingBelongsToColumnTests` (7) | HistoryView.meetingBelongsToColumn 会议→看板列归属：周期性 false / 未来→planned / 过去→done / 跨列互斥 / blocker 列永不收 / timestamp==now 走 done（R48-D，原内联在 columnItems compactMap 零覆盖） |
| `SortDoneColumnTests` (5) | HistoryView.sortDoneColumn done/problem 列降序排序：空数组 / 单元素 / sortDate 降序乱序验证 / finishDate 优先 timestamp 兜底 / 任务+会议混排（R49-A，与 R44-D sortPlannedColumn 对称缺口） |
| `ClearedSiblingArraysTests` (6) | RecurrenceEditor.clearedSiblingArrays 切单位清对侧数组：daily 清两 / weekly 清 monthDays / monthly 清 weekdays / 已空幂等 / weekdays 顺序保留 / monthDays 顺序保留（R49-B，原内联 onChange switch 零覆盖） |
| `ToggledIntTests` (6) | RecurrenceEditor.toggledInt [Int] toggle：空追加 / 末尾追加非空 / 已存在移除 / 重复值全移除 / 多值只移除目标 / 双次 toggle 还原（R49-C，weekdayChip/monthDayButton 两份重复逻辑零覆盖） |
| `FilterMeetingsForColumnTests` (7) | HistoryView.filterMeetingsForColumn 会议三重过滤：无过滤全放行（非周期）/ 标签命中 / 标签不命中全滤 / 标题大小写不敏感 / 概要命中 / tag+search 合取语义 / done 列只收过去（R49-D，原内联在 columnItems compactMap 零覆盖） |

View 层不测（SwiftUI 视图组合靠人工验证）。

## 数据目录布局

app 同级三个目录，整包可携带 / 备份。生产路径为 `~/Library/Application Support/com.zhyu.dailyreport/`，开发模式则在 `.app` 同级（`scripts/build-app.sh` 用 `-DAPP_DATA_DIR` 注入）：

| 目录 | 内容 | 清理策略 |
|---|---|---|
| `db/` | `db.sqlite` + `db.sqlite-wal` / `db.sqlite-shm`（主库 + WAL）；`db.fallback.sqlite`（兜底库）；`corrupted/<ISO>/`（主库损坏时归档的 sqlite + JSON salvage） | 归档保留最近 5 个（`pruneCorruptedArchives`） |
| `dbbackup/` | `boot-<ISO>.json`（启动快照）/ `weekly-<ISO>-w<W>.json`（每周）/ `manual-<ISO>.json`（手动）/ `pre-import-<ISO>.json`（导入前）/ `salvage-<ISO>.json`（主库抢救） | boot 同日去重 + 保留 10 份；weekly 月清理 + 硬上限 12 份 |
| `logs/` | `app.log`（1 MB 自动滚动，保留 5 份）；`.swiftdata_migrated`（旧 SwiftData 库迁移完成标志）；`.swiftdata_warned`（旧库告警去重标志） | 自动滚动 |

迁移自 SwiftData 的用户：旧 `default.store` 保留在同目录（不删），首次启动检测到 `.swiftdata_migrated` 不存在则一次性导入到 `db.sqlite`。

## 使用

1. 启动后菜单栏出现 ✅ checklist 图标，点击弹出今日面板。
2. 在面板里快速添加完成 / 计划 / 问题，选标签、优先级、是否周期。
3. 点「打开主窗口」查看概要、时间线、会议纪要、周报，或打开设置调整提醒 / 外观 / 开机自启 / 数据导入导出。
4. 数据本地保存在 `<appDir>/db/db.sqlite`（GRDB），重启不丢失。

## 技术栈

- Swift 6 + SwiftUI（原生 macOS 14+）
- GRDB.swift 6.29+（`db.sqlite` + WAL，三级容错链路）
- UserNotifications（每日提醒）
- ServiceManagement（开机自启，`SMAppService`）
- SwiftPM 构建 + 脚本打包成 `.app`（ad-hoc 签名）

## 目录结构

```
Sources/DailyReport/
├── DailyReportApp.swift    # @main: MenuBarExtra + 主窗口 + 启动 sweep/backup
├── AppState.swift          # 常量与 UserDefaults 键
├── NavigationCoordinator.swift  # AppTab enum + Tab 选中态
├── Database/               # GRDB 持久层：Records/Migrator(v1+v2+v3+v4)/AppDatabase/AppStore/RecordQueries/Environment
├── Models/                 # 纯数据/枚举（Recurrence、WorkKind 等 + TimeInterval.day/week/year 扩展）
├── Views/                  # 概要 / 时间线 / 会议 / 周报 / 设置 / 菜单栏面板
├── Components/             # 复用组件（InlineSummaryEditor、TagPicker、KindPicker、RecurrenceEditor、WriteErrorAlert…）
└── Services/               # 备份 / 导出 / 周期推进 / 提醒 / 日志
Tests/DailyReportTests/      # 574 tests / 64 suites（详见 DESIGN.md §14）
scripts/build-app.sh         # 构建 + 打包（纯 CLT）
Resources/Info.plist.template
```
