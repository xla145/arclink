# ArcLink iOS

ArcLink（弧连）是应用展示名称；工程、协议、bundle ID 和数据目录继续使用 Agent Bridge 标识，以保持兼容。

iPhone 上的 SwiftUI 客户端。项目支持手动添加，也会读取 Mac 上 Agent 的项目及历史对话；
手机创建的聊天消息和审批仍是本机模拟记录。配对成功后，手机会通过 iroh 维持一条到
桌面 `agentd` 的持久连接，能发 `Ping`/`GetSystemInfo`/`ListAgents` 等 Control RPC；真机验证
过（见 `.trellis/tasks/10-31-ios-iroh-transport/`）。终端页现在能对一个项目真正发起
`StartProcess`，看 `STREAM_AGENT_IO` 的真实 stdout/stderr，并用 `StopProcess` 停止——但这只是
裸字节透传，不解析 Claude Code/Codex 自己的协议语义（没有结构化步骤/工具调用卡片），见
`.trellis/tasks/10-31-ios-real-terminal/`。

## 打开

用 Xcode 打开 `AgentBridge.xcodeproj`，选 iPhone 模拟器后运行。

命令行编译（不签名，只适合模拟器）：

```sh
cd agent-bridge/ios
xcodebuild -project AgentBridge.xcodeproj -scheme AgentBridge \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

## 现在能做什么

- 按 Agent 查看和搜索项目，添加、修改、删除项目。
- 在当前 Agent／项目下新建 CLI 对话，发送文字、相册或粘贴图片（本地模拟，最多 4 张，每张 10 MB；保存时缩放并转 JPEG）。
- 发送任务后生成一条待审批；批准或拒绝会写回会话状态。
- 终端页显示这个会话自己的记录，不是写死的示例输出。
- 设置里可以改权限、通知、外观和会话保留天数。权限会限制能否发送和审批。
- 未配对时用相机扫描 Mac 上的配对二维码。手机不展示二维码。扫到 `agent-bridge://pair?token=…` 后才记为已配对。
- 配对成功后持久化 Mac 的 iroh `endpoint_id`，复用手机自己的密钥文件重连，不需要重新扫码。
- 设置页「Mac」区展示真实的连接状态（`Ping`/`ListAgents` 驱动），不是写死的在线状态；App 回到
  前台时会在未连接情况下自动尝试一次重连。「我的 Mac」详情页同样展示真实连接状态，并列出
  `ListAgents` 查到的每个 Agent 及其状态。
- 已连接且项目对应的 Agent 版本已验证（`validation == "verified"`）时，终端页右上角出现
  「启动」按钮：会对 Mac 上这个项目的真实路径发起 `StartProcess`，终端页展示真实
  stdout/stderr，「停止」按钮调 `StopProcess`。同一个会话重复启动是幂等的（`operation_id`
  用会话自己的 id），不会在 Mac 上开出第二个进程。

这些数据保存在 App 的 Application Support 目录 `AgentBridge/devices-v2.json`，旧版 `state.json` 由迁移逻辑保留。关掉再打开还在。`ios/work/` 是本地构建和截图目录，已在仓库 `.gitignore` 里忽略。

## 还没有的

- 不解析 Claude Code/Codex 自己的协议（没有结构化步骤/工具调用/审批卡片，终端页看到的是
  裸字节）；没有 SQLite 持久化，没有图片附件上传/下载。
- 批准不会修改桌面文件，也不会执行命令——这部分（审批、聊天）仍然是纯本地 mock，跟真实
  进程是否在跑无关。
- 真机安装需要在 Xcode 里登录 Apple 开发账号，且项目默认把签名关掉（`CODE_SIGNING_ALLOWED
  = NO`），真机构建需要显式打开签名设置并补上 `SystemConfiguration.framework` 的显式链接
  （细节见 `.trellis/spec/frontend/agent-bridge-ios.md`"真机签名"一节）。模拟器构建默认
  不签名。

## 多设备

首页右上角的设备按钮打开「我的设备」。可以添加多台 Mac，查看各自状态并切换当前项目/会话上下文；切换不会主动断开其他电脑。App 前台每 15 秒检查已保存设备，单台连接失败不影响其他设备。iOS 挂起期间不承诺持续连接，返回前台重新检查；没有新增 APNs 或后台保活。

设备记录保存在原 Application Support/AgentBridge 目录的 `devices-v2.json`，项目、会话、消息、审批与权限按设备隔离。首次加载旧 `state.json` 会保留原文件并创建 `state-v1-backup.json`，然后原子写入新版记录；旧 LAN-only 设备通过对应行的「重新扫码连接」补齐端点并保留历史。不要通过降级应用覆盖新版记录；需要回退时先备份整个目录，再恢复旧格式备份。

「移除设备」只移除手机上的该设备及其本机记录，不代表远端访问授权已撤销。Mac 端授权仍在桌面端管理。会话/审批中原有本地模拟部分保持原范围，不因多设备在线而变成跨设备实时推送。

验证入口：`AgentBridgeTests/MultiDeviceTests` 覆盖迁移、隔离、迟到结果、配对取消/失败、保存失败回滚；`AgentBridgeUITests/MultiDeviceUITests` 使用 DEBUG 限定的独立测试存储，检查深浅主题下的设备入口、切换、重启与扫码取消。测试画面中的「测试 Mac A/B」为 UI 夹具，不是真实配对主机。

## 原生页面与富文本对话

页面参考 `doc/arclink-home-chat.html`。首页固定 Claude／Codex／Herdr 选择器；当前项目按设备和 Agent 记忆，点击项目进入对话列表。右上角铃铛打开审批，齿轮打开设置，左侧设备入口保留多设备切换。右下角圆形对话按钮可切换该 Agent 下的项目，继续最近对话或新建 CLI 对话；只有第一条消息发送时才创建记录。

项目对话列表支持全部／CLI／桌面筛选和搜索。旧 `Codex 对话`／`Claude 对话` 记录自动识别为桌面历史，仅供查看，可从底部另建 CLI 对话。来源表示手机记录与 Mac 导入历史的区别，现有历史接口没有进一步提供上游 CLI／桌面程序的启动来源。

本机及 Mac 消息使用同一原生 Markdown 组件，支持标题、列表与任务项、引用、行内格式、代码及复制、横向表格、图片。超长代码独立滚动。不支持数学公式、Mermaid 和语法高亮，相关内容保留为文本。图片可按比例显示并打开预览；外链图片需点击加载，失败可重试，不读取 Mac 的本地文件路径。附件随会话本地保存，尚无跨设备图片上传。

Mac 的 `GetThreadMessages` 保留图片及明确提供的公开思考摘要／工具记录，使用既有 `role/text/timestamp` 字段，不改变 FFI。思考摘要与工具结果默认折叠；没有摘要时不生成虚构内容。桌面 `agentd` 必须更新并重启才能提供新增记录；旧 host 仍可显示原文本。内嵌图片受 host 的单张 700 KB 限制，较大图片显示占位提示。整个历史响应控制在 900 KB 内以适配现有传输帧；超长记录会保留最近内容并明确提示在 Mac 查看完整历史。

验证：`AgentBridgeTests/ConversationTests` 覆盖旧记录兼容、项目／Agent 选择、只读／权限和多图；`MessageMarkdownTests` 覆盖块解析及地址限制；`AgentBridgeUITests/MockPathTests` 使用独立测试存储验证首页到聊天的浅深色路径。
