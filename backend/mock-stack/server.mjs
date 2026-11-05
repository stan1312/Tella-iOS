// SPECTRE Capture — local mock stack for fast reproducible tests.
//   * /macros/s/MOCK/exec : the REAL Apps Script code (doPost/doGet) in a vm
//   * /upload/…, /drive/v3/… : MockDrive
//   * /__control, /__admin/*, /__owner/* : test-only control plane (owner simulation)
// Binds to 127.0.0.1 only. Never use with real data.
import http from 'node:http';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { MockDrive } from './mock-drive.mjs';
import { createGasRuntime } from './gas-runtime.mjs';

export async function startMockStack({ port = 0, redirectLikeAppsScript = true } = {}) {
  const ownerToken = 'ya29.FAKE-OWNER-TOKEN-' + crypto.randomBytes(12).toString('hex');
  let clockOffset = 0;
  const clock = () => Date.now() + clockOffset;
  const server = http.createServer();
  await new Promise((r) => server.listen(port, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const drive = new MockDrive({ baseUrl: base, ownerToken });
  let gas;
  const webAppUrl = `${base}/macros/s/MOCK/exec`;
  const newGas = () => {
    gas = createGasRuntime({ drive, ownerToken: () => ownerToken, clock, webAppUrl });
    gas.configure({ folderId: drive.folderId, apiBase: base });
  };
  newGas();
  const echoes = new Map();
  let backendFaults = {};

  const readBody = (req) => new Promise((resolve) => {
    const parts = []; req.on('data', (c) => parts.push(c)); req.on('end', () => resolve(Buffer.concat(parts).toString('utf8')));
  });
  const json = (res, status, obj, headers = {}) => { res.writeHead(status, { 'Content-Type': 'application/json', ...headers }); res.end(JSON.stringify(obj)); };

  server.on('request', async (req, res) => {
    try {
      if (Date.now() < drive.offlineUntil && !req.url.startsWith('/__')) { req.socket.destroy(); return; }
      const u = new URL(req.url, base);
      if (await drive.handleUpload(req, res)) return;

      if (u.pathname === '/macros/s/MOCK/exec') {
        if (backendFaults.unavailable > 0) { backendFaults.unavailable--; req.resume(); res.writeHead(503); res.end('<html>Service unavailable</html>'); return; }
        if (req.method === 'GET') return json(res, 200, gas.doGet());
        if (req.method !== 'POST') { res.writeHead(405); res.end(); return; }
        const out = gas.doPost(await readBody(req));
        if (redirectLikeAppsScript) {
          // Apps Script answers POST /exec with 302 to script.googleusercontent.com/macros/echo
          const k = crypto.randomBytes(8).toString('hex');
          echoes.set(k, out);
          res.writeHead(302, { Location: `${base}/macros/echo?user_content_key=${k}` }); res.end(); return;
        }
        return json(res, 200, out);
      }
      if (u.pathname === '/macros/echo' && req.method === 'GET') {
        const k = u.searchParams.get('user_content_key');
        const out = echoes.get(k); echoes.delete(k);
        return out ? json(res, 200, out) : json(res, 404, {});
      }

      // ---------- test control plane (simulates the owner / the network)
      if (u.pathname === '/__control' && req.method === 'POST') {
        const c = JSON.parse((await readBody(req)) || '{}');
        if (c.reset) { drive.reset(); newGas(); backendFaults = {}; clockOffset = 0; }
        if (c.driveFaults) drive.setFaults(c.driveFaults);
        if (c.backendFaults) backendFaults = { ...c.backendFaults };
        if (c.policy) Object.assign(gas.policy(), c.policy);
        if (typeof c.advanceClockSec === 'number') clockOffset += c.advanceClockSec * 1000;
        return json(res, 200, { ok: true });
      }
      if (u.pathname === '/__admin/invite') return json(res, 200, gas.createInvite(u.searchParams.get('label') || 'membre-test'));
      if (u.pathname === '/__admin/revoke') return json(res, 200, { ok: gas.revoke(u.searchParams.get('deviceId')) });
      if (u.pathname === '/__admin/devices') return json(res, 200, gas.listDevices());
      if (u.pathname === '/__admin/logs') return json(res, 200, { logs: gas.logs, props: [...gas.props.keys()] });
      if (u.pathname === '/__owner/content') {
        const f = drive.files.get(u.searchParams.get('id'));
        if (!f || !f.path) return json(res, 404, {});
        res.writeHead(200, { 'Content-Type': 'application/octet-stream' }); fs.createReadStream(f.path).pipe(res); return;
      }
      if (u.pathname === '/__owner/files') {
        const files = [...drive.files.values()].filter((f) => f.path).map((f) => ({ id: f.id, name: f.name, size: f.size, sha256: f.sha256, md5: f.md5, parents: f.parents, appProperties: f.appProperties }));
        return json(res, 200, { files, sessions: drive.sessions.size, requests: drive.requests.length, dropsDone: drive.dropsDone });
      }

      // ---------- anything else is the Drive REST surface (metadata) over HTTP
      const body = req.method === 'GET' || req.method === 'DELETE' ? '' : await readBody(req);
      const r = drive.handleSync({ method: req.method, url: `${base}${req.url}`, headers: req.headers, body });
      if (r.file) { res.writeHead(200, { 'Content-Type': 'application/octet-stream' }); fs.createReadStream(r.file).pipe(res); return; }
      res.writeHead(r.status, r.headers); res.end(r.text);
    } catch (e) {
      res.writeHead(500); res.end('mock error');
    }
  });

  const cleanup = () => { try { fs.rmSync(drive.dataDir, { recursive: true, force: true }); } catch {} };
  process.once('exit', cleanup);
  return { base, webAppUrl, drive, get gas() { return gas; }, ownerToken,
    close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(() => { cleanup(); r(); }); }) };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.argv.find((a) => a.startsWith('--port='))?.split('=')[1] || 0);
  const redirect = !process.argv.includes('--no-redirect');
  const s = await startMockStack({ port, redirectLikeAppsScript: redirect });
  console.log(`MOCK_STACK_READY ${s.base}`);
  process.stdin.on('end', () => process.exit(0));   // dies with the parent test process
  process.on('SIGTERM', () => process.exit(0));
  process.stdin.resume();
}
