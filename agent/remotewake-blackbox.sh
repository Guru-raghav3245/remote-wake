#!/bin/sh
# Black box: one line every 30 s in /Library/Logs/RemoteWake/blackbox.log, written by the root stay-awake daemon.
# The phone reads it over SSH after an outage to say WHY the Mac was unreachable (battery, crash, sleep, no internet).
#   sample: <epoch> b=<boot time> batt=<%> src=AC|BATT net=1|0 ts=1|0
#   BOOT:   <epoch> BOOT b=<boot time> sr=<kernel's last shutdown reason>   (written when the boot time changed)
#   STOP:   <epoch> STOP        (this script got TERM: clean shutdown, restart, or stay-awake switched off; a dead battery never writes it)
# Keeps about 7 days. Holds no location, no Wi-Fi name, nothing but these numbers.
D=/Library/Logs/RemoteWake; F=$D/blackbox.log
mkdir -p "$D"; chmod 755 "$D"; touch "$F"; chmod 644 "$F"
trap 'echo "$(date +%s) STOP" >> "$F"; exit 0' TERM INT
n=0
while :; do
  now=$(date +%s)
  b=$(sysctl -n kern.boottime | sed -n 's/.*{ sec = \([0-9]*\),.*/\1/p')
  last=$(grep ' b=' "$F" | tail -n 1 | sed -n 's/.* b=\([0-9]*\).*/\1/p')
  [ "$last" = "$b" ] || echo "$now BOOT b=$b sr=$(sysctl -n kern.shutdownreason 2>/dev/null | tr ' ' '_')" >> "$F"
  p=$(/usr/bin/pmset -g batt)
  pct=$(echo "$p" | grep -o '[0-9]*%' | head -1 | tr -d %)
  echo "$p" | grep -q 'AC Power' && src=AC || src=BATT
  # internet = a TCP connection to a public address works (a hotel login page that blocks traffic counts as no internet)
  { /usr/bin/nc -z -G 3 -w 3 1.1.1.1 443 || /usr/bin/nc -z -G 3 -w 3 8.8.8.8 53; } >/dev/null 2>&1 && net=1 || net=0
  [ "$(/usr/local/bin/tailscale status --json 2>/dev/null | /usr/bin/plutil -extract Self.Online raw -o - - 2>/dev/null)" = true ] && ts=1 || ts=0
  echo "$now b=$b batt=${pct:-?} src=$src net=$net ts=$ts" >> "$F"
  n=$((n+1))
  if [ $((n % 120)) = 0 ] && [ "$(wc -l < "$F")" -gt 24000 ]; then tail -n 20000 "$F" > "$F.tmp" && mv "$F.tmp" "$F" && chmod 644 "$F"; fi
  sleep 30 & wait $!   # `wait` lets the TERM trap run at once instead of after the sleep
done
