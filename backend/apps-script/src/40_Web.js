/**
 * SPECTRE Capture — web pages.
 *
 *  GET /exec?i=<code>  public invitation page (one tap: install the app, then join).
 *                      Shows nothing but buttons built from the code; the code is
 *                      checked only when the phone enrols (single use, 48 h).
 *  GET /exec           owner's control page ("Pilotage"): new demonstration with a
 *                      name, back to the main folder, invitations, APK link, devices.
 *                      Anyone else gets the same NOT_FOUND as before.
 *
 * Because an HtmlService page can call ANY public server function through
 * google.script.run, every public function except doGet/doPost/spectreDailyPurge
 * starts with spRequireOwner_(): an anonymous visitor has no identity (blank
 * e-mail) and is refused.
 */

function doGet(e) {
  var params = (e && e.parameter) || {};
  if (typeof params.i === 'string') return spInvitePage_(spGasEnv_(), params.i);
  if (spIsOwner_()) {
    return HtmlService.createHtmlOutput(spAdminPageHtml_()).setTitle('SPECTRE · Pilotage')
      .addMetaTag('viewport', 'width=device-width, initial-scale=1');
  }
  return ContentService.createTextOutput(JSON.stringify({ ok: false, error: { code: 'NOT_FOUND', message: 'not found' } }))
    .setMimeType(ContentService.MimeType.JSON);
}

// ---------------------------------------------------------------- owner check

function spIsOwner_() {
  try {
    var active = Session.getActiveUser().getEmail();
    var owner = Session.getEffectiveUser().getEmail();
    return !!active && active === owner;
  } catch (err) { return false; }
}

function spRequireOwner_() {
  if (!spIsOwner_()) throw new Error('Réservé au propriétaire du service.');
}

// ---------------------------------------------------------------- invitation links

var SP_CODE_RE_ = /^[A-Za-z0-9-]{20,64}$/;

/** https link to send by message: <web app>/exec?i=<code>. Single use, expires like the code. */
function spInviteHttpsLink_(env, code) {
  var url = env.store.get('CFG_WEBAPP_URL') || ScriptApp.getService().getUrl();
  return url + '?i=' + code;
}

