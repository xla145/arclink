# R2 实施计划

## 开始条件

- [x] 用户确认 Cloudflare DNS、oss bucket 和 download.classktv.com Active。
- [x] PRD、design 和本计划已收敛；用户批准最终摘要后已运行 task.py start。
- [x] 为 implement.jsonl/check.jsonl 注入 updater、website、跨层指南及本任务研究资料。

## 实施顺序

1. 创建 codex/ 功能分支，加载对应层规范，按 Trellis 分派实现与检查代理；保持外部部署配置和产品代码分离。
2. 扩展发布工具：生成 R2 独立 manifest/checksum、验证 URL 和完整双架构、幂等上传、拒绝同版本不同内容、最新版本推进保护；测试缺失/失败不会 promotion。
3. 增加 CI R2 同步流程和 Secrets/variables 校验，保持原 GitHub 原始发布。任何源的状态须明确报告，不将部分镜像称为完成。
4. 配置 bucket、域名、HTTPS、缓存和用量提醒。使用安全凭证配置，不输出密钥；涉及缺失账号的人工步骤只列具体缺项。
5. 更新新客户端 updater 主/备用 endpoint，验证 Tauri 实际 fallback 行为和签名约束。
6. 调整官网模板、配置和生成器，支持 R2 版本化双架构链接并同步展示版本。
7. 更新仓库 updater/website 规范及全局 arclink-release 技能与审计工具，保留 GitHub/R2 不同 manifest 的独立校验规则。
8. 全范围质量检查，按正式发布顺序准备新版本（若当时会话授权发布）；公开源验收后再切换入口。

## 验证

- Python release tests：URL 来源、UTF-8 notes、完整产物、幂等、重试、旧版本拒绝、promotion 失败场景。
- actionlint、相关 frontend test/build、Rust updater/lifecycle tests。
- 官网生成器测试（本地/外部 URL、错误配置）及浏览器下载链接检查。
- 原生 updater 对 R2 check/download；镜像双架构签名、版本、架构和 codesign；仅 /tmp 副本安装。
- 相同产物 GitHub/R2 SHA256 相同，两个 manifest 与各自 checksum 相符；公开 HEAD/GET/Range 和缓存策略实测。
- 用量估算和可用提醒配置核对；不宣称提醒自动阻断超额计费。

## 风险与恢复点

- 仅绑定独立下载域名，不迁移整个 DNS zone 或更改其他业务记录。
- 缺少 R2 credentials：先完成可本地验证的实现，外部部署等待安全配置。
- 新客户端 endpoint 仅影响新版本，旧版通过既有 GitHub 链路迁移；测试区分这两条路径。
- 网络收益未达预期：保持 GitHub 备用源并报告实测，不采购未授权付费服务。

## 完成记录

- 已完成发布工具/CI/客户端源配置/官网/技能/规范接入及99项检查。
- 已镜像既有0.1.3并完成公开文件、签名、受保护临时安装、官网上线和免费边缘缓存验证。
- 本次不创建新版本tag或重发二进制；新的客户端endpoint随后续客户端发布交付，边界已记录。
