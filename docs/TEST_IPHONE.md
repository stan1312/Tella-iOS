# SPECTRE Capture — Test sur iPhone réel

Prérequis : `docs/INSTALL_MAC.md` §3 réussi, signature configurée (§5), service Apps Script de **test** déployé (`docs/SETUP_GOOGLE_DRIVE.md`). Un compte Apple gratuit suffit pour installer sur votre propre iPhone (profil valable 7 jours) ; TestFlight exige le programme payant.

**Filmez uniquement des scènes neutres** (mur, écran affichant l'heure, mire). Aucune personne, aucun lieu sensible.

## Installation
1. iPhone branché, *Réglages > Confidentialité et sécurité > Mode développeur* activé.
2. Xcode : destination = votre iPhone, ▶. Au premier lancement : *Réglages > Général > VPN et gestion de l'appareil* → faire confiance à votre certificat.
3. Créez le code Tella (le coffre Tella d'origine est conservé).

## Grille de vérification (cochez et datez)
| # | Action | Attendu |
|---|---|---|
| 1 | Accueil | Carte « Dépôt SPECTRE » visible ; aucune vidéo en attente |
| 2 | *Configurer cet appareil (invitation)* → scanner le QR de `invite_qr.sh` | « Appareil configuré. Vous pouvez filmer. » ; `spectreListDevices` montre l'appareil |
| 3 | Rescanner le même QR sur un autre téléphone | Refus (invitation à usage unique) |
| 4 | Filmer 10 s en Wi-Fi | État « Transfert en cours », puis « Vérification sur le Drive… », puis « Transfert confirmé — supprimée du téléphone » ; fichier présent dans `SPECTRE_DEPOT_TEST`, même taille |
| 5 | Comparer le fichier Drive téléchargé sur le Mac avec la vidéo (si conservée via un test parallèle) | `shasum -a 256` identique ; `ffprobe` montre les métadonnées |
| 6 | Mode avion, filmer 30 s | « En attente (vidéo encore sur ce téléphone) » ; vidéo visible dans le coffre Tella |
| 7 | Désactiver le mode avion, rouvrir l'app | Envoi puis confirmation |
| 8 | Filmer 3 min, couper le Wi-Fi à mi-envoi pendant 1 min | Reprise sans repartir de zéro (progression ne retombe pas à 0 %) |
| 9 | Filmer 2 min, verrouiller l'écran immédiatement, attendre 15 min | Noter si l'envoi a progressé (iOS décide ; non garanti). Au déverrouillage, l'envoi reprend |
| 10 | Pendant un envoi, tuer l'app (balayage), la rouvrir | La tâche réapparaît et termine |
| 11 | Révoquer l'appareil (`spectreRevokeDevice`) puis filmer | Message d'erreur clair ; vidéo conservée sur le téléphone |
| 12 | Écran SPECTRE → section « Vidéo » → *Qualité vidéo* : choisir « 4K 60 i/s » si proposé (« Standard (Tella) » par défaut), rouvrir la caméra | Vidéo 2160p60 ; vérifier avec `ffprobe`. Seuls les modes détectés sur l'iPhone sont proposés |
| 13 | Ouvrir le lien `spectre://enroll?...` depuis Notes | L'app ouvre l'écran de configuration (ne doit pas casser les écrans Dropbox / serveurs Tella) |
| 14 | Vérifier les fonctions Tella existantes : coffre, verrouillage, effacement rapide (avec une vidéo encore en attente, mode avion) | Inchangées ; après l'effacement rapide, l'écran SPECTRE affiche « Aucune vidéo en attente » et l'appareil reste configuré |
| 15 | Console Mac (app *Console*, filtre `SPECTRE`) | Aucune URL `upload_id=`, aucun secret dans les journaux |

Reportez les résultats (PASS/FAIL, date, modèle d'iPhone, version iOS) dans `docs/TEST_REPORT.md`.
