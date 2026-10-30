#!/bin/bash
# Runs on the VM: once the Mac's first poll arrives, queue N pings at random 15-75 s gaps.
N=${1:-12}
TOKEN=$(grep -oE "TOKEN = '[0-9a-f]+'" ~/poll_server.py | grep -oE "[0-9a-f]{48}")
for i in $(seq 600); do grep -q "seq=1 " ~/poll.log 2>/dev/null && break; sleep 1; done
for i in $(seq $N); do
  sleep $((RANDOM % 61 + 15))
  curl -s "http://127.0.0.1:9001/ping?token=$TOKEN" >/dev/null
done
