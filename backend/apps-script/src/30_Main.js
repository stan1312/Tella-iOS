/**
 * SPECTRE Capture — web entry points and owner-only admin functions.
 *
 * Web app: doPost only handles enroll / initUpload / finalizeUpload.
 * Admin functions below are run by the OWNER from the Apps Script editor
 * (Run menu). They are never routed from doPost/doGet.
 */

function doPost(e) {
  var body = (e && e.postData && typeof e.postData.contents === 'string') ? e.postData.contents : '';
  var out = spectreHandle_(spGasEnv_(), body);
  return ContentService.createTextOutput(JSON.stringify(out)).setMimeType(ContentService.MimeType.JSON);
}

function doGet() {
  return ContentService.createTextOutput(JSON.stringify({ ok: false, error: { code: 'NOT_FOUND', message: 'not found' } }))
    .setMimeType(ContentService.MimeType.JSON);
}

/** 1) Run once. Creates the private deposit folder with the narrow drive.file scope. */
function spectreSetup() {
  var env = spGasEnv_();
  if (!env.store.get('CFG_FOLDER_ID')) {
    var res = env.http.fetch('https://www.googleapis.com/drive/v3/files?fields=id', {
      method: 'post', contentType: 'application/json; charset=UTF-8',
      headers: { Authorization: 'Bearer ' + env.token() },
      payload: JSON.stringify({ name: 'SPECTRE_DEPOT_TEST', mimeType: 'application/vnd.google-apps.folder' })
    });
    if (res.status !== 200) throw new Error('Folder creation failed: HTTP ' + res.status);
    env.store.set('CFG_FOLDER_ID', JSON.parse(res.text).id);
  }
  var hasTrigger = ScriptApp.getProjectTriggers().some(function (t) { return t.getHandlerFunction() === 'spectreDailyPurge'; });
  if (!hasTrigger) ScriptApp.newTrigger('spectreDailyPurge').timeBased().everyDays(1).atHour(3).create();
  console.log('SPECTRE setup OK. Folder id stored in Script Properties (CFG_FOLDER_ID).');
}

/** 2) After deploying the web app, store its /exec URL (Deploy > Manage deployments). */
function spectreSetWebAppUrl(url) {
  if (!/^https:\/\/script\.google\.com\/macros\/s\/[A-Za-z0-9_-]+\/exec$/.test(String(url))) {
    throw new Error('Expected https://script.google.com/macros/s/<id>/exec');
  }
  spGasEnv_().store.set('CFG_WEBAPP_URL', url);
}

/** 3) One individual invitation per team member. Edit the label, then Run. */
function spectreCreateInvite() {
  var label = 'membre-01'; // pseudonymous label, never a real name
  var env = spGasEnv_();
  var url = env.store.get('CFG_WEBAPP_URL') || ScriptApp.getService().getUrl();
  var inv = spAdminCreateInvite_(env, label, SPECTRE_POLICY.inviteTtlHours, url);
  console.log('Invitation (single use, expires ' + new Date(inv.expiresAt).toISOString() + '):\n' + inv.link);
  return inv.link;
}

function spectreListDevices() {
  var list = spAdminListDevices_(spGasEnv_());
  console.log(JSON.stringify(list, null, 2));
  return list;
}

/** Revoke one device: put its id (d_…) below, then Run. Other devices are unaffected. */
function spectreRevokeDevice(deviceId) {
  deviceId = deviceId || 'd_0000000000000000';
  var ok = spAdminRevokeDevice_(spGasEnv_(), deviceId);
  console.log(ok ? 'Revoked ' + deviceId : 'Unknown device ' + deviceId);
  return ok;
}

/** Emergency: revoke every enrolled device. */
function spectreRevokeAllDevices() {
  var env = spGasEnv_();
  spAdminListDevices_(env).forEach(function (d) { spAdminRevokeDevice_(env, d.id); });
}

function spectreDailyPurge() {
  console.log('Purged upload records: ' + spAdminPurge_(spGasEnv_()));
}

