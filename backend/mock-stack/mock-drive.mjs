// SPECTRE Capture — local fake of the Google Drive v3 REST surface used by the
// deposit backend, with fault injection. Implements the resumable-upload
// protocol (308 / Range / Content-Range), file metadata with md5/sha256
// checksums, appProperties queries, and owner-token authorisation.
// NOT a full Drive emulator: only the behaviour SPECTRE depends on.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

const GRANULARITY = 256 * 1024;

export class MockDrive {
  constructor({ baseUrl, ownerToken, dataDir }) {
    this.baseUrl = baseUrl;
    this.ownerToken = ownerToken;
    this.dataDir = dataDir || fs.mkdtempSync(path.join(os.tmpdir(), 'spectre-mockdrive-'));
    this.reset();
  }

  reset() {
    this.sessions = new Map();
    this.files = new Map();
    this.faults = {};
    this.requests = [];
    this.folderId = 'fld_' + crypto.randomBytes(8).toString('hex');
    this.files.set(this.folderId, { id: this.folderId, name: 'SPECTRE_DEPOT_TEST', mimeType: 'application/vnd.google-apps.folder', parents: [], appProperties: {} });
  }

  setFaults(f) { this.faults = { ...f }; }

  authorized(headers) {
    const h = Object.fromEntries(Object.entries(headers || {}).map(([k, v]) => [k.toLowerCase(), v]));
    return h.authorization === 'Bearer ' + this.ownerToken && !this.faults.ownerTokenExpired;
  }

  json(status, obj, headers = {}) { return { status, headers: { 'Content-Type': 'application/json', ...headers }, text: JSON.stringify(obj) }; }
  err(status, reason) { return this.json(status, { error: { code: status, message: reason, errors: [{ reason }] } }); }

  fileView(f, fields) {
    const all = {
      kind: 'drive#file', id: f.id, name: f.name, mimeType: f.mimeType, parents: f.parents,
      appProperties: f.appProperties, trashed: !!f.trashed,
      size: f.size !== undefined ? String(f.size) : undefined,
      md5Checksum: f.md5, sha256Checksum: f.sha256,
    };
    const g = this.faults.getFault;
    if (g === 'sizeWrong' && all.size) all.size = String(Number(all.size) - 1);
    if (g === 'sha256Wrong' && all.sha256Checksum) all.sha256Checksum = 'f'.repeat(64);
    if (g === 'md5Wrong' && all.md5Checksum) all.md5Checksum = '0'.repeat(32);
    if (g === 'sha256Absent') delete all.sha256Checksum;
    if (!fields) return { kind: all.kind, id: all.id, name: all.name, mimeType: all.mimeType };
    const want = fields.replace(/^files\(|\)$/g, '').split(',').map((s) => s.trim());
    const out = {};
    for (const k of want) if (all[k] !== undefined) out[k] = all[k];
    return out;
  }

  // ---------------- metadata operations (called synchronously by the GAS runtime and over HTTP)
  handleSync({ method, url, headers, body }) {
    const u = new URL(url);
    this.requests.push({ method, path: u.pathname, auth: this.authorized(headers) });
    if (this.faults.driveDown) return this.err(503, 'backendError');

    // Initiate resumable session
    if (method === 'POST' && u.pathname === '/upload/drive/v3/files' && u.searchParams.get('uploadType') === 'resumable') {
      if (!this.authorized(headers)) return this.err(401, 'authError');
      if (this.faults.storageQuotaExceeded) return this.err(403, 'storageQuotaExceeded');
      const h = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
      const meta = JSON.parse(body || '{}');
      const id = crypto.randomBytes(16).toString('hex');
      const file = path.join(this.dataDir, 'sess-' + id);
      fs.writeFileSync(file, '');
      this.sessions.set(id, {
        id, meta, declared: Number(h['x-upload-content-length']), mime: h['x-upload-content-type'],
        file, received: 0, sha: crypto.createHash('sha256'), md5: crypto.createHash('md5'),
        fields: u.searchParams.get('fields'), done: null, drops: [...(this.faults.dropAtFractions || [])],
      });
      return { status: 200, headers: { Location: `${this.baseUrl}/upload/drive/v3/files?uploadType=resumable&upload_id=${id}` }, text: '' };
    }

    // Create folder (spectreSetup)
    if (method === 'POST' && u.pathname === '/drive/v3/files') {
      if (!this.authorized(headers)) return this.err(401, 'authError');
      const meta = JSON.parse(body || '{}');
      const id = 'fld_' + crypto.randomBytes(8).toString('hex');
      this.files.set(id, { id, name: meta.name, mimeType: meta.mimeType, parents: [], appProperties: {} });
      return this.json(200, { id });
    }

    // List (owner only)
    if (method === 'GET' && u.pathname === '/drive/v3/files') {
      if (!this.authorized(headers)) return this.err(401, 'authError');
      const q = u.searchParams.get('q') || '';
      const m = q.match(/appProperties has \{ key='spectreUploadId' and value='([^']+)' \}/);
      let list = [...this.files.values()].filter((f) => f.mimeType !== 'application/vnd.google-apps.folder');
      if (m) list = list.filter((f) => f.appProperties?.spectreUploadId === m[1]);
      if (/trashed = false/.test(q)) list = list.filter((f) => !f.trashed);
      if (this.faults.getFault === 'missing') list = [];
      return this.json(200, { files: list.map((f) => this.fileView(f, u.searchParams.get('fields'))) });
    }

    const fm = u.pathname.match(/^\/drive\/v3\/files\/([^/]+)$/);
    if (fm) {
      if (!this.authorized(headers)) return this.err(401, 'authError');
      const f = this.files.get(decodeURIComponent(fm[1]));
      if (!f || (this.faults.getFault === 'missing' && method === 'GET')) return this.err(404, 'notFound');
      if (method === 'GET') {
        if (u.searchParams.get('alt') === 'media') return { status: 200, headers: {}, text: '', file: f.path };
        return this.json(200, this.fileView(f, u.searchParams.get('fields')));
      }
      if (method === 'PATCH') {
        const meta = JSON.parse(body || '{}');
        f.appProperties = { ...f.appProperties, ...(meta.appProperties || {}) };
        return this.json(200, { id: f.id });
      }
      if (method === 'DELETE') { this.files.delete(f.id); return { status: 204, headers: {}, text: '' }; }
    }
    return this.err(404, 'notFound');
  }

