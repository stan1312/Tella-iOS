/**
 * SPECTRE Capture — binds the core to real Apps Script services.
 * Only Script Properties (owner/editors only), CacheService, LockService,
 * UrlFetchApp and ScriptApp.getOAuthToken() are used. The built-in Drive service is not used (it would
 * require the full Drive scope); Drive is reached through REST with the
 * narrow `drive.file` scope.
 */
function spGasEnv_() {
  var props = PropertiesService.getScriptProperties();
  var cache = CacheService.getScriptCache();
  function bytesToHex(bytes) {
    var s = '';
    for (var i = 0; i < bytes.length; i++) {
      var b = (bytes[i] + 256) % 256;
      s += (b < 16 ? '0' : '') + b.toString(16);
    }
    return s;
  }
  function sha256Hex(str) {
    return bytesToHex(Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, str, Utilities.Charset.UTF_8));
  }
  return {
    store: {
      get: function (k) { return props.getProperty(k); },
      set: function (k, v) { props.setProperty(k, v); },
      del: function (k) { props.deleteProperty(k); },
      keys: function (prefix) { return props.getKeys().filter(function (k) { return k.indexOf(prefix) === 0; }); }
    },
    cache: {
      get: function (k) { return cache.get(k); },
      put: function (k, v, ttl) { cache.put(k, v, ttl); }
    },
    lock: function (fn) {
      var lock = LockService.getScriptLock();
      if (!lock.tryLock(20000)) throw spErr_('BUSY', 'busy');
      try { return fn(); } finally { lock.releaseLock(); }
    },
    http: {
      fetch: function (url, opts) {
        var params = {
          method: opts.method, headers: opts.headers || {}, muteHttpExceptions: true, followRedirects: false
        };
        if (opts.contentType) params.contentType = opts.contentType;
        if (opts.payload !== undefined) params.payload = opts.payload;
        var r = UrlFetchApp.fetch(url, params);
        var h = {};
        var raw = r.getHeaders();
        Object.keys(raw).forEach(function (k) { h[k.toLowerCase()] = String(raw[k]); });
        return { status: r.getResponseCode(), headers: h, text: r.getContentText() };
      }
    },
    token: function () { return ScriptApp.getOAuthToken(); },
    crypto: {
      sha256Hex: sha256Hex,
      hmacHex: function (key, msg) {
        return bytesToHex(Utilities.computeHmacSha256Signature(msg, key, Utilities.Charset.UTF_8));
      },
      // Apps Script has no CSPRNG API; Utilities.getUuid() is a type-4 UUID
      // (java.util.UUID.randomUUID -> SecureRandom). Three UUIDs (~366 random
      // bits) are condensed with SHA-256.
      randomHex: function (nBytes) {
        var out = '';
        while (out.length < nBytes * 2) {
          out += sha256Hex(Utilities.getUuid() + Utilities.getUuid() + Utilities.getUuid());
        }
        return out.slice(0, nBytes * 2);
      }
    },
    now: function () { return Date.now(); },
    log: function (event, fields) {
      // Minimal technical journal: no URLs, no secrets, no file names.
      console.log('spectre ' + event + ' ' + JSON.stringify(fields || {}));
    }
  };
}
