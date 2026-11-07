#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app="${COURIER_BUILD_APP:-$here/build/courier-overlay.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
rm -f "$app"/Contents/Resources/bird-*.png "$app"/Contents/Resources/bird-*.svg "$app/Contents/Resources/SkyLightBridge.o"
clang -O2 -fobjc-arc -c "$here/CAWindowBridge.m" -o "$app/Contents/Resources/CAWindowBridge.o"
swiftc -O -framework Foundation -framework ApplicationServices -framework CoreGraphics -framework QuartzCore \
  "$here/CodeBirdArt.swift" "$here/CABirdNode.swift" "$here/CAParticles.swift" "$here/PairPalette.swift" "$here/CAOverlayRenderer.swift" \
  "$here/RolloutState.swift" "$here/SidebarLocator.swift" "$here/CourierOverlay.swift" "$app/Contents/Resources/CAWindowBridge.o" \
  -o "$app/Contents/MacOS/courier-overlay"
swiftc -O -parse-as-library -framework AppKit "$here/PairPalette.swift" "$here/CourierPanel.swift" -o "$app/Contents/MacOS/courier-panel"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>tech.marave.courier-overlay</string>
<key>CFBundleName</key><string>courier-overlay</string>
<key>CFBundleExecutable</key><string>courier-overlay</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ "${1:-}" = "--install" ]; then
  if [ -z "${COURIER_SIGN_IDENTITY:-}" ]; then
    echo "COURIER_SIGN_IDENTITY is required for a stable Accessibility grant" >&2
    exit 2
  fi
  codesign --force --deep --options runtime --sign "$COURIER_SIGN_IDENTITY" "$app"
  destination="$HOME/Applications/courier-overlay.app"
  mkdir -p "$HOME/Applications"
  ditto "$app" "$destination"
  echo "$destination"
else
  echo "$app"
fi
