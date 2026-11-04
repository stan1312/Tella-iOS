# SPECTRE Capture — Dossier de passation

**Statut : READY_FOR_OWNER_INTEGRATION** (date : 2026-11-04). Le critère « build iOS » n'est **pas** rempli : le code iOS (`Tella/Spectre/` et les retouches Tella) n'a jamais été compilé. Les sources iOS ont été écrites sans compilateur Apple : une première passe de corrections de compilation sur Mac est à prévoir.

## 1. Ce qui est fait et vérifié
- Cœur de dépôt `SpectreCore` (Swift) et service Apps Script : **58 tests exécutés et réussis** sur Drive simulé (30 backend + 28 Swift), T02 vérifié à 2,5 Go. Détails : `docs/TEST_REPORT.md`.
- Analyse de secrets, ESLint, shellcheck : propres.

## 2. Ce qui est écrit mais non vérifié
| Élément | Fichiers | Vérification à faire |
|---|---|---|
| Intégration iOS | `Tella/Spectre/*.swift` | `scripts/mac_build_and_test.sh` |
| Test d'intégration app | `TellaTests/SpectreIntegrationTests.swift` | idem |
| Projet Xcode modifié | `Tella.xcodeproj/project.pbxproj` (via `scripts/xcode_integrate_spectre.rb`) | ouverture dans Xcode |
| CI | `.github/workflows/spectre-ci.yml` | premier push sur votre fork |
| Service Google réel | `backend/apps-script/src/` | `docs/SETUP_GOOGLE_DRIVE.md` §8 |
| Comportement appareil | — | `docs/TEST_IPHONE.md` |

## 3. Fichiers Tella modifiés (base `e530b335`)
| Fichier | Modification |
|---|---|
| `Tella/Data/MainAppModel.swift` | service `spectre` ; reprise des dépôts après déverrouillage ; effacement SPECTRE dans `deleteAfterMaxAttempts` |
| `Tella/Data/EncryptionService/EncryptionService.swift` | chaque vidéo caméra chiffrée devient une tâche de dépôt |
| `Tella/Scenes/Camera/Views/CustomCameraController.swift` | lecture correcte de `AVErrorRecordingSuccessfullyFinishedKey` ; application du mode vidéo choisi |
| `Tella/Data/VaultManager/VaultManager.swift` | `vaultContainerExists(fileId:)` (contrôle après suppression) |
| `Tella/Scenes/HomeView/ViewModel/HomeViewModel.swift` | l'effacement rapide vide aussi la file SPECTRE |
| `Tella/Scenes/HomeView/Views/Home/HomeView.swift` | carte « Dépôt SPECTRE » |
| `Tella/Application/AppDelegate.swift` | tâche d'arrière-plan ; garde si clés Dropbox/Google absentes |
| `Tella/Application/TellaApp.swift` | ouverture des liens `spectre://` |
| `Tella/Supporting Files/Info.plist` | nom « SPECTRE Capture », textes d'autorisation FR, schéma `spectre`, identifiant de tâche |
| `Tella/Supporting Files/TellaConfig.xcconfig.example` | configuration sans clés de connecteurs Tella |
| `AppIcon` | icône neutre distincte de Tella |

## 4. Décisions prises sans vous (modifiables)
1. Backend Apps Script exécuté sous votre identité, scope `drive.file` (ADR-002) ; repli Cloud Run documenté (ADR-006).
2. Copie d'envoi chiffrée séparée du coffre Tella, accessible après premier déverrouillage pour permettre l'envoi écran verrouillé (compromis, `SECURITY_THREAT_MODEL.md` S1).
3. Repli MD5 + taille si Drive n'expose pas le SHA-256 après 3 essais (`SPECTRE_POLICY` dans `00_Config.js`, et `ReceiptVerifier` côté app). Pour exiger strictement le SHA-256 : `acceptMd5Fallback: false` dans `00_Config.js` (le dépôt restera alors en « Vérification » tant que Drive n'expose pas le SHA-256) et `ReceiptVerifier(allowedChecksumSources: ["sha256"])` côté app. Dans tous les cas, l'app recalcule et compare aussi le MD5 et la taille.
4. Connecteurs Dropbox / Google Drive de Tella désactivés par défaut (pas de clés) : le dépôt SPECTRE ne les utilise pas.
5. Qualité vidéo : « Standard (Tella) » par défaut ; 1080p/4K à 30/60 i/s proposés seulement si l'iPhone les annonce.
6. Le dépôt auto Tella (`autoUpload`) reste inchangé et indépendant ; ne configurez pas de serveur Tella si vous voulez que seules les archives Drive existent.

## 5. Vos étapes, dans l'ordre
1. Créer un fork GitHub de Horizontal-org/Tella-iOS sous votre compte, puis connecter GitHub à Claude (https://claude.ai/connect-github) pour que la branche y soit poussée et une PR ouverte ; ou utiliser l'archive zip livrée.
2. Mac : `docs/INSTALL_MAC.md` (build + tests, ~30 min hors téléchargement de Xcode).
3. Google : `docs/SETUP_GOOGLE_DRIVE.md` avec un compte de test.
4. iPhone : `docs/TEST_IPHONE.md`.
5. Revue sécurité UNIL et avis DPO.
6. Apple Developer Program (99 USD/an) puis `docs/TESTFLIGHT.md`.

## 6. Points de vigilance
- Ne jamais committer `TellaConfig.xcconfig`, `.clasp.json`, `.env`, ni coller une URL `/exec` ou un lien d'invitation dans un dépôt public.
- TestFlight : nouveau build tous les ~60 jours (expiration à 90 jours).
- Révocation immédiate en cas de perte d'un téléphone (`spectreRevokeDevice`).
- `Podfile.lock` à committer après le premier `pod install`.
