# Test 1: Can APNs wake a sleeping Mac?

Part of the Remote Wake for Mac feasibility gate.

**Goal:** find out, on your own Mac, whether an Apple push notification can wake a fully asleep Mac and get your code running.

Be honest going in. Apple's DTS engineer said in a June 2026 developer forum thread ("Can APNs wake a sleeping Mac for a third-party app?") that this won't work in a way that's reliably tied to the push. We run the test anyway, so we see it on real hardware and get real numbers.

## What we're testing

1. Does a push wake the Mac at all? Or does it just sit in the queue until the Mac wakes for some other reason?
2. If the Mac wakes, does our code actually run during that wake?
3. How long is it from send to code running?

## The trap to avoid

Power Nap wakes the Mac on its own timer. So if a push shows up 7 minutes after you sent it, the push didn't wake anything. The timer did, and the push was just riding along.

To tell the difference, run lots of trials with random delays between going to sleep and sending.

- Latency looks random, anywhere from 0 to about 15 minutes: that's the timer.
- Latency is a few seconds every time: the push did it.

## Setup

You need:

- An Apple Developer Program account.
- The Mac under test. Write down the model, chip, and macOS version.
- A second computer or a cheap cloud box to send the pushes from. The Mac under test will be asleep, so it can't send them.

### Steps

1. In the developer portal, create an App ID (for example com.yourname.wakeprobe) with the Push Notifications capability. Create an APNs auth key (.p8). Note the Key ID and Team ID.
2. Build a tiny **AppKit** macOS app. Use AppKit on purpose, not Catalyst. Apple said AppKit apps get their events blocked during dark wake, and we want to see that for ourselves.
   - Call `NSApplication.shared.registerForRemoteNotifications()` and print the device token.
   - Implement `application(_:didReceiveRemoteNotification:)`. It should append a line with the current time and the payload's `sentAt` value to `~/wake1-app.log`.
   - Ask for notification permission with `UNUserNotificationCenter`.
3. Add a **Notification Service Extension** target. When it runs, it appends the current time to a log file in a shared app group folder. Apple said this is the one piece that might run early, so we test it.
4. Run the app once, copy the device token, and leave the app running in the background.
5. Save this as `send.sh` on the sender machine:

```bash
#!/bin/bash
# usage: ./send.sh background   or   ./send.sh alert
TOKEN="<device token>"
TOPIC="com.yourname.wakeprobe"
JWT="<signed ES256 JWT, iss=TeamID, kid=KeyID, max 1 hour old>"
NOW=$(date +%s)
EXP=$((NOW + 3600))

if [ "$1" = "alert" ]; then
  TYPE=alert; PRIO=10
  BODY=$(printf '{"aps":{"alert":{"title":"probe","body":"wake test"},"mutable-content":1},"sentAt":%s}' "$NOW")
else
  TYPE=background; PRIO=5
  BODY=$(printf '{"aps":{"content-available":1},"sentAt":%s}' "$NOW")
fi

echo "SENT $NOW $1" >> send-log.txt

curl -s -o /dev/null -w "%{http_code}\n" --http2 \
  -H "authorization: bearer $JWT" \
  -H "apns-topic: $TOPIC" \
  -H "apns-push-type: $TYPE" \
  -H "apns-priority: $PRIO" \
  -H "apns-expiration: $EXP" \
  -d "$BODY" \
  https://api.sandbox.push.apple.com/3/device/$TOKEN
```

Notes on the script:

- Use the sandbox host for a development-signed app. Switch to api.push.apple.com for a production-signed one.
- `apns-expiration` is a UNIX timestamp. Setting it in the future tells APNs to hold the push. If you set 0, APNs drops it when the Mac isn't reachable, and the test is useless.
- You should see `200` printed. That only means APNs accepted it. It says nothing about the Mac waking.

## Running one trial

1. Make sure the app is running and the machine is set up for the row you're testing (see the matrix below).
2. Put the Mac to full sleep with `pmset sleepnow`, or Apple menu > Sleep, or close the lid.
3. Don't touch it. Don't move the mouse.
4. Wait the delay for this trial.
5. On the sender, run `./send.sh alert` or `./send.sh background`.
6. Wait 2 minutes. Watch for any sign the Mac woke. Then wake it by hand.
7. Collect the logs (next section) and fill in the results table.

## Reading what happened

After you wake the Mac by hand:

```bash
pmset -g log | grep -E 'Sleep  |Wake  |DarkWake' | tail -40
pmset -g stats
log show --last 30m --info --predicate 'process == "apsd"'
cat ~/wake1-app.log
```

In the pmset log, each wake line has a reason after "due to". Write down the time and the reason. The exact log text changes between macOS versions, so read it by eye the first time.

Also read the app log, the Notification Service Extension log, and `send-log.txt` from the sender.

## Test matrix

Run each row at least 5 times. Change the sleep-before-send delay each time: 1, 3, 7, 12, 20 minutes. That spread is what exposes the timer.

| # | Power | Lid | Power Nap | Push type | Notes |
| --- | --- | --- | --- | --- | --- |
| 1 | AC | Open | On | background, priority 5 | Baseline |
| 2 | AC | Open | On | alert, priority 10, with extension | Does the extension run early? |
| 3 | AC | Closed | On | alert, priority 10 | Most realistic desktop-style case |
| 4 | Battery | Open | On | alert, priority 10 |  |
| 5 | Battery | Closed | On | alert, priority 10 | Most realistic laptop case |
| 6 | AC | Closed | Off | alert, priority 10 | Control. The push should NOT arrive until you wake it by hand |

Turn Power Nap on or off with `sudo pmset -a powernap 1` or `sudo pmset -a powernap 0`. Make sure "Wake for network access" is on for rows 1 to 5.

If you have a USB ethernet dongle, repeat row 3 on ethernet.

## Results table

Copy this and fill one line per trial.

| Trial | Row | Delay before send | Send time | Mac woke (pmset) | Wake reason | App log time | Extension log time | Send to code (seconds) | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 |  |  |  |  |  |  |  |  |  |

## How to read the results

| What you see | What it means |
| --- | --- |
| Mac wakes within about 10 seconds of the send, the reason isn't a timer, and the code runs | The push woke it. Big surprise. Repeat 20 times to be sure |
| Latency is spread randomly from 0 to about 15 minutes | That's the Power Nap timer. APNs is just a slow mailbox |
| Nothing arrives until you wake the Mac by hand | Matches Apple's answer |
| Mac wakes, but the code only logs after a full wake | The dark wake blocked event delivery, as Apple described |
| The extension logs but the app doesn't | Extension runs early, but it can't run your main app |

## Pass or fail

**Pass:** in at least 19 of 20 trials on rows 3 and 5, the app or the extension logged within 60 seconds of the send, while the Mac was asleep.

**Fail:** anything less. Expect this.

## If it fails

Move on to Test 2 (inbound packet wake).

Keep the dark wake timestamps from this test. They show how often Power Nap wakes your particular Mac, and that matters for the fallback plan of checking your server on wakes macOS already does.

## Time

About half a day to build. Then a day or two of trials, mostly waiting.

## Limits of this test

- It's based on one Apple engineer's forum answer plus one developer's own tests. macOS may behave differently on your version.
- Results from one Mac don't prove anything about other models.
- The test only tells us whether the push can be the wake trigger. It doesn't cover other ways to run code during a wake.