function spEsc_(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function spInvitePage_(env, code) {
  var endpoint = env.store.get('CFG_WEBAPP_URL') || ScriptApp.getService().getUrl();
  var apk = env.store.get('CFG_APK_URL') || '';
  var valid = SP_CODE_RE_.test(code);
  var q = 'enroll?v=1&endpoint=' + encodeURIComponent(endpoint) + '&code=' + (valid ? code : '');
  var deep = 'spectre://' + q;
  var intent = 'intent://' + q + '#Intent;scheme=spectre;' +
    (apk ? 'S.browser_fallback_url=' + encodeURIComponent(apk) + ';' : '') + 'end';
  var ios = env.store.get('CFG_IOS_URL') || '';
  // Step 1 depends on the phone: the APK on Android, TestFlight on iPhone (chosen by the script
  // below; without JavaScript both are shown).
  var install = (apk || ios)
    ? '<p class="step">1. Installer l\'application</p>' +
      (apk ? '<div data-os="android"><a class="btn" target="_top" href="' + spEsc_(apk) + '">Télécharger SPECTRE Capture (Android)</a>' +
             '<p class="muted">Ouvrez le fichier téléchargé et autorisez l\'installation. Ouvrez l\'appli une fois et créez votre code, puis revenez ici.</p></div>' : '') +
      (ios ? '<div data-os="ios"><a class="btn" target="_top" href="' + spEsc_(ios) + '">Installer SPECTRE Capture (iPhone, TestFlight)</a>' +
             '<p class="muted">Installez TestFlight si demandé, puis SPECTRE Capture. Ouvrez l\'appli une fois et créez votre code, puis revenez ici.</p></div>' : '')
    : '';
  var body = valid
    ? '<p class="muted">Invitation personnelle : elle ne sert qu\'une fois et expire après 48 h.</p>' + install +
      '<p class="step">' + (install ? '2. ' : '') + 'Rejoindre le dépôt</p>' +
      '<a class="btn fill" id="join" target="_top" href="' + spEsc_(deep) + '" data-android="' + spEsc_(intent) + '">Ouvrir dans SPECTRE Capture</a>' +
      '<p class="muted">Si rien ne se passe : copiez l\'adresse de cette page, puis ouvrez SPECTRE Capture, elle la reconnaîtra.</p>'
    : '<p>Lien d\'invitation incomplet. Demandez-en un nouveau.</p>';
  var html = '<!doctype html><html><head><meta charset="utf-8"><style>' +
    'body{background:#000;color:#fff;font:16px/1.45 -apple-system,Roboto,Helvetica,Arial,sans-serif;margin:0;padding:24px;max-width:520px}' +
    'h1{font-size:20px;letter-spacing:.12em;margin:0 0 16px}.step{font-weight:700;margin:24px 0 8px}' +
    '.muted{color:#999;font-size:14px}.btn{display:block;text-align:center;padding:16px;border:2px solid #fff;color:#fff;' +
    'text-decoration:none;font-weight:700;letter-spacing:.06em;text-transform:uppercase}.fill{background:#fff;color:#000}' +
    '</style></head><body><h1>SPECTRE CAPTURE</h1>' + body +
    '<script>(function(){var ua=navigator.userAgent,android=/Android/i.test(ua),ios=/iPhone|iPad|iPod/i.test(ua);' +
    'var a=document.getElementById("join");if(a&&android)a.href=a.getAttribute("data-android");' +
    'var os=android?"android":ios?"ios":"";if(os){var l=document.querySelectorAll("[data-os]");var has=false;' +
    'for(var i=0;i<l.length;i++)if(l[i].getAttribute("data-os")===os)has=true;' +
    'if(has)for(var j=0;j<l.length;j++)if(l[j].getAttribute("data-os")!==os)l[j].style.display="none";}})();</script></body></html>';
  return HtmlService.createHtmlOutput(html).setTitle('SPECTRE Capture · Invitation')
    .addMetaTag('viewport', 'width=device-width, initial-scale=1');
}

// ---------------------------------------------------------------- control page actions (owner only)

function spectrePilotageEtat() {
  spRequireOwner_();
  var env = spGasEnv_();
  var root = spRootFolderId_(env);
  var current = env.store.get('CFG_FOLDER_ID') || root;
  return {
    depositName: spFolderName_(env, current),
    rootName: spFolderName_(env, root),
    isEvent: current !== root,
    apkUrl: env.store.get('CFG_APK_URL') || '',
    iosUrl: env.store.get('CFG_IOS_URL') || '',
    devices: spAdminListDevices_(env).sort(function (a, b) { return (b.createdAt || 0) - (a.createdAt || 0); })
  };
}

function spectrePilotageManif(name) {
  spRequireOwner_();
  return spectreNouvelleManif(name);
}

function spectrePilotageDossierPrincipal() {
  spRequireOwner_();
  spectreDossierPrincipal();
  return true;
}

/** New invitation for the control page: returns the https link and a ready-to-send message. */
function spectrePilotageInviter(label) {
  spRequireOwner_();
  var env = spGasEnv_();
  label = spCleanName_(label, 40) || spNextMemberLabel_(env);
  var url = env.store.get('CFG_WEBAPP_URL') || ScriptApp.getService().getUrl();
  var inv = spAdminCreateInvite_(env, label, SPECTRE_POLICY.inviteTtlHours, url);
  var link = spInviteHttpsLink_(env, inv.code);
  return {
    label: label, link: link, expiresAt: inv.expiresAt,
    message: 'Rejoins le dépôt SPECTRE : ouvre ce lien sur ton téléphone (Android ou iPhone), installe l\'appli, crée ton code, puis reviens sur le lien et touche « Ouvrir dans SPECTRE Capture ».\n' +
      link + '\n(Lien personnel : une seule utilisation, valable 48 h.)'
  };
}

function spectrePilotageLienApk(url) {
  spRequireOwner_();
  return spSetLink_('CFG_APK_URL', url);
}

/** TestFlight public link (https://testflight.apple.com/join/…) shown to iPhones on the invitation page. */
function spectrePilotageLienIos(url) {
  spRequireOwner_();
  return spSetLink_('CFG_IOS_URL', url);
}

function spSetLink_(key, url) {
  url = String(url || '').trim();
  if (url && !/^https:\/\/[^\s"'<>]{4,500}$/.test(url)) throw new Error('Adresse invalide : elle doit commencer par https://');
  var env = spGasEnv_();
  if (url) env.store.set(key, url); else env.store.del(key);
  return url;
}

function spectrePilotageRevoquer(deviceId) {
  spRequireOwner_();
  if (!/^d_[0-9a-f]{16}$/.test(String(deviceId))) throw new Error('Identifiant invalide');
  return spAdminRevokeDevice_(spGasEnv_(), deviceId);
}

// ---------------------------------------------------------------- helpers

/** Folder name shown on phones and on the control page: no control characters or slashes. */
function spCleanName_(name, max) {
  return String(name === null || name === undefined ? '' : name).replace(/[\u0000-\u001f\u007f/\\]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max || 80);
}

function spNextMemberLabel_(env) {
  var n = Number(env.store.get('CFG_INVITE_COUNTER') || '1') + 1;
  env.store.set('CFG_INVITE_COUNTER', String(n));
  return 'membre-' + (n < 10 ? '0' : '') + n;
}

function spFolderName_(env, folderId) {
  try {
    var f = spDriveGet_(env, spConfig_(env), folderId);
    return f && typeof f.name === 'string' ? f.name : '';
  } catch (err) { return ''; }
}

function spAdminPageHtml_() {
  return '<!doctype html><html><head><meta charset="utf-8"><style>' +
    'body{background:#000;color:#fff;font:16px/1.45 -apple-system,Roboto,Helvetica,Arial,sans-serif;margin:0;padding:20px;max-width:640px}' +
    'h1{font-size:18px;letter-spacing:.14em;margin:0 0 4px}h2{font-size:13px;letter-spacing:.14em;color:#999;margin:28px 0 8px;text-transform:uppercase}' +
    '.box{border:2px solid #fff;padding:16px}.big{font-size:22px;font-weight:700}.muted{color:#999;font-size:14px}' +
    'input,textarea{width:100%;box-sizing:border-box;background:#111;color:#fff;border:1px solid #666;padding:12px;font:inherit;margin:6px 0}' +
    'button{background:#fff;color:#000;border:0;padding:12px 16px;font:inherit;font-weight:700;letter-spacing:.04em;cursor:pointer;margin:4px 8px 4px 0}' +
    'button.ghost{background:#000;color:#fff;border:2px solid #fff}button:disabled{opacity:.4}' +
    'table{width:100%;border-collapse:collapse;font-size:14px}td{border-top:1px solid #333;padding:8px 4px}.err{color:#ff6b6b}' +
    '</style></head><body>' +
    '<h1>SPECTRE · PILOTAGE</h1><div class="muted">Page réservée au propriétaire du service.</div>' +
    '<h2>Les dépôts arrivent dans</h2><div class="box"><div class="big" id="dest">…</div><div class="muted" id="destNote"></div></div>' +
    '<h2>Nouvelle manif</h2><input id="manif" placeholder="Nom du dossier, ex. 2026-11-15 Manif Lausanne" maxlength="80">' +
    '<button id="bManif">Créer et y envoyer tous les dépôts</button><button class="ghost" id="bMain">Revenir au dossier principal</button>' +
    '<div class="muted">Le nom s\'affiche sur les téléphones : n\'y mettez rien qui mette quelqu\'un en danger. Les envois déjà commencés se terminent dans l\'ancien dossier.</div>' +
    '<h2>Inviter quelqu\'un</h2><input id="label" placeholder="Surnom (facultatif, jamais le vrai nom)" maxlength="40">' +
    '<button id="bInvite">Créer un lien d\'invitation</button>' +
    '<div id="inv" style="display:none"><textarea id="msg" rows="5" readonly></textarea>' +
    '<button id="bCopy">Copier le message</button><div class="muted">Un lien par personne : une seule utilisation, valable 48 h.</div></div>' +
    '<h2>Lien de téléchargement de l\'APK</h2><input id="apk" placeholder="https://drive.google.com/…">' +
    '<button class="ghost" id="bApk">Enregistrer</button><div class="muted">Montré aux téléphones Android sur la page d\'invitation.</div>' +
    '<h2>Lien TestFlight (iPhone)</h2><input id="ios" placeholder="https://testflight.apple.com/join/…">' +
    '<button class="ghost" id="bIos">Enregistrer</button><div class="muted">Montré aux iPhone sur la page d\'invitation.</div>' +
    '<h2>Téléphones inscrits</h2><table id="dev"></table>' +
    '<p class="err" id="err"></p>' +
    '<script>' +
    'var $=function(i){return document.getElementById(i)};' +
    'function busy(b){Array.prototype.forEach.call(document.querySelectorAll("button"),function(x){x.disabled=b})}' +
    'function run(fn,arg,ok){busy(true);$("err").textContent="";var r=google.script.run.withSuccessHandler(function(v){busy(false);ok&&ok(v)})' +
    '.withFailureHandler(function(e){busy(false);$("err").textContent=(e&&e.message)||String(e)});r[fn](arg)}' +
    'function d(t){return t?new Date(t).toLocaleString("fr-CH"):"–"}' +
    'function load(){run("spectrePilotageEtat",null,function(s){$("dest").textContent=s.depositName||"(sans nom)";' +
    '$("destNote").textContent=s.isEvent?"Dossier de manif, dans "+s.rootName:"Dossier principal";$("apk").value=s.apkUrl;$("ios").value=s.iosUrl;' +
    'var t=$("dev");t.innerHTML="";s.devices.forEach(function(x){var tr=document.createElement("tr");' +
    '[x.label||x.id,x.status==="active"?"actif":"révoqué","vu "+d(x.lastSeenAt)].forEach(function(c){var td=document.createElement("td");td.textContent=c;tr.appendChild(td)});' +
    'var td=document.createElement("td");if(x.status==="active"){var b=document.createElement("button");b.className="ghost";b.textContent="Révoquer";' +
    'b.onclick=function(){if(confirm("Révoquer "+(x.label||x.id)+" ? Ce téléphone ne pourra plus déposer."))run("spectrePilotageRevoquer",x.id,load)};td.appendChild(b)}' +
    'tr.appendChild(td);t.appendChild(tr)});if(!s.devices.length)t.innerHTML="<tr><td class=muted>Aucun</td></tr>"})}' +
    '$("bManif").onclick=function(){var n=$("manif").value.trim();if(!n){$("err").textContent="Donnez un nom au dossier.";return}' +
    'run("spectrePilotageManif",n,function(){$("manif").value="";load()})};' +
    '$("bMain").onclick=function(){run("spectrePilotageDossierPrincipal",null,load)};' +
    '$("bInvite").onclick=function(){run("spectrePilotageInviter",$("label").value,function(v){$("msg").value=v.message;$("inv").style.display="block";$("label").value="";load()})};' +
    '$("bCopy").onclick=function(){$("msg").select();try{navigator.clipboard.writeText($("msg").value).then(function(){$("bCopy").textContent="Copié"},function(){document.execCommand("copy");$("bCopy").textContent="Copié"})}catch(e){document.execCommand("copy");$("bCopy").textContent="Copié"}};' +
    '$("bApk").onclick=function(){run("spectrePilotageLienApk",$("apk").value,load)};' +
    '$("bIos").onclick=function(){run("spectrePilotageLienIos",$("ios").value,load)};' +
    'load();' +
    '</script></body></html>';
}
