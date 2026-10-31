#!/bin/bash
# usage: sudo ./agent/tailscale-install.sh <dir with tailscale + tailscaled>
# Installs Tailscale as a system daemon (runs before login, can be a Tailscale SSH server). Skips if one is already running.
set -e
[ "$(id -u)" = 0 ] && [ -d "$1" ] || { echo "usage: sudo $0 <binary-dir>"; exit 1; }
if launchctl print system/com.tailscale.tailscaled >/dev/null 2>&1 && [ -x /usr/local/bin/tailscaled ]; then echo "tailscaled already installed"; exit 0; fi
install -d /usr/local/bin
install -m 755 "$1/tailscale" /usr/local/bin/
xattr -cr "$1/tailscaled" /usr/local/bin/tailscale 2>/dev/null || true   # drop the download quarantine flag
# the daemon copies itself to /usr/local/bin and sets up the LaunchDaemon; run it from OUR copy
# (running it from /usr/local/bin deletes the file it is copying, which leaves no daemon binary)
"$1/tailscaled" install-system-daemon
echo "tailscaled installed"
