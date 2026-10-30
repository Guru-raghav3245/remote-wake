// Local server for tests: the real service logic on an in-memory store. `npm run dev`, then python3 ../../tests/test_protocol.py
import http from 'node:http';
import { handle } from './lib/service.js';
import { fakeStore } from './lib/fake.js';
const store = fakeStore();
http.createServer(async (req, res) => {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const r = await handle(new Request('http://local' + req.url, { method: req.method, headers: req.headers,
    body: req.method === 'GET' ? undefined : Buffer.concat(chunks) }), process.env, store);
  res.writeHead(r.status, { 'content-type': 'application/json' });
  res.end(await r.text());
}).listen(9100, () => console.log('listening on 9100'));
