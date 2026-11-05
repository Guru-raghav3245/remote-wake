# Test 5: guarded sleep

**Why:** Test 4 showed the Mac never sleeps on its own once the 30 second wake loop runs (each scheduled wake counts as user activity and restarts the idle timer). Fix under test: after each check-in the agent sleeps the Mac only if the user has been idle 60 s and nothing else holds the Mac awake.

**Code:** `wakeloop.py --guard` (new). Idle time = `HIDIdleTime` from `ioreg -c IOHIDSystem` (real keyboard/trackpad only). Blockers = any process other than `powerd` holding `PreventUserIdleSystemSleep` or `PreventSystemSleep` in `pmset -g assertions`. It re-checks every 2 s until 5 s before the next wake, so short holds (like the 11 s audio assertion seen after each wake) can clear. Each cycle logs `guard OK idle=… -> sleeping` or `guard: staying awake idle=… blockers=[…]`.

## Setup (each run)
1. Close Claude Code (its `caffeinate` is a blocker and would void the run).
2. On AC, lid open. I restart the VM poll server and ping batch just before.
3. In Terminal: `cd "/Users/<user>/Desktop/projects/Remote Wake"`, `sudo -v`, then the command below.

## Run G1: in use, then away (15 min)
```
sudo python3 wakeloop.py 30 900 --guard
```
- 0:00 to 4:00: use the Mac normally (scroll, type every ~20 s). Note the time you stop.
- 4:00 to 15:00: hands off. Display can turn itself off. No audio.

**Expected**
| Phase | Expected log | Expected power log |
| --- | --- | --- |
| In use | `guard: staying awake idle=<60s` every cycle | no `Sleep` events |
| Away | within 1 to 3 cycles of leaving: `guard OK idle=6x s -> sleeping`, then `woke after gap ~30s` | `Sleep` then `Wake` or `DarkWake` pairs about every 30 s |

## Run G2: another app holds the Mac awake (8 min)
```
sudo python3 wakeloop.py 30 480 --guard
```
- 0:00: hands off. In a second Terminal window, run `caffeinate -i`.
- 4:00: press Ctrl-C in that window to stop it. Stay hands off.

**Expected:** 0:00 to 4:00 `guard: staying awake … blockers=['caffeinate']` and no sleep. After 4:00 `guard OK … sleeping` within 1 to 2 cycles.

## Read the logs
From `~/wake3-loop.log`, `pmset -g log` and the VM `poll.log`:
- Guard decision per cycle and the idle value used.
- `Sleep` / `Wake` / `DarkWake` events and their reasons while away.
- Ping delay (VM `DELIVER … delay=`), pings delivered.
- Did the Mac ever sleep while you were using it? Did the display flash on wakes while away?

## Pass / fail
- **Pass:** no sleep in any cycle while idle < 60 s or a blocker is present; once away, the Mac reaches `Sleep` in at least 90% of cycles within 3 cycles of the guard allowing it; worst-case ping delay 35 s or less; at least 11 of 12 pings delivered.
- **Fail A (unsafe):** the Mac sleeps while you are using it or while `caffeinate` is running.
- **Fail B (never sleeps):** the guard keeps reporting idle < 60 s while you are away, meaning the scheduled wake resets `HIDIdleTime`. Then use a different activity signal (for example lock state or display-off time).
- **Fail C (slow):** it sleeps, but the wake-to-poll delay goes past 60 s.

## After (if G1 and G2 pass)
Repeat G1 on battery, then the overnight loop-on vs loop-off battery comparison. Update the spec: rule 1 of the helper becomes "sleep only when the user is idle and nothing else holds the Mac awake", and the battery section gets real numbers.
