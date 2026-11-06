#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app="${COURIER_BUILD_APP:-$here/build/courier-overlay.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
clang -O2 -c "$here/SkyLightBridge.c" -o "$app/Contents/Resources/SkyLightBridge.o"
swiftc -O -framework Foundation -framework ApplicationServices -framework CoreGraphics -framework ImageIO \
  "$here/SidebarLocator.swift" "$here/CourierOverlay.swift" "$app/Contents/Resources/SkyLightBridge.o" \
  -o "$app/Contents/MacOS/courier-overlay"
swiftc -O -parse-as-library -framework AppKit "$here/CourierPanel.swift" -o "$app/Contents/MacOS/courier-panel"
cp "$here"/assets/bird-*.svg "$app/Contents/Resources/"
for source in "$here"/assets/bird-*.svg; do
  name=$(basename "$source" .svg)
  sed 's/width="36" height="36"/width="72" height="72"/' "$source" > "$app/Contents/Resources/$name-2x.svg"
  sips -s format png -o "$app/Contents/Resources/$name.png" "$app/Contents/Resources/$name-2x.svg" >/dev/null
  rm "$app/Contents/Resources/$name-2x.svg"
done
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
