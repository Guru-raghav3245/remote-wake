# Product Spec: Remote Wake for Mac (v2)

**Version:** 2.0, built on the 27-28 Oct 2026 feasibility tests **Status:** Personal project, feasibility proven on one Mac, build not started **Platform:** macOS (agent) and a phone app **Replaces:** v1 (the original concept spec)

## 1. What it is

Remote Wake for Mac lets you get to a sleeping Mac from your phone, from any network, with no extra hardware and no router changes.

**The promise:** tap Wake, and within about 30 seconds your Mac is awake and reachable.

Here's the honest part. It is not instant, and it is not a true push. The Mac wakes itself every so often, asks the server if anyone wants it, and stays awake if someone does. The wait is whatever is left of that interval.

This is not a remote desktop product. It only gets the Mac awake and tells you when it's online.

## 2. What the tests changed

v1 assumed some outside event could wake a sleeping Mac. The tests say no. Here is what moved.

| v1 assumption | What we found | What it means for the product |
| --- | --- | --- |
| An Apple push (APNs) can wake the Mac | When the Mac sleeps, it tells Apple's servers to hold all messages. The push showed up about 2 seconds after a manual wake, and not before | Dropped. Push can't be the trigger |
| A packet on an open connection can wake the Mac | No wake in two trials, including with keepalive offload set as root. Not enough trials to rule it out fully | Dropped for v2. Needs root and a private kernel flag even if it worked |
| Wake should feel instant | A self-scheduled wake every 30 seconds gave a worst-case wait of about 30 seconds | The promise is 'about 30 seconds' |
| Always full sleep | On AC, macOS holds a roughly 44 second sleep-preventing assertion after each wake, so a 30 second loop reaches real sleep only about every other cycle. On battery it slept properly in 27 of 29 cycles | The product principle changes. See section 11 |
| No privileged software | Scheduling wakes needs root | The Mac agent includes a small privileged helper |

## 3. How it works

1. The Mac agent schedules its own next wake (about 30 seconds out on AC).
2. The Mac sleeps on its own, like normal.
3. The Mac wakes on schedule. Wi-Fi is usable within about a second.
4. The agent asks the cloud service whether a wake request is waiting.
5. If there is none, the agent schedules the next wake and lets the Mac go back to sleep.
6. If there is one, the agent tells the server it got it, keeps the Mac awake, and reports that the Mac is online.
7. The phone app shows each step as it happens.

The Mac only makes outbound connections. Nothing is exposed to the internet, so there's no port forwarding and no public IP needed.

## 4. Goals and non-goals

### Goals

1. Get a sleeping Mac awake and reachable from any network within about 30 seconds on AC.
2. Need no extra hardware, no router changes, and no open ports.
3. Never lose a wake request. Retry until the Mac confirms.
4. Keep the battery cost low enough that people leave it on.
5. Tell the truth about what's happening, including when it doesn't know.
6. Be secure. Only the owner can wake the Mac, and a wake gives no other access.

### Non-goals

- Instant wake.
- Waking a Mac that is shut down, out of power, or has no internet.
- Unlocking the Mac, bypassing the login screen, or bypassing FileVault.
- Remote desktop, terminal, or file access.
- Keeping the Mac awake all the time.
- Supporting hardware relays, a second computer, or a NAS.

## 5. Check-in modes

The check-in interval is the product's main dial. Short means fast wake and more battery use. Long means the opposite.

The numbers below are starting points to tune. Only the 30 second row has been tested.

| Situation | Check-in interval | Expected wait | Status |
| --- | --- | --- | --- |
| On AC | 30 seconds | up to about 30 seconds | Tested |
| On battery, default | 2 to 5 minutes | up to 2 to 5 minutes | Not tested. Starting point |
| On battery, Ready mode | 30 seconds | up to about 30 seconds | Tested. Battery cost not measured |
| Quiet hours (for example overnight) | Off or 15 minutes | long | Not tested |
| Battery under 20% | Paused | none | Design choice. The app says so |

**Ready mode** is how a user chooses speed over battery. They turn it on for a time window, like 'today until 6 pm' or 'weekdays 9 to 5'. Outside the window the agent drops to the slower battery interval.

**Boost after contact** is an idea, not a tested feature. After any wake request, the agent polls fast for 10 minutes in case a second request follows.

The phone can change these settings from anywhere. The Mac picks up the change at its next check-in, so a change takes up to one interval to apply.

## 6. Rough battery picture

This is an estimate, not a measurement.

