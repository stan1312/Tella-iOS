// SPECTRE backend tests — run the real Apps Script code against MockDrive.
import { test, describe, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as H from './helpers.mjs';

let s;
before(async () => { s = await H.stack(); });
after(async () => { await s.close(); });
beforeEach(async () => { await fetch(`${s.base}/__control`, { method: 'POST', body: JSON.stringify({ reset: true }) }); });
const control = (c) => fetch(`${s.base}/__control`, { method: 'POST', body: JSON.stringify(c) });

async function fullDeposit(creds, buf, captureId) {
  const p = H.initPayload(buf, captureId);
  const init = await H.call(s, creds, 'initUpload', p);
  assert.equal(init.ok, true, JSON.stringify(init));
  const up = await H.uploadBytes(init.data.sessionUrl, buf);
  const fin = await H.call(s, creds, 'finalizeUpload', { uploadId: init.data.uploadId, captureId: p.captureId, driveFileId: up.file.id });
  return { p, init, up, fin };
}

describe('enrolment & device identity', () => {
  test('one-time invite yields a device credential; reuse is refused', async () => {
    const inv = await (await fetch(`${s.base}/__admin/invite?label=m1`)).json();
    const a = await H.post(s, { action: 'enroll', payload: JSON.stringify({ inviteCode: inv.code }) });
    assert.equal(a.ok, true);
    assert.match(a.data.deviceId, /^d_[0-9a-f]{16}$/);
    assert.match(a.data.deviceSecret, /^[0-9a-f]{64}$/);
    const b = await H.post(s, { action: 'enroll', payload: JSON.stringify({ inviteCode: inv.code }) });
    assert.deepEqual(b.error.code, 'AUTH_INVALID');
  });
  test('expired invite is refused', async () => {
    const inv = await (await fetch(`${s.base}/__admin/invite`)).json();
    await control({ advanceClockSec: 49 * 3600 });
    const a = await H.post(s, { action: 'enroll', payload: JSON.stringify({ inviteCode: inv.code }) });
    assert.equal(a.error.code, 'AUTH_INVALID');
  });
  test('enrol brute force is rate limited', async () => {
    let last;
    for (let i = 0; i < 12; i++) last = await H.post(s, { action: 'enroll', payload: JSON.stringify({ inviteCode: 'aaaaaaaa-bbbbbbbb-cccccccc-' + i.toString().padStart(8, '0') }) });
    assert.equal(last.error.code, 'RATE_LIMITED');
  });
});

describe('request authentication', () => {
  test('bad signature, unknown device, stale clock → AUTH_INVALID (indistinguishable)', async () => {
    const c = await H.enroll(s);
    const p = H.initPayload(H.fixture(1000));
    assert.equal((await H.call(s, c, 'initUpload', p, { tamper: true })).error.code, 'AUTH_INVALID');
    assert.equal((await H.call(s, { ...c, deviceId: 'd_0123456789abcdef' }, 'initUpload', p)).error.code, 'AUTH_INVALID');
    assert.equal((await H.call(s, c, 'initUpload', p, { ts: Math.floor(Date.now() / 1000) - 3600 })).error.code, 'AUTH_INVALID');
  });
  test('replayed request (same nonce) → REPLAY', async () => {
    const c = await H.enroll(s);
    const env = H.signed(c, 'initUpload', H.initPayload(H.fixture(1000)));
    assert.equal((await H.post(s, env)).ok, true);
    assert.equal((await H.post(s, env)).error.code, 'REPLAY');
  });
  test('per-device rate limit', async () => {
    const c = await H.enroll(s);
    await control({ policy: { requestsPerMinutePerDevice: 3 } });
    const codes = [];
    for (let i = 0; i < 5; i++) codes.push((await H.call(s, c, 'finalizeUpload', { uploadId: 'u_' + '0'.repeat(24), captureId: crypto.randomUUID() })).error.code);
    assert.deepEqual(codes.slice(3), ['RATE_LIMITED', 'RATE_LIMITED']);
  });
});

describe('T01 / T15 — deposit happy path (mock Drive)', () => {
  test('init → upload bytes directly to Drive → server verification → MAC receipt', async () => {
    const c = await H.enroll(s);
    const buf = H.fixture(3 * 1024 * 1024 + 123);
    const { p, init, up, fin } = await fullDeposit(c, buf);
    assert.equal(fin.ok, true, JSON.stringify(fin));
    assert.equal(fin.data.state, 'VERIFIED');
    const r = fin.data.receipt;
    assert.equal(r.size, buf.length);
    assert.equal(r.sha256, H.sha256(buf));
    assert.equal(r.checksumSource, 'sha256');
    assert.equal(r.driveFileId, up.file.id);
    assert.equal(r.mac, H.hmac(c.deviceSecret, H.canonicalReceipt(r)));
    // owner-side: exactly one file, byte-identical, neutral name, in the private folder
    const owner = await (await fetch(`${s.base}/__owner/files`)).json();
    assert.equal(owner.files.length, 1);
    assert.equal(owner.files[0].sha256, H.sha256(buf));
    assert.match(owner.files[0].name, /^SPECTRE_\d{8}T\d{6}Z_[0-9a-f]{6}_[0-9a-f]{8}\.mov$/);
    assert.deepEqual(owner.files[0].parents, [s.drive.folderId]);
    assert.equal(owner.files[0].appProperties.spectreCaptureId, p.captureId);
    // media bytes never transit through Apps Script
    assert.ok(s.gas.fetchLog.every((f) => !/upload_id=/.test(f.url)), 'GAS never touches the session');
    assert.ok(init.data.sessionUrl.includes('upload_id='));
  });
  test('T08 idempotence: repeated init returns the same session; after verification returns the same receipt', async () => {
    const c = await H.enroll(s);
    const buf = H.fixture(600 * 1024);
    const p = H.initPayload(buf);
    const a = await H.call(s, c, 'initUpload', p);
    const b = await H.call(s, c, 'initUpload', p);
    assert.equal(a.data.uploadId, b.data.uploadId);
    assert.equal(a.data.sessionUrl, b.data.sessionUrl);
    const up = await H.uploadBytes(a.data.sessionUrl, buf);
    const f1 = await H.call(s, c, 'finalizeUpload', { uploadId: a.data.uploadId, captureId: p.captureId, driveFileId: up.file.id });
    const f2 = await H.call(s, c, 'finalizeUpload', { uploadId: a.data.uploadId, captureId: p.captureId });
    const again = await H.call(s, c, 'initUpload', p);
    assert.deepEqual(f1.data.receipt, f2.data.receipt);
    assert.equal(again.data.state, 'VERIFIED');
    assert.deepEqual(again.data.receipt, f1.data.receipt);
    const owner = await (await fetch(`${s.base}/__owner/files`)).json();
    assert.equal(owner.files.length, 1, 'no duplicate Drive file');
  });
  test('same captureId with different content is refused', async () => {
    const c = await H.enroll(s);
    const id = crypto.randomUUID();
    await H.call(s, c, 'initUpload', H.initPayload(H.fixture(1000, 1), id));
    const r = await H.call(s, c, 'initUpload', H.initPayload(H.fixture(1000, 2), id));
    assert.equal(r.error.code, 'INVALID_REQUEST');
  });
});

describe('T04 — interrupted uploads', () => {
  for (const frac of [0.10, 0.50, 0.99]) {
    test(`cut at ${frac * 100}% then resume via probe; nothing verified before completion`, async () => {
      const c = await H.enroll(s);
      const buf = H.fixture(4 * 1024 * 1024 + 17, 7);
      const p = H.initPayload(buf);
      const init = await H.call(s, c, 'initUpload', p);
      await control({ driveFaults: { dropAtFractions: [frac] } });
      // a new session is needed for the fault to apply (faults are captured at session creation)
      const renewed = await H.call(s, c, 'initUpload', { ...p, renewSession: true });
      const early = await H.call(s, c, 'finalizeUpload', { uploadId: renewed.data.uploadId, captureId: p.captureId });
      assert.equal(early.data.state, 'INCOMPLETE');
      const up = await H.uploadBytes(renewed.data.sessionUrl, buf);
      assert.equal(up.cuts, 1);
      const fin = await H.call(s, c, 'finalizeUpload', { uploadId: init.data.uploadId, captureId: p.captureId, driveFileId: up.file.id });
      assert.equal(fin.data.state, 'VERIFIED');
      assert.equal(fin.data.receipt.sha256, H.sha256(buf));
    });
  }
});

describe('T06 / T07 — verification failures block', () => {
  test('HTTP success at upload but file absent on Drive → INCOMPLETE (no receipt)', async () => {
    const c = await H.enroll(s);
    const buf = H.fixture(300 * 1024);
    const p = H.initPayload(buf);
    const init = await H.call(s, c, 'initUpload', p);
    const up = await H.uploadBytes(init.data.sessionUrl, buf);
    await control({ driveFaults: { getFault: 'missing' } });
    const fin = await H.call(s, c, 'finalizeUpload', { uploadId: init.data.uploadId, captureId: p.captureId, driveFileId: up.file.id });
    assert.equal(fin.data.state, 'INCOMPLETE');
    assert.equal(fin.data.receipt, undefined);
  });
  for (const fault of ['sizeWrong', 'sha256Wrong', 'md5Wrong']) {
    test(`${fault} → MISMATCH, Drive file tagged, no receipt`, async () => {
      const c = await H.enroll(s);
      const buf = H.fixture(300 * 1024);
      const p = H.initPayload(buf);
      const init = await H.call(s, c, 'initUpload', p);
      const up = await H.uploadBytes(init.data.sessionUrl, buf);
      await control({ driveFaults: { getFault: fault } });
      const fin = await H.call(s, c, 'finalizeUpload', { uploadId: init.data.uploadId, captureId: p.captureId, driveFileId: up.file.id });
      assert.equal(fin.data.state, 'MISMATCH');
      assert.equal(fin.data.receipt, undefined);
      const owner = await (await fetch(`${s.base}/__owner/files`)).json();
      assert.equal(owner.files[0].appProperties.spectreState, 'MISMATCH');
      // a later retry without forceNewUpload is refused; with it a new upload is issued
      assert.equal((await H.call(s, c, 'initUpload', p)).error.code, 'MISMATCH');
      await control({ driveFaults: {} });
      const again = await H.call(s, c, 'initUpload', { ...p, forceNewUpload: true });
      assert.notEqual(again.data.uploadId, init.data.uploadId);
    });
  }
  test('sha256 not (yet) exposed by Drive → PENDING, then md5+size fallback after policy threshold', async () => {
    const c = await H.enroll(s);
    const buf = H.fixture(300 * 1024);
    const p = H.initPayload(buf);
    const init = await H.call(s, c, 'initUpload', p);
    const up = await H.uploadBytes(init.data.sessionUrl, buf);
    await control({ driveFaults: { getFault: 'sha256Absent' } });
    const states = [];
    for (let i = 0; i < 4; i++) {
      const f = await H.call(s, c, 'finalizeUpload', { uploadId: init.data.uploadId, captureId: p.captureId, driveFileId: up.file.id });
      states.push(f.data.state);
      if (f.data.state === 'VERIFIED') assert.equal(f.data.receipt.checksumSource, 'md5');
    }
    assert.deepEqual(states, ['PENDING', 'PENDING', 'PENDING', 'VERIFIED']);
  });
});

describe('T09 / T10 / T14 — revocation, no archive access, isolation', () => {
  test('revoked device cannot start uploads; others continue', async () => {
    const a = await H.enroll(s, 'a'); const b = await H.enroll(s, 'b');
    await fetch(`${s.base}/__admin/revoke?deviceId=${a.deviceId}`);
    assert.equal((await H.call(s, a, 'initUpload', H.initPayload(H.fixture(1000)))).error.code, 'DEVICE_REVOKED');
    assert.equal((await H.call(s, b, 'initUpload', H.initPayload(H.fixture(1000)))).ok, true);
  });
  test('web API has no list/search/read/download/move/delete action', async () => {
    const c = await H.enroll(s);
    for (const action of ['list', 'listFiles', 'search', 'download', 'get', 'read', 'move', 'delete', 'trash', 'admin', 'spAdminListDevices_', 'spectreListDevices', 'createInvite']) {
      const r = await H.post(s, H.signed(c, action, {}));
      assert.equal(r.error.code, 'INVALID_REQUEST', action);
    }
    const g = await (await fetch(s.webAppUrl)).json();
    assert.equal(g.error.code, 'NOT_FOUND');
  });
  test('device credentials + session URL give no read access to Drive', async () => {
    const c = await H.enroll(s);
    const other = await H.enroll(s, 'other');
    const victim = await fullDeposit(other, H.fixture(300 * 1024, 3));
    const buf = H.fixture(300 * 1024);
    const p = H.initPayload(buf);
    const init = await H.call(s, c, 'initUpload', p);
    const sess = init.data.sessionUrl;
    // attacker tries the Drive REST API with what a phone holds
    const attempts = [
      fetch(`${s.base}/drive/v3/files`),
      fetch(`${s.base}/drive/v3/files`, { headers: { Authorization: 'Bearer ' + c.deviceSecret } }),
      fetch(`${s.base}/drive/v3/files/${victim.fin.data.receipt.driveFileId}?alt=media`),
      fetch(`${s.base}/drive/v3/files/${victim.fin.data.receipt.driveFileId}`, { method: 'DELETE' }),
      fetch(`${s.base}/drive/v3/files/${victim.fin.data.receipt.driveFileId}`, { headers: { Authorization: 'Bearer ' + new URL(sess).searchParams.get('upload_id') } }),
      fetch(sess, { method: 'GET' }),
    ];
    const codes = (await Promise.all(attempts)).map((r) => r.status);
    assert.ok(codes.every((x) => x === 401 || x === 404), String(codes));
    // cross-device finalize of someone else's upload is indistinguishable from unknown
    const x = await H.call(s, c, 'finalizeUpload', { uploadId: victim.init.data.uploadId, captureId: victim.p.captureId });
    assert.equal(x.error.code, 'NOT_FOUND');
  });
  test('owner OAuth token never appears in any response or log', async () => {
    const c = await H.enroll(s);
    const { init, fin } = await fullDeposit(c, H.fixture(300 * 1024));
    const blob = JSON.stringify([init, fin]) + JSON.stringify((await (await fetch(`${s.base}/__admin/logs`)).json()).logs);
    assert.ok(!blob.includes(s.ownerToken));
    assert.ok(!blob.includes('ya29.'));
    const logs = s.gas.logs.join('\n');
    assert.ok(!/upload_id=|https?:\/\//.test(logs), 'no URL in backend logs');
  });
  test('T14 two devices depositing concurrently: distinct uploads, receipts, files', async () => {
    const a = await H.enroll(s, 'a'); const b = await H.enroll(s, 'b');
    const same = crypto.randomUUID();   // even the same captureId cannot collide across devices
    const [ra, rb] = await Promise.all([fullDeposit(a, H.fixture(500 * 1024, 11), same), fullDeposit(b, H.fixture(500 * 1024, 12), same)]);
    assert.equal(ra.fin.data.state, 'VERIFIED'); assert.equal(rb.fin.data.state, 'VERIFIED');
    assert.notEqual(ra.fin.data.receipt.uploadId, rb.fin.data.receipt.uploadId);
    assert.notEqual(ra.fin.data.receipt.driveFileId, rb.fin.data.receipt.driveFileId);
    assert.equal(ra.fin.data.receipt.deviceId, a.deviceId);
    assert.equal(rb.fin.data.receipt.deviceId, b.deviceId);
    assert.notEqual(ra.fin.data.receipt.mac, H.hmac(b.deviceSecret, H.canonicalReceipt(ra.fin.data.receipt)));
  });
});

describe('T11 — quotas and Google failures are explicit', () => {
  test('owner Drive full → DRIVE_QUOTA; Drive down → DRIVE_UNAVAILABLE; owner token expired → DRIVE_UNAVAILABLE', async () => {
    const c = await H.enroll(s);
    await control({ driveFaults: { storageQuotaExceeded: true } });
    assert.equal((await H.call(s, c, 'initUpload', H.initPayload(H.fixture(1000)))).error.code, 'DRIVE_QUOTA');
    await control({ driveFaults: { driveDown: true } });
    assert.equal((await H.call(s, c, 'initUpload', H.initPayload(H.fixture(1000)))).error.code, 'DRIVE_UNAVAILABLE');
    await control({ driveFaults: { ownerTokenExpired: true } });
    assert.equal((await H.call(s, c, 'initUpload', H.initPayload(H.fixture(1000)))).error.code, 'DRIVE_UNAVAILABLE');
  });
  test('per-device quotas: size, daily count, open uploads', async () => {
    const c = await H.enroll(s);
    await control({ policy: { maxFileBytes: 1000, dailyUploadsPerDevice: 2, maxOpenUploadsPerDevice: 5 } });
    assert.equal((await H.call(s, c, 'initUpload', H.initPayload(H.fixture(1001)))).error.code, 'FILE_TOO_LARGE');
    assert.equal((await H.call(s, c, 'initUpload', H.initPayload(H.fixture(10, 1)))).ok, true);
    assert.equal((await H.call(s, c, 'initUpload', H.initPayload(H.fixture(10, 2)))).ok, true);
    assert.equal((await H.call(s, c, 'initUpload', H.initPayload(H.fixture(10, 3)))).error.code, 'QUOTA_EXCEEDED');
  });
  test('input validation (mime whitelist, ids)', async () => {
    const c = await H.enroll(s);
    const b = H.fixture(10);
    assert.equal((await H.call(s, c, 'initUpload', H.initPayload(b, undefined, { mimeType: 'text/html' }))).error.code, 'INVALID_REQUEST');
    assert.equal((await H.call(s, c, 'initUpload', H.initPayload(b, '../../etc'))).error.code, 'INVALID_REQUEST');
    assert.equal((await H.call(s, c, 'finalizeUpload', { uploadId: "u_x' or 1=1", captureId: crypto.randomUUID() })).error.code, 'INVALID_REQUEST');
  });
});

describe('session lifecycle', () => {
  test('renewal after expiry issues a new session; renewal after completion → FINALIZE (no duplicate)', async () => {
    const c = await H.enroll(s);
    const buf = H.fixture(300 * 1024);
    const p = H.initPayload(buf);
    const init = await H.call(s, c, 'initUpload', p);
    const r1 = await H.call(s, c, 'initUpload', { ...p, renewSession: true });
    assert.equal(r1.data.state, 'SESSION');
    assert.notEqual(r1.data.sessionUrl, init.data.sessionUrl);
    await H.uploadBytes(r1.data.sessionUrl, buf);
    const r2 = await H.call(s, c, 'initUpload', { ...p, renewSession: true });
    assert.equal(r2.data.state, 'FINALIZE');
  });
  test('backend only calls Drive endpoints compatible with the drive.file scope', async () => {
    const c = await H.enroll(s);
    await fullDeposit(c, H.fixture(300 * 1024));
    for (const f of s.gas.fetchLog) {
      const u = new URL(f.url);
      assert.ok(['/upload/drive/v3/files', '/drive/v3/files'].includes(u.pathname) || /^\/drive\/v3\/files\/[^/]+$/.test(u.pathname), u.pathname);
    }
  });
  test('purge removes old verified records; keeps open ones', async () => {
    const c = await H.enroll(s);
    await fullDeposit(c, H.fixture(1000, 1));
    await H.call(s, c, 'initUpload', H.initPayload(H.fixture(1000, 2)));
    await control({ advanceClockSec: 31 * 86400 });
    assert.equal(s.gas.purge(), 1);
  });
});

describe('owner admin: colleagues and one folder per demonstration', () => {
  const FOLDER = 'application/vnd.google-apps.folder';
  test('spectreNouvelleManif routes new deposits to a dated sub-folder; uploads in flight finish where they started', async () => {
    const c = await H.enroll(s);
    const root = s.gas.props.get('CFG_FOLDER_ID');
    const buf = H.fixture(1500, 7);
    const p0 = H.initPayload(buf);
    const pending = await H.call(s, c, 'initUpload', p0);
    assert.equal(pending.ok, true);
    const name = s.gas.ctx.spectreNouvelleManif();
    assert.match(name, /^MANIF_\d{4}-\d{2}-\d{2}$/);
    const sub = [...s.drive.files.values()].find((f) => f.mimeType === FOLDER && f.name === name);
    assert.ok(sub, 'sub-folder created');
    assert.deepEqual(sub.parents, [root]);
    assert.equal(s.gas.props.get('CFG_FOLDER_ID'), sub.id);
    const { fin } = await fullDeposit(c, H.fixture(1000, 8));
    assert.equal(fin.ok, true);
    assert.deepEqual(s.drive.files.get(fin.data.receipt.driveFileId).parents, [sub.id]);
    const up = await H.uploadBytes(pending.data.sessionUrl, buf);
    assert.deepEqual(s.drive.files.get(up.file.id).parents, [root], 'in-flight upload keeps its original folder');
    const fin2 = await H.call(s, c, 'finalizeUpload', { uploadId: pending.data.uploadId, captureId: p0.captureId, driveFileId: up.file.id });
    assert.equal(fin2.ok, true, JSON.stringify(fin2));
    assert.equal(fin2.data.state, 'VERIFIED', JSON.stringify(fin2));
    s.gas.ctx.spectreDossierPrincipal();
    assert.equal(s.gas.props.get('CFG_FOLDER_ID'), root);
  });
  test('spectreNouvelleInvitation numbers pseudonyms and writes the link only to a file in the main folder', async () => {
    const root = s.gas.props.get('CFG_FOLDER_ID');
    s.gas.ctx.spectreNouvelleManif();
    assert.equal(s.gas.ctx.spectreNouvelleInvitation(), 'membre-02');
    assert.equal(s.gas.ctx.spectreNouvelleInvitation(), 'membre-03');
    const files = [...s.drive.files.values()].filter((f) => f.name === 'SPECTRE_INVITATION_A_SUPPRIMER.txt');
    assert.equal(files.length, 2);
    for (const f of files) {
      assert.deepEqual(f.parents, [root]);
      assert.match(f.content, /^spectre:\/\/enroll\?v=1&endpoint=.+&code=[0-9a-f-]+\n$/);
    }
    assert.ok(!/spectre:\/\/|code=/.test(s.gas.logs.join('\n')), 'link never logged');
    const code = new URL(files[0].content.trim()).searchParams.get('code');
    const a = await H.post(s, { action: 'enroll', payload: JSON.stringify({ inviteCode: code }) });
    assert.equal(a.ok, true);
    assert.ok(s.gas.ctx.spAdminListDevices_(s.gas.env()).some((d) => d.label === 'membre-02'));
  });
});

describe('static checks of the Apps Script source', () => {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const src = fs.readdirSync(path.join(here, '../src')).filter((f) => f.endsWith('.js'))
    .map((f) => fs.readFileSync(path.join(here, '../src', f), 'utf8')).join('\n');
  test('no DriveApp / HtmlService / full drive scope; manifest scopes are minimal', () => {
    assert.ok(!/DriveApp|HtmlService|google\.script\.run/.test(src));
    const manifest = JSON.parse(fs.readFileSync(path.join(here, '../src/appsscript.json'), 'utf8'));
    assert.deepEqual(manifest.oauthScopes.sort(), [
      'https://www.googleapis.com/auth/drive.file',
      'https://www.googleapis.com/auth/script.external_request',
      'https://www.googleapis.com/auth/script.scriptapp',
    ]);
    assert.equal(manifest.webapp.executeAs, 'USER_DEPLOYING');
  });
  test('no secret-looking literal in the source', () => {
    assert.ok(!/ya29\.|AIza[0-9A-Za-z_-]{20,}|-----BEGIN|client_secret/.test(src));
  });
});
