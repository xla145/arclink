# Host transport harness

`cargo test -p abp-test-harness` creates actual local iroh endpoints and drives
the same daemon pairing approval and process APIs used by the desktop app.
The `fake-agent` binary is a deterministic pipe fixture, never a production
adapter. Tests cover consent, replay/cancel, authorization, operation retry,
opaque bytes/stderr, fragmented input, negotiated limits, overflow gaps,
process ownership/generation, single-writer leases, detach and revocation.

For a manual pairing-only check, run:

```sh
cargo run -p abp-test-harness --bin abp-test-harness
```

Supply the invitation JSON on stdin and EOF, then approve the request in the
desktop pairing window. The tool never places its token in command-line
arguments or logs. It uses a fresh ephemeral peer identity; after the check,
revoke the test device in the UI. It is not a phone application or a persistent
remote controller. Real relay availability and phone scanning need separate
native tests; local transport tests do not prove either.
