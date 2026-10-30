// Remote Wake cloud service v1 on Cloudflare Workers + D1 (free plan). Wake request queue with ack, resend, expiry.
// Mac routes (token role "mac"): POST /checkin /ack /online. Phone routes (role "phone"): POST /wake, GET /request/<id>, GET /device.
// Admin (ADMIN_TOKEN secret): POST /admin/add-device {name}, POST /admin/set-interval {device, interval_s}.
// Auth is a per-device bearer token for now; QR pairing and signed requests are MVP step 4.
const RATE_PER_MIN = 10, AWAKE_S = 600, AC_S = 30, BATT_S = 60, PAUSED_S = 900, LOW_BATT = 20;
const enc = new TextEncoder();
const json = (o, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json' } });
const hex = (b) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, '0')).join('');
const rand = (n) => hex(crypto.getRandomValues(new Uint8Array(n)));
const sha256 = async (s) => hex(await crypto.subtle.digest('SHA-256', enc.encode(s)));
const same = (a, b) => a.length === b.length && crypto.subtle.timingSafeEqual(enc.encode(a), enc.encode(b));
const now = () => Date.now() / 1000;

function intervalFor(power, battery, override) {
  if (override) return [override, false];
  if (power === 'ac') return [AC_S, false];
  if (battery !== null && battery < LOW_BATT) return [PAUSED_S, true];
  return [BATT_S, false];
}

async function deviceInfo(db, did) {
  const d = await db.prepare('select last_checkin, power, battery, interval_s from devices where id=?').bind(did).first();
  const [iv, paused] = intervalFor(d.power, d.battery, d.interval_s);
  return { last_checkin: d.last_checkin, power: d.power, battery: d.battery, interval_s: iv, paused,
           no_recent_checkin: d.last_checkin === null || now() - d.last_checkin > 3 * iv + 10 };
}

const getRequest = (db, did, rid) =>
  db.prepare('select id, state, created, expires, acked_at, online_at from requests where id=? and device_id=?').bind(rid, did).first();

const audit = (db, did, event, detail = '') => db.prepare('insert into audit values (?,?,?,?)').bind(now(), did, event, detail).run();

async function auth(request, env) {
  const h = request.headers.get('authorization') || '';
  if (!h.startsWith('Bearer ')) return null;
  const t = h.slice(7), did = t.split('.')[0];
  const row = await env.DB.prepare('select mac_hash, phone_hash from devices where id=?').bind(did).first();
  if (!row) return null;
  const d = await sha256(t);
  if (same(d, row.mac_hash)) return { did, role: 'mac' };
  if (same(d, row.phone_hash)) return { did, role: 'phone' };
  return null;
}

async function admin(request, env, path, body) {
  const h = request.headers.get('authorization') || '';
  if (!env.ADMIN_TOKEN || !same(h, 'Bearer ' + env.ADMIN_TOKEN)) return json({ error: 'unauthorized' }, 401);
  if (path === '/admin/add-device') {
    const did = rand(4), mac = rand(24), phone = rand(24);
    await env.DB.prepare('insert into devices(id,name,mac_hash,phone_hash) values (?,?,?,?)')
      .bind(did, String(body.name || ''), await sha256(`${did}.${mac}`), await sha256(`${did}.${phone}`)).run();
    return json({ device: did, mac_token: `${did}.${mac}`, phone_token: `${did}.${phone}` });
  }
  if (path === '/admin/set-interval') {
    await env.DB.prepare('update devices set interval_s=? where id=?').bind(body.interval_s || null, String(body.device)).run();
    return json({ ok: true });
  }
  return json({ error: 'not found' }, 404);
}

async function route(method, path, did, role, body, env) {
  const db = env.DB, t = now(), expiry = Number(env.EXPIRY_S || 600);
  await db.prepare("update requests set state='expired' where state in ('waiting','acked') and expires<?").bind(t).run();
  await db.prepare('delete from requests where created<?').bind(t - 7 * 86400).run();   // keep the free 5 GB tiny

  if (method === 'POST' && path === '/checkin' && role === 'mac') {
    const power = body.power === 'ac' ? 'ac' : 'battery';
    const batt = Number.isInteger(body.battery) ? body.battery : null;
    await db.prepare('update devices set last_checkin=?, power=?, battery=? where id=?').bind(t, power, batt, did).run();
    const ov = (await db.prepare('select interval_s from devices where id=?').bind(did).first()).interval_s;
    const [iv, paused] = intervalFor(power, batt, ov);
    const ids = (await db.prepare("select id from requests where device_id=? and state='waiting' order by created").bind(did).all()).results.map((r) => r.id);
    return json({ requests: ids, interval_s: iv, paused, awake_s: AWAKE_S });
  }
  if (method === 'POST' && (path === '/ack' || path === '/online') && role === 'mac') {
    const r = await getRequest(db, did, String(body.id || ''));
    if (!r) return json({ error: 'unknown request' }, 404);
    if (r.state === 'expired') return json({ state: 'expired' });
    const want = path === '/ack' ? 'acked' : 'online';
    if (want === 'online' || r.state === 'waiting') {                  // idempotent: repeats change nothing
      await db.prepare('update requests set state=?, acked_at=coalesce(acked_at,?), online_at=? where id=?')
        .bind(want, t, want === 'online' ? t : null, r.id).run();
      await audit(db, did, want, r.id);
    }
    return json({ state: (await getRequest(db, did, r.id)).state });
  }
  if (method === 'POST' && path === '/wake' && role === 'phone') {
    const n = (await db.prepare('select count(*) as n from requests where device_id=? and created>?').bind(did, t - 60).first()).n;
    if (n >= RATE_PER_MIN) return json({ error: 'rate limited' }, 429);
    const rid = rand(8);
    await db.prepare("insert into requests values (?,?,?,?,'waiting',null,null)").bind(rid, did, t, t + expiry).run();
    await audit(db, did, 'wake', rid);
    return json({ id: rid, state: 'waiting', device: await deviceInfo(db, did) });
  }
  if (method === 'GET' && path.startsWith('/request/') && role === 'phone') {
    const r = await getRequest(db, did, path.slice(9));
    return r ? json({ ...r, device: await deviceInfo(db, did) }) : json({ error: 'unknown request' }, 404);
  }
  if (method === 'GET' && path === '/device' && role === 'phone') return json(await deviceInfo(db, did));
  return json({ error: 'not found' }, 404);
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname, method = request.method;
    let body = {};
    if (method === 'POST') {
      const text = await request.text();
      if (text.length > 4096) return json({ error: 'too large' }, 413);
      try { body = text ? JSON.parse(text) : {}; } catch { return json({ error: 'bad json' }, 400); }
    }
    if (path.startsWith('/admin/')) return admin(request, env, path, body);
    const a = await auth(request, env);
    if (!a) return json({ error: 'unauthorized' }, 401);
    return route(method, path, a.did, a.role, body, env);
  },
};
