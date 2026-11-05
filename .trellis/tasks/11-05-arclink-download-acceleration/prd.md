# ArcLink 客户端下载与更新加速

## 目标

用 Cloudflare R2 Standard + https://download.classktv.com 分发 ArcLink 安装包和在线更新，改善下载体验，优先在免费额度内运行。

## 背景与已确认事实

- 用户已选择 R2，classktv.com DNS 位于 Cloudflare，R2 bucket 为 oss，并于本轮确认下载域名 Custom Domains 状态为 Active。S3 API endpoint 仅供上传，不作为公开下载入口。
- 客户端内置 GitHub latest 入口：agent-bridge/desktop/src-tauri/tauri.conf.json:59；现有 manifest 使用 GitHub archive URL：agent-bridge/scripts/release-assets.py:79。
- 官网 arclink.classktv.com 使用 Nginx 静态文件分发；配置 agent-bridge/website/downloads.json:3 与线上页面仍为 0.1.1，最新已发布版本为 0.1.3。生成器当前只支持本地 downloads/ 文件。
- 单机基线与 Cloudflare 官方资料见 research/distribution.md。GitHub 前 1 MiB 约 0.85 MB/s，官网旧 DMG 前 1 MiB 约 0.33 MB/s，不代表用户地区测速。
- 官方费用及估算见 research/pricing.md。R2 免费额度与账号其他业务共享，超额可计费，不构成硬性费用上限。

## 需求

- R1：官网和新客户端以自定义域名获取同一版本双架构文件，官网正确显示当前发布版本；保留无需 JavaScript 的基本下载入口。
- R2：发布顺序继续为经过验证的功能分支合入 main、创建版本 tag、GitHub 双架构发布，再镜像 R2。功能说明在对应渠道保持一致。
- R3：保留原始 DMG/archive/signature bytes；所有更新继续验证 HTTPS、签名、签名版本和完整包签名。R2 独立 manifest 与 checksum 必须对应实际 URL 和文件。
- R4：所有版本化产物完整且公开验证通过后才推进 latest；失败保留上一入口，可重试同内容上传，不覆盖已存在的不同内容，不允许旧任务回退最新版本。
- R5：GitHub 发布和下载保留。新版本使用 R2 主入口与经测试的 GitHub metadata 备用入口；不宣称下载途中自动换源。旧版本通过一次既有更新或新版 DMG 迁移。
- R6：复用 oss bucket 时仅管理 ArcLink 路径；上传凭证通过安全本机配置或 GitHub Secrets 注入，不在聊天或客户端中暴露。
- R7：更新仓库发布/网站规范及 arclink-release 技能，支持后续直接发布时同步 R2 并完成验证。
- R8：不引入付费 Worker、国内 CDN 或 Cloudflare China Network；记录存储保留策略、请求量与免费额度，配置账号实际支持的提醒。

## 验收标准

- AC1（R1/R2）：官网版本、arm64/x64 下载链接和当前分发元数据一致；公开 HTTPS 下载成功。
- AC2（R3）：双架构安装包、更新包及 signature 与 GitHub 原始 bytes 的 SHA256 一致；各来源 manifest 对应各自 checksum，中文功能说明一致；原生 updater 完成 R2 check/download/signature 验证，当前主机临时副本安装通过。
- AC3（R4）：缺少架构、上传失败、校验失败、同版本不同内容、过期发布任务均不推进 latest，测试覆盖失败与幂等恢复。
- AC4（R5）：实测并记录 metadata 回退行为，旧客户端仍可通过既有发布链路更新；不更改已发布 0.1.3 的 tag、二进制、签名或 GitHub manifest URL。
- AC5（R6/R8）：管理范围不影响 bucket 其他内容；无凭证泄漏，无新增付费服务；说明额度和提醒不构成自动硬限额。
- AC6（R7）：后续发布技能与 CI 同步镜像规则一致；相关测试/build/actionlint 通过。
- AC7（R1）：对相同版本 bytes 记录 GitHub/R2 的 TTFB、吞吐、Range 与缓存响应。用户网络不可测时明确实际测速范围，不承诺所有地区提速。

## 范围外

自动下载跨源续传、全球探测平台、强制停止用户客户端、历史 tag/二进制重发、未授权购买付费服务。

## 部署依赖与评审状态

账号和下载域名已由用户确认；只读检查未发现本机会话 R2 配置或 GitHub R2 Secrets。凭证和公开访问检查属于上线依赖，可先完成代码与本地测试；不能把待配凭证表述为已上线。

用户在最终方案摘要后明确回复“可以”，已批准实施；任务已激活并在 codex/arclink-r2-distribution 分支开发。公开文件验证和上传凭证仍为实际上线依赖。
