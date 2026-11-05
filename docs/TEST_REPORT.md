# SPECTRE Capture — Rapport de test

**Statut global : READY_FOR_OWNER_INTEGRATION.** Build iOS **réussi** sur simulateur (CI GitHub macOS, 2026-11-05, voir §CI). Restent non vérifiés : appareil réel, Google réel, signature de distribution.

## Environnement d'exécution
| Élément | Valeur |
|---|---|
| Date | 2026-11-04 |
| OS | Linux (conteneur cloud, Ubuntu 24.04), noyau 6.18 |
| Swift | 6.0.3 (swift-6.0.3-RELEASE), swift-crypto 3.15.1 |
| Node.js | v22.23.4 |
| ffmpeg / ffprobe | 6.1.1-3ubuntu5 |
| Dépôt | fork local de Horizontal-org/Tella-iOS, base `e530b335` (release 3.3.0), branche `feature/spectre-deposit-drive` |
| Commit testé | Première série complète sur `802dbb26`. Série relancée le 2026-11-04 sur l'arbre de travail du commit de livraison « SPECTRE: documentation… » (ajouts : documentation, scripts Mac/signature, sélecteur de qualité vidéo et vidage de la file à l'effacement rapide — ces deux derniers en Swift iOS **non compilé**) : `RESULT: ALL PASSED`, mêmes chiffres |

## Commande
```bash
./scripts/run_all_tests.sh
```
Journaux bruts : `test-results/backend.log`, `test-results/spectrecore.log`, `test-results/fixtures.log`.

## Résultats — N1 Backend Apps Script (node --test) : **30 PASS / 0 FAIL**
| Suite | Tests | Résultat |
|---|---|---|
| enrolment & device identity | invitation unique, invitation expirée, brute force limité | PASS ×3 |
| request authentication | signature/appareil/horloge → AUTH_INVALID indistinct ; rejeu → REPLAY ; débit par appareil | PASS ×3 |
| T01 / T15 deposit happy path | init → upload direct → vérification serveur → reçu MAC ; T08 idempotence ; même captureId contenu différent refusé | PASS ×3 |
| T04 interrupted uploads | coupure 10 %, 50 %, 99 % puis reprise par sonde | PASS ×3 |
| T06 / T07 verification failures | fichier absent → INCOMPLETE ; taille/sha256/md5 faux → MISMATCH + marquage ; sha256 absent → PENDING puis repli md5 | PASS ×5 |
| T09 / T10 / T14 | révocation ; aucune action list/search/read/download/move/delete ; session sans accès lecture ; jeton OAuth jamais exposé ; deux appareils | PASS ×5 |
| T11 | Drive plein / indisponible / jeton expiré ; quotas taille, nombre, uploads ouverts ; validation des entrées | PASS ×3 |
| session lifecycle | renouvellement après expiration / FINALIZE ; endpoints compatibles drive.file ; purge | PASS ×3 |
| static checks | pas de DriveApp/HtmlService/scope drive complet ; pas de littéral ressemblant à un secret | PASS ×2 |