  // ---------------- byte upload over HTTP (async, streaming)
  // Returns true if handled.
  async handleUpload(req, res) {
    const u = new URL(req.url, this.baseUrl);
    if (!(u.pathname === '/upload/drive/v3/files' && req.method === 'PUT' && u.searchParams.get('upload_id'))) return false;
    const s = this.sessions.get(u.searchParams.get('upload_id'));
    this.requests.push({ method: 'PUT', path: '/upload(session)', auth: this.authorized(req.headers) });
    const send = (status, headers, body = '') => { res.writeHead(status, headers); res.end(body); };
    if (!s || this.faults.expireSessions) { req.resume(); send(404, { 'Content-Type': 'text/plain' }, 'Not Found'); return true; }
    if (this.faults.chunk503 > 0) { this.faults.chunk503--; req.resume(); send(503, {}, 'backendError'); return true; }
    const range = req.headers['content-range'] || '';
    const rangeHeader = () => (s.received > 0 ? { Range: `bytes=0-${s.received - 1}` } : {});
    if (s.done) { req.resume(); send(200, { 'Content-Type': 'application/json' }, JSON.stringify(this.fileView(s.done, s.fields))); return true; }

    let m = range.match(/^bytes \*\/(\d+)$/);
    if (m) { req.resume(); send(308, rangeHeader()); return true; }
    m = range.match(/^bytes (\d+)-(\d+)\/(\d+)$/);
    if (!m) { req.resume(); send(400, {}, 'bad Content-Range'); return true; }
    const [start, end, total] = [Number(m[1]), Number(m[2]), Number(m[3])];
    if (total !== s.declared || end >= total || start > end) { req.resume(); send(400, {}, 'range/declared mismatch'); return true; }
    if (start !== s.received) { req.resume(); send(308, rangeHeader()); return true; }   // client must resync

    const fd = fs.openSync(s.file, 'r+');
    let pos = start;
    let aborted = false;
    const dropAt = s.drops.length ? Math.floor(s.drops[0] * total) : null;
    await new Promise((resolve) => {
      req.on('data', (chunk) => {
        if (aborted) return;
        let c = chunk;
        if (dropAt !== null && pos < dropAt && pos + c.length >= dropAt) {
          c = c.subarray(0, dropAt - pos);
          aborted = true;
        }
        if (c.length) { fs.writeSync(fd, c, 0, c.length, pos); pos += c.length; }
        if (aborted) {
          s.drops.shift();
          req.socket.destroy();     // simulated network cut
          resolve();
        }
      });
      req.on('end', resolve);
      req.on('close', resolve);
      req.on('error', resolve);
    });
    // Durable bytes: on a cut, Drive keeps a granularity-aligned prefix.
    let durable = pos;
    if (aborted || pos !== end + 1) durable = Math.max(s.received, Math.floor(pos / GRANULARITY) * GRANULARITY);
    if (durable > s.received) {
      const buf = Buffer.alloc(durable - s.received);
      fs.readSync(fd, buf, 0, buf.length, s.received);
      s.sha.update(buf); s.md5.update(buf);
      s.received = durable;
    }
    fs.closeSync(fd);
    if (aborted) return true;
    if (s.received === s.declared) {
      fs.truncateSync(s.file, s.declared);
      const id = 'f' + crypto.randomBytes(14).toString('base64url').replace(/[^A-Za-z0-9]/g, 'x');
      const file = {
        id, name: s.meta.name, mimeType: s.mime, parents: s.meta.parents || [], appProperties: s.meta.appProperties || {},
        size: s.declared, md5: s.md5.digest('hex'), sha256: s.sha.digest('hex'), path: s.file,
      };
      this.files.set(id, file);
      s.done = file;
      send(200, { 'Content-Type': 'application/json' }, JSON.stringify(this.fileView(file, s.fields)));
    } else {
      send(308, rangeHeader());
    }
    return true;
  }
}
