# DailyReport — macOS 菜单栏日报助手

一个常驻菜单栏的轻量日报工具。点击菜单栏图标即可弹出面板随手记录，需要更多空间时打开完整主窗口。

> 详细设计方案见 [DESIGN.md](./DESIGN.md)。

## 功能

- **菜单栏面板** — 快速添加任务（完成 / 计划 / 问题，彩色胶囊切换）、标签、优先级、周期；下方一览今日记录 / 计划列表（每条可一键完成）/ 今日会议
- **概要** — 顶部统计概览条（完成 / 计划 / 问题 / 会议计数 + 完成率）；今日记录按类聚合；计划列表可一键完成或删除；今日会议；标签栏覆盖「今日记录 + 会议 + 计划列表」联动筛选
- **时间线** — 完成 / 计划 / 问题三列看板，三列各自独立滚动，拖拽改分类；计划列按优先级分组，问题列按「优先级 + 状态」双层嵌套分组；全文本搜索（标题 / 详情 / 会议主题），任务卡片可编辑 / 删除 / 打标签
- **会议纪要** — 会议记录与评审；周期性会议逾期自动推进到下一期；**会议概要支持随时内联编辑**（概要 / 菜单栏面板对今日会议始终可写；会议纪要页对未开会议可写，已开会议只读防误改，仍可通过「编辑」表单修改）
- **周报** — 按周翻阅，任务按**归属日**分天（完成 / 计划按 finishDate，问题按发生日）；提前完成的任务落回实际完成那天；统计卡 + 导出 XLSX（带「星期」列，按完成日排序）
- **标签** — 任务 / 日报 / 会议共享，自定义颜色，回车即建
- **周期性** — 会议与计划任务逾期原地推进；计划任务完成时克隆下一次（保留滚动计划）
- **数据安全** — 启动自动 boot 快照 + 每周五触发 weekly 备份（周五没开自动在周六/周日补）；导入前自动留 pre-import 快照；JSON 全量导出 / 导入；GRDB 主库打开失败时三级容错（归档 + JSON 抢救 + 空库重建 / fallback）
- **写失败显式反馈** — 删除 / 保存 / 拖拽分类等所有写操作失败时弹「写入失败」alert（不再静默吞 throws 让 UI 假成功），写失败保留草稿让用户重试
- **每日提醒** — 可设时间的本地通知
- **外观切换** — 跟随系统 / 浅色 / 深色，设置页一键切换（主窗口、菜单栏面板、设置窗统一）
- **开机自启** — 设置页开关；基于 `SMAppService` 注册登录项，首次开启系统授权一次
- **纯菜单栏运行** — `LSUIElement`，不占 Dock 位置

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

> Swift Testing 框架随 Xcode 提供（CLT 不带），需临时指定 `DEVELOPER_DIR`。**194 tests / 13 suites** 覆盖：

| Suite | 覆盖点 |
|---|---|
| `AppStoreTests` (36) | Tag/DailyReport/TodoItem/WorkEntry/Meeting/Review 的 CRUD + CASCADE + 关系重建 + unknown id 静默 no-op（update + delete 全覆盖）+ addReview FK 违规 + markEntryDone race + blocker→done 原地降级 + transactional 回滚 + vacuum + insert 路径的 tag/review 同步绑定 |
| `MigratorTests` (9) | v1→v2 dedup 合并 + UNIQUE 约束；v3 扩展性 + 幂等性 + 索引回归；v4 tag.name dedup（保最早 createdAt + 4 张中间表关系 INSERT OR IGNORE 迁移 + dangling 残留显式清理）+ v4 clean no-op |
| `BackupServiceTests` (33) | weekKey（含跨月/跨年边界）+ 各 prefix backup 存在性 + prune 策略 + decode 拒绝高版本/坏 JSON + decode 加固（payloadTooLarge / danglingTagReference） |
| `BackupServiceIntegrationTests` (8) | snapshotAtomic 全实体 + restore round-trip + 空 snapshot 清库 + weeklyBackupIfDue 窗口判断（周五触发 / 同周幂等 / 窗口外跳过 / 写失败返回 false） |
| `RecurrenceServiceTests` (15) | sweep 推进 + markDone 克隆下一期 + race no-op + 月度周期跨月边界（含月末 overflow 31→非 2 月）+ cleanup 分支（保 summary / 保 review） |
| `RecurrenceTests` (21) | daily/weekly/monthly + interval 跳跃 + 月末 overflow 防御 |
| `XLSXWriterTests` (19) | XML 转义 + 列字母 + CRC32 |
| `AppLoggerTests` (7) | 文件滚动各场景 |
| `ExportServiceTests` (17) | csvEscape / sanitizeSheetName / sanitizeFilename / weekdayName / markdownForDay 分组排序与 note 兜底（R21-A 测试发现并修复了「entries 为空时 note 不渲染」的 bug）+ WorkKind.emoji 编译期覆盖所有 case |
| `NavigationCoordinatorTests` (5) | 越界 rawValue 兜底回 .today + 持久化 round-trip + openMeetingEdit 切 tab（`.serialized` 隔离 UserDefaults 单例串扰） |
| `ReminderServiceTests` (7) | decision 三分支决策：disabled → removeOnly / enabled + denied → none（保旧 pending）/ enabled + 非 denied → removeAndAdd；Decision case 互斥性 |
| `NewEntryDraftTests` (9) | NewEntryDraft.canSubmit（标题空/分类非法）+ consume 三种 kind 派发 + reset 回默认 |
| `AppDatabaseTests` (7) | archiveCorruptedDB 三件套归档 + 同秒冲突 -2 后缀 + README 含 reason + 源缺失 no-op；pruneCorruptedArchives 保留最新 N + 上限内 no-op + 目录缺失 no-op |

View 层不测（SwiftUI 视图组合靠人工验证）。

## 数据目录布局

app 同级三个目录，整包可携带 / 备份：

| 目录 | 内容 |
|---|---|
| `db/` | `db.sqlite`（主库）+ WAL；`db.fallback.sqlite`（兜底）；`corrupted/<ISO>/`（损坏归档，保留最近 5 个） |
| `dbbackup/` | `boot-*.json`（启动快照，同日去重，保留 10 份）、`weekly-<ISO>-<weekKey>.json`（每周一份，月清理 + 硬上限 12 份）、`manual-*.json`、`pre-import-*.json`、`salvage-*.json` |
| `logs/` | `app.log`（1 MB 自动滚动，保留 5 份）+ `.swiftdata_warned`（旧 SwiftData 库告警去重标志） |

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
Tests/DailyReportTests/      # 194 tests / 13 suites（详见 DESIGN.md §14）
scripts/build-app.sh         # 构建 + 打包（纯 CLT）
Resources/Info.plist.template
```
