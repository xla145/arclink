#!/bin/bash
# Build the Rust ABP client for iOS and refresh AgentBridgeClient.xcframework.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=ios/Frameworks
GEN=ios/AgentBridge/Generated
mkdir -p "$OUT" "$GEN"

# Static libs for device and simulator.
for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  cargo build --release -p agent-bridge-client --target "$target" --locked
done

# UniFFI Swift bindings, generated from a host build of the same crate.
cargo build -p agent-bridge-client --locked
cargo run -p agent-bridge-client --bin uniffi-bindgen --features uniffi/cli -- \
  generate --library "$PWD/target/debug/libagent_bridge_client.dylib" \
  --language swift --out-dir "$GEN" --no-format

cat > ios/AgentBridge/Bridging-Header.h <<'EOF'
#import "Generated/agent_bridge_clientFFI.h"
EOF

rm -rf "$OUT/AgentBridgeClient.xcframework"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libagent_bridge_client.a \
  -library target/aarch64-apple-ios-sim/release/libagent_bridge_client.a \
  -output "$OUT/AgentBridgeClient.xcframework"

echo "built $OUT/AgentBridgeClient.xcframework"
