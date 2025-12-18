#!/bin/bash
# Build GhosttyKit.xcframework for iOS
#
# This script builds libghostty using Zig and packages it as an XCFramework
# for use in Willo iOS app.
#
# Prerequisites:
# - Zig 0.15.2+ installed
# - Xcode with iOS SDK
# - Metal Toolchain (run: xcodebuild -downloadComponent MetalToolchain)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
GHOSTTY_DIR="$ROOT_DIR/vendor/ghostty"
OUTPUT_DIR="$ROOT_DIR/build/xcframeworks"

echo "=== Building GhosttyKit.xcframework ==="

# Check for Zig
if ! command -v zig &> /dev/null; then
    echo "Error: Zig not found. Please install Zig 0.15.2+"
    echo "  brew install zig"
    exit 1
fi

ZIG_VERSION=$(zig version)
echo "Using Zig: $ZIG_VERSION"

# Check for submodule
if [ ! -f "$GHOSTTY_DIR/build.zig" ]; then
    echo "Error: Ghostty submodule not found"
    echo "  git submodule update --init --recursive"
    exit 1
fi

# Build xcframework
echo "Building xcframework (this may take a few minutes)..."
cd "$GHOSTTY_DIR"

# Clean previous build
rm -rf "$GHOSTTY_DIR/macos/GhosttyKit.xcframework"

# Build with Zig
# -Demit-xcframework=true: Build the xcframework
# -Dxcframework-target=universal: Build for all targets (macOS + iOS + simulator)
# -Dapp-runtime=none: Build as a library, not an app
# -Di18n=false: Skip internationalization (avoids msgfmt dependency)
zig build \
    -Demit-xcframework=true \
    -Dxcframework-target=universal \
    -Dapp-runtime=none \
    -Di18n=false \
    2>&1 | grep -v "transitive failure" | grep -v "msgfmt" || true

# Check if xcframework was created
if [ ! -d "$GHOSTTY_DIR/macos/GhosttyKit.xcframework" ]; then
    echo "Error: XCFramework not created"
    exit 1
fi

# Copy to output directory
mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/GhosttyKit.xcframework"
cp -R "$GHOSTTY_DIR/macos/GhosttyKit.xcframework" "$OUTPUT_DIR/"

echo "=== Build complete ==="
echo "XCFramework: $OUTPUT_DIR/GhosttyKit.xcframework"
echo ""
echo "Contents:"
ls -la "$OUTPUT_DIR/GhosttyKit.xcframework/"
