Chat turns: your messages are bubbles, the agent's replies are open prose.

**Yours** — right-aligned, max 82% width, `primary-soft` fill, `ink` text in `body`, `radius-lg` with a 6pt bottom-right corner; the time in `caption` `ink-muted` beneath. Attached images sit above the bubble as `radius-sm` thumbnails.

**Agent** — no bubble, full width, so long answers, lists and code read like a document. A header line shows the agent avatar (22pt tile, glyph in the agent tint), name and time. Prose is `body` at 25px line height; inline code is `font-mono` on `surface-sunken`. Copy and retry are 36pt icon buttons in `ink-muted` under the reply, not hidden in a menu.

Space turns `space-5` apart when the speaker changes, `space-3` otherwise. Consumer provides the turn (role, text/markdown, images, time).
