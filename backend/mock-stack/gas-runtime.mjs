// SPECTRE Capture — runs the REAL Apps Script source files (backend/apps-script/src/*.js)
// in a Node vm context with faithful fakes of the GAS services used.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
export const GAS_SRC = path.resolve(here, '../apps-script/src');

function toSignedBytes(buf) { return Array.from(buf, (b) => (b > 127 ? b - 256 : b)); }

export function createGasRuntime({ drive, ownerToken, clock = () => Date.now(), webAppUrl }) {
  const props = new Map();
  const cache = new Map();
  const logs = [];
  const fetchLog = [];
  let lockHeld = false;
  // Identity seen by Session: the owner by default (editor runs, control page);
  // '' models an anonymous visitor of the "Anyone" web app (Google gives no e-mail).
  const OWNER = 'owner@example.test';
  let activeUser = OWNER;

  const sandbox = {
    console: { log: (...a) => logs.push(a.join(' ')) },
    Date: class extends Date {
      constructor(...a) { if (a.length === 0) super(clock()); else super(...a); }
      static now() { return clock(); }
    },
    PropertiesService: {
      getScriptProperties: () => ({
        getProperty: (k) => (props.has(k) ? props.get(k) : null),
        setProperty: (k, v) => {
          if (String(v).length > 9 * 1024) throw new Error('Property value too large (GAS limit 9KB)');
          props.set(k, String(v));
          const total = [...props].reduce((n, [a, b]) => n + a.length + b.length, 0);
          if (total > 500 * 1024) throw new Error('Script Properties quota exceeded (500KB)');
        },
        deleteProperty: (k) => props.delete(k),
        getKeys: () => [...props.keys()],
      }),
    },
    CacheService: {
      getScriptCache: () => ({
        get: (k) => { const e = cache.get(k); if (!e || e.exp < clock()) return null; return e.v; },
        put: (k, v, ttl) => cache.set(k, { v: String(v), exp: clock() + (ttl || 600) * 1000 }),
      }),
    },
    LockService: {
      getScriptLock: () => ({
        tryLock: () => { if (lockHeld) return false; lockHeld = true; return true; },
        releaseLock: () => { lockHeld = false; },
      }),
    },
    UrlFetchApp: {
      fetch: (url, params) => {
        if (params.followRedirects !== false) throw new Error('backend must disable redirects');
        const headers = { ...(params.headers || {}) };
        if (params.contentType) headers['Content-Type'] = params.contentType;
        fetchLog.push({ method: params.method, url });
        const r = drive.handleSync({ method: String(params.method).toUpperCase(), url, headers, body: params.payload ?? '' });
        return {
          getResponseCode: () => r.status,
          getHeaders: () => r.headers || {},
          getContentText: () => r.text || '',
        };
      },
    },
    Utilities: {
      DigestAlgorithm: { SHA_256: 'sha256' },
      Charset: { UTF_8: 'utf8' },
      computeDigest: (alg, value) => toSignedBytes(crypto.createHash(alg).update(String(value), 'utf8').digest()),
      computeHmacSha256Signature: (value, key) =>
        toSignedBytes(crypto.createHmac('sha256', Buffer.from(String(key), 'utf8')).update(String(value), 'utf8').digest()),
      getUuid: () => crypto.randomUUID(),
    },
    ContentService: {
      MimeType: { JSON: 'application/json' },
      createTextOutput: (s) => ({ content: s, setMimeType() { return this; }, getContent() { return this.content; } }),
    },
    Session: {
      getActiveUser: () => ({ getEmail: () => activeUser }),
      getEffectiveUser: () => ({ getEmail: () => OWNER }),
    },
    HtmlService: {
      createHtmlOutput: (html) => ({
        kind: 'html', content: String(html), title: '',
        setTitle(t) { this.title = t; return this; }, addMetaTag() { return this; }, getContent() { return this.content; },
      }),
    },
    ScriptApp: {
      getOAuthToken: () => ownerToken(),
      getService: () => ({ getUrl: () => webAppUrl }),
      getProjectTriggers: () => [],
      newTrigger: () => ({ timeBased: () => ({ everyDays: () => ({ atHour: () => ({ create: () => {} }) }) }) }),
    },
  };
  // Make sure the real code never touches services we do not grant.
  for (const forbidden of ['DriveApp', 'SpreadsheetApp', 'GmailApp', 'MailApp']) {
    Object.defineProperty(sandbox, forbidden, { get() { throw new Error(`${forbidden} must not be used`); } });
  }
  const ctx = vm.createContext(sandbox);
  const files = fs.readdirSync(GAS_SRC).filter((f) => f.endsWith('.js')).sort();
  for (const f of files) vm.runInContext(fs.readFileSync(path.join(GAS_SRC, f), 'utf8'), ctx, { filename: f });

  return {
    ctx, props, logs, fetchLog,
    doPost: (body) => JSON.parse(ctx.doPost({ postData: { contents: body } }).getContent()),
    /** GET as an anonymous visitor (default) or as the owner: { kind: 'html'|'json', content, title }. */
    get: (parameter = {}, { asOwner = false } = {}) => {
      const prev = activeUser; activeUser = asOwner ? OWNER : '';
      try {
        const out = ctx.doGet({ parameter });
        return { kind: out.kind === 'html' ? 'html' : 'json', content: out.getContent(), title: out.title || '' };
      } finally { activeUser = prev; }
    },
    /** Runs fn with the given Session identity ('' = anonymous). */
    as: (email, fn) => { const prev = activeUser; activeUser = email; try { return fn(); } finally { activeUser = prev; } },
    env: () => ctx.spGasEnv_(),
    configure: ({ folderId, apiBase }) => {
      props.set('CFG_FOLDER_ID', folderId);
      props.set('CFG_DRIVE_API_BASE', apiBase);
      props.set('CFG_TEST_MODE', 'true');
      props.set('CFG_WEBAPP_URL', webAppUrl);
    },
    createInvite: (label = 'membre-test') =>
      ctx.spAdminCreateInvite_(ctx.spGasEnv_(), label, 48, webAppUrl),
    revoke: (deviceId) => ctx.spAdminRevokeDevice_(ctx.spGasEnv_(), deviceId),
    listDevices: () => ctx.spAdminListDevices_(ctx.spGasEnv_()),
    purge: () => ctx.spAdminPurge_(ctx.spGasEnv_()),
    policy: () => ctx.SPECTRE_POLICY,
  };
}
