# SPECTRE Capture — Modèle de menaces (STRIDE)

Statut : **relecture sécurité recommandée** avant toute donnée de terrain réelle. Déploiement prévu : compte Google **personnel** du responsable (avec abonnement de stockage), dont il est le seul administrateur.
Ce document décrit le système tel qu'il est implémenté dans ce dépôt (branche `feature/spectre-deposit-drive`).
Les tests cités sont des tests réellement exécutés sur le mock (voir `docs/TEST_REPORT.md`). Un comportement observé sur le mock ne prouve rien sur Google Drive réel.

## 1. Actifs et frontières de confiance

| Actif | Où il vit | Protection |
|---|---|---|
| Vidéo originale (clair) | `tmp/` d'AVCaptureMovieFileOutput, quelques secondes à minutes | Supprimée dès que le chiffrement Tella réussit (comportement Tella). Protection de données iOS du conteneur |
| Copie coffre Tella | Conteneur Tella, AES-256-CTR, clé dérivée du code Tella | Inaccessible tant que Tella est verrouillé |
| Copie d'envoi (outbox SPXO1) | `Application Support/Spectre/outbox`, AES-256-GCM segmenté, clé par capture | Clé dans le Keychain `AfterFirstUnlockThisDeviceOnly`, non synchronisée ; exclu de la sauvegarde |
| Secret de l'appareil (HMAC) | Keychain du téléphone, Script Properties côté propriétaire | Jamais dans l'IPA, jamais dans les journaux |
| URL de session resumable | Mémoire + file JSON locale (chiffrée par la protection de données iOS) | Jamais journalisée (`SpectreLog` caviarde les URL) |
| Jeton OAuth du propriétaire | Uniquement chez Google (Apps Script `executeAs USER_DEPLOYING`) | Jamais transmis au téléphone (test backend « owner OAuth token never appears ») |
| Dossier de dépôt Drive | Drive du propriétaire, dossier `SPECTRE_DEPOT_TEST` | Scope `drive.file` : le script ne voit que les fichiers qu'il a créés |
| Reçu de dépôt | Réponse `FINALIZE` signée HMAC | Seul `ReceiptVerifier` peut produire un `VerifiedReceipt` |

Frontières : (A) téléphone ↔ Apps Script (HTTPS, requêtes signées HMAC) ; (B) téléphone ↔ `googleapis.com` upload resumable (HTTPS, URL de session porteuse) ; (C) Apps Script ↔ Drive API (OAuth du propriétaire) ; (D) application ↔ coffre Tella (même processus).

## 2. Analyse STRIDE par scénario

### S1 — Téléphone saisi ou perdu (déverrouillé ou non)
- **I (divulgation)** : si le téléphone n'a jamais été déverrouillé depuis le démarrage, Keychain et outbox sont inaccessibles. Après le premier déverrouillage (`AfterFirstUnlock`), un attaquant capable d'extraire le système de fichiers d'un téléphone allumé peut lire la clé de l'outbox et la copie d'envoi en attente. **Compromis assumé** : ce choix est nécessaire pour que l'envoi continue en arrière-plan écran verrouillé. Alternative plus stricte (`WhenUnlocked`) documentée : l'envoi ne progresserait qu'écran déverrouillé.
- Les vidéos **déjà déposées et vérifiées** ne sont plus sur le téléphone (copies supprimées après reçu vérifié, clé outbox détruite = effacement cryptographique, test `testDestroyIsCryptographicErasure`).
- Le téléphone ne peut **ni lister, ni lire, ni télécharger, ni supprimer** les archives (T10, test backend « web API has no list/search/read/download/move/delete action »).
- **S (usurpation)** : avec le téléphone, un attaquant peut **déposer** de nouveaux fichiers jusqu'à la révocation. Mitigation : `spectreRevokeDevice` (T09), quotas par appareil, fichiers nommés par appareil (`_<dev6>_`) donc triables.
- Résiduel : la copie coffre Tella reste protégée par le code Tella ; les fonctions Tella (effacement rapide, suppression après N échecs) restent actives et effacent aussi les données SPECTRE (`deleteAfterMaxAttempts`).

### S2 — Fichier temporaire en clair
- **I** : la vidéo existe en clair dans `tmp/` entre la fin d'enregistrement et la fin du chiffrement Tella. Hérité de Tella. Résiduel : l'effacement sur mémoire flash n'est pas garanti physiquement (wear levelling) ; seule la protection de données iOS (clés de classe effacées) protège ces blocs.

