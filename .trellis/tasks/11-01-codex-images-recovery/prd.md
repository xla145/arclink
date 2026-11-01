# Codex images and disconnection recovery

User explicitly requests both image sending and reconnect recovery for iOS remote Codex through Mac desktop. Preserve current text, approval and multi-Mac behavior.

Accept: up to four user-selected images genuinely reach native Codex (bounded JPEG data URLs); image-only turns supported; errors preserve drafts. During network loss/foreground return automatically reattach SAME process with per-channel byte checkpoints and lease proof, restore output without replaying turn/start or approval writes. Partial NDJSON uploads must not poison the process. Unsupported old hosts fail clearly. Native process lost/restart and retained-buffer gaps require honest stopped/limited state; no fake completion or duplicate execution. Persist native thread ID for subsequent process/thread resume across app restart. Tests cover image data, byte offsets, lease replacement, stale callbacks, mid-UTF8 disconnection, pending ack recovery, and native two-end smoke.

No APNs, pairing-journal expansion, new transport or universal unbounded offline storage.