- A 30 second interval is about 960 wake cycles in 8 hours.
- The two battery runs lost 16 mAh (15 minutes, lid open) and 27 mAh (15 minutes, lid closed). Both numbers include time the Mac was awake and in use, so they're upper bounds.
- On a battery of around 6,000 mAh (check the real pack size), that works out to roughly 1% to 1.7% per hour at 30 seconds.
- My guess for a clean number is around 1% per hour, which is roughly 8% over a night. Treat that as a guess until the overnight test is done.
- A 2 to 5 minute interval should cut the extra cost several times over, since there are far fewer wakes.

**Target (to validate):** extra battery cost of 0.3% per hour or less in the default battery mode.

## 7. Mac agent

Two parts:

- **A small privileged helper** (background service running as root). It schedules wakes and holds the power assertion. It does nothing else.
- **A normal user-level agent and menu bar app.** It handles pairing, settings, status, and diagnostics, and talks to the helper.

### Rules for the helper

1. **Never force sleep.** The test loop ran `pmset sleepnow` every cycle. The real agent only schedules the next wake and lets macOS sleep on its own, so it never puts a Mac to sleep while someone is using it.
2. **Only touch its own scheduled wakes.** Don't cancel wakes set by the user or other apps.
3. **Stay awake only when asked.** When a wake request arrives, take one power assertion for a limited time (default 10 minutes) and release it.
4. **Back off on failure.** If the server can't be reached, retry with a growing delay and a cap. Don't hammer the network.
5. **Handle clock changes** and timezone changes without losing the schedule.
6. **Keep it tiny.** No scripting, no remote commands, no config that comes from the network beyond a few validated numbers (interval, window, awake time).

Scheduling is done with `pmset schedule wake` in the tests. A production build should check whether the IOKit power event API is cleaner. That's an open question.

## 8. Wake request protocol

The test server marked a ping as delivered the moment the Mac replied, and one reply got lost. That lost a ping. The real protocol must not do this.

1. The phone sends a wake request. The server gives it an ID and a short expiry (default 10 minutes).
2. The Mac checks in. The server returns any open request IDs.
3. The Mac sends an ack for each ID.
4. The server marks it **delivered** only after the ack.
5. If no ack arrives, the server returns the same request again at the next check-in.
6. Acks and requests are idempotent. Receiving the same ID twice is harmless.
7. When the Mac is awake and responding, the agent sends **online**.
8. If the request expires first, the phone shows that it could not be confirmed.

### Statuses the phone shows

| State | What the app says |
| --- | --- |
| Request created | Sending wake request |
| Server has it | Waiting for your Mac to check in. Usually under 30 seconds |
| Mac acked | Your Mac got the request and is waking |
| Mac online | Your Mac is online |
| Expired | Wake could not be confirmed |
| No recent check-in | Your Mac hasn't checked in since 2:14 pm. It may be off, offline, or out of power |
| Paused | Checking is paused (low battery or quiet hours) |

Because we know the last check-in time and the interval, the app can say how long the wait should be. And a Mac that hasn't checked in is never labelled 'asleep'. It could be off, offline, or dead, and we can't tell.

## 9. Cloud service

Simple on purpose.

- Accounts and device registration.
- A wake request queue with expiry.
- Per-device records: last check-in time, current interval, battery state, mode.
- Ack and online tracking.
- Push notifications to the phone when the Mac comes online. (APNs works fine toward the phone, because the phone is awake.)
- Rate limiting and an audit log of wake requests.

The server never stores anything from the Mac's files or account.

## 10. Phone app

### Screens

- **Mac list and status.** Name, last check-in, last wake, current mode, Wake button.
- **Wake in progress.** The step-by-step status from section 8, with a live estimate.
- **Settings.** Ready mode windows, quiet hours, low-battery cutoff, how long the Mac stays awake.
- **Diagnostics.** Last 20 check-ins, last failure and reason, agent version, macOS version.
- **Pairing.** Scan a QR code shown by the Mac.

## 11. Product principle (changed from v1)

v1 said: keeping a Mac awake with its display off is not an acceptable substitute for waking it from full sleep.

The test results force a more precise version.

