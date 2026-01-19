#!/bin/bash
set -euo pipefail

# Willo Bridge Plugin Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/vu1n/willo/main/willo-bridge-plugin/install.sh | bash
#    or: curl -fsSL <url>/install.sh | bash -s -- --version 1.0.0

VERSION="${1:-1.0.0}"
INSTALL_DIR="$HOME/.willo"
WASM_URL="https://github.com/vu1n/willo/releases/download/bridge-v${VERSION}/willo-bridge.wasm"

# Colors (if terminal supports it)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

echo -e "${GREEN}Willo Bridge Plugin Installer${NC}"
echo "Installing version: $VERSION"
echo ""

# Check for zellij
if ! command -v zellij &> /dev/null; then
    echo -e "${YELLOW}Warning: Zellij not found in PATH${NC}"
    echo "The plugin requires Zellij 0.40.0+ to function."
fi

# Check zellij version if available
if command -v zellij &> /dev/null; then
    ZELLIJ_VERSION=$(zellij --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    echo "Detected Zellij version: $ZELLIJ_VERSION"

    # Simple version check (0.40.0 minimum)
    MAJOR=$(echo "$ZELLIJ_VERSION" | cut -d. -f1)
    MINOR=$(echo "$ZELLIJ_VERSION" | cut -d. -f2)
    if [[ "$MAJOR" -eq 0 && "$MINOR" -lt 40 ]]; then
        echo -e "${RED}Error: Zellij 0.40.0+ required for pipe support (found: $ZELLIJ_VERSION)${NC}"
        exit 1
    fi
fi

# Create install directory
mkdir -p "$INSTALL_DIR"

# Download plugin
echo ""
echo "Downloading plugin..."
if command -v curl &> /dev/null; then
    curl -fsSL "$WASM_URL" -o "$INSTALL_DIR/willo-bridge.wasm.tmp"
elif command -v wget &> /dev/null; then
    wget -q "$WASM_URL" -O "$INSTALL_DIR/willo-bridge.wasm.tmp"
else
    echo -e "${RED}Error: Neither curl nor wget found${NC}"
    exit 1
fi

# Verify download (basic check - file exists and has content)
if [[ ! -s "$INSTALL_DIR/willo-bridge.wasm.tmp" ]]; then
    echo -e "${RED}Error: Download failed or file is empty${NC}"
    rm -f "$INSTALL_DIR/willo-bridge.wasm.tmp"
    exit 1
fi

# Atomic move
mv "$INSTALL_DIR/willo-bridge.wasm.tmp" "$INSTALL_DIR/willo-bridge.wasm"
echo "$VERSION" > "$INSTALL_DIR/willo-bridge.version"

# Set permissions
chmod 644 "$INSTALL_DIR/willo-bridge.wasm"
chmod 644 "$INSTALL_DIR/willo-bridge.version"

echo ""
echo -e "${GREEN}Installation complete!${NC}"
echo "  Plugin: $INSTALL_DIR/willo-bridge.wasm"
echo "  Version: $VERSION"
echo ""
echo "The Willo app will automatically use this plugin when connecting"
echo "to Zellij sessions on this server."
