/**
 * SPECTRE Capture — deposit-only backend core logic.
 * Pure functions over an injected `env` (see 20_GasEnv.js) so that the exact
 * same code runs in Apps Script and in the Node test harness.
 *
 * Exposed web actions: enroll, initUpload, finalizeUpload. There is NO action
 * to list, search, read, download, move or delete archive content.
 */

function SpectreError_(code, message) {
  this.code = code;
  this.message = message || code;
}

function spErr_(code, message) { return new SpectreError_(code, message); }

var SPECTRE_ACTIONS_ = { enroll: true, initUpload: true, finalizeUpload: true };

/** Entry point for one web request (raw POST body string). Returns a plain object. */
function spectreHandle_(env, rawBody) {
  try {
    if (typeof rawBody !== 'string' || rawBody.length === 0 || rawBody.length > 16384) {
      throw spErr_('INVALID_REQUEST', 'body');
    }
    var envl;
    try { envl = JSON.parse(rawBody); } catch (e) { throw spErr_('INVALID_REQUEST', 'json'); }
    if (!envl || typeof envl !== 'object' || !SPECTRE_ACTIONS_[envl.action]) {
      throw spErr_('INVALID_REQUEST', 'action');
    }
    if (typeof envl.payload !== 'string' || envl.payload.length > 8192) throw spErr_('INVALID_REQUEST', 'payload');
    var payload;
    try { payload = JSON.parse(envl.payload); } catch (e2) { throw spErr_('INVALID_REQUEST', 'payload json'); }
    if (!payload || typeof payload !== 'object') throw spErr_('INVALID_REQUEST', 'payload');

    if (envl.action === 'enroll') return { ok: true, data: spEnroll_(env, payload) };

    var device = spAuthenticate_(env, envl);
    if (envl.action === 'initUpload') return { ok: true, data: spInitUpload_(env, device, payload) };
    if (envl.action === 'finalizeUpload') return { ok: true, data: spFinalize_(env, device, payload) };
    throw spErr_('INVALID_REQUEST', 'action');
  } catch (e) {
    if (e instanceof SpectreError_) {
      env.log('reject', { code: e.code });
      return { ok: false, error: { code: e.code, message: e.message } };
    }
    env.log('internal', { kind: String(e && e.name || 'Error') });
    return { ok: false, error: { code: 'INTERNAL', message: 'internal error' } };
  }
}

// ---------------------------------------------------------------- helpers

var RE_UUID_ = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
var RE_HEX64_ = /^[0-9a-f]{64}$/;
var RE_HEX32_ = /^[0-9a-f]{32}$/;
var RE_DEVICE_ = /^d_[0-9a-f]{16}$/;
var RE_UPLOAD_ = /^u_[0-9a-f]{24}$/;
var RE_DRIVE_ID_ = /^[A-Za-z0-9_-]{10,128}$/;
var RE_INVITE_ = /^[A-Za-z0-9-]{20,64}$/;

function spGetJson_(env, key) {
  var v = env.store.get(key);
  return v ? JSON.parse(v) : null;
}
function spPutJson_(env, key, obj) { env.store.set(key, JSON.stringify(obj)); }

function spUtcDay_(ms) { return new Date(ms).toISOString().slice(0, 10).replace(/-/g, ''); }

function spFileStamp_(ms) {
  var s = new Date(ms).toISOString(); // 2026-11-04T16:56:53.123Z
  return s.slice(0, 4) + s.slice(5, 7) + s.slice(8, 10) + 'T' + s.slice(11, 13) + s.slice(14, 16) + s.slice(17, 19) + 'Z';
}

