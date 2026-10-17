#!/bin/zsh
# Builds a release Wheelie.app in ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
APP=build/Wheelie.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Wheelie" "$APP/Contents/MacOS/Wheelie"

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Wheelie</string>
    <key>CFBundleDisplayName</key><string>Wheelie</string>
    <key>CFBundleIdentifier</key><string>local.wheelie.Wheelie</string>
    <key>CFBundleExecutable</key><string>Wheelie</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Wheelie || true
    rm -rf /Applications/Wheelie.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Wheelie.app"
fi
