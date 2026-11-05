# Test 4: Does the wake loop work when macOS sleeps on its own?

**Question:** every earlier run forced sleep with `pmset sleepnow`. The v2 spec says the agent never forces sleep. If a scheduled wake is a full wake (display on), the Mac may stay awake until its idle timeout and never sleep between check-ins.

**Reuses:** `wakeloop.py --no-sleep` (schedules the next wake, never calls `sleepnow`), `poll_server.py`, `ping_batch.sh`. No new code.

## Setup
1. Restart the VM poll server and ping batch (`~/restart_poll.sh` on the VM). Check firewall rule `wakeprobe-9001` still allows your current public IP.
2. Save `pmset -g custom` and `pmset -g assertions` to a file.
3. Plug in the charger (AC first, battery second).
4. **Quit Claude Code first.** Its `caffeinate` holds the Mac awake and would void the test. Start the loop from the Terminal app, then do not touch the Mac:
   ```
   sudo python3 wakeloop.py 30 900 --no-sleep
   ```
5. After 15 minutes, reopen Claude Code and say "read the logs".

## Conditions (one 15 minute run each, lid open, hands off)
| Run | Power | Idle `sleep` setting |
| --- | --- | --- |
| N1 | AC | your current 1 minute |
| N2 | AC | 10 minutes (a typical default; you change it with `sudo pmset -c sleep 10`) |
| N3 | Battery | 10 minutes (`sudo pmset -b sleep 10`) |

Put the settings back after the runs. I won't change them without your OK.

## What to read
From `pmset -g log` and `~/wake3-loop.log`, per cycle:
- Wake type: `Wake` (full) or `DarkWake`, and the reason.
- Did a `Sleep` event follow within the interval? What triggered it (idle, maintenance)?
- Poll delay per ping, and whether any wake was skipped.

## Pass / fail
- **Pass:** the Mac reaches `Sleep` in at least 90% of cycles, wakes are DarkWake or short, and worst-case ping delay is 35 seconds or less.
- **Fail:** the Mac stays awake across cycles (full wakes, no `Sleep` events), or pings wait longer than 60 seconds.
- **If it fails:** the plan B is to use the IOKit power API for a DarkWake-only scheduled wake, or have the agent end its own wake after the check-in. Test that next, not before.

## Also record
Whether the display lights up on each wake, and any wake that took the Mac to a lock screen or fan spin-up.
