# 01 — Architecture de SPECTRE Capture

## 1. Flux de référence

```mermaid
sequenceDiagram
    autonumber
    participant Cam as CameraService (Tella)
    participant Vault as Coffre Tella (AES-CTR, SQLCipher)
    participant Svc as SpectreDepositService
    participant Eng as DepositEngine (SpectreCore)
    participant Box as EncryptedOutbox (AES-GCM, clé Keychain)
    participant GAS as Service de dépôt (Apps Script, compte propriétaire)
    participant Drive as Google Drive privé
    Cam->>Vault: fin d'enregistrement → chiffrement (inchangé)
    Vault-->>Svc: EncryptionService .completed (fileSource == .camera)
    Svc->>Eng: register(captureId) — tâche durable
    Svc->>Box: déchiffre la copie du coffre → outbox chiffrée + SHA-256/MD5 (contrôle croisé VaultFileDB.hash)
    Eng->>GAS: initUpload(captureId, taille, sha256, md5) signé HMAC (secret appareil)
    GAS->>Drive: crée une session resumable (jeton OAuth propriétaire, jamais renvoyé)
    GAS-->>Eng: uploadId + URL de session (capacité pour CE fichier seulement)
    Eng->>Drive: PUT des octets par blocs de 8 Mio (probe 308/Range, reprise)
    Drive-->>Eng: 200 + id du fichier (informatif)
    Eng->>GAS: finalizeUpload(uploadId, driveFileId)
    GAS->>Drive: files.get : dossier, taille, md5Checksum, sha256Checksum, appProperties
    GAS-->>Eng: reçu VERIFIED + MAC (HMAC du secret appareil) / PENDING / INCOMPLETE / MISMATCH
    Eng->>Eng: ReceiptVerifier (MAC, ids, taille, SHA-256, MD5, source) → état `confirmed` persisté
    Eng->>Box: DeletionCoordinator : temporaires → entrée du coffre → outbox (clé détruite d'abord)
```

Les octets vidéo vont **directement du téléphone à Google Drive** ; Apps Script ne manipule que des métadonnées (< 16 Ko par requête).

## 2. Composants (responsabilités du mandat → code réel)

| Responsabilité | Code | Plate-forme / test |
|---|---|---|
| Capture/Vault | `CameraService`, `VaultManager`, `VaultFilesManager` (Tella, inchangés sauf correctif `AVErrorRecordingSuccessfullyFinishedKey` et `vaultContainerExists`) ; crochet `EncryptionService.handleBackgroundResult` | iOS |
| UploadQueue | `SpectreCore/DepositEngine.swift` (`actor DepositEngine`), `Stores.swift` (`FileQueueStore`, un JSON atomique par captation) | Linux + iOS |
| Copie d'envoi | `EncryptedOutbox.swift` (format `SPXO1`, segments AES-256-GCM, AAD = en-tête+index+dernier) | Linux + iOS |
| UploadTransport | `ResumableUploader.swift` (protocole Drive resumable), `SpectreHTTPTransport.swift` (`URLSessionTransport` éphémère) | Linux + iOS |
| ReceiptVerifier | `ReceiptVerifier.swift` — seul constructeur de `VerifiedReceipt` | Linux + iOS |
| DeletionCoordinator | `DeletionCoordinator.swift` (+ `OutboxCopyHandler`, `FileCopyHandler`), `Tella/Spectre/TellaVaultCopyHandler.swift` | Linux + iOS |
| DepositBackend | `backend/apps-script/src/*.js` (`spectreHandle_`, `spEnroll_`, `spInitUpload_`, `spFinalize_`) | Apps Script ; testé en Node (vm) |
| AdminProvisioning | `30_Main.js` : `spectreSetup`, `spectreCreateInvite`, `spectreListDevices`, `spectreRevokeDevice`, `spectreRevokeAllDevices`, `spectreDailyPurge` (éditeur Apps Script uniquement) ; `Enrollment.swift`, `SpectreEnrollmentView.swift` | |
| SecurityTests | `backend/apps-script/test/backend.test.mjs`, `SpectreCore/Tests/…/ScenarioTests.swift` (T10, journaux), `scripts/secret_scan.sh`, contrôle `strings` du binaire dans `scripts/mac_build_and_test.sh` | |
| UI | `SpectreHomeCard`, `SpectreStatusView`, `SpectreRecordRow` (états du §3.1 + « confirmé mais copie locale présente » + « suppression bloquée ») | iOS |

## 3. Machine à états (persistée avant chaque effet de bord)

