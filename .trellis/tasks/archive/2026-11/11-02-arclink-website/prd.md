# ArcLink 客户端介绍与下载官网

## 目标
制作中文响应式单页，让访客了解 ArcLink 弧连，并下载 Mac 客户端。

## 背景与确认决策
- 用户已同意创建任务、Mac 使用现有安装包、iOS 显示“即将开放”。
- 品牌为 ArcLink / 弧连；沿用深靛蓝、青色与蓝色和现成图标。品牌依据：`.trellis/tasks/10-31-arclink-brand-design/prd.md`；原资产目录不存在，应用内图标位于 `agent-bridge/desktop/src/assets/arclink-icon.svg`。
- Mac 包为 `agent-bridge/target/release/bundle/dmg/ArcLink_0.1.0_aarch64.dmg`（约 9.4 MB）。平台为 Apple Silicon，系统最低版本 macOS 13（`agent-bridge/desktop/src-tauri/tauri.conf.json`）。不声称已经签名或公证。
- 功能事实依据 `agent-bridge/ios/README.md`：配对、多 Mac、项目与历史查看、远程 Codex 图文对话和审批。手机需要配对在线 Mac；不夸大其他 Agent 或平台支持。

## 需求
- R1：品牌导航、醒目的产品首屏与下载入口，展示 Mac 与 iPhone 协作的产品示意。
- R2：展示设备配对、项目与会话、远程 Codex 对话及审批；提供安装 Mac、手机配对、开始使用三步指引。
- R3：Mac 下载区标明版本、架构、最低系统要求，并下载实际 DMG；iOS 显示即将开放，不使用虚假按钮或链接。
- R4：桌面与手机浏览器适配，键盘可访问、清晰焦点、减少动画偏好、基础 SEO 元信息。
- R5：独立静态网页、本地预览与部署说明、集中管理下载配置。

## 验收标准
- 产品名称、功能介绍与运行条件一致，示意界面不冒充真实截图（R1、R2）。
- Mac 下载请求成功，下载文件与源包一致；iOS 不触发无效跳转（R3）。
- 390 px 与 1440 px 宽度无横向溢出，导航锚点与键盘操作可用（R4）。
- 按说明可启动预览并部署静态文件，不依赖 Tauri 原生桥接（R5）。

## 范围外
不构建或重新签名客户端、不新增登录、后台、支付、统计或其他平台安装包。

## 风险与后续
现有本地包的签名、公证与正式发布验证不在本轮范围；下载区准确标明测试版本。后续可替换正式下载地址及 iOS 分发链接。用户已批准最终方案，任务进入实施。

## 用户追加授权：线上发布
用户明确要求部署到 vps.md 中与域名关联的服务器 89.45.45.158，域名 arclink.classktv.com。新增验收：HTTPS 可访问、HTTP 跳转 HTTPS、线上 DMG 与源包哈希一致，保留现有其他站点。证书通过现有 Certbot webroot 管理，静态版本目录及 current 链接支持回滚。凭据不得进入网页、部署包或版本控制。
