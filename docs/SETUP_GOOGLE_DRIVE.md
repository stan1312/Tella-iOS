# SPECTRE Capture — Connexion à votre Google Drive (service de dépôt Apps Script)

Durée : ~20 minutes. Rien dans ce dépôt ne contient d'identifiant Google ; tout se fait dans **votre** compte.
**Commencez avec un compte Google de test** (ou au minimum un dossier de test) et uniquement des vidéos synthétiques.

## 0. Principe
- Le service tourne dans Google Apps Script **sous votre identité** (`executeAs: USER_DEPLOYING`). Votre jeton OAuth ne quitte jamais Google.
- Scope Drive minimal : `drive.file`. Le script ne voit **que** les fichiers qu'il a créés lui-même ; il ne peut lire aucun autre fichier de votre Drive.
- Le téléphone ne peut que **déposer** : aucune action lister/rechercher/télécharger/déplacer/supprimer n'existe dans l'API.
- Les octets vidéo vont directement du téléphone à `googleapis.com` (upload resumable) ; le script ne fait qu'ouvrir la session et vérifier le résultat (taille + SHA-256) avant d'émettre un reçu signé.

## 1. Préparer le compte
1. Votre compte Google personnel convient (vous en êtes le seul administrateur, aucune restriction ne bloque l'accès « Tout le monde »). Grâce au scope `drive.file`, le script ne voit **que** le dossier `SPECTRE_DEPOT_TEST` et les fichiers qu'il crée, jamais le reste de votre Drive. Activez impérativement la validation en deux étapes, idéalement avec une clé de sécurité : la sécurité des vidéos repose sur celle de votre compte.
2. Vérifiez l'espace disponible sur Drive (les vidéos 4K pèsent ~400 Mo/min).

## 2. Créer le projet Apps Script
**Option A — copier-coller (le plus simple)**
1. Allez sur https://script.google.com → *Nouveau projet*. Nommez-le `SPECTRE Depot`.
2. *Paramètres du projet* (roue dentée) → cochez « Afficher le fichier manifeste appsscript.json ».
3. Remplacez le contenu de `appsscript.json` par celui de `backend/apps-script/src/appsscript.json`.
4. Créez quatre fichiers script portant exactement ces noms et collez-y le contenu correspondant (l'ordre alphabétique compte) :
   `00_Config`, `10_Core`, `20_GasEnv`, `30_Main` (depuis `backend/apps-script/src/*.js`). Supprimez `Code.gs`.

**Option B — clasp (ligne de commande)**
```bash
npm install -g @google/clasp
clasp login                       # ouvre votre navigateur, compte de test
cd backend/apps-script
clasp create --type standalone --title "SPECTRE Depot" --rootDir src
clasp push
```
(`.clasp.json` est ignoré par git ; un modèle est fourni dans `.clasp.json.example`.)

## 3. Initialiser
1. Dans l'éditeur, sélectionnez la fonction `spectreSetup` → *Exécuter*.
2. Google demande d'autoriser l'accès. Comme le script n'est pas publié, un écran « Google n'a pas validé cette application » apparaît : *Paramètres avancés* → *Accéder à SPECTRE Depot (non sécurisé)*. Vérifiez que les autorisations demandées se limitent à : fichiers Drive créés par l'application, connexion à un service externe, gestion des déclencheurs.
3. Résultat attendu dans le journal : `SPECTRE setup OK`. Un dossier `SPECTRE_DEPOT_TEST` apparaît à la racine de votre Drive, et un déclencheur quotidien de purge (`spectreDailyPurge`, 3 h UTC) est créé.

## 4. Déployer l'application web
1. *Déployer* → *Nouveau déploiement* → type *Application Web*.
2. *Exécuter en tant que* : **Moi**. *Qui a accès* : **Tout le monde** (anonyme). C'est nécessaire car le téléphone n'a pas de compte Google ; l'authentification se fait par la signature HMAC de chaque requête.
3. Copiez l'URL qui se termine par `/exec`.
4. Dans `30_Main`, exécutez une fois `spectreSetWebAppUrl` en remplaçant temporairement l'argument, par exemple en ajoutant puis supprimant une fonction :
   ```js
   function _tmp() { spectreSetWebAppUrl('https://script.google.com/macros/s/VOTRE_ID/exec'); }
   ```
   (Exécutez `_tmp`, puis supprimez-la.)

> Compte personnel (Gmail, avec ou sans abonnement Google One) : aucune restriction. Seul un compte Google Workspace géré par une organisation peut interdire l'accès « Tout le monde » ; repli dans ce cas : Cloud Run (`docs/01_ARCHITECTURE.md`, ADR-006).

## 5. Inviter un membre de l'équipe
1. Modifiez le libellé dans `spectreCreateInvite` (`'membre-01'`, pseudonyme, jamais un vrai nom), puis *Exécuter*.
2. Le journal affiche un lien `spectre://enroll?v=1&endpoint=…&code=…` : **usage unique, expire en 48 h**.
3. Sur votre Mac, hors ligne : `./scripts/invite_qr.sh 'LE_LIEN'` affiche un QR dans le terminal. Montrez-le **en personne** ; le membre le scanne depuis SPECTRE Capture (carte « Dépôt SPECTRE » de l'accueil → *Configurer cet appareil (invitation)*). Ne l'envoyez pas par messagerie.
4. `spectreListDevices` liste les appareils (id `d_…`, libellé, date d'inscription, statut).

## 6. Révoquer (téléphone perdu, départ d'un membre)
- Un appareil : dans `spectreRevokeDevice`, remplacez `'d_0000000000000000'` par l'id, *Exécuter*. Effet immédiat : ses prochaines requêtes reçoivent `DEVICE_REVOKED`. Les autres appareils continuent.
- Urgence : `spectreRevokeAllDevices`, puis nouvelles invitations.
- Les appareils expirent automatiquement après 180 jours sans réinscription.

## 7. Paramètres et quotas (fichier `00_Config.js`, `SPECTRE_POLICY`)
20 Gio max par fichier · 60 Gio et 300 dépôts par appareil et par jour · 25 envois ouverts · 60 requêtes/min · 10 tentatives d'inscription/min · tolérance d'horloge 600 s · purge des enregistrements après 30 jours. Les quotas propres à Apps Script (durée d'exécution, appels UrlFetch par jour) s'appliquent aussi : https://developers.google.com/apps-script/guides/services/quotas.

## 8. Vérifications sur Google réel (non faisables dans l'environnement de développement)
À faire avec un compte de test et des vidéos synthétiques (`scripts/make_fixtures.sh`) :
1. Dépôt d'une vidéo courte : fichier `SPECTRE_<date>_<appareil>_<capture>.mov` présent dans `SPECTRE_DEPOT_TEST`, taille identique ; l'app affiche « Transfert confirmé — supprimée du téléphone ».
2. Coupure du Wi-Fi à mi-envoi puis retour : reprise sans recommencer depuis zéro.
3. Une vidéo de plusieurs centaines de Mo : noter le délai avant que Drive expose `sha256Checksum` (l'app affiche « Vérification sur le Drive… » ; après 3 essais elle accepte taille + MD5, conformément à la politique).
4. Révocation d'un appareil pendant un envoi : l'original reste sur le téléphone avec un message clair.
5. Vérifier dans *Exécutions* d'Apps Script qu'aucun journal ne contient d'URL de session ni de secret.
6. Notez les résultats dans `docs/TEST_REPORT.md` (section à ajouter « Google réel »).

## 9. Rotation et fin de vie
- Changer de compte Google : refaire §2–4 sur le nouveau compte, réinviter tous les appareils, révoquer tout sur l'ancien.
- Nouvelle version du script : *Déployer* → *Gérer les déploiements* → modifier le déploiement existant (l'URL `/exec` reste la même).
