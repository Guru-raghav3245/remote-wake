// Remote Wake cloud service v1 for Vercel Functions (Hobby, free) + Upstash Redis (free). Wake request queue with ack, resend, expiry.
// Mac routes (token role "mac"): POST /checkin /ack /online. Phone routes (role "phone"): POST /wake, GET /request/<id>, GET /device.
// Public (no token, per-IP rate limited): POST /register {name} -> Mac token + one-time pairing code; POST /pair {code} -> phone token.
// Mac also: POST /pair-code (new code), GET /device. Admin (ADMIN_TOKEN env): POST /admin/add-device {name}, POST /admin/set-interval {device, interval_s}.
// Auth is a per-device bearer token. Pairing is a device-code flow (no accounts): the Mac registers itself and shows a code, the phone enters it.
// Open registration is capped by MAX_DEVICES (default 5) so strangers cannot burn the free-tier quota. Signed requests are still to do.
// Free-tier budget: Upstash bills every command, and a Lua EVAL bills 1 + one per redis.call, so scripts do not help. Instead a check-in
// costs 1 read (auth + settings + pending flag) and writes only every HEARTBEAT_S or when power/battery change: about 1.5 commands on average
// at 30 s = about 130K of the 500K monthly commands (3 to 4 Macs). The pending list is read only while a wake request is open (device field pending_until).
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';

const HEARTBEAT_S = 60, RATE_PER_MIN = 10, AWAKE_S = 600, AC_S = 30, BATT_S = 60, PAUSED_S = 900, LOW_BATT = 20, KEEP_S = 7 * 86400;
const json = (o, status = 200) => Response.json(o, { status });
const rand = (n) => randomBytes(n).toString('hex');
const sha256 = (s) => createHash('sha256').update(s).digest('hex');
const same = (a, b) => typeof a === 'string' && typeof b === 'string' && a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b));
const num = (v) => (v === null || v === undefined || v === '' ? null : Number(v));
const obj = (flat) => { const o = {}; for (let i = 0; i < (flat || []).length; i += 2) o[flat[i]] = flat[i + 1]; return o; };
const DEVICE_FIELDS = ['mac_hash', 'phone_hash', 'interval_s', 'last_checkin', 'power', 'battery', 'pair_code', 'pending_until'];
const CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789', CODE_TTL_S = 900;           // 32 chars (no 0/O/1/I): 8 chars = 40 bits
const newCode = () => [...randomBytes(8)].map((b) => CODE_CHARS[b % 32]).join('');   // 256 % 32 == 0, so no modulo bias
const showCode = (c) => c.slice(0, 4) + '-' + c.slice(4);

function intervalFor(power, battery, override) {
  if (override) return [override, false];
  if (power === 'ac') return [AC_S, false];
  if (battery !== null && battery < LOW_BATT) return [PAUSED_S, true];
  return [BATT_S, false];
}

function deviceInfo(d, now) {
  const [iv, paused] = intervalFor(d.power, d.battery, d.interval_s);
  return { last_checkin: d.last_checkin, power: d.power, battery: d.battery, interval_s: iv, paused,
           no_recent_checkin: d.last_checkin === null || now - d.last_checkin > Math.max(3 * iv + 10, 2 * HEARTBEAT_S) };   // last_checkin is only written every HEARTBEAT_S
}

// Requests expire lazily: no cleanup writes, the state is derived when read.
function requestView(h, now) {
  if (!h.state) return null;
  const expires = Number(h.expires);
  const state = (h.state === 'waiting' || h.state === 'acked') && now > expires ? 'expired' : h.state;
  return { id: h.id, state, created: Number(h.created), expires, acked_at: num(h.acked_at), online_at: num(h.online_at) };
}

const auditCmds = (did, event, detail) => [['LPUSH', `audit:${did}`, JSON.stringify([Date.now() / 1000, event, detail])], ['LTRIM', `audit:${did}`, 0, 99]];

async function admin(request, env, store, path, body) {
  if (!env.ADMIN_TOKEN || !same(request.headers.get('authorization'), 'Bearer ' + env.ADMIN_TOKEN)) return json({ error: 'unauthorized' }, 401);
  if (path === '/admin/add-device') {
    const did = rand(4), mac = rand(24), phone = rand(24);
    await store.pipe([['HSET', `device:${did}`, 'name', String(body.name || ''), 'mac_hash', sha256(`${did}.${mac}`), 'phone_hash', sha256(`${did}.${phone}`)]]);
    return json({ device: did, mac_token: `${did}.${mac}`, phone_token: `${did}.${phone}` });
  }
  if (path === '/admin/set-interval' && /^[0-9a-f]{8}$/.test(String(body.device))) {
    await store.pipe([['HSET', `device:${body.device}`, 'interval_s', Number(body.interval_s) || 0]]);
    return json({ ok: true });
  }
  return json({ error: 'not found' }, 404);
}

