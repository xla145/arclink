# Connection and relay findings

## Current code

- `agent-bridge/Cargo.toml:26`: pins iroh `=1.4.1` with `tls-ring`.
- `agent-bridge/crates/agentd/src/network.rs:32`: `NetworkServer::start(..., relay_enabled)` builds `presets::N0`; the boolean currently only disables all relays when false.
- `agent-bridge/desktop/src-tauri/src/runtime.rs:150`: desktop passes `true`; no private relay config is provisioned.
- `agent-bridge/crates/agentd/src/lib.rs:388`: QR version 1 contains endpoint identity, session, one-use pair token, expiry and device name; no relay hints.
- `agent-bridge/crates/agent-bridge-client/src/endpoint.rs:12`: one shared endpoint owner per normalized phone identity path, with a OnceCell. Replacing it for one host would break multi-device isolation.
- `agent-bridge/crates/agent-bridge-client/src/lib.rs:115`: `pair_over_iroh` reuses the shared owner and connects by endpoint ID alone.
- `agent-bridge/crates/agent-bridge-client/src/connection.rs:420`: reconnect similarly dials by endpoint ID alone.
- `agent-bridge/ios/AgentBridge/DeviceStorage.swift:17`: `PairedMac.endpointID` is persisted; private relay hints and credential references are absent.
- `agent-bridge/ios/AgentBridge/AppModel.swift:695`: QR decoding currently performs ad hoc JSON field extraction. New relay payload needs one typed decoder shared by validation and pairing orchestration.
- `agent-bridge/crates/agentd/src/identity.rs`: macOS identity already uses Security.framework Keychain APIs. Keep the identity namespace and reuse the native storage pattern for a separate relay credential item.
- `agent-bridge/scripts/ios-build-client.sh`: builds device/simulator Rust libraries and regenerates UniFFI Swift bindings/XCFramework.

## Version-specific iroh behavior

Source inspected in the installed cargo registry for iroh/iroh-relay 1.4.1:

- `socket/biased_rtt_path_selector.rs`: default selector marks IPv4/IPv6 primary and relay backup; across tiers it switches immediately. This already implements the requested direct-first policy. Do not add a custom selector or fixed direct-only timeout.
- `Endpoint::insert_relay` and `remove_relay`: allow updating the running shared endpoint relay map without replacing phone identity ownership. Credential changes still need explicit race/generation and rollback handling.
- `RelayConfig::new(url, None)` avoids QAD probes for this HTTPS-only deployment. `RelayMap::with_auth_token`/per-entry `RelayConfig::with_auth_token` provide bearer-header authentication.
- `Connection::paths`/`paths_stream`: expose actual current path and updates. Report the selected path, not the presence of a relay URL or simply a successful dial.
- HTTPS probes must remain enabled: they find a home relay when UDP/QAD is blocked.

## Operational evidence and boundaries

`output/iroh-relay/deployment.md` records deployment. Random access key remains on the server, not in this task. Public HTTPS, automatic renewal, and a full authenticated relay echo through an SSH tunnel passed. A production cellular-network check is still required. The local development network has Fake-IP DNS behavior; do not disable TLS or alter machine-wide VPN settings to hide it.

## Known unrelated edits

At task creation, iOS App/Components/SettingsViews and multi-device UI tests already had user/session edits. Read and preserve them; do not restore the worktree or reformat unrelated content. Do not commit `vps.md`.
