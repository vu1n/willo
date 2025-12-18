#!/bin/bash
# Build libwillo for iOS
#
# This script compiles the Willo terminal bridge (willo_shim.zig) into a
# static library for iOS devices.
#
# Usage:
#   ./scripts/build_libwillo.sh [debug|release]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
GHOSTTY_DIR="$PROJECT_ROOT/vendor/ghostty"
OUTPUT_DIR="$PROJECT_ROOT/apps/ios/Willo/Libraries"

# Parse arguments
BUILD_MODE="${1:-release}"
case "$BUILD_MODE" in
    debug)
        ZIG_OPT="-O Debug"
        ;;
    release)
        ZIG_OPT="-O ReleaseFast"
        ;;
    *)
        echo "Usage: $0 [debug|release]"
        exit 1
        ;;
esac

echo "Building libwillo for iOS ($BUILD_MODE)..."

# Create output directory
mkdir -p "$OUTPUT_DIR"

cd "$GHOSTTY_DIR"

# Build for iOS device (arm64)
echo "Building for iOS device (aarch64-ios)..."
zig build-lib \
    -target aarch64-ios \
    $ZIG_OPT \
    --name willo \
    -fno-llvm \
    -fno-lld \
    src/lib_willo.zig \
    2>&1 || {
        echo "Note: Standard zig build-lib failed, trying with build system..."

        # If direct compilation fails, we need to use the full build system
        # because of module dependencies. For now, let's output instructions.
        echo ""
        echo "Direct compilation requires module resolution."
        echo "The willo_shim.zig needs to be built as part of the Ghostty build system."
        echo ""
        echo "Add to build.zig a new target for libwillo, similar to libghostty-vt."
        exit 1
    }

# Copy output
if [ -f "libwillo.a" ]; then
    cp libwillo.a "$OUTPUT_DIR/"
    echo "Built: $OUTPUT_DIR/libwillo.a"
fi

# Also copy the header
cp "$PROJECT_ROOT/apps/ios/Willo/Sources/Bridging/willo_bridge.h" "$OUTPUT_DIR/"

echo "Done! Library built at: $OUTPUT_DIR/"
