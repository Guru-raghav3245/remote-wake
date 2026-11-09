#!/bin/bash
# usage: sudo ./agent/stayawake-uninstall.sh
[ "$(id -u)" = 0 ] || { echo "usage: sudo $0"; exit 1; }
launchctl bootout system/com.guru.stayawake 2>/dev/null || true
pmset -a disablesleep 0 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.guru.stayawake.plist /etc/sudoers.d/stayawake /usr/local/libexec/remotewake-blackbox.sh; rm -rf /Library/Logs/RemoteWake
echo "removed; the Mac sleeps normally again"
