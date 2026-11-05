# Agent Bridge iOS 0.1 — 观感/主路径（mock 连接）合同

状态：开工中 · 2026-10-31  
工程：`/Users/mac/mac-dev/agent-bridge/ios`（MacBook）  
对照：`agent-bridge-mobile.html` + `agent-bridge-ios-client.md` §04/§10  
显示名：Agent Bridge · Bundle：`dev.agentbridge.ios` · 版本 0.1.0  
写手：MacBook Mini Codex（同刀不双开）· 编排：@macmini开发 · 验收：@x资讯整理

## 本刀要做（主路径 ≤5 步可点完）

1. **首页**：Mac 连接状态 pill（mock 在线）· Agent tab（Claude/Codex/…）· 项目列表可搜 · 待审批条可进列表  
2. **项目**：会话列表 · 新建会话 · 进聊天  
3. **会话/聊天**：发文本（mock Agent 回复）· 可选假图附件气泡 · 事件 pill（tool/审批）可点  
4. **审批**：列表 + 详情（命令/diff 预览区有内容）· 批准/拒绝后状态变化 + toast  
5. **设置**：我的 Mac（mock 已配对一台）· 外观/通知等基础项可点不崩  

深浅色 + 安全区 + 键盘不挡输入，对照 HTML 原型观感，忌套娃卡片/双主视觉抢眼。

## 本刀不做

真 iroh / UniFFI / Rust XCFramework、真 daemon 配对、APNs、多主机切换、ASC 建应用/上架、Android。

## 验收（齐才 PASS）

- 模拟器浅色/深色各一套主路径截图：首页、项目、聊天（有回复）、审批详情、设置  
- `xcodebuild` 模拟器 Debug 编译通过（日志路径报群）  
- Critique ≥8/10（≤5 问：主路径是否一眼懂、审批是否可决策、是否像 iOS 而非网页套壳）  
- 未扩做「不做」清单  

PASS 后：群里报 → 可选 TF Internal（不绑正式上架）→ 下一刀再谈真连接。

## 分流

DocDue 0.5.0(8) 已走 ASC/Internal，与本刀并行时 **写手仍只开 Agent Bridge 这一刀**；DocDue 仅 @appstore操作 补核，不新开 Codex。
