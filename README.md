# SPECTRE Capture

Application iOS de captation vidéo pour une équipe de recherche, dérivée de [Tella iOS](https://github.com/Horizontal-org/Tella-iOS) (MIT, © HORIZONTAL ; voir `NOTICE.md` et `README_TELLA.md`).
Chaque vidéo filmée est déposée dans **un dossier Google Drive privé du responsable**, puis supprimée du téléphone **uniquement** après un reçu vérifié par le serveur (taille exacte + SHA-256). Les téléphones peuvent déposer, jamais lire, lister, télécharger ni supprimer les archives.

> **Statut : READY_FOR_OWNER_INTEGRATION.** La logique de dépôt et le backend sont testés sur un Drive simulé (58 tests automatisés exécutés et réussis). Le build iOS passe sur simulateur (CI GitHub macOS, Xcode 16.4) avec les tests SPECTRE de l'app ; l'iPhone réel et Google réel restent à vérifier. Vidéos fictives uniquement tant que les tests réels (Mac, Google, iPhone) ne sont pas concluants.

## Architecture (résumé)
```
iPhone (SPECTRE Capture)                       Google
 caméra Tella → coffre Tella (AES)             Apps Script (exécuté par le responsable, scope drive.file)
            └→ file d'envoi chiffrée (AES-GCM)  ├ enroll / initUpload / finalizeUpload, requêtes signées HMAC
                 │ 1. initUpload ───────────────┤   ouvre une session resumable dans SPECTRE_DEPOT_TEST
                 │ 2. octets ───────────────────────────────→ googleapis.com (upload resumable, reprise)
                 │ 3. finalizeUpload ───────────┤   relit taille + SHA-256 sur Drive → reçu signé
                 └ 4. reçu vérifié localement → suppression des copies (coffre, file, temporaire)
```
Détails : `docs/01_ARCHITECTURE.md`. Menaces : `docs/SECURITY_THREAT_MODEL.md`.

## Contenu
| Dossier | Rôle |
|---|---|
| `SpectreCore/` | Paquet Swift indépendant de l'UI : file durable, chiffrement de la file, upload resumable, vérification du reçu, suppression conditionnelle, moteur d'états |
| `Tella/Spectre/` | Intégration iOS : Keychain, stockage protégé, tâche d'arrière-plan, écran d'état, inscription par QR, qualité vidéo |
| `backend/apps-script/` | Service de dépôt Apps Script + tests ; `backend/mock-stack/` : Drive simulé local |
| `scripts/` | Tests, build Mac, signature, QR d'invitation, analyse de secrets, archive |
| `docs/` | Audit, architecture, menaces, plan et rapport de test, guides |
| `tests/fixtures/` | Vidéos synthétiques générées (non versionnées) |

## Tester localement (Linux ou macOS, sans compte)
```bash
./scripts/make_fixtures.sh     # vidéos synthétiques (ffmpeg)
./scripts/run_all_tests.sh     # backend (node) + SpectreCore (swift test) + analyse de secrets
```
Prérequis : Swift 5.9+ (6.0 testé), Node 20+ (22 testé), ffmpeg. Sur Mac : `./scripts/mac_build_and_test.sh` (build et tests de l'app, voir `docs/INSTALL_MAC.md`).

## Guides
- Installation Mac : `docs/INSTALL_MAC.md`
- Connexion à votre Google Drive : `docs/SETUP_GOOGLE_DRIVE.md`
- Test sur iPhone : `docs/TEST_IPHONE.md`
- TestFlight : `docs/TESTFLIGHT.md`
- Guide équipe (1 page) : `docs/GUIDE_EQUIPE_1_PAGE.md`
- Passation : `docs/HANDOVER.md`

## Licence
MIT, comme Tella (`LICENSE`). Les modifications SPECTRE sont publiées sous la même licence. « Tella » et « HORIZONTAL » sont des noms de leurs détenteurs ; SPECTRE Capture n'est pas un produit HORIZONTAL et n'est pas soutenu par HORIZONTAL.
