A status tag states a conversation's or step's state in one word with an icon.

22pt tall, `radius-sm`, `caption` text. Five states, each a soft background with its strong color: **live** (`primary-soft` + `live`, with a dot) for running; **waiting** (`warning-soft` + `warning`, clock) for pending approval; **done** (`success-soft` + `success`, checkmark); **failed** (`danger-soft` + `danger`, xmark); **neutral** (`surface-sunken` + `ink-muted`) for read-only history and source labels.

Consumer provides the state and an optional count. Every tag has an icon or dot *and* a word: success and failure must never be told apart by hue alone.
