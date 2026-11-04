# 00 — Audit de Tella iOS (base du fork SPECTRE Capture)

*Rédigé le 2026-11-04. Toutes les références ci-dessous ont été lues dans le dépôt cloné ; rien n'est supposé.*

## 1. Environnement d'audit

| Élément | Valeur observée |
|---|---|
| Machine | Linux x86_64 (Ubuntu 24.04, conteneur cloud), **pas de macOS, pas de Xcode** |
| Swift | 6.0.3 (paquet Ubuntu `swiftlang`, extrait localement) — suffit pour compiler/tester `SpectreCore`, pas l'app iOS |
| Node.js | 22.23.4 (tests backend + faux Drive) |
| ffmpeg | 6.1.1 (vidéos synthétiques) |
| Réseau | GitHub accessible ; `download.swift.org` et Docker Hub bloqués/limités |
| Conséquence | **Aucune compilation iOS n'a été faite.** Statut « build validé » impossible ici (critère §8.2). |

## 2. Version épinglée

| Dépôt | Branche | Commit | Date |
|---|---|---|---|
| Horizontal-org/Tella-iOS | `master` (merge `release/3.3.0`) | `e530b335fda180a406b2fcb559f6d14c125ca50b` | 2026-09-14 |
| Horizontal-org/Tella-Android (référence) | défaut | `1170ec04ffff851eb498e5adefddf7856763f2da` | 2026-10-21 |
| Horizontal-org/tellaweb (référence) | défaut | `20543f97b090787859e81d2dc354d08295f85da9` | 2026-11-04 |

Branche de travail : `feature/spectre-deposit-drive`. `MARKETING_VERSION = 3.3.0`, `CURRENT_PROJECT_VERSION = 160`, cible iOS 15.0, `SWIFT_VERSION = 5.0`.

**Licence** : `LICENSE` = MIT, « Copyright (c) 2025 Horizontal ». Conservée telle quelle ; chaque fichier Tella garde son en-tête `Licensed under MIT`. Les ajouts SPECTRE sont sous MIT (voir `NOTICE.md`).

`tellaweb` ne contient que la configuration de déploiement (docker-compose, nginx) : le protocole serveur n'y est pas. Il a été lu depuis le client iOS (`BaseUploadOperation`).

## 3. Dépendances

| Source | Dépendance | Contrainte | Observation |
|---|---|---|---|
| `Podfile` | SQLCipher | `>= 4.5.2` | base chiffrée du coffre |
| | ZIPFoundation | non épinglée | |
| | GoogleSignIn | `~> 9.1` | connecteur Drive **personnel** de Tella (OAuth sur le téléphone) |
| | GoogleAPIClientForREST/Drive | non épinglée | idem |
| | SwiftyDropbox | non épinglée | connecteur Dropbox |
| SPM (`project.pbxproj`) | NextcloudKit | `upToNextMajor 4.0.8` | |
| | Mantis | `exact 2.28.0` | édition d'image |
| | swift-certificates | `upToNextMajor 1.8.1` | partage de proximité |
| SPECTRE | swift-crypto | `3.x` (résolu 3.15.1) | **uniquement Linux/tests** ; iOS utilise CryptoKit |

⚠ **Reproductibilité** : `Podfile.lock` et `Package.resolved` sont dans `.gitignore` du projet Tella → les versions flottent. Recommandation : sur le Mac du propriétaire, après le premier `pod install` réussi, committer `Podfile.lock` (voir `INSTALL_MAC.md`).

⚠ **Configuration manquante** : `Tella/Supporting Files/TellaConfig.xcconfig` est référencé comme configuration de base et était copié dans le bundle (phase *Copy Bundle Resources*) mais il est git-ignoré → le projet ne compile pas tel quel. SPECTRE fournit `TellaConfig.xcconfig.example` (clés vides) et a retiré ce fichier des ressources embarquées.

## 4. Carte du code (chemins et symboles réels)

