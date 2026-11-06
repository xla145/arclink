# 桌面端页面设计重新优化

## Goal
重新优化 ArcLink 桌面客户端（Tauri 托盘弹出面板，`agent-bridge/desktop`）的视觉与布局：接入品牌色、信息层级更清晰、把 320×480 小面板的空间更多留给内容。用户已选定"视觉 + 布局优化"深度：信息结构（设备 / Agent / 进程 三 tab）保持不变。

## Background（代码与 2026-11-06 预览截图）
- 面板为 320×最高 480 的无边框透明托盘窗口，14px 圆角外壳（`src-tauri/tauri.conf.json`，spec `agent-bridge-desktop.md` §3）。
- 视图：主面板三 tab、配对、设置（含更新）、日志、确认弹窗（`src/App.tsx`）；样式集中在 `src/styles/panel.css`；预览入口 `?preview=default|empty|error|pairing`（仅 DEV）。
- 品牌色：深靛蓝 #171C38，青 #50E3D4 → 蓝 #568BFF（`10-31-arclink-brand-design`）；当前 UI 用的是通用 Tailwind 蓝 #2563eb / #60a5fa。
- 现状问题：
  1. 头部（Logo 行 + 状态条卡片 + tab 卡片）约占 180px（`App.tsx:116-207`）。
  2. 状态条与 tab 同为灰卡片，层级扁平；网络异常时状态点仍为灰色（`App.tsx:165`）。
  3. 空状态下"已发现 Agent"被挤到底部不可见（`App.tsx:375-388`）。
  4. 错误横幅过高，把设备列表挤出可视区。
  5. 设备卡片撤销 "×" 常驻醒目，易误触（`App.tsx:330-336`）。
  6. 页脚 uptime 与状态条信息重复（`App.tsx:444`）。

## Requirements
- R1 头部压缩：状态并入头部（状态胶囊 + 副信息"N 台在线 · 运行时长"），tab 轻量化。
- R2 采用品牌色令牌，浅/深色两套，文本对比度 ≥ 4.5:1。
- R3 状态点按 online / connecting / warning(网络异常) / error(服务不可用) 区分颜色。
- R4 设备、Agent、进程改为紧凑分组列表；撤销按钮默认低调、hover/focus 高亮。
- R5 空状态与错误横幅紧凑化，空状态下 Agent 区可见。
- R6 页脚去除重复 uptime，仅保留弱状态文本与"查看日志"。
- R7 设置 / 配对 / 日志 / 弹窗统一套用新样式，结构不变。
- 约束：保持全部功能、文案语义、aria 名称、焦点陷阱、Esc 行为与 spec 契约；保持 320×480 与 14px 透明圆角外壳；不改 Rust / bridge / 协议 / 窗口配置。

## Acceptance Criteria
- [ ] 主面板头部（不含预览标签）高度 ≤ 110px（R1）。
- [ ] 界面强调色来自品牌蓝/青；浅深色截图中文字清晰可读（R2）。
- [ ] `?preview=error` 状态点显示警示色，非灰色（R3）。
- [ ] `?preview=default` 设备行撤销按钮默认低对比，hover 时变为危险色（R4）。
- [ ] `?preview=empty` 在 480 高度内可同时看到配对按钮和至少一个 Agent 行；`?preview=error` 横幅下方至少可见一个完整设备行（R5）。
- [ ] 页脚不再显示运行时长，运行时长出现在头部（R6）。
- [ ] 设置、日志、配对、撤销弹窗在 320×480 浅/深色下无溢出、无水平滚动（R7）。
- [ ] 在 `agent-bridge/desktop/` 下 `corepack pnpm test --run` 与 `corepack pnpm build` 通过。

## Out of Scope
- iOS 客户端（另有 11-04-ios-redesign）。
- 信息结构重做（单页仪表盘等）、新功能、后端、协议、窗口尺寸变更。
- 打包后的原生 macOS 应用实测（本任务只在浏览器预览中验收布局；可作为后续手动检查）。
