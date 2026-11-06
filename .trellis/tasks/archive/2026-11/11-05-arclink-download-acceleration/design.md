# R2 分发设计

状态：in_progress。用户已批准最终实施摘要，`classktv.com` DNS 已在 Cloudflare，R2 bucket 为 `oss`，公开下载域名已确认 Active。

## 架构与边界

- 使用 R2 Standard bucket `oss`、拟定自定义 HTTPS 域名 `download.classktv.com` 及 Cloudflare 缓存，不引入 Worker。仅管理本项目版本路径和入口对象，不改动 bucket 其他内容。
- main/tag/GitHub Release 继续提供发布来源和原始附件；CI 将原始 DMG、archive、sig 镜像至 R2，保持签名 bytes 不变。
- `releases/arclink-vX.Y.Z/` 保存不可覆盖的版本化文件、R2 URL manifest 和该 manifest 对应的 checksum。GitHub 与 R2 的 manifest 允许 URL 不同，因此各自校验和独立生成。
- 仅在双架构附件、签名及校验文件上传并经公开 URL 校验全部通过后更新根 `latest.json`。失败保留上一版入口，不删除已发布版本。
- 固定版本附件长缓存；latest metadata 不缓存或短 TTL + revalidation，具体规则随域名实际配置验证。为 DMG、tar.gz、sig、json 设置准确 Content-Type；支持 HEAD/GET/Range。
- CI 上传和 latest promotion 使用串行发布；防止旧工作流覆盖较新版本。R2 部分完成可幂等重试，相同路径已存在但 digest 不一致则停止。

## 客户端与网站

- 新客户端内置 R2 latest 主入口及 GitHub metadata 备用入口。必须核查当前 updater 实际回退规则，测试后再宣称回退可用；metadata 回退不等于下载中途自动换源。
- GitHub manifest 继续指向 GitHub archive，R2 manifest 指向 R2 archive，保留完整独立分发链路。R2 下载失败时显示可重试错误，并保留人工 GitHub 下载方式；跨源自动续传不在本次范围内。
- 0.1.3 及更早版本内置的 GitHub 入口无法远程改写。本次保留这些发布，旧客户端通过一次正常更新或新版 R2 DMG 安装迁移至新入口，不覆盖旧 manifest。
- 官网模板/生成器支持经验证的 HTTPS 外部版本化地址，更新版本、arm64/x64 下载信息，保留无 JavaScript 基础下载；使用同一次发布的元数据，避免再次停留在 0.1.1。
- 扩展现有 arclink-release 技能和仓库 spec，使后续发布包含 R2 镜像及验收。

## 免费额度与凭证

- 无付费 Worker/国内 CDN；使用现有域名时无新增域名注册开销。
- R2 免费额度与账号其他 bucket 共享。发布前核算保留版本容量和请求量，配置可用的用量提醒；提醒不构成硬性支出上限，不承诺无限免费。
- R2 写入凭证仅限目标 bucket；CI Secrets 保存 account ID/access key/secret，公开下载 base URL 可作变量。Cloudflare 管理 token 与 S3 对象上传密钥分离，禁止进入客户端或日志。
- 自定义域名需要所在 zone 与 bucket 的账号关系满足 Cloudflare 条件。未确认 DNS 控制权前不变更 nameserver 或现有记录。

## 验收和回退

- 对两个来源的相同二进制校验 digest；验证 R2 manifest、notes、版本和 signed-version，实际原生下载及临时副本安装。
- 冷/热访问及 1 MiB Range 对比同一版本，记录网络位置、TTFB、吞吐、响应缓存头。无法完成用户网络测试时明确限制。
- 镜像或验证失败不推进入口；GitHub 原始发布仍可手动下载。修复服务故障优先恢复同版本镜像，禁止自动降级 latest 或移动 tag。

## 待确认

上传凭证安全配置和真实公开附件验证仍为上线前提；域名 Active 状态已由用户确认。S3 API endpoint 不等于可匿名 GET 的 CDN 域名。其余实施细节在当前 SDK/接口验证后固定，不创建虚构资源。
