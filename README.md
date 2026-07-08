# DailyReport — macOS 菜单栏日报助手

一个常驻菜单栏的轻量日报工具。点击菜单栏图标即可弹出面板随手记录，需要更多空间时打开完整主窗口。

## 功能

- **菜单栏面板** — 快速添加任务（完成 / 计划 / 问题，彩色胶囊切换）、标签、优先级、周期；下方一览今日记录 / 计划列表 / 今日会议
- **概要** — 顶部统计概览条（完成 / 计划 / 问题 / 会议计数 + 完成率）；今日记录按类聚合；计划列表可一键完成或删除；今日会议；标签栏覆盖「今日记录 + 会议 + 计划列表」联动筛选
- **时间线** — 完成 / 计划 / 问题三列看板，拖拽改分类，全文本搜索（标题 / 详情 / 会议主题），任务卡片可编辑 / 删除 / 打标签
- **待办** — 独立待办项 + 来自时间线的「计划」任务，完成 / 删除
- **会议纪要** — 会议记录与评审；周期性会议逾期自动推进到下一期
- **周报** — 按周翻阅，任务按**归属日**分天（完成 / 计划按 finishDate，问题按发生日）；提前完成的任务落回实际完成那天；统计卡 + 导出 XLSX（带「星期」列，按完成日排序）
- **标签** — 任务 / 日报 / 会议共享，自定义颜色，回车即建
- **周期性** — 会议与计划任务逾期原地推进；计划任务完成时克隆下一次（保留滚动计划）
- **数据安全** — 设置页支持 JSON 全量导出 / 导入；导入前自动留快照；Schema 迁移失败 wipe 前自动备份到 `~/Library/Application Support/com.zhyu.dailyreport/backups/`
- **每日提醒** — 可设时间的本地通知
- **纯菜单栏运行** — `LSUIElement`，不占 Dock 位置

> 导出当前仅保留**周报 XLSX**（按星期几组织）。时间线 / 概要的历史导出入口已移除。

## 构建

需要 **Xcode**（Command Line Tools 缺少 SwiftData 宏插件，脚本会自动切换到 Xcode）。

```bash
bash scripts/build-app.sh
```

产物：`DailyReport.app`。

启动：

```bash
open DailyReport.app
```

卸载：

```bash
rm -rf DailyReport.app
```

## 使用

1. 启动后菜单栏出现 ✅ checklist 图标，点击弹出今日面板。
2. 在面板里快速添加完成 / 计划 / 问题，选标签、优先级、是否周期。
3. 点「打开主窗口」查看概要、时间线、会议纪要、周报，或打开设置调整提醒 / 数据导入导出。
4. 数据本地保存（SwiftData，`~/Library/Application Support/default.store`），重启不丢失。

## 技术栈

- Swift 6 + SwiftUI（原生 macOS 14+）
- SwiftData（`@Model` 本地持久化，轻量迁移）
- Swift Charts（统计图表）
- UserNotifications（每日提醒）
- SwiftPM 构建 + 脚本打包成 `.app`

## 目录结构

```
Sources/DailyReport/
├── DailyReportApp.swift    # @main: MenuBarExtra + 主窗口 + 启动 sweep
├── AppState.swift          # 常量与 UserDefaults 键
├── Models/                 # SwiftData 模型（WorkEntry / Meeting / Tag …）
├── Views/                  # 概要 / 时间线 / 待办 / 会议 / 周报 / 设置
├── Components/             # 复用组件（标签选择、KindPicker、RecurrenceEditor…）
└── Services/               # 导出 / 备份 / 周期推进 / 提醒
scripts/build-app.sh        # 构建 + 打包
Resources/Info.plist.template
```