### S3 — Réseau hostile / interception
- **T/I** : TLS système (ATS) vers `script.google.com` et `googleapis.com`. Le schéma d'inscription n'accepte que `https://script.google.com/...` ou `*.run.app` (`EnrollmentParser`, `testParser`).
- **R/T (rejeu)** : chaque requête porte horodatage + nonce + HMAC ; rejeu → `REPLAY`, horloge > 600 s → `AUTH_INVALID` (tests backend « request authentication »).
- Pas d'épinglage de certificat (non implémenté) : un proxy TLS installé par profil MDM pourrait intercepter. Résiduel documenté.

### S4 — Vol de l'URL de session resumable
- **E/T** : l'URL de session permet d'écrire **ce seul fichier** jusqu'à sa complétion (≈ 1 semaine de validité côté Google). Elle ne donne aucun accès en lecture au Drive (test « device credentials + session URL give no read access to Drive », sur mock). Elle n'est jamais journalisée. Si un attaquant y écrit d'autres octets, la vérification serveur taille + SHA-256 échoue → `MISMATCH`, aucun reçu, aucune suppression (T07).
- À vérifier sur Google réel : liaison éventuelle de la session à l'IP, comportement d'un PUT sans jeton.

### S5 — Faux succès / serveur menteur
- **T** : aucune suppression sur clic, sur 100 %, sur réponse HTTP initiale ni sur absence d'erreur. La suppression exige un `VerifiedReceipt` : ids, taille exacte, SHA-256 (ou MD5 selon la politique), `checksumSource`, statut `VERIFIED`, MAC HMAC valide, Drive id égal à celui renvoyé par l'upload. Tests : T06 (HTTP OK mais fichier absent), T07 (taille/checksum différents), T07b (reçu altéré), `testEveryFieldIsChecked`, `testForgedMacRejected`, `testExpiredSessionAndLyingServer` (offset serveur incohérent).
- `DeletionCoordinator` re-vérifie le reçu au moment de supprimer.

### S6 — Compte Google du propriétaire compromis
- Hors du contrôle de l'application : un attaquant avec le compte du propriétaire lit tout le Drive. Le compte étant **personnel** (Gmail, photos, autres fichiers), sa compromission exposerait aussi les vidéos : validation en deux étapes obligatoire (clé de sécurité ou application d'authentification, pas de SMS), Protection Avancée Google recommandée, vérifier régulièrement les appareils connectés et les applications autorisées. Le scope `drive.file` garantit seulement que le script SPECTRE ne voit que ses propres fichiers, pas le reste du Drive. Le téléphone ne détient aucun moyen d'accès à ce compte.

### S7 — Script Properties
- **I** : les secrets HMAC des appareils sont stockés dans les Script Properties du projet Apps Script. Toute personne éditrice du projet peut les lire. Mitigation : projet non partagé, propriétaire unique ; `spectreRevokeAllDevices` en cas de doute. Résiduel accepté pour la solution « Apps Script d'abord » ; l'alternative Cloud Run + Secret Manager est décrite dans `docs/01_ARCHITECTURE.md` (ADR).

