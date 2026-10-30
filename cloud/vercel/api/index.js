// Vercel entry point: one function for every route (fewer functions, free-plan friendly). Needs UPSTASH_REDIS_REST_URL / _TOKEN
// (or the KV_REST_API_URL / _TOKEN names the Vercel Marketplace integration sets) and ADMIN_TOKEN.
import { handle } from '../lib/service.js';

const url = process.env.UPSTASH_REDIS_REST_URL || process.env.KV_REST_API_URL;
const token = process.env.UPSTASH_REDIS_REST_TOKEN || process.env.KV_REST_API_TOKEN;
const store = {
  async pipe(cmds) {
    const r = await fetch(url + '/pipeline', { method: 'POST', headers: { Authorization: 'Bearer ' + token },
      body: JSON.stringify(cmds.map((c) => c.map(String))) });
    return (await r.json()).map((x) => { if (x.error) throw new Error(x.error); return x.result; });
  },
};
export default { fetch: (request) => handle(request, process.env, store) };
