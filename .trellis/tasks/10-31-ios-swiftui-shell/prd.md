# iOS SwiftUI 壳

## Goal

按 `doc/agent-bridge-mobile.html` 原型做出能在 iOS 模拟器里点通的 SwiftUI 应用。数据全部来自本地 mock，不接 iroh、daemon 或 UniFFI。

## Requirements

- 导航覆盖：首页、项目会话列表、对话、审批列表与详情、终端、设置、设备列表与详情、添加/编辑项目、未配对空状态。
- 首页显示已连接 Mac 名称与在线状态、待审批提示、Agent 切换、项目搜索、添加项目入口。
- 对话页支持文本发送、图片选择预览、气泡展示；新建会话与已有会话标题不同。
- 审批可批准或拒绝，并给出结果提示。危险操作（断开配对、删除项目、清除历史）先确认。
- 未配对时在当前页面展示二维码，不另开弹窗。
- 界面跟随系统深浅色，中文文案。

## Constraints

- 只新增 `agent-bridge/ios/`，不改现有 daemon 与桌面端行为。
- 不引入第三方依赖。二维码用系统 `CIQRCodeGenerator`。
- 模拟器构建关闭签名。

## Acceptance Criteria

- [ ] `xcodebuild` 能在 iOS 模拟器上编译通过。
- [ ] 从首页可以进入项目、会话、审批、设置，并能返回。
- [ ] 对话页能发出一条文本消息，并在列表里看到自己的气泡。
- [ ] 空状态页在当前屏幕显示二维码，而不是弹出新窗口。

## Notes

- 交互以 `doc/agent-bridge-mobile.html` 为准，实现细节以 `doc/agent-bridge-ios-client.md` 为参考，但本任务不实现其中的 Rust / UniFFI / SQLite。
