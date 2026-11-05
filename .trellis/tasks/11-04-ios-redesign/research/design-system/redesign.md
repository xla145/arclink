# 页面重设计

本节记录每个页面相对当前实现的改动，组件见各自卡片，完整画面见 Screens 分组。

## 全局

- 统一配色：删除 `ChatStyle` 的绿色方案和各处 `Color(.systemGroupedBackground)`、`.purple`、`.orange`、`.green`，全部改用本系统的 token。实现上新建一个 `ArcTheme`（替代 `ChatStyle`），按 token 名提供 `Color`。
- 统一字号：最小 `caption`（12px），取消 8–9pt 文字。
- 统一圆角：只用 `radius-sm/md/lg/xl/full` 五档。
- `AccentColor` 改为 `primary` 的亮暗两值，系统控件（Toggle、Link、Picker）自动跟随。

## 首页 Home

- 大标题「项目」+ Agent 分段控件 + 当前项目卡片 + 最近项目列表。
- 去掉「最近 / 所有项目」切换，列表按最近活动排序，搜索覆盖全部。
- 左上设备胶囊（圆点 + 名称 + 状态词），右上审批铃铛带数量角标、设置。
- 底部居中「新对话」胶囊按钮，替代无标签的黑色圆形按钮。

## 项目详情 Project

- 与首页同一套 ListRow：对话标题 `row-title`，摘要 `footnote`，状态用 StatusTag（运行中、待审批、只读历史）。
- 导航栏右侧「新对话」图标按钮；搜索框为 `surface-sunken` 的 40pt 输入框。

## 对话 Chat

- 导航栏显示对话标题和「项目 · Agent」，去掉滚动区内的大标题。
- 你的消息：右侧 `primary-soft` 气泡；Agent 回复：全宽正文 + 头像行。
- 工具步骤折叠为 StepsDisclosure，失败数量写在摘要里。
- 审批以 ApprovalCard 内嵌在对话流中；允许 = `primary`，拒绝 = `secondary`。
- Composer：模型胶囊在输入框内，发送/停止为 36pt 圆形按钮；错误为 Banner。

## 审批 Approvals

- 列表：ListRow，左侧 Agent 图标，第二行为项目 · 对话，右侧等待时长。
- 详情：问题式标题 + 一句影响说明 + CodeBlock + 底部固定的「拒绝 / 允许」。

## 新对话 Sheet

- 中号 Sheet（`radius-xl` 顶角），依次：项目（ListRow 选择）、模型（Picker）、首条消息（Composer 样式输入框），底部一个 block 主按钮「开始」。

## 设置与设备

- 系统 inset grouped 列表，背景 `bg`、行 `surface`；设备行用 DeviceStatus 的圆点 + 状态词；「移除设备」用 danger 按钮放在最底部。

## 配对 Pairing / 扫码

- 未配对：图标 + 「连接你的 Mac」+ 一句价值说明 + 三步说明 + 底部「扫描二维码」。
- 扫码页保持全屏相机；扫描线改为 `brand-teal`；失败用 Banner。