function spConstEq_(a, b) {
  a = String(a); b = String(b);
  if (a.length !== b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

function spRateLimit_(env, key, limit) {
  var bucket = key + ':' + Math.floor(env.now() / 60000);
  var n = Number(env.cache.get(bucket) || '0') + 1;
  env.cache.put(bucket, String(n), 120);
  if (n > limit) throw spErr_('RATE_LIMITED', 'slow down');
}

function spRequestCanonical_(action, deviceId, ts, nonce, payload, env) {
  return ['spectre-req-v1', action, deviceId, String(ts), nonce, env.crypto.sha256Hex(payload)].join('\n');
}

function spReceiptCanonical_(r) {
  return ['spectre-receipt-v1', String(r.v), r.status, r.captureId, r.uploadId, r.deviceId,
    r.driveFileId, String(r.size), r.sha256, r.md5, r.checksumSource, r.verifiedAt].join('\n');
}

function spConfig_(env) {
  var folderId = env.store.get('CFG_FOLDER_ID');
  if (!folderId) throw spErr_('DRIVE_UNAVAILABLE', 'backend not configured');
  var base = env.store.get('CFG_DRIVE_API_BASE') || 'https://www.googleapis.com';
  if (base.indexOf('https://') !== 0 && env.store.get('CFG_TEST_MODE') !== 'true') {
    throw spErr_('INTERNAL', 'insecure api base');
  }
  return { folderId: folderId, base: base };
}

// ---------------------------------------------------------------- enrolment

function spEnroll_(env, p) {
  spRateLimit_(env, 'rl:enroll', SPECTRE_POLICY.enrollRequestsPerMinute);
  if (typeof p.inviteCode !== 'string' || !RE_INVITE_.test(p.inviteCode)) throw spErr_('AUTH_INVALID', 'invite');
  var invKey = 'inv:' + env.crypto.sha256Hex(p.inviteCode);
  return env.lock(function () {
    var inv = spGetJson_(env, invKey);
    var now = env.now();
    if (!inv || inv.usedAt || inv.expiresAt < now) throw spErr_('AUTH_INVALID', 'invite');
    var deviceId = 'd_' + env.crypto.randomHex(8);
    var secret = env.crypto.randomHex(32);
    var device = {
      id: deviceId, label: inv.label || '', secret: secret, status: 'active',
      createdAt: now, expiresAt: now + SPECTRE_POLICY.deviceTtlDays * 86400000,
      openUploads: 0, lastSeenAt: now
    };
    spPutJson_(env, 'dev:' + deviceId, device);
    inv.usedAt = now; inv.deviceId = deviceId;
    spPutJson_(env, invKey, inv);
    env.log('enrolled', { device: deviceId });
    return { deviceId: deviceId, deviceSecret: secret, expiresAt: device.expiresAt };
  });
}

function spAuthenticate_(env, e) {
  if (typeof e.deviceId !== 'string' || !RE_DEVICE_.test(e.deviceId)) throw spErr_('AUTH_INVALID', 'auth');
  if (typeof e.sig !== 'string' || !RE_HEX64_.test(e.sig)) throw spErr_('AUTH_INVALID', 'auth');
  if (typeof e.nonce !== 'string' || !/^[0-9a-f]{32}$/.test(e.nonce)) throw spErr_('AUTH_INVALID', 'auth');
  if (typeof e.ts !== 'number' || Math.abs(env.now() / 1000 - e.ts) > SPECTRE_POLICY.clockSkewSec) {
    throw spErr_('AUTH_INVALID', 'clock');
  }
  var device = spGetJson_(env, 'dev:' + e.deviceId);
  // Unknown device and bad signature are indistinguishable (no enumeration).
  if (!device) throw spErr_('AUTH_INVALID', 'auth');
  var expected = env.crypto.hmacHex(device.secret, spRequestCanonical_(e.action, e.deviceId, e.ts, e.nonce, e.payload, env));
  if (!spConstEq_(expected, e.sig)) throw spErr_('AUTH_INVALID', 'auth');
  if (device.status !== 'active') throw spErr_('DEVICE_REVOKED', 'revoked');
  if (device.expiresAt < env.now()) throw spErr_('DEVICE_EXPIRED', 'expired');
  var nonceKey = 'n:' + e.deviceId + ':' + e.nonce;
  if (env.cache.get(nonceKey)) throw spErr_('REPLAY', 'replay');
  env.cache.put(nonceKey, '1', SPECTRE_POLICY.nonceTtlSec);
  spRateLimit_(env, 'rl:' + e.deviceId, SPECTRE_POLICY.requestsPerMinutePerDevice);
  return device;
}

// ---------------------------------------------------------------- upload init

function spValidateInit_(p) {
  if (typeof p.captureId !== 'string' || !RE_UUID_.test(p.captureId)) throw spErr_('INVALID_REQUEST', 'captureId');
  if (typeof p.size !== 'number' || !isFinite(p.size) || p.size <= 0 || Math.floor(p.size) !== p.size) {
    throw spErr_('INVALID_REQUEST', 'size');
  }
  if (p.size > SPECTRE_POLICY.maxFileBytes) throw spErr_('FILE_TOO_LARGE', 'too large');
  if (typeof p.sha256 !== 'string' || !RE_HEX64_.test(p.sha256)) throw spErr_('INVALID_REQUEST', 'sha256');
  if (typeof p.md5 !== 'string' || !RE_HEX32_.test(p.md5)) throw spErr_('INVALID_REQUEST', 'md5');
  var ext = SPECTRE_POLICY.allowedMime[p.mimeType];
  if (!ext) throw spErr_('INVALID_REQUEST', 'mimeType');
  return ext;
}

function spInitUpload_(env, device, p) {
  var ext = spValidateInit_(p);
  var cfg = spConfig_(env);
  return env.lock(function () {
    device = spGetJson_(env, 'dev:' + device.id); // fresh copy under lock
    var capKey = 'cap:' + device.id + ':' + p.captureId;
    var existingId = env.store.get(capKey);
    var u = existingId ? spGetJson_(env, 'upl:' + existingId) : null;
    var now = env.now();

    if (u) {
      if (u.size !== p.size || u.sha256 !== p.sha256 || u.md5 !== p.md5) {
        throw spErr_('INVALID_REQUEST', 'captureId already used for different content');
      }
      if (u.state === 'VERIFIED') return { state: 'VERIFIED', receipt: u.receipt };
      if (u.state === 'MISMATCH' && !p.forceNewUpload) throw spErr_('MISMATCH', 'previous upload mismatched');
      if (u.state === 'INITIATED') {
        var fresh = now - u.sessionCreatedAt < SPECTRE_POLICY.sessionMaxAgeSec * 1000;
        if (!p.renewSession && fresh && u.sessionUrl) {
          return { state: 'SESSION', uploadId: u.id, sessionUrl: u.sessionUrl,
                   expiresAt: u.sessionCreatedAt + SPECTRE_POLICY.sessionMaxAgeSec * 1000 };
        }
        // Renewal: never create a second Drive file if the first one completed.
        if (spFindDriveFile_(env, cfg, u, null)) return { state: 'FINALIZE', uploadId: u.id };
        u.sessionUrl = spCreateSession_(env, cfg, u);
        u.sessionCreatedAt = now;
        u.renewals = (u.renewals || 0) + 1;
        spPutJson_(env, 'upl:' + u.id, u);
        env.log('session-renewed', { device: device.id });
        return { state: 'SESSION', uploadId: u.id, sessionUrl: u.sessionUrl,
                 expiresAt: now + SPECTRE_POLICY.sessionMaxAgeSec * 1000 };
      }
      if (u.state === 'MISMATCH' && p.forceNewUpload) {
        u.state = 'SUPERSEDED';
        spPutJson_(env, 'upl:' + u.id, u);
        device.openUploads = Math.max(0, (device.openUploads || 0) - 1);
      }
    }

    // Quotas (reserved at init, corrected at verification).
    if ((device.openUploads || 0) >= SPECTRE_POLICY.maxOpenUploadsPerDevice) throw spErr_('QUOTA_EXCEEDED', 'open uploads');
    var useKey = 'use:' + device.id + ':' + spUtcDay_(now);
    var use = spGetJson_(env, useKey) || { bytes: 0, count: 0 };
    if (use.count + 1 > SPECTRE_POLICY.dailyUploadsPerDevice) throw spErr_('QUOTA_EXCEEDED', 'daily count');
    if (use.bytes + p.size > SPECTRE_POLICY.dailyBytesPerDevice) throw spErr_('QUOTA_EXCEEDED', 'daily bytes');

    var uploadId = 'u_' + env.crypto.randomHex(12);
    var nu = {
      id: uploadId, deviceId: device.id, captureId: p.captureId, size: p.size, sha256: p.sha256,
      md5: p.md5, mime: p.mimeType, ext: ext, state: 'INITIATED', createdAt: now,
      name: 'SPECTRE_' + spFileStamp_(now) + '_' + device.id.slice(2, 8) + '_' + p.captureId.slice(0, 8) + '.' + ext,
      pendingCount: 0, renewals: 0
    };
    nu.sessionUrl = spCreateSession_(env, cfg, nu);
    nu.sessionCreatedAt = now;
    spPutJson_(env, 'upl:' + uploadId, nu);
    env.store.set(capKey, uploadId);
    use.count += 1; use.bytes += p.size;
    spPutJson_(env, useKey, use);
    device.openUploads = (device.openUploads || 0) + 1;
    device.lastSeenAt = now;
    spPutJson_(env, 'dev:' + device.id, device);
    env.log('session-created', { device: device.id });
    return { state: 'SESSION', uploadId: uploadId, sessionUrl: nu.sessionUrl,
             expiresAt: now + SPECTRE_POLICY.sessionMaxAgeSec * 1000 };
  });
}

function spDriveError_(res) {
  if (res.status === 403 && /storageQuotaExceeded|quotaExceeded/.test(res.text)) return spErr_('DRIVE_QUOTA', 'drive full');
  if (res.status === 429 || (res.status === 403 && /rateLimitExceeded|userRateLimitExceeded/.test(res.text))) {
    return spErr_('RATE_LIMITED', 'drive rate');
  }
  return spErr_('DRIVE_UNAVAILABLE', 'drive ' + res.status);
}

/** Initiates a Drive resumable session with the OWNER's token (never returned). */
function spCreateSession_(env, cfg, u) {
  var url = cfg.base + '/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true&fields=' +
    encodeURIComponent('id,size,md5Checksum,sha256Checksum');
  var meta = {
    name: u.name, parents: [cfg.folderId], mimeType: u.mime,
    appProperties: { spectreUploadId: u.id, spectreCaptureId: u.captureId, spectreDeviceId: u.deviceId }
  };
  var res = env.http.fetch(url, {
    method: 'post',
    contentType: 'application/json; charset=UTF-8',
    headers: {
      Authorization: 'Bearer ' + env.token(),
      'X-Upload-Content-Type': u.mime,
      'X-Upload-Content-Length': String(u.size)
    },
    payload: JSON.stringify(meta)
  });
  if (res.status !== 200) throw spDriveError_(res);
  var loc = res.headers['location'];
  if (!loc) throw spErr_('DRIVE_UNAVAILABLE', 'no session');
  return loc;
}

// ---------------------------------------------------------------- finalize

function spDriveGet_(env, cfg, fileId) {
  var res = env.http.fetch(cfg.base + '/drive/v3/files/' + encodeURIComponent(fileId) +
    '?supportsAllDrives=true&fields=' + encodeURIComponent(SPECTRE_DRIVE_FIELDS), {
    method: 'get', headers: { Authorization: 'Bearer ' + env.token() }
  });
  if (res.status === 404) return null;
  if (res.status !== 200) throw spDriveError_(res);
  return JSON.parse(res.text);
}

function spFindDriveFile_(env, cfg, u, hintId) {
  if (hintId && RE_DRIVE_ID_.test(hintId)) {
    var f = spDriveGet_(env, cfg, hintId);
    if (f && f.appProperties && f.appProperties.spectreUploadId === u.id && !f.trashed) return f;
  }
  var q = "appProperties has { key='spectreUploadId' and value='" + u.id + "' } and trashed = false";
  var res = env.http.fetch(cfg.base + '/drive/v3/files?supportsAllDrives=true&includeItemsFromAllDrives=true&q=' +
    encodeURIComponent(q) + '&fields=' + encodeURIComponent('files(' + SPECTRE_DRIVE_FIELDS + ')'), {
    method: 'get', headers: { Authorization: 'Bearer ' + env.token() }
  });
  if (res.status !== 200) throw spDriveError_(res);
  var files = (JSON.parse(res.text).files || []).filter(function (x) {
    return x.appProperties && x.appProperties.spectreUploadId === u.id;
  });
  if (files.length > 1) env.log('duplicate-drive-files', { upload: u.id, n: files.length });
  return files.length ? files[0] : null;
}

function spMarkMismatch_(env, cfg, fileId) {
  try {
    env.http.fetch(cfg.base + '/drive/v3/files/' + encodeURIComponent(fileId) + '?supportsAllDrives=true', {
      method: 'patch', contentType: 'application/json; charset=UTF-8',
      headers: { Authorization: 'Bearer ' + env.token() },
      payload: JSON.stringify({ appProperties: { spectreState: 'MISMATCH' } })
    });
  } catch (e) { /* best effort */ }
}

function spFinalize_(env, device, p) {
  if (typeof p.uploadId !== 'string' || !RE_UPLOAD_.test(p.uploadId)) throw spErr_('INVALID_REQUEST', 'uploadId');
  if (typeof p.captureId !== 'string' || !RE_UUID_.test(p.captureId)) throw spErr_('INVALID_REQUEST', 'captureId');
  var u = spGetJson_(env, 'upl:' + p.uploadId);
  // Other devices' uploads are indistinguishable from non-existent ones.
  if (!u || u.deviceId !== device.id || u.captureId !== p.captureId) throw spErr_('NOT_FOUND', 'unknown upload');
  if (u.state === 'VERIFIED') return { state: 'VERIFIED', receipt: u.receipt };
  if (u.state === 'MISMATCH') return { state: 'MISMATCH', detail: u.mismatch || 'mismatch' };
  if (u.state !== 'INITIATED') throw spErr_('NOT_FOUND', 'unknown upload');

  var cfg = spConfig_(env);
  var f = spFindDriveFile_(env, cfg, u, p.driveFileId);
  if (!f) return { state: 'INCOMPLETE' };

  var problems = [];
  if ((f.parents || []).indexOf(cfg.folderId) < 0) problems.push('folder');
  if (String(f.size) !== String(u.size)) problems.push('size');
  if (!f.md5Checksum || String(f.md5Checksum).toLowerCase() !== u.md5) problems.push('md5');
  var source = 'sha256';
  if (f.sha256Checksum) {
    if (String(f.sha256Checksum).toLowerCase() !== u.sha256) problems.push('sha256');
  } else {
    source = 'md5';
  }

  return env.lock(function () {
    u = spGetJson_(env, 'upl:' + p.uploadId);
    if (u.state === 'VERIFIED') return { state: 'VERIFIED', receipt: u.receipt };
    var now = env.now();
    if (problems.length) {
      u.state = 'MISMATCH'; u.mismatch = problems.join(','); u.driveFileId = f.id; u.sessionUrl = null;
      spPutJson_(env, 'upl:' + u.id, u);
      spMarkMismatch_(env, cfg, f.id);
      env.log('mismatch', { device: device.id, what: u.mismatch });
      return { state: 'MISMATCH', detail: u.mismatch };
    }
    if (source === 'md5') {
      u.pendingCount = (u.pendingCount || 0) + 1;
      if (!SPECTRE_POLICY.acceptMd5Fallback || u.pendingCount <= SPECTRE_POLICY.pendingBeforeMd5Fallback) {
        spPutJson_(env, 'upl:' + u.id, u);
        return { state: 'PENDING', retryAfterSec: SPECTRE_POLICY.pendingRetryAfterSec };
      }
    }
    var receipt = {
      v: 1, status: 'VERIFIED', captureId: u.captureId, uploadId: u.id, deviceId: device.id,
      driveFileId: f.id, size: u.size, sha256: u.sha256, md5: u.md5, checksumSource: source,
      verifiedAt: new Date(now).toISOString()
    };
    var dev = spGetJson_(env, 'dev:' + device.id);
    receipt.mac = env.crypto.hmacHex(dev.secret, spReceiptCanonical_(receipt));
    u.state = 'VERIFIED'; u.receipt = receipt; u.driveFileId = f.id; u.sessionUrl = null; u.verifiedAt = now;
    spPutJson_(env, 'upl:' + u.id, u);
    dev.openUploads = Math.max(0, (dev.openUploads || 0) - 1);
    dev.lastSeenAt = now;
    spPutJson_(env, 'dev:' + dev.id, dev);
    env.log('verified', { device: device.id, source: source });
    return { state: 'VERIFIED', receipt: receipt };
  });
}

// ---------------------------------------------------------------- admin (owner only, never routed from the web)

function spAdminCreateInvite_(env, label, ttlHours, endpointUrl) {
  var code = env.crypto.randomHex(16).replace(/(.{8})(?=.)/g, '$1-');
  var now = env.now();
  var hours = ttlHours || SPECTRE_POLICY.inviteTtlHours;
  spPutJson_(env, 'inv:' + env.crypto.sha256Hex(code), {
    label: String(label || '').slice(0, 40), createdAt: now, expiresAt: now + hours * 3600000
  });
  var link = 'spectre://enroll?v=1&endpoint=' + encodeURIComponent(endpointUrl) + '&code=' + code;
  return { code: code, link: link, expiresAt: now + hours * 3600000 };
}

function spAdminListDevices_(env) {
  return env.store.keys('dev:').map(function (k) {
    var d = spGetJson_(env, k);
    return { id: d.id, label: d.label, status: d.status, createdAt: d.createdAt, expiresAt: d.expiresAt,
             lastSeenAt: d.lastSeenAt, openUploads: d.openUploads };
  });
}

function spAdminRevokeDevice_(env, deviceId) {
  return env.lock(function () {
    var d = spGetJson_(env, 'dev:' + deviceId);
    if (!d) return false;
    d.status = 'revoked'; d.revokedAt = env.now(); // secret kept so the phone can be told it is revoked
    spPutJson_(env, 'dev:' + deviceId, d);
    env.log('revoked', { device: deviceId });
    return true;
  });
}

function spAdminPurge_(env) {
  var cutoff = env.now() - SPECTRE_POLICY.purgeVerifiedAfterDays * 86400000;
  var removed = 0;
  env.store.keys('upl:').forEach(function (k) {
    var u = spGetJson_(env, k);
    if (u && (u.state === 'VERIFIED' || u.state === 'SUPERSEDED') && (u.verifiedAt || u.createdAt) < cutoff) {
      env.store.del(k);
      env.store.del('cap:' + u.deviceId + ':' + u.captureId);
      removed++;
    }
  });
  var dayCut = spUtcDay_(env.now() - 3 * 86400000);
  env.store.keys('use:').forEach(function (k) { if (k.split(':')[2] < dayCut) env.store.del(k); });
  env.store.keys('inv:').forEach(function (k) {
    var i = spGetJson_(env, k);
    if (i && i.expiresAt < env.now() - 7 * 86400000) env.store.del(k);
  });
  return removed;
}
