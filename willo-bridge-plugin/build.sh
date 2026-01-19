#!/bin/bash
set -euo pipefail

# Build the Willo Bridge Plugin for Zellij
# Outputs: target/wasm32-wasip1/release/willo_bridge.wasm

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Check for Rust
if ! command -v cargo &> /dev/null; then
    echo "Error: Rust/Cargo not found. Install from https://rustup.rs"
    exit 1
fi

# Check for wasm target (try both names - wasip1 is the new name, wasi is legacy)
WASM_TARGET=""
if rustup target list --installed | grep -q "wasm32-wasip1"; then
    WASM_TARGET="wasm32-wasip1"
elif rustup target list --installed | grep -q "wasm32-wasi"; then
    WASM_TARGET="wasm32-wasi"
else
    echo "Adding wasm32-wasip1 target..."
    rustup target add wasm32-wasip1
    WASM_TARGET="wasm32-wasip1"
fi

echo "Building willo-bridge plugin (target: $WASM_TARGET)..."
cargo build --release --target "$WASM_TARGET"

# Get version from Cargo.toml
VERSION=$(grep '^version' Cargo.toml | head -1 | sed 's/.*"\(.*\)".*/\1/')

# Output location
WASM_PATH="target/$WASM_TARGET/release/willo_bridge.wasm"

if [[ -f "$WASM_PATH" ]]; then
    SIZE=$(ls -lh "$WASM_PATH" | awk '{print $5}')
    echo ""
    echo "Build successful!"
    echo "  Output: $WASM_PATH"
    echo "  Size:   $SIZE"
    echo "  Version: $VERSION"

    # Copy to dist directory for easy access
    mkdir -p dist
    cp "$WASM_PATH" "dist/willo-bridge.wasm"
    echo "$VERSION" > "dist/willo-bridge.version"
    echo ""
    echo "Distribution files:"
    echo "  dist/willo-bridge.wasm"
    echo "  dist/willo-bridge.version"
else
    echo "Error: Build failed - WASM not found at $WASM_PATH"
    exit 1
fi
