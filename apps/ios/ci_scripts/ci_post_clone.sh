#!/bin/bash
set -euo pipefail

# ci_post_clone.sh - Xcode Cloud post-clone script
# Downloads pre-built xcframeworks from GitHub Releases
# instead of relying on Git LFS (avoids bandwidth costs)

FRAMEWORKS_DIR="$CI_PRIMARY_REPOSITORY_PATH/apps/ios/Willo/Frameworks"
RELEASE_TAG="frameworks-v1"
REPO="vu1n/willo"
ARCHIVE_NAME="willo-frameworks.tar.gz"

echo "==> Creating Frameworks directory"
mkdir -p "$FRAMEWORKS_DIR"

echo "==> Downloading xcframeworks from GitHub Release: $RELEASE_TAG"

# Download the frameworks archive from GitHub Releases (public repo, no auth needed)
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$RELEASE_TAG/$ARCHIVE_NAME"

cd "$FRAMEWORKS_DIR"

# Clean any LFS pointer files (they'll be small text files, not real binaries)
# Only clean if the frameworks look like LFS pointers (< 1KB)
for xcfw in *.xcframework; do
    if [ -d "$xcfw" ]; then
        # Check if any .a or framework binary is suspiciously small (LFS pointer)
        first_binary=$(find "$xcfw" -name "*.a" -o -name "*.framework" | head -1)
        if [ -n "$first_binary" ] && [ "$(stat -f%z "$first_binary" 2>/dev/null || echo 0)" -lt 1024 ]; then
            echo "  Removing LFS pointer: $xcfw"
            rm -rf "$xcfw"
        fi
    fi
done

# Download and extract
echo "  Downloading from: $DOWNLOAD_URL"
curl -L --retry 3 --retry-delay 5 -o "$ARCHIVE_NAME" "$DOWNLOAD_URL"
echo "  Extracting frameworks..."
tar xzf "$ARCHIVE_NAME"
rm "$ARCHIVE_NAME"

echo "==> Frameworks installed:"
du -sh *.xcframework

echo "==> Resolving Swift packages..."
cd "$CI_PRIMARY_REPOSITORY_PATH/apps/ios"
xcodebuild -project Willo.xcodeproj \
  -scheme Willo \
  -resolvePackageDependencies

echo "==> Post-clone complete"
