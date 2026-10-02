#!/bin/bash
# Builds Easel.app from the code in this folder.
# Run it from Terminal with:   bash make-app.sh
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift isn't installed yet. Run this first, then try again:"
  echo "    xcode-select --install"
  exit 1
fi

echo "Building Easel… (the first time takes a few minutes)"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/Easel"
APP="Easel.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Easel"

# App icon
WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -z "$size" "$size" Resources/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$double" "$double" Resources/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$WORK"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Easel</string>
    <key>CFBundleDisplayName</key>
    <string>Easel</string>
    <key>CFBundleExecutable</key>
    <string>Easel</string>
    <key>CFBundleIdentifier</key>
    <string>local.easel.app</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# Sign it for this Mac only (needed so macOS will open it).
if ! codesign --force --sign - "$APP" >/dev/null 2>&1; then
  echo "Note: couldn't sign the app. It may still open fine."
fi

echo ""
echo "Done! Easel.app is ready. Drag it into your Applications folder."
open -R "$APP"
