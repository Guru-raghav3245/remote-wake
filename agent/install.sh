#!/bin/bash
# usage: sudo ./agent/install.sh <service-url> <mac-token>
# Installs the agent as a root LaunchDaemon. Remove with: sudo ./agent/uninstall.sh
set -e
[ "$(id -u)" = 0 ] && [ -n "$2" ] || { echo "usage: sudo $0 <service-url> <mac-token>"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
install -d /usr/local/libexec /usr/local/etc
install -m 755 "$HERE/wakeagent.py" /usr/local/libexec/wakeagent.py
( umask 077; printf '{"url": "%s", "token": "%s"}\n' "$1" "$2" > /usr/local/etc/wakeagent.json )
cat > /Library/LaunchDaemons/com.guru.wakeagent.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.guru.wakeagent</string>
  <key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>/usr/local/libexec/wakeagent.py</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
PLIST
launchctl bootout system/com.guru.wakeagent 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.guru.wakeagent.plist
echo "installed; log: /var/log/wakeagent.log"
