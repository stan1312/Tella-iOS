# SPECTRE Capture — Installation et build sur votre Mac

C'est l'étape qui permet d'affirmer « build iOS validé ». Elle n'a pas pu être faite dans l'environnement de développement (Linux, sans Xcode).

## 1. Prérequis
- macOS 14 ou plus, ~40 Go libres.
- Xcode 16 ou plus (Tella 3.3 utilise la syntaxe Swift 6) (App Store), lancé une fois, avec un simulateur iOS installé (*Settings > Platforms*).
- Homebrew (https://brew.sh), puis :
```bash
brew install cocoapods node ffmpeg qrencode gitleaks
```
Vérification (lecture seule) : `./scripts/check_env_mac.sh`

## 2. Récupérer le projet
Soit l'archive `SPECTRE-Capture-<commit>.zip` livrée (décompressez-la), soit votre fork GitHub :
```bash
git clone https://github.com/<VOTRE_COMPTE>/<VOTRE_FORK>.git SPECTRE-Capture
cd SPECTRE-Capture && git checkout feature/spectre-deposit-drive
```
> L'archive zip n'est pas un dépôt git : `scripts/package_handover.sh` et `secret_scan.sh` en mode historique demandent un clone git.

## 3. Build + tests automatiques (sans signature, sans compte Apple)
```bash
./scripts/mac_build_and_test.sh          # premier iPhone simulé disponible ; SIM="iPhone 16" pour choisir
```
Ce script : crée `TellaConfig.xcconfig` depuis l'exemple (connecteurs Dropbox/Google Drive de Tella désactivés), `pod install`, build Debug pour simulateur, tests SPECTRE dans l'app (cible `SpectreAppTests`), la suite SpectreCore + backend, puis vérifie qu'aucun jeton/secret Google n'est présent dans le binaire. Journaux : `test-results/mac/`.

Résultat attendu : `SpectreAppTests : PASS` et `BINAIRE: aucun jeton/secret Google détecté`. **Envoyez-moi les journaux en cas d'échec** : les erreurs de compilation Swift sont probables à ce premier passage, car le code iOS n'a jamais été compilé.

Après un `pod install` réussi, committez `Podfile.lock` pour figer les dépendances.

## 4. Lancer sur le simulateur
Ouvrez `Tella.xcworkspace` (pas le `.xcodeproj`), schéma `Tella`, un simulateur, ▶. Le simulateur n'a pas de caméra : il sert à vérifier l'interface (carte SPECTRE, écran d'état, inscription par lien).

## 5. Identité et signature (avant tout iPhone ou TestFlight)
```bash
./scripts/configure_signing.sh ch.<votre-nom>.spectrecapture <TEAM_ID>
```
Remplace l'identifiant de bundle Tella (`org.wearehorizontal.tella`) et l'équipe Horizontal par les vôtres (Team ID : developer.apple.com → Account → Membership details). Dans Xcode : cible *Tella* → *Signing & Capabilities* → cochez *Automatically manage signing*, choisissez votre équipe. La cible d'extension éventuelle et `VaultManager` gardent leur configuration de bibliothèque.

## 6. Problèmes fréquents
| Symptôme | Solution |
|---|---|
| `pod: command not found` | `brew install cocoapods` |
| `TellaConfig.xcconfig not found` | relancer `mac_build_and_test.sh` (il le crée) |
| Simulateur introuvable | `xcrun simctl list devices available`, puis `SIM="<nom>"` |
| Erreurs de compilation dans `Tella/Spectre/` ou `SpectreCore/` | m'envoyer `test-results/mac/build.log` |
