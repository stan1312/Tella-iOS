// Test-side re-implementation of the phone protocol (independent from Swift),
// used to exercise the backend "hors application" (mandate Phase 1).
import crypto from 'node:crypto';
import { startMockStack } from '../../mock-stack/server.mjs';

export async function stack(opts = {}) { return startMockStack({ redirectLikeAppsScript: true, ...opts }); }

export const sha256 = (b) => crypto.createHash('sha256').update(b).digest('hex');
export const md5 = (b) => crypto.createHash('md5').update(b).digest('hex');
export const hmac = (k, m) => crypto.createHmac('sha256', Buffer.from(k, 'utf8')).update(m, 'utf8').digest('hex');

export function canonicalReq(action, deviceId, ts, nonce, payload) {
  return ['spectre-req-v1', action, deviceId, String(ts), nonce, sha256(Buffer.from(payload, 'utf8'))].join('\n');
}
export function canonicalReceipt(r) {
  return ['spectre-receipt-v1', String(r.v), r.status, r.captureId, r.uploadId, r.deviceId, r.driveFileId,
    String(r.size), r.sha256, r.md5, r.checksumSource, r.verifiedAt].join('\n');
}

export async function post(s, envelope) {
  const r = await fetch(s.webAppUrl, { method: 'POST', body: JSON.stringify(envelope), headers: { 'Content-Type': 'text/plain' } });
  return r.json();   // fetch follows the Apps-Script-like 302 → GET echo
}

export function signed(creds, action, payloadObj, { ts, nonce, tamper } = {}) {
  const payload = JSON.stringify(payloadObj);
  ts = ts ?? Math.floor(Date.now() / 1000);
  nonce = nonce ?? crypto.randomBytes(16).toString('hex');
  let sig = hmac(creds.deviceSecret, canonicalReq(action, creds.deviceId, ts, nonce, payload));
  if (tamper) sig = sig.replace(/^./, sig[0] === 'a' ? 'b' : 'a');
  return { action, deviceId: creds.deviceId, ts, nonce, payload, sig };
}

export async function enroll(s, label = 'membre-test') {
  const inv = await (await fetch(`${s.base}/__admin/invite?label=${label}`)).json();
  const out = await post(s, { action: 'enroll', payload: JSON.stringify({ inviteCode: inv.code, platform: 'test' }) });
  if (!out.ok) throw new Error('enroll failed ' + JSON.stringify(out));
  return { ...out.data, invite: inv };
}

export function fixture(size, seed = 1) {
  const b = Buffer.alloc(size);
  let x = seed >>> 0;
  for (let i = 0; i < size; i++) { x = (x * 1664525 + 1013904223) >>> 0; b[i] = x >>> 24; }
  return b;
}

export function initPayload(buf, captureId = crypto.randomUUID(), extra = {}) {
  return { captureId, size: buf.length, sha256: sha256(buf), md5: md5(buf), mimeType: 'video/quicktime', ext: 'mov', ...extra };
}

export async function call(s, creds, action, payload, o) { return post(s, signed(creds, action, payload, o)); }

/** Phone-side resumable upload (probe → PUT chunks → follow 308 Range). */
export async function uploadBytes(sessionUrl, buf, chunk = 256 * 1024 * 4) {
  const probe = async () => {
    const r = await fetch(sessionUrl, { method: 'PUT', headers: { 'Content-Range': `bytes */${buf.length}` } });
    if (r.status === 200 || r.status === 201) return { done: await r.json() };
    if (r.status === 308) { const rg = r.headers.get('range'); return { next: rg ? Number(rg.split('-')[1]) + 1 : 0 }; }
    throw new Error('probe ' + r.status);
  };
  let st = await probe();
  let cuts = 0;
  while (!st.done) {
    const start = st.next;
    const end = Math.min(buf.length, start + chunk) - 1;
    try {
      const r = await fetch(sessionUrl, { method: 'PUT', headers: { 'Content-Range': `bytes ${start}-${end}/${buf.length}` }, body: buf.subarray(start, end + 1) });
      if (r.status === 200 || r.status === 201) st = { done: await r.json() };
      else if (r.status === 308) { const rg = r.headers.get('range'); st = { next: rg ? Number(rg.split('-')[1]) + 1 : 0 }; }
      else throw new Error('put ' + r.status);
    } catch (e) {
      if (String(e.message).startsWith('put ')) throw e;
      cuts++;
      st = await probe();
    }
  }
  return { file: st.done, cuts };
}
