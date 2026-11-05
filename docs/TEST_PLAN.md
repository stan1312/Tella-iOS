# SPECTRE Capture — Plan de test

Données : **exclusivement synthétiques** (octets pseudo-aléatoires déterministes, vidéos générées par `scripts/make_fixtures.sh` avec ffmpeg `testsrc2`). Aucune donnée de terrain.

## Niveaux
| Niveau | Où | Outil | Exécutable sans Mac |
|---|---|---|---|
| N1 Backend Apps Script | `backend/apps-script/test/` | `node --test` + runtime GAS simulé (`mock-stack/gas-runtime.mjs`) + faux Drive (`mock-drive.mjs`) | oui |
| N2 Cœur Swift | `SpectreCore/Tests/` | XCTest via `swift test`, contre le mock HTTP réel (`mock-stack/server.mjs`) | oui (Linux ou macOS) |
| N3 Intégration app | `SpectreAppTests/SpectreIntegrationTests.swift` | Xcode, simulateur iOS | **non** (Mac requis) |
| N4 Appareil réel | `docs/TEST_IPHONE.md` | iPhone + Drive de test | **non** |
| N5 Google réel | `docs/SETUP_GOOGLE_DRIVE.md` §8 | Apps Script déployé sur un compte de test | **non** (compte requis) |

## Matrice T01–T15 (mandat)
| Id | Exigence | Test(s) automatisé(s) | Critère de réussite |
|---|---|---|---|
| T01 | Vidéo courte, réseau stable | `ScenarioTests.testT01_…`, backend « init → upload … → MAC receipt » | Reçu vérifié puis suppression des copies locales ; fichier Drive identique (SHA-256) |
| T02 | Vidéo volumineuse | `ScenarioTests.testT02_largeVideoOriginalUnmodified` (64 Mio par défaut, `SPECTRE_LARGE_TEST_BYTES` pour plusieurs Go) | Contenu Drive = original octet pour octet, coupure à 50 % reprise |
| T03 | Capture hors ligne | `testT03_offlineCaptureKeepsOriginalAndVisibleTask` | Original conservé, tâche visible « En attente (vidéo encore sur ce téléphone) », envoi ensuite |
| T04 | Coupures à 10/50/99 % | `testT04_…`, backend « T04 — interrupted uploads » | Reprise depuis l'offset serveur, aucun reçu ni suppression avant la fin |
| T05 | Crash pendant l'envoi | `testT05_crashMidUploadRecoversFromDisk` | Nouveau moteur rechargé depuis le disque termine sans perte |
| T06 | HTTP OK mais fichier absent | `testT06_…`, backend « HTTP success … file absent » | Pas de reçu, suppression bloquée |
| T07 | Taille/checksum différents | `testT07_…`, `testT07b_tamperedReceiptBlocksDeletion`, backend « sizeWrong / sha256Wrong / md5Wrong » | `MISMATCH`, alerte visible, original conservé |
| T08 | Idempotence / double traitement | `testT08_concurrentProcessingIsIdempotent`, backend « T08 idempotence » | Un seul fichier Drive, un seul reçu |
| T09 | Appareil révoqué | `testT09_…`, backend « revoked device » | `DEVICE_REVOKED`, original conservé, autres appareils non affectés |
| T10 | Téléphone compromis | `testT10_…`, backend « no list/search/read/download/move/delete », « session URL give no read access » | Aucune opération de lecture/suppression possible |
| T11 | Pannes Google / quotas | `testT11_…`, backend « T11 — quotas and Google failures » | Erreurs explicites, tentatives bornées, original conservé |
| T12 | Métadonnées et original intacts | `testT12_originalAndMetadataPreservedByteForByte` (fixtures ffmpeg + ffprobe) | SHA-256 identique, `creation_time`/`location` présents dans la copie Drive |
| T13 | Suppression conditionnelle | Couvert par T01, T06, T07, T07b, `DeletionCoordinatorTests`, `ReceiptVerifierTests` | Suppression uniquement avec `VerifiedReceipt` |
| T14 | Deux appareils simultanés | `testT14_twoDevicesSimultaneously`, backend « T14 two devices » | Uploads, reçus et fichiers distincts |
| T15 | Mock Drive local | L'ensemble N1 + N2 tourne sur le mock | Suite verte sans réseau externe |
| — | Journaux sans données sensibles | `testLogsContainNoSensitiveData`, `testLogRedaction` | Aucune URL de session, aucun secret |
| — | Analyse de secrets | `scripts/secret_scan.sh` | Aucun secret dans le dépôt |

## Commandes
```bash
./scripts/make_fixtures.sh          # vidéos synthétiques (ffmpeg)
./scripts/run_all_tests.sh          # N1 + N2 + secret scan, journaux dans test-results/
SPECTRE_LARGE_TEST_BYTES=2684354560 swift test --package-path SpectreCore --filter testT02   # T02 multi-Go
./scripts/mac_build_and_test.sh     # sur Mac : N3 + build simulateur + N1/N2
```

## Hors automatisation (à faire manuellement)
Voir `docs/TEST_IPHONE.md` (arrière-plan réel, verrouillage, 4K/60, Keychain sur appareil, QR, coexistence Dropbox/serveurs Tella) et `docs/SETUP_GOOGLE_DRIVE.md` §8 (Google réel).
