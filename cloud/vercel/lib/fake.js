// In-memory stand-in for the Upstash REST pipeline, covering only the commands service.js uses. For local tests.
export function fakeStore() {
  const db = new Map();                                        // key -> Map (hash) | Array of [score, member] (zset) | Array (list)
  const bound = (v, up) => (v === '-inf' ? -Infinity : v === '+inf' ? Infinity : String(v).startsWith('(') ? Number(String(v).slice(1)) + (up ? -1e-9 : 1e-9) : Number(v));
  const cmds = {
    HSET: (k, ...a) => { const h = db.get(k) || new Map(); let n = 0; for (let i = 0; i < a.length; i += 2) { n += h.has(a[i]) ? 0 : 1; h.set(a[i], String(a[i + 1])); } db.set(k, h); return n; },
    HMGET: (k, ...f) => f.map((x) => db.get(k)?.get(x) ?? null),
    HGETALL: (k) => [...(db.get(k) || new Map())].flat(),
    ZADD: (k, s, m) => { const z = (db.get(k) || []).filter((e) => e[1] !== m); z.push([Number(s), m]); db.set(k, z); return 1; },
    ZREM: (k, m) => { const z = db.get(k) || []; db.set(k, z.filter((e) => e[1] !== m)); return 1; },
    ZRANGEBYSCORE: (k, lo, hi) => (db.get(k) || []).filter((e) => e[0] >= bound(lo) && e[0] <= bound(hi, true)).sort((a, b) => a[0] - b[0]).map((e) => e[1]),
    ZREMRANGEBYSCORE: (k, lo, hi) => { const z = db.get(k) || []; db.set(k, z.filter((e) => !(e[0] >= bound(lo) && e[0] <= bound(hi, true)))); return 1; },
    ZCARD: (k) => (db.get(k) || []).length,
    LPUSH: (k, v) => { const l = db.get(k) || []; l.unshift(v); db.set(k, l); return l.length; },
    LTRIM: (k, a, b) => { db.set(k, (db.get(k) || []).slice(a, b + 1)); return 'OK'; },
    HGET: (k, f) => db.get(k)?.get(f) ?? null,
    GET: (k) => db.get(k) ?? null,
    SET: (k, v) => { db.set(k, String(v)); return 'OK'; },
    GETDEL: (k) => { const v = db.get(k) ?? null; db.delete(k); return v; },
    DEL: (k) => (db.delete(k) ? 1 : 0),
    INCR: (k) => { const n = Number(db.get(k) || 0) + 1; db.set(k, String(n)); return n; },
    DECR: (k) => { const n = Number(db.get(k) || 0) - 1; db.set(k, String(n)); return n; },
    EXPIRE: () => 1,
  };
  return { async pipe(list) { return list.map(([c, ...a]) => cmds[c](...a.map((x) => (typeof x === 'number' && !Number.isInteger(x) ? x : x)))); } };
}
