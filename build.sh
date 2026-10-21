#!/bin/zsh
# Builds GimbalBar.app next to this script.
set -e
cd "${0:A:h}"
APP=GimbalBar.app
rm -rf build "$APP"
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon from icon/icon-1024.png
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s icon/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) icon/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

clang -O2 -c ptz.c -o build/ptz.o
swiftc -O -parse-as-library -import-objc-header ptz.h \
  GimbalBar.swift build/ptz.o \
  -framework IOKit -framework CoreFoundation -framework Carbon -framework AVFoundation \
  -o "$APP/Contents/MacOS/GimbalBar"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>GimbalBar</string>
  <key>CFBundleIdentifier</key><string>io.amirm.gimbalbar</string>
  <key>CFBundleExecutable</key><string>GimbalBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCameraUsageDescription</key><string>Exibe a imagem da DJI Osmo Pocket 3 para controlar o enquadramento.</string>
</dict></plist>
EOF

codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
