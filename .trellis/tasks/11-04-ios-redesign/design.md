# Design — iOS 全局视觉重设计

## Source of truth
设计系统 artifact：https://claude.ai/artifact/DkRxCsY6E6E8PYTsvXHgjP 。规划阶段的本地副本在 `research/design-system/`（`tokens.json`、`README.md`、`redesign.md`、`components/*/README.md`、`bundle.css`）。实现时按 token **名称**映射，数值从 `tokens.json` 抄写，不自行调色。

## Boundaries
只改展示层：`agent-bridge/ios/AgentBridge/` 下的 View 文件、新增主题/组件文件、`Assets.xcassets/AccentColor.colorset`，以及受选择器影响的 UI 测试。不触碰 `AppModel.swift` 的状态/传输逻辑（除非为“最近活动排序”需要一个只读派生属性）、`CodexChatSession.swift`、`Generated/`、持久化。

## New files
1. `ArcTheme.swift` — 取代 `ChatStyle` 的颜色部分：
   ```swift
   enum ArcTheme {
       static let bg = adaptive(0xF5F6FA, 0x0F1326)
       static let surface = adaptive(0xFFFFFF, 0x181D33)
       // surfaceSunken, line, ink, inkMuted, inkFaint, primary, onPrimary, primarySoft,
       // live, success(+Soft), warning(+Soft), danger(+Soft), agentClaude/Codex/Herdr,
       // codeBg, codeInk, codeMuted, brandNavy/Teal/Blue
       enum Space { static let s1: CGFloat = 4 … s8 = 32 }
       enum Radius { static let sm: CGFloat = 8, md = 12, lg = 18, xl = 24 }
       static let tapMin: CGFloat = 44, iconTile: CGFloat = 36
   }
   ```
   `adaptive` 复用现有 `ChatStyle.adaptive` 的 `UIColor { traits in … }` 实现（支持 alpha 的重载用于 `scrim`）。圆角统一 `RoundedRectangle(cornerRadius:style: .continuous)`。
   `ChatStyle.swift` 只保留滚动相关类型（`ChatScrollPosition`、`ChatBottomPreference`、`ChatScrollFollowState`），颜色常量删除；文件可改名为 `ChatScroll.swift`（需同步 `project.pbxproj`）或保留原名，实施时二选一并在 implement.md 记录。
2. `ArcComponents.swift` — R3 的共享组件：
   - `ArcButtonStyle(kind: .primary/.secondary/.danger/.ghost, block: Bool, pill: Bool)` 作为 `ButtonStyle`，按下态降低不透明度，禁用 40%。
   - `AgentSwitcher(selection:)`、`DeviceStatusPill(name:online:stateLabel:)`、`ArcCard { }`、`ArcListGroup { }` + `ArcListRow(icon:title:subtitle:trailing:tags:)`、`StatusTag(kind:text:)`、`ArcBanner(text:action:)`、`IconTile(symbol:accent:)`。
   - `Pill`（Components.swift）由 `StatusTag` 取代；`ToastBanner` 改为使用 `ArcTheme.ink`/`bg` 并保持 `toast` identifier（遵守 spec 中的 toast 对比度教训：显式颜色，不用 hierarchical `.primary` + `.background`）。
3. 现有聊天组件（`MacMessageViews.swift` 的 `AgentStepsDisclosure`、`MessageStepDetail`、`MessageCodeBlock`、表格/引用；`ChatView.swift` 的气泡、审批卡、Composer）原地改色与间距，不重写结构，以保住 11-03 的行为。

## Data flow / behavior changes
- 首页项目列表：原 `scopedProjects()` 的 `.recent` 按 `createdAt` 排序。移除 `ProjectScope` 后统一为“最近活动”：优先使用该项目会话的最大 `createdAt`（`store.sessions(for:)` 已可得），否则项目 `createdAt`。在 View 内计算，不改 store。
- 新对话按钮：保留 `chat-fab` identifier 于新的胶囊按钮上，避免 UI 测试大面积改动；accessibilityLabel 保持「开启对话」→ 改为「新对话」并同步测试。
- 审批详情：`ApprovalDetailView` 的按钮移入 `.safeAreaInset(edge: .bottom)`，与 spec“safeAreaInset for … approval actions”一致。

## Compatibility
- 外观偏好仍由 RootView `preferredColorScheme` 控制；所有颜色走 `UIColor` dynamic provider，自动跟随。
- `AccentColor` 改为亮 `#2F62E0` / 暗 `#6B9AFF`，影响系统 Toggle/Link/Picker 的着色——这是期望行为。
- Dynamic Type：只用语义字体；`ArcListRow` 在 `typeSize.isAccessibilitySize` 时把时间戳移到第二行（沿用 ChatView 现有做法）。

## Coordination
`11-03-claude-remote-chat` 也会改 `ChatView.swift`。本任务对 ChatView 只做样式层改动，避免移动消息/审批/发送逻辑代码块，降低合并冲突。若该任务先合入，按其结构重新应用样式。

## Rollback
每个阶段一个独立提交（见 implement.md）。回退某阶段即可恢复该部分原样式；`ArcTheme` 为新增文件，回退无副作用。
