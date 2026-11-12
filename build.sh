#!/bin/zsh
# Şerit'i derler, ~/Applications/Şerit.app olarak kurar ve girişte başlatır.
#   ./build.sh               -> derle + kur + başlat
#   ./build.sh --no-install  -> sadece build/Serit.app üret
set -euo pipefail
cd "${0:A:h}"

BUNDLE_ID="${SERIT_BUNDLE_ID:-local.$(whoami).serit}"
BUILD=build
APP="$BUILD/Serit.app"

rm -rf "$APP" "$BUILD/Serit.iconset"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/Serit.iconset"

echo "→ simge"
swift scripts/make_icon.swift "$BUILD/icon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon.png" --out "$BUILD/Serit.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BUILD/icon.png" --out "$BUILD/Serit.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/Serit.iconset" -o "$APP/Contents/Resources/Serit.icns"

echo "→ derleme"
swiftc -O Sources/*.swift -o "$APP/Contents/MacOS/Serit" -framework IOKit -framework CoreAudio -framework AudioToolbox -framework CoreLocation -framework EventKit

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>Şerit</string>
<key>CFBundleDisplayName</key><string>Şerit</string>
<key>CFBundleExecutable</key><string>Serit</string>
<key>CFBundleIconFile</key><string>Serit</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSLocationUsageDescription</key><string>Şerit, hava durumunu bulunduğun yer için göstermek üzere konumunu sadece şehir düzeyinde kullanır.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Şerit, hava durumunu bulunduğun yer için göstermek üzere konumunu sadece şehir düzeyinde kullanır.</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>Şerit, takvimdeki sıradaki etkinliği saatin yanında göstermek için takvimini okur.</string>
<key>NSAppleEventsUsageDescription</key><string>Şerit, Spotify ve Music'te çalan şarkıyı Touch Bar'da göstermek için bu uygulamalara sorar.</string>
<key>NSHumanReadableCopyright</key><string>Touch Bar'ın hızlı ve kendini onaran hali.</string>
</dict></plist>
EOF

SIGN_ID="-"
if security find-identity -p codesigning 2>/dev/null | grep -q "Veda Local Signing"; then SIGN_ID="Veda Local Signing"; fi
codesign --force -s "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"

[[ "${1:-}" == "--no-install" ]] && { echo "✓ $APP"; exit 0; }

echo "→ kurulum"
DEST="$HOME/Applications/Şerit.app"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$BUNDLE_ID" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"; cp -R "$APP" "$DEST"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$BUNDLE_ID</string>
<key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/Serit</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ProcessType</key><string>Interactive</string>
<key>StandardErrorPath</key><string>$HOME/Library/Logs/serit.log</string>
</dict></plist>
EOF
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "✓ Şerit kuruldu ve çalışıyor."
