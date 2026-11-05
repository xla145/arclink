ArcLink 让你在 iPhone 上接续 Mac 上的 Claude、Codex、Herdr 对话，并随时处理它们的审批请求。这套设计系统的目标只有三个：**简洁**（每屏一个主任务、一种强调色）、**美观**（取自图标的深蓝与弧光蓝，统一全应用）、**好用**（主要操作在拇指区、状态永远有文字）。

## 设计原则

1. **一个强调色。** 所有可点的主操作、链接、选中态和焦点环都用 `primary`。不再用绿色表示“允许”、紫色表示命令、黑色表示新建。
2. **对话就是文档。** Agent 的回复不加气泡、全宽排版；只有你自己的消息用 `primary-soft` 气泡。
3. **状态有字。** 任何状态（在线、运行中、待审批、失败）都是图标或圆点 + 一个词，不能只靠颜色区分。
4. **拇指可达。** 每屏唯一的主操作固定在底部（新对话、允许/拒绝、扫描二维码），点击区域不小于 `tap-min`。
5. **安静的层级。** 用 `bg` → `surface` → `surface-sunken` 三层明度区分层级；卡片不加阴影，只有浮在内容上的东西用 `shadow-float`。

## 文案

- 中文界面，短句，动词开头：「继续」「允许」「扫描二维码」「新对话」。按钮 2–4 个字。
- 用“你”，不用“您”。Agent 名称保留英文原样：Claude、Codex、Herdr；Mac 不翻译。
- 时间用相对时间：「3 分钟前」「昨天」「周一」。数量写在词后：「12 个对话」「1 待审批」。
- 错误说清发生了什么和怎么办：「发送失败：Mac 已离线」+「重试」。不用感叹号，不用 emoji。
- 句末不加句号的场景：按钮、标签、Toast、列表标题。

## 颜色

- 每屏背景都用 `bg`；卡片、列表组、Composer 用 `surface`；搜索框、图标底块、分段控件轨道用 `surface-sunken`；组内分隔线用 `line`。
- 正文与标题用 `ink`；路径、计数、时间等次要信息用 `ink-muted`（在三种底色上两种主题都 ≥ 4.5:1）；`ink-faint` 只给箭头等装饰图形。
- 主操作 `primary` 填充配 `on-primary` 文字。暗色主题的 `primary` 变亮，所以它上面的文字是深色，不要写死白色。
- `live`（品牌青）只表示“连接/运行中”：在线圆点、运行中标签、流式输出指示。
- 语义色成对使用：`success`/`success-soft`、`warning`/`warning-soft`（待审批专用）、`danger`/`danger-soft`。强色做文字与图标，soft 做底。
- Agent 色 `agent-claude`、`agent-codex`、`agent-herdr` 只用于该 Agent 的图标，不用于文字或大面积填充。
- 代码、命令、终端一律用 `code-bg` + `code-ink`，两种主题下都是深色块。
- `brand-navy`、`brand-teal`、`brand-blue` 是图标原色，只用于品牌场景（启动页、配对页图标、封面），不要直接用于界面控件。

## 字体

系统字体（SF Pro + 苹方），全部走 Dynamic Type，不内置字体文件。

- 每个根页面一个 `large-title`（项目、审批、设置）；详情页标题用 `title`；导航栏标题和卡片标题用 `headline`。
- 消息正文 `body`；列表行主标题 `row-title`；次要操作 `subhead`；路径和第二行 `footnote`；时间与标签 `caption`。
- `caption`（12px）是最小字号。原代码里的 `.system(size: 9)` 和 `size: 8` 全部改为 `caption`。
- 路径、命令、代码用 `code`（等宽）。

## 间距与圆角

- 屏幕左右边距 `space-4`；卡片内边距 `space-4`；屏内分区间距 `space-6`。
- 列表行最小高度 64pt，图标块 `icon-tile`（36pt），图标与文字间距 `space-3`。
- 对话中换说话人间隔 `space-5`，同一说话人连续消息 `space-3`。
- 圆角：标签与缩略图 `radius-sm`；按钮、输入框、代码块 `radius-md`；卡片、列表组、气泡 `radius-lg`；Composer 与 Sheet `radius-xl`；胶囊与圆形 `radius-full`。所有圆角用 `.continuous` 样式。

## 图标

- 用 SF Symbols，线性（非填充）样式，字重跟随文字。组件预览中的线性图标是 SF Symbols 的网页替代，实际实现以 SF Symbols 为准。
- 固定映射：Claude `sparkle`、Codex `chevron.left.forwardslash.chevron.right`、Herdr `square.grid.2x2`；项目 `folder`；对话 `bubble.left`；审批 `bell`；待审批 `clock`；设置 `gearshape`；扫码 `qrcode.viewfinder`。
- 不用 emoji 作装饰。

## 状态与反馈

- 加载：列表用下拉刷新；按钮内用小号 `ProgressView`，不整页遮罩。
- 成功：短暂 Toast（`ink` 胶囊）。失败：就地 Banner（`danger-soft`）并给出 重试。
- 空状态：图标 + 一句说明 + 一个主按钮，顶部留 `space-8`。
- 动效：系统默认弹簧，时长 0.2–0.3s；不做循环动画（扫描线除外）。尊重“减弱动态效果”。

## 无障碍

- 所有文字与底色在两种主题下 ≥ 4.5:1；图标、边框、焦点环 ≥ 3:1。
- 点击区域 ≥ `tap-min`（44pt）。
- 支持到 AX 字号：列表行允许换行，时间戳在大字号下移到第二行。
- 每个图标按钮都有中文 accessibilityLabel；状态标签朗读完整词语。
