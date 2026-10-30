# Protocol tests for the cloud service (section 8 of the spec). Run against a local `wrangler dev`:
#   cd cloud/worker && npx wrangler d1 execute remote-wake --local --file=schema.sql
#   npx wrangler dev --local --port 9100 --var ADMIN_TOKEN:testadmin --var EXPIRY_S:3
#   (Vercel version: cd cloud/vercel && REG_PER_HOUR=1000 PAIR_PER_HOUR=1000 MAX_DEVICES=1000 ADMIN_TOKEN=testadmin npm run dev)
#   python3 tests/test_protocol.py            (BASE=http://127.0.0.1:9100 ADMIN=testadmin by default)
import json, os, time, unittest, urllib.error, urllib.request

BASE = os.environ.get('BASE', 'http://127.0.0.1:9100')
ADMIN = os.environ.get('ADMIN', 'testadmin')

def call(method, path, token, body=None):
    req = urllib.request.Request(BASE + path, method=method, data=json.dumps(body or {}).encode() if method == 'POST' else None,
                                 headers={'Authorization': 'Bearer ' + token})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b'{}')

class Pairing(unittest.TestCase):                                               # needs the server's default MAX_DEVICES/REG_PER_HOUR raised (see header)
    def test_register_pair_once(self):
        s, d = call('POST', '/register', '', {'name': 'mac'})
        self.assertEqual(s, 200)
        self.assertEqual(call('GET', '/device', d['mac_token'])[1]['paired'], False)
        s, p = call('POST', '/pair', '', {'code': d['code'].lower()})           # case and the dash do not matter
        self.assertEqual((s, p['device'], p['name']), (200, d['device'], 'mac'))
        self.assertEqual(call('POST', '/pair', '', {'code': d['code']})[0], 404)   # single use
        self.assertEqual(call('POST', '/pair', '', {'code': 'AAAA-AAAA'})[0], 404)
        self.assertEqual(call('GET', '/device', d['mac_token'])[1]['paired'], True)
        self.assertEqual(call('POST', '/wake', p['phone_token'])[0], 200)          # the paired phone can wake this Mac
        self.assertEqual(call('POST', '/checkin', p['phone_token'])[0], 404)

    def test_new_code_replaces_old(self):
        _, d = call('POST', '/register', '', {'name': 'mac'})
        _, n = call('POST', '/pair-code', d['mac_token'])
        self.assertNotEqual(n['code'], d['code'])
        self.assertEqual(call('POST', '/pair', '', {'code': d['code']})[0], 404)   # old code is dead
        self.assertEqual(call('POST', '/pair', '', {'code': n['code']})[0], 200)
        self.assertEqual(call('POST', '/pair-code', 'bad')[0], 401)

class Protocol(unittest.TestCase):
    def setUp(self):
        _, d = call('POST', '/admin/add-device', ADMIN, {'name': 'test'})
        self.did, self.mac, self.phone = d['device'], d['mac_token'], d['phone_token']

    def wake(self):
        return call('POST', '/wake', self.phone)[1]['id']

    def test_auth(self):
        self.assertEqual(call('POST', '/checkin', 'nope')[0], 401)
        self.assertEqual(call('POST', '/checkin', self.phone)[0], 404)          # phone token cannot use mac routes
        self.assertEqual(call('POST', '/wake', self.mac)[0], 404)               # mac token cannot create wakes
        self.assertEqual(call('POST', '/admin/add-device', 'wrong')[0], 401)
        self.assertEqual(call('POST', '/checkin', self.did + '.bad')[0], 401)

    def test_resend_until_ack_then_online(self):
        rid = self.wake()
        for _ in range(3):                                                       # no ack: the same id comes back every time
            self.assertEqual(call('POST', '/checkin', self.mac, {'power': 'ac', 'battery': 90})[1]['requests'], [rid])
        self.assertEqual(call('POST', '/ack', self.mac, {'id': rid})[1]['state'], 'acked')
        self.assertEqual(call('POST', '/ack', self.mac, {'id': rid})[1]['state'], 'acked')   # idempotent
        self.assertEqual(call('POST', '/checkin', self.mac, {'power': 'ac'})[1]['requests'], [])
        self.assertEqual(call('POST', '/online', self.mac, {'id': rid})[1]['state'], 'online')
        self.assertEqual(call('POST', '/ack', self.mac, {'id': rid})[1]['state'], 'online')   # late duplicate does not go backwards
        self.assertEqual(call('GET', '/request/' + rid, self.phone)[1]['state'], 'online')

    def test_expiry(self):                                                       # server started with EXPIRY_S:3
        rid = self.wake()
        time.sleep(4)
        self.assertEqual(call('POST', '/checkin', self.mac, {'power': 'ac'})[1]['requests'], [])
        self.assertEqual(call('GET', '/request/' + rid, self.phone)[1]['state'], 'expired')
        self.assertEqual(call('POST', '/ack', self.mac, {'id': rid})[1]['state'], 'expired')

    def test_intervals(self):
        iv = lambda b: call('POST', '/checkin', self.mac, b)[1]
        self.assertEqual((iv({'power': 'ac'})['interval_s'], iv({'power': 'ac'})['paused']), (30, False))
        self.assertEqual(iv({'power': 'battery', 'battery': 80})['interval_s'], 60)
        low = iv({'power': 'battery', 'battery': 15})
        self.assertEqual((low['interval_s'], low['paused']), (900, True))

    def test_rate_limit_and_isolation(self):
        for _ in range(10):
            self.assertEqual(call('POST', '/wake', self.phone)[0], 200)
        self.assertEqual(call('POST', '/wake', self.phone)[0], 429)
        _, other = call('POST', '/admin/add-device', ADMIN, {'name': 'other'})
        rid = call('POST', '/wake', other['phone_token'])[1]['id']               # another device's request is invisible to this one
        self.assertEqual(call('GET', '/request/' + rid, self.phone)[0], 404)
        self.assertEqual(call('POST', '/ack', self.mac, {'id': rid})[0], 404)

    def test_status_for_phone(self):
        self.assertTrue(call('GET', '/device', self.phone)[1]['no_recent_checkin'])
        call('POST', '/checkin', self.mac, {'power': 'ac', 'battery': 99})
        d = call('GET', '/device', self.phone)[1]
        self.assertFalse(d['no_recent_checkin'])
        self.assertEqual((d['power'], d['battery']), ('ac', 99))

if __name__ == '__main__':
    unittest.main(verbosity=2)
