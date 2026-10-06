#!/bin/sh
# Build Pacer.app — a hand-rolled macOS app bundle, no Xcode project needed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# Build in the cache directory: codesign refuses bundles that carry iCloud's
# protected file-provider attributes, which a checkout in iCloud Drive has.
BUILD="${HOME}/Library/Caches/dev.maxim.pacer/build"
APP="$BUILD/Pacer.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

# Clean previous build
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

# Info.plist
cp "$HERE/Info.plist" "$CONTENTS/Info.plist"

# Resources: per-mode menu bar templates (auto-tinted by AppKit) + app icon
# (Assets.car: the Liquid Glass icon for macOS 26 and later; AppIcon.icns: the same icon for earlier versions.
# Both are rendered from Pacer.icon by Tools/app_icon.sh.)
cp "$HERE/Resources/"MenuBarIcon*Template*.png   "$RES/"
cp "$HERE/Resources/AppIcon.icns"                "$RES/"
cp "$HERE/Resources/Assets.car"                 "$RES/"

# Compile Swift sources into a single binary
swiftc \
    -target arm64-apple-macos13.0 \
    -O \
    -framework AppKit \
    -framework SwiftUI \
    -framework ServiceManagement \
    -o "$MACOS/Pacer" \
    "$HERE/Sources/"*.swift

chmod +x "$MACOS/Pacer"

# Strip iCloud / Finder extended attributes — codesign refuses bundles with them.
xattr -cr "$APP" 2>/dev/null || true

# Ad-hoc codesign so Gatekeeper lets us launch & SMAppService accepts the bundle.
codesign --force --deep --sign - "$APP"

# Strip quarantine if this folder was downloaded/synced
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo
echo "Built: $APP"
echo
echo "To run:    open '$APP'"
echo "To install:  mv '$APP' /Applications/"
