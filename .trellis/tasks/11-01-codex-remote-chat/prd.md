# Codex remote chat

User authorized real iOS chat through the Mac desktop host, borrowing Orca patterns. Today send is local mock. New and subsequent Codex messages must reach the actual Mac Codex app-server and stream public assistant replies. Failures and unknown delivery must be visible, with no automatic turn replay. Preserve per-device workspace isolation, imported read-only histories and existing raw terminal behavior. Support real cancellation and explicit approval responses; unsupported inputs must never appear successfully sent.

Acceptance: handshake, thread creation/resume, first and subsequent turns, fragmented JSON/UTF-8 streaming, errors/exit/gap, cancellation and approvals have meaningful tests; iOS builds; exact installed Codex protocol smoke. Keep existing iroh/ABP host byte relay and task+approval authorization. No new transport or full connection-recovery plan.
