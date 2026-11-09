#!/bin/bash
# usage: sudo ./agent/stayawake-install.sh [user]   (undo: sudo ./agent/stayawake-uninstall.sh)
# [user] (default: the sudo caller) may then turn it on/off without a password, see the sudoers rule below.
# Keeps the Mac awake, lid closed too, on AC and on battery. Replaces the old wake-loop agent.
set -e
[ "$(id -u)" = 0 ] || { echo "usage: sudo $0"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
# the old agent sleeps the Mac when idle, which would fight this one
launchctl bootout system/com.guru.wakeagent 2>/dev/null || true
launchctl disable system/com.guru.wakeagent 2>/dev/null || true
mkdir -p /usr/local/libexec; install -m 755 -o root -g wheel "$HERE/remotewake-blackbox.sh" /usr/local/libexec/remotewake-blackbox.sh
install -m 644 -o root -g wheel "$HERE/com.guru.stayawake.plist" /Library/LaunchDaemons/com.guru.stayawake.plist
launchctl enable system/com.guru.stayawake 2>/dev/null || true
launchctl bootout system/com.guru.stayawake 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.guru.stayawake.plist
U="${1:-$SUDO_USER}"
if [ -n "$U" ]; then  # exactly these four commands, nothing else
  T=$(mktemp); L=com.guru.stayawake
  echo "$U ALL=(root) NOPASSWD: /bin/launchctl disable system/$L, /bin/launchctl bootout system/$L, /bin/launchctl enable system/$L, /bin/launchctl bootstrap system /Library/LaunchDaemons/$L.plist" > "$T"
  visudo -cf "$T" >/dev/null && install -m 440 -o root -g wheel "$T" /etc/sudoers.d/stayawake; rm -f "$T"
fi
sleep 1
pmset -g | grep -q 'SleepDisabled.*1' && echo "installed: Mac stays awake (AC and battery)" || echo "installed, but sleep is not disabled yet"
