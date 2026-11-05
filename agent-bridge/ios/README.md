# ArcLink iOS

ArcLink（弧连）是应用展示名称；工程、协议、bundle ID 和数据目录继续使用 Agent Bridge 标识，以保持兼容。

iPhone 上的 SwiftUI 客户端。配对后通过 iroh 连接 Mac 桌面客户端内嵌的 `agentd`。
Codex 项目支持新建远程图文对话、连续发送、流式回复、命令／文件审批、中断和前台断线续接。
Mac 启动本机已验证版本的 Codex app-server，iOS 解析其 JSON-RPC；历史导入对话继续只读。
演示工作区仍使用本地模拟，远程路径不会回退到模拟成功。

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
- 在配对 Mac 的 Codex 项目中新建 CLI 对话并发送文字，查看真实流式回复；需要审批时显示 Codex 的请求。
- 演示工作区支持本地文字／图片模拟；远程 Codex 的图片会压缩后真正发送给 Mac。
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

- 远程聊天支持 Codex 图文与命令／文件审批；交互式工具问答、完整步骤卡片尚未支持。
- 网络中断或回到前台会自动尝试接回原进程并补收输出，不会自动重发任务或审批。明确失败保留草稿，结果未知先核对原任务；重试失败有「重试连接」入口。
- 未配对演示工作区的批准仅更新本地状态。
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

项目对话列表支持全部／CLI／桌面筛选和搜索。旧 `Codex 对话`／`Claude 对话` 记录自动识别为桌面历史，仅供查看，可从底部另建 CLI 对话。来源依据 Mac 上的实际记录区分 CLI／桌面；缺少来源的旧记录显示为未知。来源和只读状态分别判断，导入历史继续只读。

本机及 Mac 消息使用同一原生 Markdown 组件，支持标题、列表与任务项、引用、行内格式、代码及复制、横向表格、图片。超长代码独立滚动。不支持数学公式、Mermaid 和语法高亮，相关内容保留为文本。图片可按比例显示并打开预览；外链图片需点击加载，失败可重试，不读取 Mac 的本地文件路径。远程 Codex 发送时会压缩并上传图片内容，附件随本地会话保存。

Mac 的 `GetThreadMessages` 保留图片及明确提供的公开思考摘要／工具记录，使用既有 `role/text/timestamp` 字段，不改变 FFI。思考摘要与工具结果默认折叠；没有摘要时不生成虚构内容。桌面 `agentd` 必须更新并重启才能提供新增记录；旧 host 仍可显示原文本。内嵌图片受 host 的单张 700 KB 限制，较大图片显示占位提示。整个历史响应控制在 900 KB 内以适配现有传输帧；超长记录会保留最近内容并明确提示在 Mac 查看完整历史。

验证：`AgentBridgeTests/ConversationTests` 覆盖旧记录兼容、项目／Agent 选择、只读／权限和多图；`MessageMarkdownTests` 覆盖块解析及地址限制；`AgentBridgeUITests/MockPathTests` 使用独立测试存储验证首页到聊天的浅深色路径。


## 私有中继与直连优先

手机扫描 Mac 配对二维码时会同时导入直连地址提示和中继访问凭证，无需填写地址或密钥。首次配对仍需 Mac 批准；已有 Mac 重新扫码即可刷新连接配置，项目和会话历史会保留。当前 Mac 的私有中继已经自动部署并配置，设置页只说明自动连接方式，不提供手动凭证表单。

凭证保存在系统钥匙串，设备 JSON 只保存引用和地址提示。二维码包含敏感访问凭证，请勿公开分享。同一个中继地址使用不同密钥时会报告冲突；暂不支持跨多台已保存设备批量轮换共享密钥。

连接会保留直连和中继两条路径，优先使用可用直连，必要时通过中继传输；状态显示实际使用的路径。中继不替代 Mac 的配对授权，也不提供 iOS 后台保活。真机蜂窝网络可用性需要独立验证，不能由模拟器或服务器健康检查推断。


## 对话列表本地缓存

Mac 的项目与对话列表按设备、Agent 缓存在手机本地，打开页面先显示已有记录，重启 App 后仍可复用。成功获取后的 5 分钟内不会重复同步；超过 5 分钟后会在连接可用时后台更新，已有列表保留显示。首页、项目对话列表可下拉刷新，主动获取 Mac 最新列表。

离线或刷新失败时继续显示本地缓存；成功的空列表也会缓存。多个页面同时请求同一台 Mac、同一个 Agent 时共用一次同步，缓存不跨设备混用。本次缓存覆盖项目和对话列表，不改变打开对话正文时的消息获取行为。


## 远程 Codex 验证

`CodexChatSessionTests` 覆盖原生握手、分片 UTF-8、连续 turn、审批、中断与未知投递；
`RemoteChatTests` 覆盖首条发送、失败保留草稿、按设备隔离及目录去重。
Rust 可选测试 `real_codex_chat_turns_over_iroh` 已经通过真实 Mac 主机链路发送两条只读短消息并收到回复。
此结果不代表已完成真机蜂窝网络验收；手机需要运行包含本次代码的新构建，Mac 保持在线且 Codex 已登录。

参考 Orca 的发送结果分类、发送来源捕获和不自动重放设计：
[发送结果](https://github.com/stablyai/orca/blob/main/mobile/src/session/native-chat/mobile-native-chat-send.ts)、
[结构化发送](https://github.com/stablyai/orca/blob/main/mobile/src/session/mobile-structured-agent-session-send.ts)。
保留 ArcLink 自有 iroh/ABP 传输与 Mac 权限校验。


## 图片与断线恢复

相册和粘贴图片均支持远程 Codex，最多 4 张。发送时每张 JPEG 压缩至 256 KB 内，
合计不超过 1 MB；发送记录保存与实际上传相同的图片。Mac 先收齐完整消息再交给 Codex，
传到一半断线不会留下损坏的原生输入。

网络恢复后使用原进程、字节位置和输入租约续接；已显示的内容不重复追加，任务和审批
不自动重发。离线输出保留量为 4 MB，超过时会明确提示缺失。手机挂起期间不保证后台
执行，回到前台会恢复检查。App 被杀后没有内存中的恢复位置和租约证明；若旧进程仍在
运行，会阻止重复启动并提示先去 Mac 核实。Mac 退出或重启后不承诺恢复旧进程。

本次同时扩展 Mac 协议和 iOS 库，**需要先更新 Mac，再更新 iOS**。旧 Mac 会明确提示升级，
不会悄悄降级成模拟发送。
