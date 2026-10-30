# Remote Wake for Mac: feasibility results

Run 27-28 Oct 2026 on one Mac (MacBook Pro `Mac17,9`, Apple M5 Pro, macOS 26.6.2), home Wi-Fi, no Apple TV / HomePod / sleep proxy on the network. Sender: a GCP e2-micro VM (us-central1-a).

## Bottom line

Requirement used for judging: a user must never wait more than 1 minute.

| Approach | Result | Meets the 1-minute bar? |
| --- | --- | --- |
| Test 1: APNs push as the wake trigger | The push did **not** wake the Mac. It was delivered about 2 s after a manual wake. | No |
| Test 2: inbound packet on an open TCP connection | The packet did **not** wake the Mac, also with keepalive offload enabled as root. | No |
| Fallback: Mac schedules its own wakes every 30 s and polls the server | In the last three runs all 12 pings reached the server's delivery step each time (one reply was lost on the Mac in run C), worst case 29.8 / 29.6 / 30.9 s. Works on AC and battery, lid open and closed. | Yes (about 30 s worst case) |

Only the scheduled-wake fallback worked. It is a polling design, not a true push. It needs root, a resend-until-acknowledged protocol, and an overnight battery measurement before anyone should rely on it.

## Test 1: can APNs wake a sleeping Mac?

One trial run: row 1 (AC, lid open, Power Nap on, background push, 1-minute delay). Not run: rows 2 to 6, the other delays, ethernet. The mechanism below made more trials look pointless.

- Mac slept 23:21:44. Push sent 23:22:37. No wake event of any kind until a manual wake at 23:24:57. The app logged the push at 23:24:59 (142 s after it was sent).
- Root cause, from the `apsd` log: when the Mac sleeps, `apsd` tells Apple's push servers "send all messages: NO", stops its connections to `push.apple.com` / `sandbox.push.apple.com`, and schedules its own wakes 10 to 15 minutes out. On wake it sends "send all messages: YES" and the held push arrives. APNs queues pushes while the Mac sleeps, so a push cannot be the trigger.
- The Notification Service Extension never ran. macOS started it and killed it for "sluggish startup" (about 2 s). Turning off the debug-dylib stub and running the app from `~/Applications` did not fix it. Cause unresolved.
- Not needed to conclude, but unresolved: whether the extension runs "early" (row 2 of the matrix).

## Test 2: does an inbound packet wake a sleeping Mac?

Python client on the Mac, server on the VM, one long-lived TCP connection, Power Nap off, "Wake for network access" on.

- Trial 1 (plain socket): ping sent while asleep. No wake in about 8 minutes. The server's TCP stack kept retransmitting unanswered, so the Mac's network stack stayed silent for the whole sleep.
- This Mac's wake history does contain Wi-Fi-firmware wakes such as `E_TKO_TCP_DATA`, which is the chip waking the host for data on an offloaded TCP connection. The system registers such connections for its own services.
- Setting `TCP_KEEPALIVE_OFFLOAD` (0x211, from xnu `tcp_private.h`) as a normal user fails with `EPERM`. The kernel checks `PRIV_NETINET_TCP_KA_OFFLOAD`. As root it succeeds.
- Trial 2 (root client, offload flag set and confirmed): still no wake. The ping arrived 65 s after a manual wake, via a TCP retransmit.
- Limits: two trials only. I could not confirm the Wi-Fi firmware actually took over the connection. Not run: the other matrix rows, the no-ping control, ethernet (no dongle), a second network.

## Scheduled-wake fallback

Mac runs `wakeloop.py` as root: poll the VM over HTTP, `pmset schedule wake` 30 s ahead, `pmset sleepnow`, repeat for 15 minutes. The VM queues 12 pings at random 15 to 75 s gaps while the Mac sleeps. Delay = time from the ping being queued to the Mac's next poll picking it up.

| Run | Conditions | Pings delivered | Delay mean / median / max (s) | Notes |
| --- | --- | --- | --- | --- |
| A | AC, lid open | 10 of 12 | 15.3 / n/a / 25.5 | My server kept one pending message, so pings 1 and 3 were overwritten. Test bug. |
| B | AC, lid open, server fixed | 12 of 12 | 19.0 / 19.9 / 29.8 | 30 of 30 polls OK. Wakes fired 0.1 to 0.3 s after schedule. Half the cycles never fully slept (see below). |
| C | Battery, lid open | 12 of 12 server-side, 11 received | 13.8 / 10.6 / 29.6 | One poll reply was lost, so one ping was lost from the Mac's side. 27 of 29 cycles slept properly. |
| D | Battery, lid closed | 12 of 12 | 19.6 / 21.7 / 30.9 | 24 of 24 polls OK at the time I read the log; I did not see the last 6 cycles. Opened the lid at 12:08:06, after all 12 pings. |

Findings:
- On AC, `powerd` holds a sleep-preventing assertion (`com.apple.powermanagement.acwakelinger`, about 44 s) after each wake, so a 30 s loop only reaches real sleep every other cycle. The Mac sits in DarkWake (screen off, CPU and Wi-Fi on) instead. No such assertion appeared on battery. It is undocumented, and I read it only from this Mac's `pmset -g log`.
- Wi-Fi was usable within about a second of every wake, including closed-lid dark wakes.
- The worst case slightly exceeds the 30 s interval (30.9 s) because each cycle takes a little over 30 s.
- Battery use is **not measured**. Run C lost 16 mAh and run D 27 mAh, but both numbers include time with the Mac awake and in use around the run, and there is no no-loop baseline. Do not read a drain rate from them.

## Not tested / open

- The overnight battery comparison from the Test 2 doc (loop on versus off).
- Other networks and routers; any NAT or captive-portal behaviour.
- The loop as a background service rather than a Terminal script. It needs root to schedule wakes.
- Delivery guarantees: the server marks a ping delivered when it replies, so a lost reply loses the ping (seen once in run C). A real protocol needs acknowledgement and resend.
- Shorter intervals (10 to 15 s) and what they cost in battery.
- Whether the Notification Service Extension can be made to run at all.

## What was created

In this folder: `project.yml` and `WakeProbe.xcodeproj` (AppKit probe app plus extension), `WakeProbe/`, `NotificationService/`, `Config/`, `send.sh`, `trial.sh`, `collect.sh` (Test 1); `server.py`, `client.py`, `trial2.sh`, `collect2.sh` (Test 2); `poll_server.py`, `wakeloop.py`, `ping_batch.sh` (fallback); `trials.log`, `trials2.log`; `CLAUDE.md`; the APNs key `AuthKey_L72JVD5GGR.p8`.
Elsewhere: Mac logs `~/wake1-app.log`, `~/wake2-client.log`, `~/wake3-loop*.log`, `~/wake3-battery-start*.txt`; VM `~/send-log.txt`, `~/poll.log`, `~/server.log`.
Apple developer portal: App IDs `com.guru.wakeprobe` and `com.guru.wakeprobe.service`, App Group `group.com.guru.wakeprobe`, APNs key `L72JVD5GGR`, one registered device.
GCP: project `<gcp-project>`, VM `wakeprobe-sender`, firewall rules `wakeprobe-9000` and `wakeprobe-9001`.

## Still to clean up (nothing has been removed)

- Stop the root `wakeloop.py` and the suspended `sudo` job on the Mac (needs `sudo`).
- Turn Power Nap back on: `sudo pmset -a powernap 1`.
- Switch Xcode back to the personal Apple account.
- Delete the GCP project (`gcloud projects delete <gcp-project>`) and, if no longer wanted, the Apple portal key, App IDs, App Group and device.
