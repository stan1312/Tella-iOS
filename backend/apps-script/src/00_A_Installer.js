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
  var boundary = 'spectre' + env.crypto.randomHex(8);
  var meta = { name: 'SPECTRE_INVITATION_A_SUPPRIMER.txt', parents: [env.store.get('CFG_FOLDER_ID')], mimeType: 'text/plain' };
  var body = '--' + boundary + '\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n' + JSON.stringify(meta) +
    '\r\n--' + boundary + '\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n' + link + '\n\r\n--' + boundary + '--';
  var res = env.http.fetch('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id', {
    method: 'post', contentType: 'multipart/related; boundary=' + boundary,
    headers: { Authorization: 'Bearer ' + env.token() }, payload: body
  });
  console.log(res.status === 200 ? 'SPECTRE install OK. Invitation file written in the deposit folder.' :
    'SPECTRE install OK, but the invitation file could not be written (HTTP ' + res.status + '); link above.');
  return 'OK';
}
