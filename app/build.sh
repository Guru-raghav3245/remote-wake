#!/bin/bash
# builds "Remote Wake.app" and "Remote Wake.dmg" next to this script (ad-hoc signed, local use)
set -e; cd "$(dirname "$0")"
A="build/Remote Wake.app"; rm -rf build; mkdir -p "$A/Contents/MacOS"
swiftc -O -parse-as-library -o "$A/Contents/MacOS/RemoteWake" RemoteWakeMenu.swift
mkdir -p "$A/Contents/Resources/agent"; cp ../agent/wakeagent.py ../agent/install.sh ../agent/uninstall.sh "$A/Contents/Resources/agent/"
cat > "$A/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Remote Wake</string>
<key>CFBundleIdentifier</key><string>com.guru.remotewake.menu</string>
<key>CFBundleExecutable</key><string>RemoteWake</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
P
codesign --force -s - "$A"
rm -f "Remote Wake.dmg" build/rw.dmg
swift make_bg.swift build/bg.png
hdiutil create -quiet -size 20m -fs HFS+ -volname "Remote Wake" -ov build/rw.dmg
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
