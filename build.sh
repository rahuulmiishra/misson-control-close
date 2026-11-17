#!/bin/bash
# Builds MissionControlCloser.app. No Xcode required — swiftc plus a hand-rolled bundle.
set -e
cd "$(dirname "$0")"

APP="build/MissionControlCloser.app"
BUNDLE_ID="dev.allahabadi.MissionControlCloser"
VERSION="1.0"

rm -rf "$APP"
mkdir -p build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Mission Control Closer</string>
    <key>CFBundleDisplayName</key>       <string>Mission Control Closer</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>MissionControlCloser</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# Universal binary: Apple Silicon plus Intel, so the app can be shared with
# anyone on macOS 13+.
echo "Compiling arm64…"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
    Sources/*.swift -o build/mcc-arm64 \
    -framework AppKit -framework ApplicationServices -framework ServiceManagement

echo "Compiling x86_64…"
swiftc -O -swift-version 5 -target x86_64-apple-macos13.0 \
    Sources/*.swift -o build/mcc-x86_64 \
    -framework AppKit -framework ApplicationServices -framework ServiceManagement

echo "Merging…"
lipo -create build/mcc-arm64 build/mcc-x86_64 \
    -output "$APP/Contents/MacOS/MissionControlCloser"
rm -f build/mcc-arm64 build/mcc-x86_64

# Ad-hoc signature. Accessibility permission is keyed to it, so a rebuild can
# require re-granting in System Settings.
codesign --force --sign - "$APP" 2>/dev/null || echo "warning: codesign failed (app will still run)"

# Accessibility permission is bound to the signed binary at a fixed path, so
# keep updating the installed copy rather than leaving a second one in build/.
if [ -d /Applications/MissionControlCloser.app ]; then
    RUNNING=$(pgrep -f "/Applications/MissionControlCloser.app" || true)
    [ -n "$RUNNING" ] && pkill -f "/Applications/MissionControlCloser.app" && sleep 1
    rm -rf /Applications/MissionControlCloser.app
    cp -R "$APP" /Applications/
    echo "Updated /Applications/MissionControlCloser.app"
    if [ -n "$RUNNING" ]; then
        open /Applications/MissionControlCloser.app
        echo "Relaunched. If it stops working, re-tick it in Accessibility settings."
    fi
fi

echo "Built $APP"
lipo -archs "$APP/Contents/MacOS/MissionControlCloser" | sed 's/^/  architectures: /' 
