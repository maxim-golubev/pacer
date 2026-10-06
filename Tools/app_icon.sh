#!/bin/sh
# Renders the app icon document (Pacer.icon) into the committed files the build copies:
#   Resources/Assets.car    the compiled icon; macOS 26 and later draw it with Liquid Glass in every appearance
#   Resources/AppIcon.icns  the default appearance up to 1024 px, for macOS 13 to 15
#   docs/images/icon-light.png, icon-dark.png   the README's icon
# Needs Xcode 26 (actool, and Icon Composer's ictool). Run it after editing the icon.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$HERE/Pacer.icon"
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

swiftc -O -framework AppKit -o "$SCRATCH/compose" "$HERE/Tools/icon_compose.swift"

# The tile alone, masked to its rounded shape, as ictool draws it
tile() { "$ICTOOL" "$DOC" --export-image --output-file "$3" --platform macOS --rendition "$1" \
    --width "$2" --height "$2" --scale 1 >/dev/null 2>&1; }

mkdir "$SCRATCH/compiled"
xcrun actool "$DOC" --compile "$SCRATCH/compiled" --platform macosx --minimum-deployment-target 13.0 \
    --app-icon Pacer --output-partial-info-plist "$SCRATCH/partial.plist" >/dev/null
cp "$SCRATCH/compiled/Assets.car" "$HERE/Resources/Assets.car"

mkdir "$SCRATCH/AppIcon.iconset"
for points in 16 32 128 256 512; do
    for factor in 1 2; do
        pixels=$((points * factor))
        name="icon_${points}x${points}"; [ "$factor" = 2 ] && name="${name}@2x"
        tile Default $(( (pixels * 824 + 512) / 1024 )) "$SCRATCH/tile.png"
        "$SCRATCH/compose" "$SCRATCH/tile.png" "$SCRATCH/AppIcon.iconset/$name.png" "$pixels" 824
    done
done
iconutil --convert icns --output "$HERE/Resources/AppIcon.icns" "$SCRATCH/AppIcon.iconset"

# On a web page the grid's margin is only empty space: the README's icon keeps just room for the shadow
for pair in Default:light Dark:dark; do
    tile "${pair%%:*}" $(( (256 * 944 + 512) / 1024 )) "$SCRATCH/readme.png"
    "$SCRATCH/compose" "$SCRATCH/readme.png" "$HERE/docs/images/icon-${pair##*:}.png" 256 944
done
echo "Wrote Resources/Assets.car, Resources/AppIcon.icns, docs/images/icon-light.png and icon-dark.png"
