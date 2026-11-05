#!/bin/bash
# Run on the Mac under test, after waking it by hand.
echo "== pmset log =="; pmset -g log | grep -E 'Sleep  |Wake  |DarkWake' | tail -40
echo "== pmset stats =="; pmset -g stats
echo "== apsd =="; log show --last 30m --info --predicate 'process == "apsd"'
echo "== app log =="; cat ~/wake1-app.log
echo "== extension log =="; cat ~/Library/Group\ Containers/group.com.guru.wakeprobe/wake1-ext.log
