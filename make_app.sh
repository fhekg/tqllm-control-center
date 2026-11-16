#!/bin/bash
# 打包 tqLLM Control Center.app：release 构建 + Info.plist + 图标 + ad-hoc 签名。
set -euo pipefail
cd "$(dirname "$0")"
PY="${DSH_PYTHON:-/Users/xingbin/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3}"

./build.sh release

APP="build/tqLLM Control Center.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TqLLMControlCenter "$APP/Contents/MacOS/TqLLMControlCenter"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.xingbin.tqllm-control-center</string>
  <key>CFBundleName</key><string>tqLLM Control Center</string>
  <key>CFBundleDisplayName</key><string>tqLLM Control Center</string>
  <key>CFBundleExecutable</key><string>TqLLMControlCenter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# 图标
"$PY" Tools/make_icon.py build/icon_1024.png
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size build/icon_1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double build/icon_1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "app ready: $APP"