`awaitingPreparation → queued → uploading → awaitingVerification → confirmed → completed`, plus `blocked` (incohérence d'intégrité ou reçu invalide : **jamais** de suppression) et un `failure` attaché (réseau, quota, révocation…) avec `nextAttemptAt` (retry exponentiel borné : 8 essais par défaut, puis « à réessayer » manuel).

Garanties construites dans les types : `DeletionCoordinator.deleteLocalCopies(of:authorizedBy:)` exige un `VerifiedReceipt`, que seul `ReceiptVerifier.verify` fabrique ; le reçu stocké est **re-vérifié** au moment de supprimer (après redémarrage par exemple).

## 4. Décisions d'architecture (ADR)

### ADR-001 — Fork + module isolé (options A+B)
*Décision* : conserver Tella (caméra, coffre, verrouillage) et ajouter `SpectreCore` (logique pure, testable sans Xcode) + `Tella/Spectre/` (colle iOS). Diff Tella : 7 fichiers, ~40 lignes. *Rejeté* : nouvelle application (C) — aucun blocage mesurable.

### ADR-002 — Service de dépôt Apps Script, exécuté « en tant que » propriétaire
*Décision* : web app `executeAs: USER_DEPLOYING`, `access: ANYONE_ANONYMOUS`, scopes `drive.file` + `script.external_request` + `script.scriptapp`. Authentification applicative par appareil (HMAC-SHA256, horodatage ±10 min, nonce anti-rejeu en cache), invitations à usage unique (48 h), révocation individuelle, quotas (taille, nombre et volume par jour, envois ouverts, débit), purge quotidienne.
*Pourquoi viable* : Apps Script ne reçoit pas les octets (respect des quotas : 50 Mo de charge utile, 6 min d'exécution) ; il crée la session resumable avec `ScriptApp.getOAuthToken()` et ne renvoie que l'URL de session.
*Limites connues* : Script Properties limitées à 500 Ko (≈ 400 envois ouverts/récents ; purge à 30 jours) ; les réponses web Apps Script passent par une redirection 302 vers `script.googleusercontent.com` (gérée et testée) ; pas de code HTTP d'erreur (erreurs en JSON). **À valider par un PoC réel** : liaison de la session resumable à l'IP/origine, acceptation des PUT sans jeton depuis un autre réseau, délai d'apparition de `sha256Checksum`.
*Repli documenté* : ADR-006.

### ADR-003 — File d'envoi chiffrée séparée du coffre Tella
*Contexte* : le coffre Tella n'est déchiffrable qu'app déverrouillée (clé en mémoire) ; un envoi en arrière-plan écran verrouillé est donc impossible depuis le coffre.
*Décision* : à la fin de l'import, déchiffrer une fois la copie du coffre (app ouverte, juste après le filmage), produire un conteneur `SPXO1` chiffré AES-256-GCM avec une **clé aléatoire par captation** stockée dans le Keychain (`AfterFirstUnlockThisDeviceOnly`, non synchronisée), fichiers en `completeUntilFirstUserAuthentication`, exclus des sauvegardes. Le temporaire clair est effacé par la routine Tella `deleteTmpFiles`.
*Coût* : double occupation disque pour les vidéos en attente ; une captation non encore préparée (coffre verrouillé trop tôt) le sera au prochain déverrouillage (`prepareAwaitingCaptures`).
*Bénéfice* : effacement cryptographique (destruction de la clé) ; envoi possible écran verrouillé quand iOS accorde du temps.

### ADR-004 — Reçu authentifié et double vérification
Le serveur vérifie lui-même le fichier Drive (dossier, `appProperties.spectreUploadId`, taille, MD5 toujours, SHA-256 si exposé ; sinon `PENDING` puis repli MD5+taille après 3 constats, réglable `acceptMd5Fallback`). Il signe le reçu par HMAC avec le secret de l'appareil ; le client recompare tout à ses empreintes locales et à l'id Drive reçu lors du dernier bloc.

### ADR-005 — Intégration Xcode : sources compilées dans la cible
`SpectreCore` est un paquet SwiftPM (tests Linux/macOS) **et** ses sources sont ajoutées à la cible `Tella` par `scripts/xcode_integrate_spectre.rb` (évite une référence de paquet local non vérifiable sans Xcode). Collisions de noms traitées (`SpectreHTTPRequest`…). Conséquence : dans l'app, `VerifiedReceipt.init` est visible du module ; la garantie reste assurée par revue et tests. Alternative possible sur Mac : glisser `SpectreCore/` comme paquet local.

### ADR-006 — Repli si Apps Script ne convient pas : Cloud Run minimal
Même API (`enroll`, `initUpload`, `finalizeUpload`), même logique (`10_Core.js` est indépendant d'Apps Script via `env`), compte de service ou OAuth propriétaire côté serveur, secrets dans Secret Manager, stockage des appareils dans Firestore. Prérequis : projet Google Cloud avec facturation activée (coût faible mais non nul), domaine `*.run.app` (déjà accepté par `EnrollmentParser`). **Aucun déploiement effectué** ; à décider par le propriétaire. *Interdit* : compte Google partagé sur les téléphones.

### ADR-007 — Arrière-plan iOS honnête
`beginBackgroundTask` après chaque passage + `BGProcessingTask` (`<bundle>.spectre-upload`, réseau requis). Le transfert de fond `URLSession.background` n'est **pas** encore utilisé pour les blocs (il exigerait des fichiers de blocs en clair sur disque) : à évaluer après les essais sur iPhone. L'interface indique qu'iOS peut retarder l'envoi.

## 5. Ce qui n'a pas été changé dans Tella
Chiffrement du coffre, déverrouillage, verrouillage à la mise en arrière-plan, effacement après tentatives ratées (étendu aux données SPECTRE), connecteurs Tella Web/Nextcloud/Dropbox/Drive personnel (non utilisés, laissés en place).
