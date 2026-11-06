# Design — 桌面端视觉与布局优化

## 边界
- 只改 `agent-bridge/desktop/src/styles/panel.css`、`src/App.tsx` 头部/页脚/设备卡片 JSX，及 `components/*` 中必要的 className/结构微调。
- 不改 bridge、hooks、types、Rust、tauri.conf；不改任何 aria-label、按钮可访问名与现有文案语义（测试依赖）。

## 设计令牌（:root，浅/深两套）
- 品牌：`--brand-ink #171C38`、`--brand-cyan #50E3D4`、`--brand-blue #568BFF`、`--brand-gradient`。
- `--accent` 改为品牌蓝系（浅色 #3A6FF0 保证 4.5:1 对比；深色 #6E9BFF），`--accent-soft` 相应调整。
- 深色背景改为偏靛蓝的中性色（如 #12151F / 卡片 #1A1E2B / 边框 #272C3B），浅色保持近白（#F7F8FB / #FFFFFF / #E6E8EF）。
- 新增 `--warning` 状态点用于"网络异常/连接中"，`--error` 用于服务不可用。

## 布局（320×480）
1. 头部压缩到 ~96px：
   - 第一行：Logo 24px + "ArcLink" + 右侧状态胶囊（状态点 + 运行中/网络异常/服务不可用）+ 设置按钮。
   - 第二行：副信息 `1 台在线 · 运行 4h 23m`（合并原状态条 detail 与页脚 uptime），小号次级色。
   - 分段 tab 变为更轻的下划线/胶囊样式，高度 28px。
   - 子页面（设置/配对/日志）保持返回按钮 + 标题，不显示状态行与 tab。
2. 内容区：卡片去掉重色背景，改为分组列表（同一圆角容器内行分隔），行高 ~48px。
3. 设备行：撤销按钮默认低对比，hover/focus 时高亮为 error 色；状态以小胶囊显示"直连/中继/离线 · 时间"。
4. 空状态：插画区缩小（图标 40px、按钮紧凑），保证下方"已发现 Agent"可见。
5. 错误横幅：紧凑单行标题 + 描述 + 行内按钮，左侧色条，最多占 ~72px。
6. 页脚：只保留左侧 `agentd` 版本/状态弱文本与"查看日志"，高度 36px。
7. 弹窗、设置、日志、配对：统一使用新令牌、按钮与分组列表样式；结构不变。

## 状态点映射
- running && network ready/无错误 → online（success）
- loading || network starting → connecting（warning，脉冲动画，尊重 prefers-reduced-motion）
- network error → warning 实心
- 服务不可用 → error

## 兼容 / 回滚
- 纯前端样式改动；回滚 = 还原 panel.css 与 App.tsx。
