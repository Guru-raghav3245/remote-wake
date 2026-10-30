# Remote Wake Mac agent v1. Runs as root under launchd (see install.sh).
# Each cycle: check in -> ack and hold awake for any wake request -> schedule its own next wake -> sleep only if the user is idle.
# usage: wakeagent.py [--dry-run] [--max-cycles N]     config: /usr/local/etc/wakeagent.json {"url": ..., "token": ...}
# --dry-run: no pmset, no caffeinate, no sleeping; logs what it would do (works without root).
import json, os, re, subprocess, sys, time, urllib.request

CONF = os.environ.get('WAKEAGENT_CONF', '/usr/local/etc/wakeagent.json')
LOG = os.environ.get('WAKEAGENT_LOG', '/var/log/wakeagent.log')
DRY = '--dry-run' in sys.argv
MAX_CYCLES = int(sys.argv[sys.argv.index('--max-cycles') + 1]) if '--max-cycles' in sys.argv else None
IDLE_S = 60            # user must be idle this long before the agent sleeps the Mac
BACKOFF_CAP = 300
conf = json.load(open(CONF))
awake = None           # caffeinate process held for a wake request (killed by its own timeout)

def log(*a):
    with open(LOG, 'a') as f:
        f.write('%s %s\n' % (time.strftime('%Y-%m-%d %H:%M:%S'), ' '.join(str(x) for x in a)))

def api(path, body):
    req = urllib.request.Request(conf['url'] + path, data=json.dumps(body).encode(),
                                 headers={'Authorization': 'Bearer ' + conf['token'], 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())

def power():
    out = subprocess.run(['pmset', '-g', 'batt'], capture_output=True, text=True).stdout
    m = re.search(r'(\d+)%', out)
    return ('ac' if 'AC Power' in out else 'battery'), (int(m.group(1)) if m else None)

def idle_s():          # seconds since the last real keyboard/trackpad event; scheduled wakes do not reset it
    out = subprocess.run(['ioreg', '-c', 'IOHIDSystem'], capture_output=True, text=True).stdout
    m = re.search(r'"HIDIdleTime" = (\d+)', out)
    return int(m.group(1)) / 1e9 if m else 0

def blockers():        # processes other than powerd holding the Mac awake (includes our own caffeinate)
    out = subprocess.run(['pmset', '-g', 'assertions'], capture_output=True, text=True).stdout
    return sorted(set(m.group(1) for m in re.finditer(
        r'pid \d+\((\w[^)]*)\).*?(?:PreventUserIdleSystemSleep|PreventSystemSleep)', out) if m.group(1) != 'powerd'))

def hold_awake(seconds):
    global awake
    if DRY:
        return log('dry-run: would hold the Mac awake for', seconds, 's')
    if awake is None or awake.poll() is not None:     # one assertion at a time; it releases itself after `seconds`
        awake = subprocess.Popen(['caffeinate', '-i', '-t', str(seconds)])

def schedule_wake(target):
    when = time.strftime('%m/%d/%y %H:%M:%S', time.localtime(target))
    if DRY:
        return log('dry-run: would schedule wake for', when)
    subprocess.run(['pmset', 'schedule', 'wake', when])    # only adds our own entry; never cancels anyone else's

def guarded_sleep(target, interval):
    # re-check every 2 s until just before the next wake: short holds (audio etc.) may clear
    while time.time() < target - 5:
        idle, held = idle_s(), blockers()
        if idle >= IDLE_S and not held:
            if DRY:
                log('dry-run: would sleep, idle=%.0fs' % idle)
                break
            log('sleeping, idle=%.0fs' % idle)
            subprocess.run(['pmset', 'sleepnow'])
            break          # sleepnow returns before the Mac is asleep; wait for the wake below instead of starting another cycle
        time.sleep(2)
    else:
        log('staying awake, idle=%.0fs blockers=%s' % (idle_s(), blockers()))
    time.sleep(min(max(0, target - time.time()), interval + 5))   # cap protects against clock jumps

log('start dry=%s' % DRY)
fails, cycles, interval = 0, 0, 30
while MAX_CYCLES is None or cycles < MAX_CYCLES:
    cycles += 1
    try:
        p, batt = power()
        for attempt in range(1, 9):                   # the network may take a few seconds after a wake
            try:
                r = api('/checkin', {'power': p, 'battery': batt})
                break
            except Exception as e:
                if attempt == 8:
                    raise
                time.sleep(1)
        fails, interval = 0, r['interval_s']
        for rid in r['requests']:
            api('/ack', {'id': rid})
            hold_awake(r['awake_s'])
            api('/online', {'id': rid})
            log('wake request', rid, 'acked, online')
    except Exception as e:
        fails += 1
        interval = min(BACKOFF_CAP, interval * 2 ** min(fails, 4))      # back off; do not hammer the network
        log('checkin failed (%d)' % fails, repr(e), 'next in', interval, 's')
    target = int(time.time()) + interval
    schedule_wake(target)
    guarded_sleep(target, interval)
log('done')
