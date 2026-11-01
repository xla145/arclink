# 读取 Mac 上 Codex/Claude Code 真实项目列表

## Goal

手机上的"项目"一直是手动输入的文件夹路径，跟 Codex/Claude Code 在这台 Mac 上实际记录过
哪些项目完全无关——这造成了反复的误解（"codex 没有项目列表"）。真实情况是：

- `~/.codex/config.toml` 的 `[projects."<路径>"]` 段是 Codex CLI 自己维护的、真实存在的
  受信项目路径表（已在这台机器上现场确认过，有多条真实记录）。
- `~/.claude/projects/<编码后的路径>/*.jsonl` 每个会话文件第一行就带 `"cwd":"<真实路径>"`
  字段，不需要猜文件夹名的编码规则，直接读 JSON 字段最可靠（已现场验证）。

本任务让 `agentd` 新增一个只读 RPC，把这两份本地记录如实转发给已配对的手机，手机能看、能
一键"导入"成本地 `ProjectItem`，不做双向同步、不做自动追踪。

## Requirements

### R1 `agentd` 新 RPC：`ListAgentProjects`

- 入参：`{"agent_id": "codex" | "claude"}`（跟 `StartProcess` 的 `agent_id` 同一套值）。
- Codex：解析 `~/.codex/config.toml`，取所有 `[projects."<path>"]` 表的 key（路径），忽略
  `trust_level` 等其他字段；文件不存在或解析失败返回空列表，不报错（这是正常状态，不是
  异常）。
- Claude Code：遍历 `~/.claude/projects/*/`，每个子目录取任意一个 `*.jsonl` 文件的第一行，
  解析 `cwd` 字段；目录不存在同样返回空列表。
- 鉴权：跟 `ListAgents`/`ListProcesses` 一样只需要 `view` 权限，不需要新的权限位。
- 返回体：`Vec<{path: String, last_seen: Option<String>}>`（`last_seen` 暂时留空/不做，除非
  实现过程中发现几乎零成本拿到，不为了这个字段单独解析更多文件）。
- 路径去重；对 home 目录做展开（`~` → 实际用户目录），返回绝对路径。

### R2 iOS 调用与展示

- `agent-bridge-client` 新增 `BridgeConnection.listAgentProjects(agentId: String) -> [MacProjectPath]`
  （UniFFI Record，只含 `path: String`）。
- 在「添加项目」页，选中 Agent 之后（如果已连接），展示一个"从 Mac 导入"列表（来自
  `listAgentProjects`），点一下某一项直接把 `path`/`name`（取路径最后一段作为默认名字）
  填进现有的新建项目表单，用户确认保存——不是自动创建，用户仍然要点"保存"。
- 已连接但调用失败（权限/协议错误）：这个"从 Mac 导入"区域安静地不显示，不弹错误打断正在
  填表的用户（跟现有空状态一致：未连接时这个区域也直接不出现）。

## Constraints

- 只读：不修改 `~/.codex/config.toml`、不修改 `~/.claude/projects/`，不新增写权限位。
- 不解压 Codex 的 `.zst` session 文件（压缩、解析成本高，且 `config.toml` 已经够用）；
  Claude Code 的 `.jsonl` 文件按需读取不超过第一行，不整文件加载。
- 不做"自动同步"或后台轮询；只在「添加项目」页主动调用一次。
- 不处理除 `codex`/`claude` 外的 `agent_id`（`herdr` 返回空列表）。

## Acceptance Criteria

- [ ] `agentd` 新增一个针对 `ListAgentProjects` 方法的单元/集成测试：构造一个临时
      `~/.codex/config.toml`（或注入可配置的 base 目录，避免测试污染真实用户目录）验证
      能解析出预期路径；`~/.claude/projects/` 同理。
- [ ] 真机验证：这台 Mac 上已经有真实的 `~/.codex/config.toml` 项目记录和
      `~/.claude/projects/` 目录——在「添加项目」页选 Codex，能看到真实路径列表并导入成功，
      新建的 `ProjectItem.path` 跟 Mac 上记录的路径完全一致。
- [ ] Claude Code 同理验证一次。
- [ ] 两份文件都不存在/为空时，「添加项目」页不出现"从 Mac 导入"区域，也不报错。
- [ ] `cargo fmt`/`clippy`/`test` 和 iOS 模拟器 + 真机 Debug 构建都通过。

## Notes

- 跟 `10-31-ios-real-terminal` 任务不冲突：那个任务让"手动添加的项目"能真正跑进程；
  这个任务让"添加项目"这一步能从 Mac 上真实已有的记录里选，而不是盲打路径。两个任务合起来
  才是完整的"真实项目"体验，但分别可独立验收。
- 这是本任务第一次改动 `agentd` 的 RPC 表（之前两个 iOS 任务都刻意没有改 Mac 侧协议）。