### Caméra
- `Tella/Scenes/Camera/Views/CustomCameraController.swift` — `public class CameraService` (`AVCaptureMovieFileOutput videoOutput`), `startCaptureVideo()` écrit dans `NSTemporaryDirectory()/movie-<timestamp>.mov` (`createTempFileURL()`), `setupCaptureSession()` utilise `sessionPreset = .high`, `cameraDeviceInput(type:)` choisit triple/dual/wide (pas d'ultra grand-angle seul), `fileOutput(_:didFinishRecordingTo:from:error:)`.
- **Défaut relevé** : si `error != nil`, l'enregistrement est abandonné même quand `AVErrorRecordingSuccessfullyFinishedKey == true` (disque plein, durée max, interruption) → perte possible d'une vidéo valide. **Corrigé** dans le fork.
- `Tella/Scenes/Camera/ViewModel/CameraViewModel.swift` — `saveVideo()` → `saveFile(urlFile:)` → `addVaultFileInBackground` → `MainAppModel.addVaultFile(importedFiles:autoUpload:)` avec `fileSource: .camera`. GPS : `CameraService.shouldPreserveMetadata` + `videoOutput.add(location:)`, piloté par `settings.preserveMetadata`.
- Photos : la caméra n'écrit **pas** dans la photothèque. `PHPhotoLibrary` n'est utilisé que pour l'import et la suppression d'originaux importés (`VaultFilesManager.removeOriginalImage(assets:)`).

### Coffre chiffré
- `Tella/Data/VaultManager/VaultManager.swift` — `save(_:vaultFileId:)` chiffre vers `Documents/Containers/<id>` puis efface le temporaire (`deleteTmpFiles`) ; `loadVaultFileToURL(file:…)` déchiffre vers `NSTemporaryDirectory()` avec `FileProtectionType.complete` ; `securelyDeleteTempFile(at:)` = écrasement aléatoire (`wipeFileContents`) + suppression ; `clearTmpDirectory()`.
- `Tella/Data/Crypto/CryptoManager.swift` + `Cryptor.swift` (`FileCryptor`) — AES-256 **CTR** par blocs de 8 Mo via CommonCrypto ; clé dérivée de la clé privée du coffre, présente en mémoire seulement après déverrouillage (`unlockedVaultPrivateKey`).
- `Tella/Data/VaultManager/VaultFilesManager.swift` — `deleteVaultFile(fileIds:)` (fichier + ligne SQLCipher, qui contient aussi la **vignette** `VaultFileDB.thumbnail`). `addVaultFile(importedFile:)` calcule déjà le **SHA-256 du clair** (`filePath.sha256Hash()` → `VaultFileDB.hash`) : SPECTRE le réutilise comme contrôle croisé.
- Entitlement `com.apple.developer.default-data-protection = NSFileProtectionCompleteUnlessOpen` (`Tella/Supporting Files/Tella.entitlements`).
- Aucun `isExcludedFromBackup` dans Tella : `Documents/Containers` (chiffré) part dans les sauvegardes iCloud/Finder.

### Envoi, reprise, auto-report, auto-delete
- `Tella/Data/Networking/Upload/UploadService.swift` — `OperationQueue` (1 concurrent), sessions par défaut et **arrière-plan** (`NetworkSessionProvider.makeBackgroundUploadSession`, `TellaURLSessionConfigurationFactory.makeBackground`).
- `BaseUploadOperation.swift` — protocole Tella Web : `headReportFile` (taille reçue) → `putReportFile` (reprise par décalage via `vaultManager.extract(from:offsetSize:)`) → `postReportFile` (v1). `didComplete(task:error:)` : succès = **code HTTP 2xx**.
- **Auto-delete** : `checkAllFilesAreUploaded()` → `deleteCurrentAutoReport()` supprime les fichiers du coffre dès que tous les fichiers sont `.submitted`, statut posé sur **succès HTTP** — exactement ce que le mandat interdit (§3.3). **SPECTRE n'utilise pas ce chemin.**
- `AutoUpload.swift` — rapport automatique pour un serveur Tella Web ; écoute `NetworkMonitor.connectionDidChange`.
- `Tella/Application/TellaApp.swift` — `saveData(lockAppType:)` : au passage en arrière-plan, verrouille et vide le temporaire sauf si `uploadService.hasFilesToUploadOnBackground`.

### Connexion Google Drive existante
- `Tella/Data/Networking/Repositories/GDriveRepository.swift` — `GIDSignIn` + `GTLRDriveService`, scope `drive.file` **de l'utilisateur du téléphone**, `GTLRUploadParameters` (envoi par l'utilisateur connecté). Incompatible avec §3.4 (ni compte ni jeton du propriétaire sur l'appareil) → **non réutilisé** ; laissé en place mais désactivé par configuration vide (`TellaConfig.xcconfig.example`).

### Notifications, journaux, télémétrie
- Pas de notifications locales/pushes pour l'envoi ; des *toasts* in-app.
- `Tella/Utils/DebugLogging.swift` — `debugLog` compilé seulement en `DEBUG || STAGING` (rien en Release). Les journaux DEBUG contiennent des chemins de fichiers.
- Aucune dépendance d'analytics ou de crash reporting dans le `Podfile`.

### Réglages
- `MainAppModel.settings` (`SettingsModel`, JSON dans `UserDefaults` clé `com.tella.settings`) : `preserveMetadata`, `lockTimeout`, `quickDelete`, etc.

### Tests existants
- `TellaTests/VaultManagerTests.swift` (4 tests + perf) avec `TellaTests/Mocks/MockCryptoManager.swift` ; `TellaUITests/TellaUITests.swift` (gabarit). **Non exécutés ici** (nécessitent Xcode).

## 5. Conclusions pour la conception
1. La caméra et le coffre sont réutilisables sans modification de leur chiffrement → stratégie **(A)+(B)** : crochets minimaux dans Tella + module isolé (`SpectreCore`, `Tella/Spectre/`).
2. Le coffre Tella n'est lisible qu'**app déverrouillée** (clé en mémoire) : impossible d'envoyer depuis le coffre en arrière-plan verrouillé. D'où une **file d'envoi SPECTRE chiffrée séparément** (clé par captation dans le Keychain), voir ADR-003.
3. L'auto-delete de Tella se déclenche sur un succès HTTP : à proscrire. SPECTRE impose un **reçu serveur vérifié** (taille + SHA-256/MD5 + identifiants + MAC).
4. Le connecteur Google Drive de Tella place un compte Google sur le téléphone : à écarter au profit d'un **service de dépôt** côté Google.
5. Échecs préexistants consignés : `TellaConfig.xcconfig` manquant ; versions non verrouillées ; abandon de vidéos sur erreur AVFoundation « terminée avec succès ».
