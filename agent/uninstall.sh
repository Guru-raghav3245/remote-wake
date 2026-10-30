#!/bin/bash
# usage: sudo ./agent/uninstall.sh   (removes only the files install.sh created)
launchctl bootout system/com.guru.wakeagent 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.guru.wakeagent.plist /usr/local/libexec/wakeagent.py /usr/local/etc/wakeagent.json
echo "removed"
rm -f /etc/sudoers.d/remotewake