### S8 — Déni de service / épuisement de quota
- **D** : 60 requêtes/min/appareil, 300 dépôts/jour, 60 Gio/jour, 25 uploads ouverts, 20 Gio/fichier, 10 tentatives d'inscription/min (tests « per-device rate limit », « per-device quotas », « enrol brute force is rate limited »). Drive plein → `DRIVE_QUOTA` explicite, l'original est conservé (T11). Quotas Apps Script (temps d'exécution, UrlFetch/jour) : à mesurer sur compte réel.
- Un appareil compromis peut remplir le quota journalier ; la révocation l'arrête.

### S9 — Invitation interceptée
- **S** : le code d'invitation est à usage unique, expire en 48 h, l'inscription est limitée en débit. Remise en personne par QR (`scripts/invite_qr.sh`, généré hors ligne). Un code volé avant usage permet d'inscrire un appareil : la liste `spectreListDevices` le révèle et il se révoque.

### S10 — Journaux
- **I** : `SpectreLog` caviarde URL et longues valeurs hexadécimales (`testLogRedaction`, `testLogsContainNoSensitiveData`). Côté backend, aucun secret, jeton ni URL de session dans les journaux (test « owner OAuth token never appears in any response or log »).

### S11 — Sauvegarde iCloud / transfert d'appareil
- Outbox exclue de la sauvegarde ; éléments Keychain `ThisDeviceOnly` non synchronisables : une restauration sur un autre téléphone ne transporte ni secret ni copies d'envoi. Le coffre Tella suit le comportement Tella d'origine.

### S12 — Répudiation
- **R** : chaque fichier Drive porte `appProperties` (`spectreUploadId`, `spectreCaptureId`, `spectreDeviceId`) et un nom contenant l'appareil ; le backend conserve l'état par upload pendant 30 jours. Pas de signature par l'appareil de l'heure de capture : l'horodatage de nom est celui du serveur.

### S13 — Confidentialité vis-à-vis de Google
- Les vidéos sont stockées **en clair chez Google** (le chiffrement outbox ne couvre que le téléphone). Google, en tant que sous-traitant, et toute réquisition visant le compte du propriétaire y ont accès. Décision du responsable : acceptable ou non selon la sensibilité des images et les personnes filmées ; un chiffrement de bout en bout (clé publique de l'équipe) casserait la vérification SHA-256 côté Drive telle que conçue et est hors périmètre.

### S14 — Droit à l'effacement / gouvernance
- La suppression des archives se fait par le propriétaire dans Drive (le système n'offre volontairement aucune suppression distante). Prévoir une procédure écrite (qui demande, qui supprime, corbeille Drive vidée).

## 2 bis. Spécificités Android (APK `spectre`)
- **A-S1 (équivalent S1)** : secret d'appareil et clé de l'outbox scellés par une clé AES-GCM du Keystore Android (non exportable, liée au matériel quand le téléphone le permet), fichiers dans `noBackupFilesDir` (stockage chiffré par identifiant, accessible **après le premier déverrouillage**). Même compromis que l'iPhone : l'envoi continue écran verrouillé ; un attaquant capable d'extraire la mémoire d'un téléphone allumé déjà déverrouillé une fois peut lire les copies en attente. Pas d'exigence d'authentification par clé (`setUserAuthenticationRequired`) pour cette raison.
- **A-S2** : la caméra Tella écrit la vidéo en clair dans un fichier temporaire avant de la chiffrer dans le coffre (hérité de Tella, comme S2). Le dictaphone écrit directement dans le coffre chiffré. La copie d'envoi est produite **depuis le coffre déchiffré en flux**, sans fichier temporaire en clair (ré-encapsulation `.m4a` en deux passes, empreinte vérifiée).
- **A-S9 (invitation)** : le lien `spectre://enroll` peut être ouvert par n'importe quelle app ou page web ; l'app exige le **déverrouillage Tella** et une **confirmation explicite** affichant l'hôte du service avant d'enregistrer quoi que ce soit (et avertit si une configuration existante serait remplacée). Seuls `https://script.google.com/...` et `*.run.app` sont acceptés.
- **A-S11 (sauvegarde)** : `allowBackup=false` (Tella) et données SPECTRE dans `noBackupFilesDir` : ni sauvegarde Google, ni transfert d'appareil.
- **A-S15 (distribution hors Play Store)** : l'APK est installé depuis une source « inconnue ». Risque : un faux APK présenté comme SPECTRE. Mitigation : APK remis en personne (QR), empreinte SHA-256 du fichier et du certificat publiées dans le résumé CI ; Android refuse toute mise à jour signée par une autre clé. La clé de signature reste au propriétaire (secret GitHub chiffré + copie hors ligne). Désactiver l'autorisation « sources inconnues » après installation.
- **A-S16 (arrière-plan)** : WorkManager (service de premier plan `dataSync`, notification neutre `VISIBILITY_SECRET`). Certains fabricants suspendent les tâches en arrière-plan : l'envoi reprend au déverrouillage suivant de l'app ; réglage batterie « sans restriction » conseillé (`docs/ANDROID_APK.md` §4).

## 3. Risques résiduels principaux (synthèse)
1. Téléphone allumé saisi après premier déverrouillage : copies en attente lisibles par un attaquant avancé (compromis `AfterFirstUnlock`).
2. Fichier `tmp/` en clair hérité de Tella ; effacement flash non garanti.
3. Vidéos en clair chez Google ; sécurité totale dépendante du compte propriétaire.
4. Un téléphone compromis peut déposer jusqu'à révocation.
5. Secrets d'appareils lisibles par les éditeurs du projet Apps Script.
6. Pas d'épinglage TLS.
7. Comportements Google réels (session, latence de `sha256Checksum`, quotas Apps Script) **non vérifiés** dans cet environnement.
8. Build iOS et comportement en arrière-plan **non vérifiés** (pas de Mac ici).
9. Android : comportement réel sur téléphone (caméra, arrière-plan selon fabricant, Keystore) **non vérifié** ici (pas d'appareil ni d'émulateur) ; APK distribué hors Play Store.

## 4. Validation requise
- Relecture sécurité recommandée (ce document + `docs/01_ARCHITECTURE.md` + code `SpectreCore/` et `backend/apps-script/src/`).
- Réflexion du responsable sur S13/S14 (confidentialité chez Google, effacement), selon les personnes filmées.
- Tant que les tests réels (Mac, Google, iPhone) ne sont pas concluants : vidéos fictives et dossier de test uniquement.
