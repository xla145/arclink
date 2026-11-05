The composer is where you write to the agent; it also shows which model will answer and lets you stop a running turn.

A `surface` field with a `line` outline and `radius-xl`, pinned above the keyboard on `bg`. Text in `body`; placeholder 给 Claude 发消息… in `ink-muted`. The tool row holds attach (+), the model chip (`surface-sunken`, `radius-full`, tap to change) and the 36pt send circle: `primary` with an up arrow when there is text, `surface-sunken` and disabled when empty, a stop square while the agent is running.

Consumer provides the draft binding, attachments, model name, `busy` and the send/stop handlers. Errors appear as a Banner directly above it, not as red caption text.
