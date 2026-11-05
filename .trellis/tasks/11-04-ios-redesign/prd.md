# iOS 全局视觉重设计（落地 ArcLink iOS 设计系统）

## Goal
把已发布的设计系统 [ArcLink iOS Design System](https://claude.ai/artifact/DkRxCsY6E6E8PYTsvXHgjP) 落地到 SwiftUI 应用，让全应用**简洁、美观、好用**：一套配色、一套字号、一套组件，首页 / 对话 / 审批 / 配对等页面按设计稿重排。

## Background
- 用户要求“对整个 iOS app 的页面进行重新设计，简洁，美观，好用”，审阅设计系统后选择“建任务并规划”。
- 现状：各页面配色不一致——`ChatStyle.swift` 是绿色方案（11-03-ios-chat-prototype 引入），首页/设置用系统灰 `Color(.systemGroupedBackground)`，命令预览用 `.purple`，审批用 `.green/.red`，新建按钮为无标签黑色圆形 FAB；存在 8–9pt 文字（`ProjectViews.swift:141-156`、`HomeView.swift` 角标）。
- 设计系统的唯一来源是 artifact 中的 `project/tokens.json`、`README.md`、`redesign.md` 与各组件 README；本地副本在会话 scratchpad，规划时会复制到本任务 `research/`。
- 相关任务：`11-03-ios-chat-prototype`（completed，绿色对话方案，本任务将替换其配色但保留其交互与数据契约）；`11-03-claude-remote-chat`（planning，同样修改 `ChatView.swift` / `AppModel.swift`，需避免冲突）。
- 工作区有大量与本任务无关的未提交改动（host、transport、desktop、website），必须保留。

## Requirements
R1. **主题 token**：新增单一主题来源（`ArcTheme`），按设计系统 token 名提供亮/暗自适应颜色、间距、圆角；`AccentColor` 资源改为 `primary` 亮暗两值。删除 `ChatStyle` 颜色，所有视图不再直接使用 `Color(.systemGroupedBackground)` / `.secondarySystemGroupedBackground` / `.purple` / `.orange` / `.green` / `.red` 等硬编码语义色（Agent tint 改为 `agent-*` token；扫码相机页的黑底/白字除外）。
R2. **字号**：最小字号为 `caption`（`.caption`，12pt 基准），移除所有 `.system(size: 8/9)` 文本；全部使用 Dynamic Type 语义字体。
R3. **共享组件**：按设计系统实现 SwiftUI 组件——Button 样式（primary / secondary / danger / ghost / block / floating pill）、AgentSwitcher、DeviceStatus、ProjectCard、ListRow + 分组容器、StatusTag、MessageBubble（用户气泡 / Agent 全宽正文）、StepsDisclosure、CodeBlock、ApprovalCard、Composer、Toast + Banner。各页面复用它们，不再各自拼样式。
R0. **交互原型为准**：页面结构与交互以 `prototypes/arclink-ios/index.html`（可点击，`#selftest` 自检 21 条流程）为准；与下文描述冲突时以原型为准。
R4. **信息架构与工作台**：不使用底部 Tab 栏（用户决定，2026-11-04）。单一导航栈，工作台为根页面且不显示标题；顶部左侧 DeviceStatus（点开切换 Mac），右侧审批铃铛（`warning` 数量角标，`approval-entry`）与设置齿轮（`settings-entry`），审批与设置为推入页。工作台内容：Mac 离线时显示离线条与「重连」；有待审批时显示「待你批准 · N」区，逐条完整展示请求（来源对话、标题、命令或路径）并提供「拒绝 / 允许」，点卡片进入详情；决定后该条立即从工作台消失（历史仍在审批页）；「进行中」区列出所有运行中的对话及其最新一行输出；「项目」区含搜索、添加、AgentSwitcher 与按最近活动排序的项目列表（行内显示待审批 / 运行中标签）；底部「新对话」按钮。移除「最近 / 所有项目」分段控件与当前项目大卡片。项目详情的来源筛选为「全部 / ArcLink / 桌面导入」chips，底部「在此项目新对话」。
R5. **对话页**：导航栏显示对话标题 + 「项目 · Agent」，移除滚动区内大标题；用户消息 `primary-soft` 气泡，Agent 回复全宽正文 + 头像行；回复下方直接提供复制/重试；StepsDisclosure、CodeBlock、ApprovalCard（允许 = primary，拒绝 = secondary）；Composer 内含模型胶囊与 36pt 发送/停止按钮；发送错误显示为带「重试」的 Banner。保留 11-03-ios-chat-prototype 的全部行为契约（滚动跟随、回到最新、草稿、图片、停止、恢复、只读历史）。
R6. **审批**：列表用 ListRow；详情为问题式标题 + 一句影响说明 + CodeBlock（命令或 diff）+ 工作目录行，「拒绝 / 允许」固定在底部 safe area。
R7. **其他页面**：项目详情、添加项目、新对话 Sheet、设置、设备列表/选择、终端视图、未配对页（图标 + 「连接你的 Mac」+ 三步 + 底部「扫描二维码」）与扫码页（扫描线改 `brand-teal`、失败用 Banner）统一使用 R1–R3。
R8. **无障碍**：两种主题下文字 ≥ 4.5:1、图标/边框 ≥ 3:1；点击区域 ≥ 44pt；状态始终有图标 + 文字；AX 字号下不裁切主要控件；尊重「减弱动态效果」；现有 accessibilityIdentifier（如 `chat-fab`、`toast`、`device-switcher`、`approval-entry`、`continue-chat`、`project-*`）保留或在 UI 测试中同步更新。
R10. **桌面对话分叉**（用户 2026-11-04 要求并入本任务）：Mac 桌面端的只读对话底部显示「已在 Mac 桌面端打开」提示卡。Codex 对话提供「创建分叉」：进入新对话页（标题「分叉自「原标题」」，可选模型 + 权限），第一条消息发送时由 Mac 上的 Codex `thread/fork` 生成带完整历史的新线程，之后与普通 ArcLink 对话相同；原桌面对话不受影响。Claude 对话暂无原生分叉通道（依赖 11-03-claude-remote-chat），显示「新建对话」作为替代。不提供「重试」：App 无法检测桌面端是否仍占用该对话。
R11. **浏览 Mac 文件夹添加项目**（用户 2026-11-05 要求并入本任务）：添加项目页提供「浏览 Mac 上的文件夹」，从 Mac 用户主目录起逐级浏览子文件夹（含 git 的标「项目」），「选择此文件夹」填入路径并在名称为空时取文件夹名。Mac 端新增 `ListDirectory`，仅限主目录内、只列文件夹；旧版 Mac 端提示更新，手动输入路径仍可用。需要更新 Mac 端 ArcLink 才能在真机使用。
R9. **不改行为**：不改变数据模型、传输、审批语义、配对流程与持久化键；外观偏好（自动/浅色/深色）继续在 RootView 生效。唯一的行为变化是 R4 的项目范围切换移除（列表改为按最近活动排序）。

## Acceptance
A1. 模拟器亮/暗两种主题下，首页、对话、审批详情、配对四个页面的截图与设计系统 Screens 卡片布局一致（R1、R4–R7）。
A2. `grep` 确认 `AgentBridge/*.swift` 中不再出现 `ChatStyle.`、`systemGroupedBackground`、`.system(size: 8`/`9`，以及 R1 列出的硬编码语义色（扫码页例外已注明）（R1、R2）。
A3. 所有页面在最大辅助字号下主要按钮、发送、允许/拒绝可见且可点（R8）。
A4. 现有单元测试与 UI 测试（`MockPathTests`、`MultiDeviceUITests`、`RelayNetworkUITests`）全部通过；因 FAB 改为「新对话」按钮等需要的测试改动仅限选择器/文案（R8、R9）。
A5. 对话页滚动跟随、回到最新、发送/停止、图片、审批、恢复、只读历史行为回归通过（R5、R9）。
A6. `xcodebuild` Debug 构建无新增警告；资源目录编译通过。

## Decisions
- D1. 对话页由绿色方案改为品牌蓝 `primary`：用户在看过设计系统后选择按其实施，视为替换 11-03 的配色（交互保留）。
- D2. 移除首页「最近 / 所有项目」分段控件，列表按最近活动排序，搜索覆盖全部项目。
- D3. 系统字体 + Dynamic Type，不引入自定义字体；图标用 SF Symbols。

## Out of scope
Mac 桌面端与官网改版；传输/Agent 协议改动；Claude 远程对话功能（11-03-claude-remote-chat）；新增 App 功能；App 图标更换；发布与自动提交。
