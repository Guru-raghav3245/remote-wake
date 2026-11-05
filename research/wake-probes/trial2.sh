#!/bin/bash
# usage: ./trial2.sh <row 1-6> <delay-minutes>     (row 6 = no-ping control: pass 0 ping with PING=no)
# Schedules a ping on the VM (it keeps running while this Mac sleeps), saves pmset settings, sleeps the Mac.
# Wake the Mac by hand at delay + 2 min, then run ./collect2.sh.
set -e
cd "$(dirname "$0")"
ROW=$1 DELAY=$2
[ -n "$DELAY" ] || { echo "usage: $0 <row> <delay-min>"; exit 1; }
pgrep -f "python3 .*client.py" >/dev/null || { echo "client.py isn't running"; exit 1; }
tail -1 ~/wake2-client.log | grep -qE "error|closed" && { echo "client not connected: $(tail -1 ~/wake2-client.log)"; exit 1; }
SRC=$(pmset -g batt | head -1 | sed "s/.*'\(.*\)'.*/\1/")
NAP=$(pmset -g | awk '/powernap/{print $2}')
echo "$(date +%s),row=$ROW,delay_min=$DELAY,power=$SRC,powernap=$NAP,ping=${PING:-yes}" >> trials2.log
pmset -g >> trials2-pmset.txt
if [ "${PING:-yes}" = yes ]; then
  CMD="sleep $((DELAY*60)); echo ping > ~/ctl"
else
  CMD="true"
fi
gcloud compute ssh --project=<gcp-project> --zone=us-central1-a --quiet wakeprobe-sender \
  --command "setsid nohup sh -c '$CMD' >/dev/null 2>&1 < /dev/null &"
echo "Sleeping now. VM pings in $DELAY min. Don't touch the Mac; wake it by hand in $((DELAY+2)) min."
sleep 2
pmset sleepnow
