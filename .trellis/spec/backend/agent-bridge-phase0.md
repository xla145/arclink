# Native Agent Phase 0 contract

## 1. Scope / Trigger
Applies to `phase0/prototype`, a local Codex command-approval probe. No remote transport, daemon, terminal or durable store is implemented. CLI 0.165.0 is the only validated target; schema hashes live in `phase0/schema-manifest.json`.

## 2. Signatures
`cargo run --manifest-path phase0/prototype/Cargo.toml -- --work-dir ABS_NEW_DIR --output NEW_JSONL [--model MODEL] [--timeout-secs N] [--codex-bin PATH]`.
Native flow: `initialize`, `initialized`, `thread/start`, `turn/start`, `item/commandExecution/requestApproval`, response `{id,result:{decision}}`, `turn/interrupt`, `thread/resume`.

## 3. Contracts
Preserve numeric vs string RPC IDs. Bind decisions to process generation, thread, turn and native request; item ID alone is insufficient because callback IDs may differ within an item. Use `on-request`, reviewer `user`, `read-only`; accept only exact test commands and cwd. `decline` does not imply task failure; `cancel` interrupts. Pipe write alone is not acknowledgement or execution proof. Evidence is an allowlisted projection; never persist auth, environment or arbitrary Agent output.

## 4. Validation & Error Matrix
- Unknown CLI version / unsupported request / correlation mismatch: fail closed without approval.
- Overlong, malformed or truncated JSONL / EOF / timeout: fail explicitly, clean up owned process.
- Duplicate, stale generation or expired approval: no native write.
- Uncertain delivery: OutcomeUnknown, no automatic retry.
- Fresh workspace already exists: refuse to run (markers would invalidate observations).

## 5. Good / Base / Bad Cases
Good: real approval pending, absent marker before and after hold, one decision, matching native completion and expected filesystem effect.
Base: native decline followed by a completed turn with no marker.
Bad: use assistant text as an approval, claim success from help output, or infer process resurrection from thread resume.

## 6. Tests Required
Bounded framing with fragmented UTF-8 and coalesced lines; malformed/oversized/truncated frames; stale/duplicate/expired requests; two callers competing for one write permit. Real integration must check marker effects, native terminal statuses, next turn and new-process history recovery. Document separately pending-command cancellation versus already-running command cancellation. SQLite concurrency/crash claims require independent database tests, not mutex tests.

## 7. Wrong vs Correct
Wrong: a memory token present in resumed developer instructions proves conversation recovery.
Correct: seed the token only in user history, restart the native process and verify history/recall without resending the answer. Do not conflate conversation persistence with a surviving OS process or live approval.
