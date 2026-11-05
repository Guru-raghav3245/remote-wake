#!/bin/bash
# builds "Remote Wake.app" and "Remote Wake.dmg" next to this script (ad-hoc signed, local use)
set -e; cd "$(dirname "$0")"
A="build/Remote Wake.app"; rm -rf build; mkdir -p "$A/Contents/MacOS"
swiftc -O -parse-as-library -o "$A/Contents/MacOS/RemoteWake" RemoteWakeMenu.swift
mkdir -p "$A/Contents/Resources/agent"; cp AppIcon.icns logo.png "$A/Contents/Resources/"; cp ../agent/tailscale-install.sh ../agent/stayawake-install.sh ../agent/stayawake-uninstall.sh ../agent/com.guru.stayawake.plist "$A/Contents/Resources/agent/"
[ -d vendor/tmux ] && cp -R vendor/tmux "$A/Contents/Resources/tmux" || echo "note: no vendor/tmux (run ./build-tmux.sh); Phone sessions will be hidden"
[ -d vendor/tailscale ] && cp -R vendor/tailscale "$A/Contents/Resources/tailscale" || echo "note: no vendor/tailscale (run ./build-tailscale.sh); app will not bundle Tailscale"
APK=../android-app/build/app/outputs/flutter-apk/app-release.apk
[ -f "$APK" ] && cp "$APK" "$A/Contents/Resources/RemoteWake.apk" || echo "note: no release APK (cd ../android-app && flutter build apk --release --target-platform android-arm64); app will not bundle the phone app"
cat > "$A/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Remote Wake</string>
<key>CFBundleIdentifier</key><string>com.guru.remotewake.menu</string>
<key>CFBundleExecutable</key><string>RemoteWake</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
P
H="$A/Contents/Library/LoginItems/Remote Wake Menu.app"; mkdir -p "$H/Contents/MacOS"
cp "$A/Contents/MacOS/RemoteWake" "$H/Contents/MacOS/"
sed -e 's/menu<\/string>/menu.helper<\/string>/' -e 's/<string>Remote Wake<\/string>/<string>Remote Wake Menu<\/string>/' -e 's/<key>LSMinimumSystemVersion/<key>LSUIElement<\/key><true\/><key>LSMinimumSystemVersion/' "$A/Contents/Info.plist" > "$H/Contents/Info.plist"
codesign --force -s - "$H"
codesign --force -s - "$A"
rm -f "Remote Wake.dmg" build/rw.dmg
swift make_bg.swift build/bg.png
hdiutil create -quiet -size 250m -fs HFS+ -volname "Remote Wake" -ov build/rw.dmg
MNT=$(hdiutil attach -nobrowse build/rw.dmg | sed -n 's/.*\(\/Volumes\/.*\)/\1/p')
cp -R "$A" "$MNT/"; ln -s /Applications "$MNT/Applications"
mkdir "$MNT/.background"; cp build/bg.png "$MNT/.background/bg.png"
VOL=$(basename "$MNT")
osascript <<S
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 100
    set background picture of opts to file ".background:bg.png"
    set position of item "Remote Wake.app" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
S
sync; hdiutil detach -quiet "$MNT"
hdiutil convert -quiet build/rw.dmg -format UDZO -o "Remote Wake.dmg"
echo built: $PWD/"Remote Wake.dmg"
