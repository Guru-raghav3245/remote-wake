# Remote Wake cloud service v1: wake request queue with ack, resend and expiry. stdlib only.
# usage: python3 cloud/server.py serve [port=9100] [host=127.0.0.1] [db=wake.db]
#        python3 cloud/server.py add-device <name> [db=wake.db]   (prints the mac and phone tokens once)
# Auth is a per-device bearer token for now; QR pairing and signed requests are MVP step 4.
import hashlib, hmac, json, secrets, sqlite3, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EXPIRY_S = 600          # a wake request is dropped if the Mac has not confirmed by then
RATE_PER_MIN = 10       # wake requests per device
AWAKE_S = 600           # how long the Mac stays awake after a request
AC_S, BATT_S, PAUSED_S, LOW_BATT = 30, 60, 900, 20

db, lock = None, threading.Lock()

def init(path):
    global db
    db = sqlite3.connect(path, check_same_thread=False)
    db.executescript('''
        create table if not exists devices(id text primary key, name text, mac_hash text, phone_hash text,
            last_checkin real, power text, battery int, interval_s int);
        create table if not exists requests(id text primary key, device_id text, created real, expires real,
            state text, acked_at real, online_at real);
        create table if not exists audit(ts real, device_id text, event text, detail text);''')

def q(sql, *a):
    with lock:
        rows = db.execute(sql, a).fetchall()
        db.commit()
        return rows

def audit(did, event, detail=''):
    q('insert into audit values (?,?,?,?)', time.time(), did, event, detail)

def add_device(name):
    did, mac, phone = secrets.token_hex(4), secrets.token_urlsafe(24), secrets.token_urlsafe(24)
    toks = ['%s.%s' % (did, mac), '%s.%s' % (did, phone)]
    q('insert into devices(id,name,mac_hash,phone_hash) values (?,?,?,?)', did, name,
      *[hashlib.sha256(t.encode()).hexdigest() for t in toks])
    return did, toks[0], toks[1]

def auth(headers):
    h = headers.get('Authorization', '')
    if not h.startswith('Bearer '):
        return None
    tok = h[7:]
    rows = q('select id, mac_hash, phone_hash from devices where id=?', tok.partition('.')[0])
    if not rows:
        return None
    digest = hashlib.sha256(tok.encode()).hexdigest()
    for role, want in (('mac', rows[0][1]), ('phone', rows[0][2])):
        if hmac.compare_digest(digest, want):
            return rows[0][0], role
    return None

def interval_for(power, battery, override):
    if override:
        return override, False
    if power == 'ac':
        return AC_S, False
    if battery is not None and battery < LOW_BATT:
        return PAUSED_S, True
    return BATT_S, False

def expire():
    q("update requests set state='expired' where state in ('waiting','acked') and expires<?", time.time())

def request_row(did, rid):
    rows = q('select id, state, created, expires, acked_at, online_at from requests where id=? and device_id=?', rid, did)
    return None if not rows else dict(zip(('id', 'state', 'created', 'expires', 'acked_at', 'online_at'), rows[0]))

def device_info(did):
    last, power, batt, ov = q('select last_checkin, power, battery, interval_s from devices where id=?', did)[0]
    iv, paused = interval_for(power, batt, ov)
    return {'last_checkin': last, 'power': power, 'battery': batt, 'interval_s': iv, 'paused': paused,
            'no_recent_checkin': last is None or time.time() - last > 3 * iv + 10}

def route(method, path, did, role, body):
    """Returns (status, json). Mac routes need role 'mac', phone routes 'phone'."""
    now = time.time()
    expire()
    if method == 'POST' and path == '/checkin' and role == 'mac':
        power = 'ac' if body.get('power') == 'ac' else 'battery'
        batt = body.get('battery') if isinstance(body.get('battery'), int) else None
        q('update devices set last_checkin=?, power=?, battery=? where id=?', now, power, batt, did)
        ov = q('select interval_s from devices where id=?', did)[0][0]
        iv, paused = interval_for(power, batt, ov)
        ids = [r[0] for r in q("select id from requests where device_id=? and state='waiting' order by created", did)]
        return 200, {'requests': ids, 'interval_s': iv, 'paused': paused, 'awake_s': AWAKE_S}
    if method == 'POST' and path in ('/ack', '/online') and role == 'mac':
        r = request_row(did, str(body.get('id', '')))
        if not r:
            return 404, {'error': 'unknown request'}
        if r['state'] == 'expired':
            return 200, {'state': 'expired'}
        want = 'acked' if path == '/ack' else 'online'
        if want == 'online' or r['state'] == 'waiting':          # idempotent: repeats change nothing
            q('update requests set state=?, acked_at=coalesce(acked_at,?), online_at=? where id=?',
              want, now, now if want == 'online' else None, r['id'])
            audit(did, want, r['id'])
        return 200, {'state': request_row(did, r['id'])['state']}
    if method == 'POST' and path == '/wake' and role == 'phone':
        if q('select count(*) from requests where device_id=? and created>?', did, now - 60)[0][0] >= RATE_PER_MIN:
            return 429, {'error': 'rate limited'}
        rid = secrets.token_hex(8)
        q("insert into requests values (?,?,?,?,'waiting',null,null)", rid, did, now, now + EXPIRY_S)
        audit(did, 'wake', rid)
        return 200, {'id': rid, 'state': 'waiting', 'device': device_info(did)}
    if method == 'GET' and path.startswith('/request/') and role == 'phone':
        r = request_row(did, path[9:])
        return (200, dict(r, device=device_info(did))) if r else (404, {'error': 'unknown request'})
    if method == 'GET' and path == '/device' and role == 'phone':
        return 200, device_info(did)
    return 404, {'error': 'not found'}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        a = auth(self.headers)
        if not a:
            return self.reply(401, {'error': 'unauthorized'})
        n = int(self.headers.get('Content-Length') or 0)
        if n > 4096:
            return self.reply(413, {'error': 'too large'})
        try:
            body = json.loads(self.rfile.read(n) or b'{}') if method == 'POST' else {}
        except ValueError:
            return self.reply(400, {'error': 'bad json'})
        self.reply(*route(method, self.path.split('?')[0], a[0], a[1], body))

    def do_GET(self):
        self.handle_any('GET')

    def do_POST(self):
        self.handle_any('POST')

def make_server(path, host='127.0.0.1', port=9100):
    init(path)
    return ThreadingHTTPServer((host, port), H)

if __name__ == '__main__':
    a = sys.argv[1:]
    if a[:1] == ['serve']:
        port, host, path = int(a[1]) if len(a) > 1 else 9100, a[2] if len(a) > 2 else '127.0.0.1', a[3] if len(a) > 3 else 'wake.db'
        print('serving on %s:%d' % (host, port), flush=True)
        make_server(path, host, port).serve_forever()
    elif a[:1] == ['add-device'] and len(a) > 1:
        init(a[2] if len(a) > 2 else 'wake.db')
        did, mac, phone = add_device(a[1])
        print('device', did, '\nmac token  ', mac, '\nphone token', phone)
    else:
        sys.exit(__doc__)
