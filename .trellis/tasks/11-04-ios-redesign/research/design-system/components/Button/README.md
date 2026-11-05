Buttons are how every action in ArcLink is taken, from Allow on an approval to starting a new conversation.

- **primary** — `primary` fill, `on-primary` label. One per screen region: 允许, 发送, 扫描二维码, 新对话.
- **secondary** — `surface-sunken` fill, `ink` label. The quiet partner of a primary: 拒绝, 取消.
- **danger** — `danger-soft` fill, `danger` label, always with an icon. Only for destructive settings actions (移除设备, 删除项目). Deny on an approval is *secondary*, not danger: denying is safe.
- **ghost** — text-only `primary`. Inline links such as 查看完整请求.
- **block** — full width, 50pt tall, for the single action of a screen (pairing, approval detail).
- **pill + float** — the 新对话 button, bottom-centre of Home, with `shadow-float`. It replaces the anonymous black chat FAB: label it.
- **Icon button** — 44pt hit target (`tap-min`), `ink` glyph; a count badge uses `warning` with `surface` text.

Consumer provides the label (verb first, two to four characters in Chinese), an optional SF Symbol, and the action. Minimum height is `tap-min`; radius `radius-md`, or `radius-full` for pill. Disabled is 40% opacity, never a different color. Never use green for Allow: the action color is always `primary`.