## Résultats — N2 SpectreCore (swift test, contre le mock HTTP) : **28 PASS / 0 FAIL** (16,4 s)
| Test | Résultat | Preuve |
|---|---|---|
| OutboxTests ×3 (aller-retour, altération détectée, effacement cryptographique) | PASS | spectrecore.log |
| ReceiptVerifierTests ×4 (reçu valide, chaque champ vérifié, MAC forgé, Drive id / politique md5) | PASS | idem |
| ResumableUploaderTests ×2 (reprise depuis l'offset serveur, session expirée / serveur menteur) | PASS | idem |
| DeletionCoordinatorTests ×1 (échec partiel signalé, fichier hors racine jamais déclaré supprimé) | PASS | idem |
| EnrollmentAndLoggingTests ×3 (parseur, caviardage, libellés FR) | PASS | idem |
| T01, T03, T04, T05, T06, T07, T07b, T08, T09, T10, T11, T14, journaux | PASS | idem |
| T02 (64 Mio, valeur par défaut) | PASS (5,1 s) | idem |
| T12 (fixtures ffmpeg 1080p30 avec métadonnées + 2160p60, ffprobe comparé) | PASS (1,1 s) | idem + fixtures.log |

### T02 multi-gigaoctet (exécution dédiée)
`SPECTRE_LARGE_TEST_BYTES=2684354560 swift test --package-path SpectreCore --filter testT02` : **PASS** en 206,6 s, 2 684 354 560 octets, coupure à 50 % puis reprise, SHA-256 Drive = original `8e60fdca28c62c5a42ef9b6775827f417ddfceeba7cea5aec5147d5944648755`.

## Contrôles statiques
| Contrôle | Commande | Résultat |
|---|---|---|
| Analyse de secrets | `./scripts/secret_scan.sh` (motifs + detect-secrets ; gitleaks non installé ici) | PASS (aucun secret ; 1 faux positif connu exclu : motif grep dans `mac_build_and_test.sh`) |
| ESLint backend | `npx eslint apps-script` (dans `backend/`) | PASS |
| Syntaxe JS | `node --check` sur les sources | PASS |
| Shellcheck | `shellcheck scripts/*.sh` | PASS |

## CI GitHub (stan1312/Tella-iOS, PR #1) — 2026-11-05, commit `edc0903f`
| Job | Environnement | Résultat |
|---|---|---|
| `linux` | conteneur swift:6.0-noble | `RESULT: ALL PASSED` (backend 30/30, SpectreCore 28/28, secret scan) |
| `macos` | macos-15, Xcode 16.4, simulateur iPhone 16 Pro | `** BUILD SUCCEEDED **` (app Debug simulateur, non signée) ; `SpectreAppTests : PASS` (5/5 : Keychain, identifiant de capture, protection/exclusion de sauvegarde, Info.plist, détection vidéo) ; SpectreCore 28/28 et backend 30/30 sur macOS ; contrôle du binaire : aucun jeton/secret Google |

Corrections apportées pendant cette passe : Xcode 15.4 → 16 (Tella 3.3 utilise `@retroactive`) ; tests SPECTRE de l'app déplacés dans la cible `SpectreAppTests`, car la cible d'origine `TellaTests` (VaultManagerTests, ModelStubs, MockCryptoManager) ne compile plus contre Tella 3.3, indépendamment de SPECTRE ; hôte de test signé ad hoc (`-`) pour le Keychain du simulateur (erreur -34018 sinon) ; T12 tolère le format de date de ffmpeg 9.

## Non exécuté (SKIP — impossible ici)
| Élément | Raison | Où le faire |
|---|---|---|
| Tests UI, build signé pour appareil | Compte Apple requis | `docs/TEST_IPHONE.md` |
| Google Drive / Apps Script réels (liaison IP des sessions, PUT sans jeton, latence `sha256Checksum`, quotas Apps Script) | Aucun compte Google ; interdiction de déploiement réel | `docs/SETUP_GOOGLE_DRIVE.md` §8 |
| Arrière-plan iOS réel, Keychain sur appareil, capture 4K matérielle, QR caméra, `onOpenURL` vs vues Dropbox/serveurs Tella | Pas d'iPhone | `docs/TEST_IPHONE.md` |
| gitleaks | Non installé dans le conteneur | `brew install gitleaks` puis `scripts/secret_scan.sh` |

## Incidents rencontrés et corrigés
1. Toolchain Swift : sites de téléchargement bloqués ; installation depuis les paquets Ubuntu `swiftlang` 6.0.3.
2. La révocation renouvelait le secret → le client voyait AUTH_INVALID au lieu de DEVICE_REVOKED ; corrigé (secret conservé, statut révoqué).
3. FoundationNetworking réessayait silencieusement après une coupure, masquant T04 ; le mock simule désormais une fenêtre hors ligne après chaque coupure.
4. Collision de noms `HTTPRequest`/`HTTPResponse` avec Tella ; renommés `SpectreHTTP*`.
5. `TellaConfig.xcconfig` absent (gitignoré) mais référencé et embarqué dans le bundle ; ajout d'un fichier exemple, retrait du bundle.
6. `scripts/configure_signing.sh` ne remplaçait pas l'équipe conditionnelle `DEVELOPMENT_TEAM[sdk=iphoneos*]` ; corrigé (perl), vérifié sur une copie du projet (9 occurrences remplacées, 0 équipe Horizontal restante), puis restauré.
