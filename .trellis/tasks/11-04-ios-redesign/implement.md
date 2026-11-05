# Implement — iOS 全局视觉重设计

工作目录 `agent-bridge/ios`。每阶段结束跑构建；阶段 3、5、7 后跑相关测试。每阶段可单独提交（提交需用户确认）。

## Phase 0 — 准备
- [x] 确认 `research/design-system/` 已包含 tokens.json、README.md、redesign.md、组件 README。
- [x] 记录当前基线：`research/baseline/test.log`（单元测试 128 通过；UI 测试基线即有 2 个失败：`MockPathTests.testDarkPaths`、`MultiDeviceUITests.testDarkDeviceSwitching`）。

## Phase 1 — 主题基础（R1、R2）
- [x] 新增 `ArcTheme.swift`（颜色、Space、Radius、尺寸）；工程使用同步文件夹，无需改 `project.pbxproj`。
- [x] `AccentColor.colorset` 改为 primary 亮/暗两值。
- [x] `ChatStyle` 颜色常量改为转发到 `ArcTheme`（临时兼容层，Phase 7 删除）。
- 结果：构建通过，单元测试 128/128 通过，模拟器对话页已为蓝色方案。
- 验证：构建通过；对话页颜色已变为蓝色方案。

## Phase 2 — 共享组件（R3）
- [x] 新增 `ArcComponents.swift`：ArcButtonStyle（`.arc(...)`）、IconTile、ArcCard、ArcListGroup（数据驱动，iOS 17 不能用 `Group(subviews:)`）/ArcDivider/ArcListRow、ArcSectionHeader、StatusTag、DeviceStatusPill、AgentSwitcher、ArcBanner；`ToastBanner` 改用 ink/bg；`AgentKind.tint`、`SessionStatus.tint` 指向 token。
- [x] `#Preview`：亮 / 暗 / AX 字号三个。
- 验证：构建通过；Xcode 预览目检。

## Phase 3 — 首页（R4）
- [x] ~~`AgentBridgeApp.swift` RootView 改为三 Tab `TabView`~~ → 已撤回：用户决定去掉底部菜单，改回单一 `NavigationStack`，审批 / 设置放到工作台右上角（铃铛 + 齿轮），工作台不显示标题。曾实现的 iOS 17/18 自绘悬浮 Tab 栏一并删除。
- [x] `HomeView.swift`：按原型 `prototypes/arclink-ios/index.html#tour:home`——DeviceStatusPill、待审批汇总卡、「进行中」区、项目区（搜索/添加/AgentSwitcher/按最近活动排序）、离线条、「新对话」浮动按钮（保留 `chat-fab`）。删除 `ProjectScope` 与当前项目大卡片。
- [x] 更新 UI 测试中 `approval-entry` / `settings-entry` 入口为 Tab。
- [x] 更新 `MockPathTests` / `MultiDeviceUITests`：标题「工作台」、审批/设置走 Tab、审批后不再返回；切换 Mac 在扫码页关闭后重试一次点按（相机权限中断会吞掉首次点按，基线深色失败即此原因）。
- 结果：单元测试 128/128，UI 测试 23/23 全部通过（基线 2 个失败已消除）；截图 `research/after/home-light-dark.png`。
- 验证：`MockPathTests`、`MultiDeviceUITests` 通过；亮/暗截图对照 HomeScreen 卡片。

## Phase 4 — 项目、新对话、添加项目（R7）
- [x] `ProjectViews.swift` 项目详情：头部卡片（路径/Agent/Mac/对话数）、来源 chips（全部 / ArcLink / 桌面导入，`source-*` 标识）、搜索框、ArcListRow + StatusTag（待审批时只显示带数量的标签）、底部「在此项目新对话」（`project-new-chat`，搜索时隐藏）、右上菜单（项目设置 / 复制路径 / 移除项目）。移除 9pt 文本。
- [x] `AddProjectView`：Agent 分段、Mac 已有项目多选 + 全选、可选手动路径（默认空，名称可留空取文件夹名）、工具栏「添加 / 保存」。
- [x] `NewConversationSheet`：标题「新对话」、权限改分段控件 + 说明、token 配色、底部「开始对话」块按钮；提交逻辑未改。
- [x] UI 测试选择器同步（`新对话` 标题、权限分段、`project-new-chat`、`source-*`）。
- 结果：全量测试通过（单元 128、UI 23）；截图 `research/after/phase4.png`。

## Phase 5 — 对话页（R5）
- [x] `ChatView.swift`：用户气泡（primary-soft，右下小圆角）、Agent 头像行、ApprovalCard（等待你批准 / 拒绝·允许，处理后灰色）、Composer（Agent 胶囊、36pt 发送/停止）、错误 ArcBanner、连接恢复条、只读历史条（AX 字号下紧凑）、对话内隐藏 Tab 栏。导航栏标题/副标题原已存在；AX 大标题保留。未加「重试生成」（无对应 API）。
- [x] `MacMessageViews.swift`：StepsDisclosure、MessageStepDetail（输入输出用 code-bg）、CodeBlock、表格、引用、清单改用 token；新增 `statusColor`。`ConversationSummary` 最小字号改为 caption。
- [x] 删除 `ChatStyle` 颜色兼容层（原 Phase 7 项，提前完成）。
- 结果：全量测试通过（单元 128、UI 23）；截图 `research/after/phase5.png`。
- 验证：`RemoteChatTests`、`ConversationTurnTests`、`MessageMarkdownTests`、`MockPathTests` 通过；手动核对滚动跟随、回到最新、键盘、只读历史。

