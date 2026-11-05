# Test 2: Does an inbound packet wake a sleeping Mac?

Part of the Remote Wake for Mac feasibility gate.

**Goal:** see whether data sent from a server down a connection the Mac opened earlier can wake the Mac from sleep, and whether code on the Mac can answer within a few seconds.

## Why this is worth a test

The LidGuard project (adipascu/LidGuard on GitHub) is a menu bar app that fights battery drain on Apple Silicon. Its readme says packets from remote peers show up as wake events on a sleeping Mac. If that's true, a Mac with a long-lived connection to your server could be woken by the server sending it a message. That would be close to instant.

But the evidence is one readme. Treat this as a hypothesis, and expect it might only work on some chips, macOS versions, or networks. It's also a known battery-drain source, so we'll measure that too.

## The idea

1. The Mac opens a long-lived TCP connection to a server you control.
2. The Mac goes to full sleep.
3. The server sends a small message down that connection.
4. If the network hardware wakes the Mac for it, the client reads the message and replies with an ack.
5. The server logs how long the ack took.

## Things that can fool you

- **Sleep proxies.** An Apple TV, HomePod, or AirPort on your network can answer for a sleeping Mac. Write down whether you have one. If you can, unplug it for the main runs.
- **Router NAT timeout.** If your router forgets the connection while the Mac sleeps, the packet gets dropped. Vary the sleep time to find where that happens.
- **Power Nap.** It wakes the Mac on its own timer, which muddies everything. Turn it off for the main runs with `sudo pmset -a powernap 0`, and do one control run with it on.
- **Keep-awake tools.** Don't use caffeinate, Amphetamine, or anything that holds a power assertion. Then you're not testing sleep.
- **Settings.** Save the output of `pmset -g` at the start of every session.

## Setup

You need a server with a public IP and one open port (the code below uses 9000). A cheap cloud VM is fine. This is a throwaway test, but the shared token in the code keeps random scanners out.

### server.py (runs on the server)

Press Enter in its terminal to send a ping.

```python
import socket, time, threading, sys

TOKEN = 'change-me-long-random-string'
conn = None

def stamp():
    return time.strftime('%H:%M:%S')

def read_loop(f):
    for line in f:
        print(stamp(), 'got:', line.strip(), flush=True)
    print(stamp(), 'client disconnected', flush=True)

def accept_loop(srv):
    global conn
    while True:
        c, addr = srv.accept()
        c.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        f = c.makefile()
        first = f.readline().strip()
        if first != 'hello ' + TOKEN:
            c.close()
            continue
        conn = c
        print(stamp(), 'client connected', addr, flush=True)
        threading.Thread(target=read_loop, args=(f,), daemon=True).start()

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('0.0.0.0', 9000))
srv.listen(1)
threading.Thread(target=accept_loop, args=(srv,), daemon=True).start()

print('Press Enter to send a ping. Ctrl-C to quit.')
n = 0
for _ in sys.stdin:
    if conn:
        n += 1
        t = time.time()
        conn.sendall(('ping %d %s\n' % (n, t)).encode())
        print(stamp(), 'SENT ping', n, 'at', t, flush=True)
    else:
        print('no client connected')
```

### client.py (runs on the Mac)

```python
import socket, time, os

HOST = 'YOUR.SERVER.IP'
PORT = 9000
TOKEN = 'change-me-long-random-string'
LOG = os.path.expanduser('~/wake2-client.log')

def log(msg):
    with open(LOG, 'a') as f:
        f.write('%.3f %s\n' % (time.time(), msg))

def run():
    s = socket.create_connection((HOST, PORT))
    s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    f = s.makefile()
    s.sendall(('hello ' + TOKEN + '\n').encode())
    log('connected')
    for line in f:
        log('received: ' + line.strip())
        s.sendall(('ack ' + line.split()[1] + ' ' + str(time.time()) + '\n').encode())
    log('connection closed by server')

while True:
    try:
        run()
    except Exception as e:
        log('error: ' + repr(e))
    time.sleep(5)
```