- On battery, the Mac reaches real sleep between check-ins in almost every cycle.
- On AC, macOS itself holds the Mac in dark wake for about 44 seconds after each wake (an undocumented assertion we only saw in one Mac's logs), so about half of 30 second cycles never reach full sleep.
- **The agent never adds its own keep-awake.** The only time it holds the Mac awake is for a real wake request, for a limited time.
- The app and docs say plainly that on AC the Mac may stay in a light, screen-off state between check-ins.

## 12. Security

- **Pairing needs explicit approval.** The Mac agent shows a QR code. The phone scans it. The Mac owner approves on the Mac.
- **Per-device keys.** Each phone and Mac gets its own key pair, stored in the system Keychain or Secure Enclave where possible.
- **Signed requests.** Wake requests carry a signature, a timestamp, and a nonce. Old or repeated requests are rejected.
- **Encryption everywhere.** TLS for every connection.
- **Revocable.** Remove a phone or a Mac from either side, and its keys stop working at once.
- **No open ports.** The Mac only connects out.
- **A wake gives no access.** No files, no terminal, no screen.
- **The root helper is the high-value target.** It accepts only a few validated numbers and a wake command from the local user agent. It never runs commands or code from the network.
- **Rate limits** on wake requests per device.

## 13. Targets

These are targets to validate, not claims.

| Metric | Target |
| --- | --- |
| Wake delivered to the Mac, on AC | At least 95% within 60 seconds. Worst case about 35 seconds |
| Lost requests | None. Retry until acked or expired |
| Extra battery cost, default battery mode | 0.3% per hour or less |
| Extra hardware | None |
| Router changes | None |
| Failure reporting | A clear status, with a reason where we know it |

When reporting any result, state the number of trials and the setup it was tested on.

## 14. What has been validated

**Tested once:** one MacBook Pro (Mac17,9, Apple M5 Pro, macOS 26.6.2), home Wi-Fi, no Apple TV or HomePod on the network, sender on a GCP VM.

| Run | Conditions | Result |
| --- | --- | --- |
| B | AC, lid open | 12 of 12 delivered, worst case 29.8 seconds |
| C | Battery, lid open | 12 of 12 reached the server step, 11 received by the Mac (one reply lost), worst case 29.6 seconds |
| D | Battery, lid closed | 12 of 12 delivered, worst case 30.9 seconds |

(Run A had a server bug and isn't counted.)

**Not tested, and shelved for now:**

- A second Mac or a second network. This is a personal project, so those are on hold.
- Ethernet.
- Other Mac models and macOS versions.
- Overnight battery cost, loop on vs off.
- Intervals other than 30 seconds.
- The agent as a real background service instead of a Terminal script.
- Captive portals, VPNs, and unusual routers.

If this ever goes beyond personal use, those become required before any public claim.

## 15. MVP

Build in this order. Each step has to work before the next.

1. **Overnight battery test.** Reuse the existing scripts: loop on one night, off the next, same battery start. This decides how hard to push the 30 second interval.
2. **Mac agent v1.** Privileged helper plus menu bar app. Schedules its own wakes, lets macOS sleep naturally, never forces sleep.
3. **Cloud service v1.** Device registration, wake queue, ack and resend, expiry.
4. **Pairing and signed requests.** QR pairing, per-device keys.
5. **Phone app v1.** Mac list, Wake button, live status.
6. **Interval tuning.** Try 1, 2, and 5 minutes on battery and pick defaults.
7. **Daily use for a week.** Log every wake request, every miss, and the battery impact.

Out of scope for the MVP: Ready mode windows, quiet hours, boost after contact, and diagnostics beyond a basic log. Add them once the core works.

## 16. Open questions and risks

- **Battery cost.** The biggest unknown. Numbers above are a guess.
- **Undocumented behaviour.** The 44 second assertion on AC isn't documented anywhere, and macOS updates could change it or other power behaviour.
- **Root requirement.** Scheduling wakes needs a privileged helper. That likely rules out the Mac App Store, but that needs checking before any distribution plan.
- **Scheduling API.** `pmset schedule wake` worked. Is the IOKit power event API a better fit for a real service?
- **Other wake schedules.** How does the agent coexist with the user's own scheduled wakes and with other apps?
- **Closed lid on other models.** Tested on one machine.
- **Network edge cases.** Captive portals, VPNs, Wi-Fi roaming, and flaky hotel networks can all make a check-in fail. Does the app show it clearly?
- **Phone-side limits.** The phone can only ask. It can't speed up the Mac's next check-in.
- **Overnight drift.** Does the wake schedule hold up across a night, a week, and a daylight saving change?

## 17. Cleanup from the feasibility run

Before building:

- Stop the root `wakeloop.py` job and the suspended sudo job.
- Turn Power Nap back on: `sudo pmset -a powernap 1`.
- Don't commit the APNs `.p8` key. Revoke it, since APNs won't be used toward the Mac.
- Delete the GCP test project and the Apple test App IDs, App Group, and device if they're no longer wanted.
