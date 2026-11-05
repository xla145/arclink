The agent switcher picks which agent's projects Home shows: Claude, Codex or Herdr.

A segmented control on a `surface-sunken` track, 44pt total height, `radius-md`. The selected segment is a `surface` chip with `ink` semibold text; others are `ink-muted`. Each agent keeps its glyph in its own tint (`agent-claude`, `agent-codex`, `agent-herdr`) — the tint is only ever on the icon, never the label or the fill. An agent not installed on the Mac shows at 55% opacity and stays tappable; Home then shows an empty state explaining how to install it.

Consumer provides the list of agents with `installed` flags and the current selection. Place it directly under the large title, full width with `space-4` side margins. VoiceOver: each segment reads its name plus 已选择 / 未安装.
