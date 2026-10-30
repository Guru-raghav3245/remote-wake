#!/bin/bash
# usage: ./trial.sh <row 1-6> <delay-minutes> <alert|background>
# Schedules the push on the VM (it keeps running while this Mac sleeps), then sleeps the Mac.
# After the push should have arrived (delay + 2 min), wake the Mac by hand, then run ./collect.sh.
set -e
cd "$(dirname "$0")"
ROW=$1 DELAY=$2 TYPE=$3
[ -n "$TYPE" ] || { echo "usage: $0 <row> <delay-min> <alert|background>"; exit 1; }
pgrep -x WakeProbe >/dev/null || { echo "WakeProbe app isn't running"; exit 1; }
SRC=$(pmset -g batt | head -1 | sed "s/.*'\(.*\)'.*/\1/")
NAP=$(pmset -g | awk '/powernap/{print $2}')
echo "$(date +%s),row=$ROW,delay_min=$DELAY,type=$TYPE,power=$SRC,powernap=$NAP" >> trials.log
gcloud compute ssh --project=<gcp-project> --zone=us-central1-a --quiet wakeprobe-sender \
  --command "setsid nohup sh -c 'sleep $((DELAY*60)); ./send.sh $TYPE' >/dev/null 2>&1 < /dev/null &"
echo "VM will send '$TYPE' in $DELAY min. Sleeping now. Don't touch the Mac; wake it by hand in $((DELAY+2)) min."
sleep 2
pmset sleepnow
