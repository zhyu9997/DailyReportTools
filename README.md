# DailyReport — macOS 菜单栏日报助手

一个常驻菜单栏的轻量日报工具。点击菜单栏图标即可弹出面板随手记录，需要更多空间时打开完整主窗口。

> 详细设计方案见 [DESIGN.md](./DESIGN.md)。

## 功能

- **菜单栏面板** — 快速添加任务（完成 / 计划 / 问题，彩色胶囊切换）、标签、优先级、周期；下方一览今日记录 / 计划列表（每条可一键完成）/ 今日会议
- **概要** — 顶部统计概览条（完成 / 计划 / 问题 / 会议计数 + 完成率）；今日记录按类聚合；计划列表可一键完成或删除；今日会议；标签栏覆盖「今日记录 + 会议 + 计划列表」联动筛选
- **时间线** — 完成 / 计划 / 问题三列看板，三列各自独立滚动，拖拽改分类；计划列按优先级分组，问题列按「优先级 + 状态」双层嵌套分组；全文本搜索（标题 / 详情 / 会议主题），任务卡片可编辑 / 删除 / 打标签
- **待办** — 独立待办项 + 来自时间线的「计划」任务，完成 / 删除
- **会议纪要** — 会议记录与评审；周期性会议逾期自动推进到下一期；**会议概要支持随时内联编辑**（概要 / 菜单栏面板对今日会议始终可写；会议纪要页对未开会议可写，已开会议只读防误改，仍可通过「编辑」表单修改）
- **周报** — 按周翻阅，任务按**归属日**分天（完成 / 计划按 finishDate，问题按发生日）；提前完成的任务落回实际完成那天；统计卡 + 导出 XLSX（带「星期」列，按完成日排序）
- **标签** — 任务 / 日报 / 会议共享，自定义颜色，回车即建
- **周期性** — 会议与计划任务逾期原地推进；计划任务完成时克隆下一次（保留滚动计划）
- **数据安全** — 启动自动 boot 快照 + 每周五触发 weekly 备份（周五没开自动在周六/周日补）；导入前自动留 pre-import 快照；JSON 全量导出 / 导入；GRDB 主库打开失败时三级容错（归档 + JSON 抢救 + 空库重建 / fallback）
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

> Swift Testing 框架随 Xcode 提供（CLT 不带），需临时指定 `DEVELOPER_DIR`。60 个核心算法单测覆盖 `Recurrence` 边缘 case、`BackupService` prune 策略 + snapshot/restore 端到端、`RecurrenceService` 推进、`AppStore` CRUD 与关系重建、`markEntryDone` 克隆逻辑、`AppLogger` 文件滚动（含滚动链路 / 边界 maxBytes=0 / keepCount=1）。核心数据层覆盖率 ≈ 70-100%（Migrator/RecordQueries/Recurrence/RecurrenceService/AppStore/Records），View 层不测。

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
├── Database/               # GRDB 持久层：Records/Migrator/AppDatabase/AppStore/RecordQueries/Environment
├── Models/                 # 纯数据/枚举（Recurrence、WorkKind 等）
├── Views/                  # 概要 / 时间线 / 待办 / 会议 / 周报 / 设置
├── Components/             # 复用组件（标签选择、KindPicker、RecurrenceEditor…）
└── Services/               # 备份 / 导出 / 周期推进 / 提醒 / 日志
Tests/DailyReportTests/      # 核心算法单测（BackupService prune、Recurrence、sweep）
scripts/build-app.sh         # 构建 + 打包
Resources/Info.plist.template
```