Run it in Terminal with `python3 client.py` and leave it running. If python3 isn't installed, macOS will offer to install the command line tools.

## Running one trial

1. Start the server. Start the client on the Mac. Confirm the server prints "client connected".
2. On the Mac, run `sudo pmset -a powernap 0`. Save `pmset -g` output.
3. Put the Mac to full sleep with `pmset sleepnow`, or close the lid if that's the row you're testing.
4. Wait for the delay of this trial. Vary it: 1, 5, 15, 30, 60 minutes.
5. On the server, press Enter once. Watch the terminal for 60 seconds for an "ack" line.
6. Whatever happens, wake the Mac by hand afterward and run:

```bash
pmset -g log | grep -E 'Sleep  |Wake  |DarkWake' | tail -30
cat ~/wake2-client.log
```

7. In the pmset log, find the wake closest to your ping. Write down the reason after "due to". Look for reasons that mention network, Wi-Fi, or packets. The LidGuard readme mentions one called E\_RX\_IP\_PACKET, but exact strings vary by macOS version.
8. Fill in the results table.

## Test matrix

Run each row at least 5 times, then 20 times for any row that looks promising.

| # | Network | Power | Lid | Power Nap | Notes |
| --- | --- | --- | --- | --- | --- |
| 1 | Wi-Fi | AC | Open | Off | Baseline |
| 2 | Wi-Fi | AC | Closed | Off |  |
| 3 | Wi-Fi | Battery | Closed | Off | Most realistic laptop case |
| 4 | Ethernet | AC | Open or closed | Off | Needs a desktop Mac or a dongle |
| 5 | Wi-Fi | AC | Closed | On | Control. Does Power Nap change the result? |
| 6 | Wi-Fi | AC | Closed | Off | **No-ping control.** Send nothing and see if and when the Mac wakes anyway |

Also repeat your best row on a second network, such as a different Wi-Fi, so you aren't testing one router's quirks.

## Results table

| Trial | Row | Slept for | Ping sent | Ack received | Delay (seconds) | Wake reason (pmset) | Connection still alive? | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 |  |  |  |  |  |  |  |  |

## How to read the results

| What you see | What it means |
| --- | --- |
| Ack in under 10 seconds, wake reason is network-related | Packet wake works. Repeat 20 times, then do the battery check |
| Ping only arrives at the next timer wake | Not packet-driven. It's just the timer |
| Connection dies after N minutes of sleep | Router NAT timeout. N is your limit unless the Mac can refresh the connection |
| Mac wakes but never sends the ack | The wake is too short, or your process didn't get CPU time. Note how long the wake lasted |
| Mac wakes over and over with no pings | Drain problem. Count wakes with `pmset -g stats` |

## Pass or fail

**Pass:** in at least 19 of 20 trials on a row, the ack comes back within 60 seconds and the wake reason points to the network, not a timer. Under 10 seconds is the real goal.

**Conditional pass:** works only on some rows, like ethernet on AC, or only up to a certain sleep length. That can still be a product with clear limits.

**Fail:** pings only arrive on timer wakes, or the connection dies when the Mac sleeps.

## Battery drain check (only if it passes)

1. Charge to the same level two nights in a row.
2. Night 1: client running, lid closed, on battery, no pings.
3. Night 2: client not running, same setup.
4. Each morning run `pmset -g batt` and `pmset -g stats`. Compare the percent lost and the dark wake counts.

If night 1 drains far more, packet wake may be AC-only.

## If it fails

Fallbacks, using what you learned in Test 1:

- On AC, schedule the Mac's own wakes every 30 to 60 seconds, and check your server on each one.
- On battery, check your server on the dark wakes macOS already does.

## Time

About an hour to set up, since the code is above. Then a day or two of trials, mostly waiting.

## Limits of this test

- The idea rests on one readme. It may only hold on some chips or macOS versions.
- Home routers and ISPs behave very differently. One network's result doesn't carry over to the next.
- A Python script in Terminal isn't the final shape. A real version would be a background service, and that may behave differently during a dark wake.
