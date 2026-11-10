/**
 * One-click install (owner runs it once from the editor, after `clasp deploy`):
 * deposit folder + daily purge trigger, web app URL (from the git-ignored
 * 99_Local.js written on the owner's Mac), first single-use invitation.
 * The invitation link is also written to SPECTRE_INVITATION_A_SUPPRIMER.txt in
 * the deposit folder so the owner's Mac can turn it into a QR code; delete it after use.
 */
function spectreInstall() {
  spectreSetup();
  var env = spGasEnv_();
  if (!env.store.get('CFG_WEBAPP_URL') && typeof SPECTRE_LOCAL_WEBAPP_URL === 'string') {
    spectreSetWebAppUrl(SPECTRE_LOCAL_WEBAPP_URL);
  }
  if (!env.store.get('CFG_WEBAPP_URL')) throw new Error('Web app URL unknown: deploy the web app first.');
  var link = spectreCreateInvite();
  var ok = spWriteInvitationFile_(env, link);
  console.log(ok ? 'SPECTRE install OK. Invitation file written in the deposit folder.' :
    'SPECTRE install OK, but the invitation file could not be written; link above.');
  return 'OK';
}

/**
 * New colleague: one single-use invitation, labelled membre-02, membre-03…
 * (pseudonyms only). The link goes to SPECTRE_INVITATION_A_SUPPRIMER.txt in the
 * main deposit folder; the owner's Mac turns it into a QR code and deletes the file.
 * The colleague scans the QR in person: never send it by messaging.
 */
function spectreNouvelleInvitation() {
  var env = spGasEnv_();
  var n = Number(env.store.get('CFG_INVITE_COUNTER') || '1') + 1;
  env.store.set('CFG_INVITE_COUNTER', String(n));
  var label = 'membre-' + (n < 10 ? '0' : '') + n;
  var url = env.store.get('CFG_WEBAPP_URL') || ScriptApp.getService().getUrl();
  var inv = spAdminCreateInvite_(env, label, SPECTRE_POLICY.inviteTtlHours, url);
  var ok = spWriteInvitationFile_(env, inv.link);
  console.log('Invitation ' + label + ' created (single use, expires ' + new Date(inv.expiresAt).toISOString() + '). ' +
    (ok ? 'File written in the deposit folder.' : 'The invitation file could not be written.'));
  return label;
}

/**
 * New demonstration: creates a dated sub-folder (MANIF_YYYY-MM-DD, rename it freely
 * in Drive) inside the main deposit folder; every later deposit goes there.
 * Uploads already in progress finish in the previous folder. No code to edit.
 */
function spectreNouvelleManif() {
  var env = spGasEnv_();
  var root = spRootFolderId_(env);
  var name = 'MANIF_' + new Date(env.now()).toISOString().slice(0, 10);
  var id = spCreateDriveFolder_(env, name, root);
  env.store.set('CFG_FOLDER_ID', id);
  console.log('Folder ' + name + ' created; new deposits go there. You can rename it in Drive.');
  return name;
}

/** Back to the main deposit folder (e.g. between two demonstrations). */
function spectreDossierPrincipal() {
  var env = spGasEnv_();
  env.store.set('CFG_FOLDER_ID', spRootFolderId_(env));
  console.log('New deposits go to the main deposit folder again.');
}

function spRootFolderId_(env) {
  var root = env.store.get('CFG_ROOT_FOLDER_ID') || env.store.get('CFG_FOLDER_ID');
  if (!root) throw new Error('Run spectreInstall first.');
  env.store.set('CFG_ROOT_FOLDER_ID', root);
  return root;
}

function spCreateDriveFolder_(env, name, parentId) {
  var meta = { name: name, mimeType: 'application/vnd.google-apps.folder' };
  if (parentId) meta.parents = [parentId];
  var res = env.http.fetch(spApiBase_(env) + '/drive/v3/files?fields=id', {
    method: 'post', contentType: 'application/json; charset=UTF-8',
    headers: { Authorization: 'Bearer ' + env.token() }, payload: JSON.stringify(meta)
  });
  if (res.status !== 200) throw new Error('Folder creation failed: HTTP ' + res.status + ' ' + spApiErrorReason_(res.text));
  return JSON.parse(res.text).id;
}

/** Writes the invitation link to a text file in the main deposit folder. Never logged. */
function spWriteInvitationFile_(env, link) {
  var boundary = 'spectre' + env.crypto.randomHex(8);
  var meta = { name: 'SPECTRE_INVITATION_A_SUPPRIMER.txt', parents: [spRootFolderId_(env)], mimeType: 'text/plain' };
  var body = '--' + boundary + '\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n' + JSON.stringify(meta) +
    '\r\n--' + boundary + '\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n' + link + '\n\r\n--' + boundary + '--';
  var res = env.http.fetch(spApiBase_(env) + '/upload/drive/v3/files?uploadType=multipart&fields=id', {
    method: 'post', contentType: 'multipart/related; boundary=' + boundary,
    headers: { Authorization: 'Bearer ' + env.token() }, payload: body
  });
  return res.status === 200;
}

function spApiBase_(env) {
  return env.store.get('CFG_TEST_MODE') === 'true' && env.store.get('CFG_DRIVE_API_BASE') || 'https://www.googleapis.com';
}
