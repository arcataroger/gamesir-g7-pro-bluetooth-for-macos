#!/bin/zsh
# Builds "GameSir G7 Pro Bluetooth Setup.app" into build/. Needs Xcode Command Line Tools (swiftc). Ad-hoc signed.
set -e
HERE=${0:A:h}
APP="$HERE/build/GameSir G7 Pro Bluetooth Setup.app"
command -v swiftc >/dev/null || { echo "swiftc not found: xcode-select --install"; exit 1; }
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "==> Compiling"
swiftc -O -parse-as-library "$HERE/src/Core.swift" "$HERE/src/Install.swift" "$HERE/src/App.swift" -o "$APP/Contents/MacOS/G7ProSetup" 2>&1 | grep -v -E '^$|warning:' || true
[ -x "$APP/Contents/MacOS/G7ProSetup" ] || { echo "compile failed (app)"; exit 1; }
swiftc -O "$HERE/src/Core.swift" "$HERE/src/Install.swift" "$HERE/src/main.swift" -o "$APP/Contents/MacOS/g7pro" 2>&1 | grep -v -E '^$|warning:' || true
[ -x "$APP/Contents/MacOS/g7pro" ] || { echo "compile failed (cli)"; exit 1; }
mkdir -p "$HERE/build"; ln -sf "$APP/Contents/MacOS/g7pro" "$HERE/build/g7pro"
echo "==> Icon"
ICONTOOL="$HERE/build/icon-render"; swiftc -O "$HERE/tools/icon.swift" -o "$ICONTOOL" 2>&1 | grep -v warning || true
ICONSET="$HERE/build/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  "$ICONTOOL" "$ICONSET/icon_${sz}x${sz}.png" $sz >/dev/null
  "$ICONTOOL" "$ICONSET/icon_${sz}x${sz}@2x.png" $((sz*2)) >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
echo "==> Bundling resources"
cp -R "$HERE/data" "$HERE/personality" "$APP/Contents/Resources/"
VERSION=$(git -C "$HERE" describe --tags --always 2>/dev/null || echo dev)
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>GameSir G7 Pro Bluetooth Setup</string>
  <key>CFBundleDisplayName</key><string>GameSir G7 Pro Bluetooth Setup</string>
  <key>CFBundleIdentifier</key><string>com.arcataroger.g7pro-bluetooth-setup</string>
  <key>CFBundleExecutable</key><string>G7ProSetup</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PL
echo "==> Signing (ad hoc)"
codesign --force --deep --sign - "$APP"
# An ad-hoc signature changes every build, which silently invalidates a previous Input Monitoring grant
# (the toggle stays on in System Settings but no longer matches). Clear it so the next launch prompts cleanly.
tccutil reset ListenEvent com.arcataroger.g7pro-bluetooth-setup >/dev/null 2>&1 || true
echo "Built: $APP"
echo "CLI:   $HERE/build/g7pro  (symlink into the app)"
