The current-project card is Home's first thing: the project you were last in and a one-tap way back into its latest conversation.

`surface` card, `radius-lg`, `space-4` padding. Header: an `accent` icon tile (`primary-soft` / `primary`), an eyebrow in `caption` (当前项目 · N 个对话) and the project name in `headline`. The path follows in `font-mono` 13px `ink-muted`, truncated in the middle. The resume strip is a `bg` well with the latest conversation title and 继续 in `primary` — when there is no conversation yet it reads 在这个项目中开始新对话 / 开始.

Consumer provides the project (name, path, count) and the latest session (title or none). Tapping the header opens the project; tapping the strip opens the conversation. Do not stack a second card above it.
