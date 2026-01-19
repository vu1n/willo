#!/bin/bash
set -euo pipefail

# Build the Willo Bridge Plugin and update iOS app resources
# Usage: ./scripts/build-bridge-plugin.sh [--ios-build]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$ROOT_DIR/willo-bridge-plugin"
IOS_RESOURCES="$ROOT_DIR/apps/ios/Willo/Sources/Resources"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}=== Building Willo Bridge Plugin ===${NC}"
echo ""

# Build the WASM plugin
cd "$PLUGIN_DIR"
./build.sh

# Copy to iOS resources
echo ""
echo -e "${YELLOW}Copying to iOS app resources...${NC}"
mkdir -p "$IOS_RESOURCES"
cp dist/willo-bridge.wasm "$IOS_RESOURCES/"
cp dist/willo-bridge.version "$IOS_RESOURCES/"

echo -e "${GREEN}✓ Updated iOS resources:${NC}"
ls -la "$IOS_RESOURCES/willo-bridge"*

# Optionally build iOS app
if [[ "${1:-}" == "--ios-build" ]]; then
    echo ""
    echo -e "${YELLOW}Building iOS app...${NC}"
    cd "$ROOT_DIR/apps/ios"
    xcodebuild -scheme Willo \
        -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4),OS=18.6' \
        build 2>&1 | grep -E "(BUILD|error:|warning:)" || true

    if xcodebuild -scheme Willo \
        -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4),OS=18.6' \
        build 2>&1 | grep -q "BUILD SUCCEEDED"; then
        echo -e "${GREEN}✓ iOS app build succeeded${NC}"
    fi
fi

echo ""
echo -e "${GREEN}Done!${NC}"
echo ""
echo "Next steps:"
echo "  - Build iOS app: cd apps/ios && xcodebuild -scheme Willo ..."
echo "  - Or run with --ios-build flag to build automatically"
