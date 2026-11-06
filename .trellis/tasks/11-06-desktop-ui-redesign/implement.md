# Implement — 桌面端视觉与布局优化

1. 重写 `panel.css` 的令牌（浅/深）与基础组件（button、text-button、icon-button、status-dot、badge）。
2. 改 `App.tsx` 头部：合并状态行进头部，副信息行含在线数与运行时长；tab 轻量化；状态点映射按 design.md。
3. 页脚精简（移除重复 uptime）；设备卡片改分组列表 + 低调撤销按钮。
4. 调整空状态、错误横幅、loading 的尺寸。
5. 设置 / 配对 / 日志 / 弹窗套用新样式，核对 320×480 无溢出。
6. 验证：
   - `cd agent-bridge/desktop && corepack pnpm test --run`
   - `cd agent-bridge/desktop && corepack pnpm build`
   - 浏览器 320×480 截图：`?preview=default|empty|error|pairing`、设置、日志、撤销弹窗，浅色 + 深色。
7. 回滚点：每步后可单独还原 panel.css / App.tsx。