## Phase 6 — 审批、设置、终端、配对（R6、R7）
- [x] `ApprovalViews.swift`：列表（待处理 / 历史分段 + ArcListRow + StatusTag）；详情问题式标题 + 代码块 + 工作目录 / 审批 ID + 底部「拒绝 / 允许」；终端用 code-bg / codeDanger（新增 token，未进已发布设计系统）。
- [x] `SettingsViews.swift`：`.arcGroupedList()` + 每个 Section `listRowBackground(surface)`；Mac 行与设备行为图标块 + 状态圆点 + 状态词。
- [x] `AgentBridgeApp.swift` 未配对页（图标 + 「连接你的电脑」+ 三步 + 底部「扫描二维码」）；扫码线改 brand-teal；删除无引用的 `Pill`。失败提示仍沿用 Toast（未改 Banner）。
- [x] 用户后续调整（2026-11-04）：去掉底部 Tab 栏与工作台标题；工作台自绘顶部（设备状态 + 铃铛 + 设置）；待审批在工作台完整展示、决定后消失；项目内新 CLI 对话只保留模型 + 权限设置并随首条消息生效；对话输入栏删除粘贴按钮（粘贴保留在新对话 Sheet）。
- 验证：构建 + 全部 UI 测试。

## Phase 6b — 桌面对话分叉（R10）
- [x] `ChatSessionOptions.forkFromThreadId`（可选，旧数据可解码）；`Route.fork(projectId:sourceId:)`。
- [x] `CodexChatSession.initialize`：无自有线程且有 `forkFromThreadId` 时调用 `thread/fork`（带模型、sandbox、审批策略、cwd，`excludeTurns`）；已有自有线程时仍 `thread/resume`，不会重复分叉。
- [x] `ChatView`：桌面对话底部 `desktopSessionBar`（Codex →「创建分叉」`fork-session`；Claude →「新建对话」`readonly-new-chat`）；分叉页沿用新对话设置卡，标题「分叉自「…」」，会话标题「分叉 · 原标题」，首条消息时才创建。
- [x] 测试：`CodexChatSessionTests` 新增分叉 / 不重复分叉两例；`MockPathTests.testDesktopCodexConversationForks`。

## Phase 6c — 浏览 Mac 文件夹（R11）
- [x] agentd：`directories.rs`（`list_directory`，主目录限定、符号链接逃逸拒绝、最多 400 项）+ 3 个单元测试；`network.rs` 新增 `ListDirectory` RPC 与 `list_directory_v1` 能力。
- [x] agent-bridge-client：`MacDirectoryListing` / `MacDirectoryEntry` 与 `list_directory`；解析测试。`cargo test -p agentd`（53）与 `-p agent-bridge-client`（19）通过。
- [x] `scripts/ios-build-client.sh` 重新生成 Swift 绑定与 xcframework（仅新增 205 行）。
- [x] iOS：`MacFolderPicker.swift`；添加项目页「浏览 Mac 上的文件夹」；DEBUG 夹具 `ARCLINK_UI_TEST_DIRECTORIES`；UI 测试 `testAddProjectByBrowsingMacFolders`。
- [ ] 真机验证需先更新 Mac 端 ArcLink（含新 agentd）。

## Phase 7 — 收尾（A2、A3、A6）
- [x] 删除 `ChatStyle` 颜色兼容层；A2 grep：仅剩扫码页黑白控件与深色代码块内分隔线（均为预期例外）。
- [ ] 最大辅助字号 + 减弱动态效果下逐页检查。
- [ ] 全量 `xcodebuild test`；亮/暗四页截图存 `research/after/` 并与设计稿对照。
- [x] 更新 `.trellis/spec/frontend/agent-bridge-ios.md`：新增「Design system (ArcLink iOS)」及两条 Gotcha（NavigationStack 外的 inset、iOS 18/26 系统控件差异）。

## Commands
```bash
cd agent-bridge/ios
xcodebuild -scheme AgentBridge -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme AgentBridge -destination 'platform=iOS Simulator,name=iPhone 17' test
grep -nE 'ChatStyle\.|systemGroupedBackground|system\(size: (8|9)' AgentBridge/*.swift
```
（模拟器名称以 `xcrun simctl list devices available` 为准。）

## Review gates
- Phase 3 完成后给用户看首页截图，确认方向再继续。
- Phase 5 完成后给用户看对话页截图。

## Rollback points
Phase 1、3、5、6 各为独立提交；回退任一阶段不影响其他阶段（Phase 1 回退前需先回退依赖它的阶段）。
