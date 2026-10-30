#!/bin/bash
# Run on the Mac after waking it by hand.
echo "== pmset log =="; pmset -g log | grep -E 'Sleep  |Wake  |DarkWake' | tail -12 | cut -c1-260
echo "== client log =="; tail -8 ~/wake2-client.log
echo "== server log =="; gcloud compute ssh --project=<gcp-project> --zone=us-central1-a --quiet wakeprobe-sender --command 'tail -8 server.log' 2>&1 | tail -8
