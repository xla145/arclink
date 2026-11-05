A list row is the one row shape for projects, conversations and devices.

Rows live in an inset group (`surface`, `radius-lg`) with `line` hairlines starting after the icon tile. Each row is at least 64pt: a 36pt icon tile (`surface-sunken` / `ink-muted`), the title in `row-title`, a right-aligned `caption` timestamp in `ink-muted`, a second line in `footnote` `ink-muted` (path · count), optional tags under it, and a `ink-faint` chevron.

Consumer provides title, subtitle, timestamp, optional tags (see StatusTag) and the action. Never use text smaller than `caption` (12px); the old 9pt labels are gone. A pending approval is a `waiting` tag in the row, not a bare orange icon.
