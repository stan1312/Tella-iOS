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

## Essais réels chez le propriétaire — 2026-11-08 (Mac, Google personnel, iPhone)
| Élément | Résultat observé |
|---|---|
| Mac du propriétaire, Xcode 27.2 | `BUILD SUCCEEDED` ; SpectreAppTests 5/5 ; backend 30/30 ; SpectreCore 28/28 ; secret scan propre ; contrôle du binaire OK |
| Apps Script réel (compte Google personnel) | `clasp push` + `clasp deploy` ; `spectreInstall` : dossier SPECTRE_DEPOT_TEST créé, purge quotidienne programmée, invitation créée (« SPECTRE install OK ») après correction du 403 (incident 7) ; clasp déconnecté ensuite |
| Signature iPhone | Équipe personnelle gratuite : app installée et lancée via `devicectl` (incident 8). Expiration du profil : 7 jours |
| Inscription par QR (caméra réelle) | OK, appareil `membre-01` ; invitation à usage unique consommée ; image du QR supprimée |
| Dépôt de bout en bout (vidéo factice de 5 s, sans personne) | Fichier `SPECTRE_20261108T173316Z_….mov` (3 347 848 octets) présent dans SPECTRE_DEPOT_TEST, constaté par les métadonnées de la synchronisation Google Drive du Mac (fichier non ouvert). L'app a indiqué le transfert confirmé (constat du propriétaire) |

Reste à vérifier sur appareil : coupure réseau pendant un envoi, envoi en arrière-plan, 4K, révocation (`spectreRevokeDevice`) vue par l'app, suppression de la copie locale après reçu, `spectreListDevices` (un seul appareil attendu).

## Mise à jour du 2026-11-09 (Mac du propriétaire, équipe Apple payante)
| Élément | Résultat observé |
|---|---|
| Backend (`node --test`) | 35 PASS / 0 FAIL (ajouts : dossier par manif, invitations numérotées, action `status`, dépôt audio, envoi en cours pendant un changement de dossier) |
| SpectreCore (`swift test`, Mac) | 30 PASS / 0 FAIL (ajouts : `depositStatus`, dépôt audio m4a) |
| Apps Script réel | `clasp push` + mise à jour du déploiement existant (version 3, même URL /exec) |
| Signature | Équipe payante (Apple Developer Program, personne physique) ; App ID en « Protected Unless Open » ; `default-data-protection = NSFileProtectionCompleteUnlessOpen` vérifié par `codesign` ; aucun secret ni URL /exec dans le binaire |
| iPhone | Build Debug installée et lancée (nouvel accueil noir et blanc) |

À constater par le propriétaire : accueil, carte « DÉPÔT · … », essai dictaphone (.m4a dans le Drive).

## Non exécuté (SKIP — impossible ici)
| Élément | Raison | Où le faire |
|---|---|---|
| Tests UI | Non automatisés | `docs/TEST_IPHONE.md` |
| Google Drive réel : liaison IP des sessions, latence `sha256Checksum`, quotas Apps Script (le dépôt simple est validé, voir ci-dessus) | Non mesuré | `docs/SETUP_GOOGLE_DRIVE.md` §8 |
| Arrière-plan iOS réel, capture 4K matérielle, `onOpenURL` vs vues Dropbox/serveurs Tella | Pas encore fait sur l'iPhone | `docs/TEST_IPHONE.md` |
| gitleaks | Non installé dans le conteneur | `brew install gitleaks` puis `scripts/secret_scan.sh` |

## Incidents rencontrés et corrigés
1. Toolchain Swift : sites de téléchargement bloqués ; installation depuis les paquets Ubuntu `swiftlang` 6.0.3.
2. La révocation renouvelait le secret → le client voyait AUTH_INVALID au lieu de DEVICE_REVOKED ; corrigé (secret conservé, statut révoqué).
3. FoundationNetworking réessayait silencieusement après une coupure, masquant T04 ; le mock simule désormais une fenêtre hors ligne après chaque coupure.
4. Collision de noms `HTTPRequest`/`HTTPResponse` avec Tella ; renommés `SpectreHTTP*`.
5. `TellaConfig.xcconfig` absent (gitignoré) mais référencé et embarqué dans le bundle ; ajout d'un fichier exemple, retrait du bundle.
6. `scripts/configure_signing.sh` ne remplaçait pas l'équipe conditionnelle `DEVELOPMENT_TEAM[sdk=iphoneos*]` ; corrigé (perl), vérifié sur une copie du projet (9 occurrences remplacées, 0 équipe Horizontal restante), puis restauré.
7. Apps Script réel : création du dossier refusée (HTTP 403) car l'API Drive n'est pas activée dans le projet Cloud par défaut d'un script neuf. Corrigé en déclarant le service avancé Drive v3 dans le manifeste (portée toujours `drive.file` seule) ; l'erreur affiche désormais la raison Google.
8. Équipe Apple personnelle gratuite : refuse les capacités « Access Wi-Fi Information » (retirée du dépôt, aucun code ne lit le SSID) et « Data Protection » par défaut (retirée seulement dans la build locale du propriétaire ; le dépôt la conserve pour le compte payant). Avec cette build, n'utiliser que des vidéos factices.
