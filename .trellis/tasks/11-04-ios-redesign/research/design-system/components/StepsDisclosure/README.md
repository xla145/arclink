The steps disclosure folds the agent's tool calls (reads, commands, edits) into one quiet line inside its reply.

Collapsed: a 44pt row on `surface` with a `line` outline, `radius-md`, summary in `footnote` `ink-muted` — 执行了 N 个步骤, plus · N 个失败 when any failed. Expanded: one line per step, status icon (`success` check, `danger` xmark, `live` spinner while running), the step title in 13px semibold and its target in `font-mono` `ink-muted`, truncated. Tapping a step pushes the full detail.

Consumer provides the steps (title, summary, status). Default to collapsed once the turn finishes; keep it expanded while the agent is still running.