// Public routes. Per-IP counters keep strangers from registering in bulk or guessing codes.
async function limited(store, key, max, ttl) {
  const [n] = await store.pipe([['INCR', key], ['EXPIRE', key, ttl, 'NX']]);
  return n > max;
}

async function newPairCode(store, did, oldCode, now) {
  const code = newCode();
  await store.pipe([...(oldCode ? [['DEL', `pair:${oldCode}`]] : []), ['SET', `pair:${code}`, `${did}|${now + CODE_TTL_S}`, 'EX', CODE_TTL_S], ['HSET', `device:${did}`, 'pair_code', code]]);
  return { code: showCode(code), code_expires_in: CODE_TTL_S };
}

async function publicRoute(request, env, store, path, body) {
  const ip = (request.headers.get('x-forwarded-for') || 'local').split(',')[0].trim(), now = Date.now() / 1000;
  if (path === '/register') {
    if (await limited(store, `rl:reg:${ip}`, Number(env.REG_PER_HOUR || 5), 3600)) return json({ error: 'too many registrations, try later' }, 429);
    const [n] = await store.pipe([['INCR', 'devices:count']]);
    if (n > Number(env.MAX_DEVICES || 5)) { await store.pipe([['DECR', 'devices:count']]); return json({ error: 'service is full' }, 503); }
    const did = rand(4), mac = rand(24);
    await store.pipe([['HSET', `device:${did}`, 'name', String(body.name || '').slice(0, 60), 'mac_hash', sha256(`${did}.${mac}`)]]);
    return json({ device: did, mac_token: `${did}.${mac}`, ...(await newPairCode(store, did, null, now)) });
  }
  if (path === '/pair') {
    if (await limited(store, `rl:pair:${ip}`, Number(env.PAIR_PER_HOUR || 20), 3600)) return json({ error: 'too many attempts, try later' }, 429);
    const code = String(body.code || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
    if (code.length !== 8) return json({ error: 'invalid or expired code' }, 404);
    const [val] = await store.pipe([['GETDEL', `pair:${code}`]]);      // one use: the code is gone as soon as it is read
    const [did, exp] = String(val || '').split('|');
    if (!val || now > Number(exp)) return json({ error: 'invalid or expired code' }, 404);
    const phone = rand(24);
    const [, name] = await store.pipe([['HSET', `device:${did}`, 'phone_hash', sha256(`${did}.${phone}`), 'pair_code', ''], ['HGET', `device:${did}`, 'name']]);
    return json({ phone_token: `${did}.${phone}`, device: did, name });
  }
  return json({ error: 'not found' }, 404);
}

export async function handle(request, env, store) {
  const url = new URL(request.url), method = request.method;
  const p = url.searchParams.get('_p');                       // set by the vercel.json rewrite; falls back to the real path
  const path = p !== null ? '/' + p : url.pathname.replace(/^\/api(?=\/|$)/, '') || '/';
  let body = {};
  if (method === 'POST') {
    const text = await request.text();
    if (text.length > 4096) return json({ error: 'too large' }, 413);
    try { body = text ? JSON.parse(text) : {}; } catch { return json({ error: 'bad json' }, 400); }
  }
  if (path.startsWith('/admin/')) return admin(request, env, store, path, body);
  if (method === 'POST' && (path === '/register' || path === '/pair')) return publicRoute(request, env, store, path, body);

  const h = request.headers.get('authorization') || '';
  const tok = h.startsWith('Bearer ') ? h.slice(7) : '', did = tok.split('.')[0];
  if (!/^[0-9a-f]{8}$/.test(did)) return json({ error: 'unauthorized' }, 401);
  const [vals] = await store.pipe([['HMGET', `device:${did}`, ...DEVICE_FIELDS]]);
  const dev = Object.fromEntries(DEVICE_FIELDS.map((f, i) => [f, vals[i]]));
  const digest = sha256(tok);
  const role = same(digest, dev.mac_hash) ? 'mac' : same(digest, dev.phone_hash) ? 'phone' : null;
  if (!role) return json({ error: 'unauthorized' }, 401);
  Object.assign(dev, { interval_s: num(dev.interval_s), last_checkin: num(dev.last_checkin), battery: num(dev.battery) });

  const now = Date.now() / 1000, expiry = Number(env.EXPIRY_S || 600);
  if (method === 'POST' && path === '/checkin' && role === 'mac') {
    const power = body.power === 'ac' ? 'ac' : 'battery', batt = Number.isInteger(body.battery) ? body.battery : null;
    const cmds = [];
    if (dev.last_checkin === null || now - dev.last_checkin >= HEARTBEAT_S || power !== dev.power || batt !== dev.battery)
      cmds.push(['HSET', `device:${did}`, 'last_checkin', now, 'power', power, 'battery', batt === null ? '' : batt]);
    const openRequests = Number(dev.pending_until) > now;                 // only unexpired, unacked requests: the same id comes back until acked
    if (openRequests) cmds.push(['ZRANGEBYSCORE', `pending:${did}`, `(${now}`, '+inf']);
    const res = cmds.length ? await store.pipe(cmds) : [];
    const ids = openRequests ? res[res.length - 1] : [];
    const [iv, paused] = intervalFor(power, batt, dev.interval_s);
    return json({ requests: ids, interval_s: iv, paused, awake_s: AWAKE_S });
  }
  if (method === 'POST' && (path === '/ack' || path === '/online') && role === 'mac') {
    const rid = String(body.id || '');
    if (!/^[0-9a-f]{16}$/.test(rid)) return json({ error: 'unknown request' }, 404);
    const [flat] = await store.pipe([['HGETALL', `req:${rid}`]]);
    const raw = obj(flat);
    if (raw.device !== did) return json({ error: 'unknown request' }, 404);
    const r = requestView({ ...raw, id: rid }, now);
    if (r.state === 'expired') return json({ state: 'expired' });
    if (path === '/ack' && r.state !== 'waiting') return json({ state: r.state });          // idempotent: repeats change nothing
    const set = path === '/ack' ? ['state', 'acked', 'acked_at', now] : ['state', 'online', 'online_at', now, ...(r.acked_at ? [] : ['acked_at', now])];
    await store.pipe([['HSET', `req:${rid}`, ...set], ['ZREM', `pending:${did}`, rid], ...auditCmds(did, path.slice(1), rid)]);
    return json({ state: path === '/ack' ? 'acked' : 'online' });
  }
  if (method === 'POST' && path === '/wake' && role === 'phone') {
    const [, n] = await store.pipe([['ZREMRANGEBYSCORE', `rate:${did}`, '-inf', now - 60], ['ZCARD', `rate:${did}`]]);
    if (n >= RATE_PER_MIN) return json({ error: 'rate limited' }, 429);
    const rid = rand(8);
    await store.pipe([
      ['HSET', `req:${rid}`, 'device', did, 'state', 'waiting', 'created', now, 'expires', now + expiry], ['HSET', `device:${did}`, 'pending_until', now + expiry],
      ['EXPIRE', `req:${rid}`, KEEP_S], ['ZADD', `pending:${did}`, now + expiry, rid], ['ZREMRANGEBYSCORE', `pending:${did}`, '-inf', now],
      ['ZADD', `rate:${did}`, now, rid], ['EXPIRE', `rate:${did}`, 120], ...auditCmds(did, 'wake', rid)]);
    return json({ id: rid, state: 'waiting', device: deviceInfo(dev, now) });
  }
  if (method === 'GET' && path.startsWith('/request/') && role === 'phone') {
    const rid = path.slice(9);
    if (!/^[0-9a-f]{16}$/.test(rid)) return json({ error: 'unknown request' }, 404);
    const raw = obj((await store.pipe([['HGETALL', `req:${rid}`]]))[0]);
    return raw.device === did ? json({ ...requestView({ ...raw, id: rid }, now), device: deviceInfo(dev, now) }) : json({ error: 'unknown request' }, 404);
  }
  if (method === 'POST' && path === '/pair-code' && role === 'mac') return json(await newPairCode(store, did, dev.pair_code, now));
  if (method === 'GET' && path === '/device') return json({ ...deviceInfo(dev, now), paired: !!dev.phone_hash });
  return json({ error: 'not found' }, 404);
}
