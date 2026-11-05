# Desktop planning restart: source gap

The user approved reusing this task and entering planning on 2026-10-31.
The new source of truth is `doc/agent-bridge-desktop-client.md` and
`doc/agent-bridge-tray.html`: Tauri 2, Rust, React/TypeScript, Vite,
an embedded daemon, and a compact tray host with discovery, pairing,
device revocation, process status and I/O relay.

Current checkout inspection found no `agent-bridge/` directory, Cargo.toml,
package.json, Rust product source or Swift product source. CodeGraph did
not locate the product implementation either. Historical task claims about
the daemon, Swift client and 37 tests are not verified in this checkout.
The existing design.md and implement.md describe the historical Swift
approach and must not be used to implement the new request.

The HTML includes demonstration devices and decorative QR code generation;
production state and pairing must come from real backend operations.

Blocking scope decision: locate the existing backend source for reuse, or
confirm a greenfield implementation including the necessary daemon crates.
After resolution, rewrite the PRD, design and implementation plan together.
No product code has been changed or implementation dispatched.

## Resolution
The user subsequently requested a greenfield build. The source-location
question is closed; current PRD/design/implementation plan supersede the
historical Swift documents. See greenfield-contract.md for active context.
