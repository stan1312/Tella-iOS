# SPECTRE Capture Android — APK, signature, installation

Même service de dépôt que l'iPhone : le script Apps Script déjà déployé (`backend/apps-script/`) **n'est pas modifié**. Un téléphone Android s'inscrit avec une invitation `spectreNouvelleInvitation` exactement comme un iPhone ; ses dépôts arrivent dans le même dossier Drive (ou le dossier de la manifestation en cours).

## 1. Ce que contient l'APK
- Base : Tella Android (Horizontal-org, licence MIT), variante `spectre` (`android/mobile`, flavor `spectre`).
- Identifiant : `org.spectre.capture` (modifiable via la variable de dépôt `SPECTRE_APPLICATION_ID`), nom « SPECTRE Capture », icône neutre, thème noir et blanc. Android 8.0 minimum.
- Accueil : carte « DÉPÔT · NOM DE LA MANIF » + deux grands boutons carrés **Appareil photo** et **Dictaphone**.
- Après chaque vidéo ou enregistrement : copie chiffrée (AES-256-GCM) → envoi automatique vers Drive (reprise après coupure) → reçu signé vérifié → suppression de la copie locale du coffre.
- Le dictaphone Tella enregistre en AAC brut ; l'app le ré-encapsule en `.m4a` **sans ré-encodage** (son identique, vérifié par test) car le service n'accepte que `audio/mp4`.
- Secret de l'appareil : scellé par une clé du Keystore Android (non exportable), hors sauvegarde.
- **Aucune** URL `/exec`, invitation ou clé n'est compilée dans l'APK (vérifié à chaque build par la CI).

## 2. Clé de signature (une fois, sur votre Mac, 2 minutes)
La clé de signature identifie « vos » mises à jour : un APK signé par une autre clé ne peut pas remplacer l'app installée. Elle reste chez vous ; seule une copie chiffrée va dans les secrets GitHub.

```sh
mkdir -p ~/spectre-signing && cd ~/spectre-signing
# Mot de passe long (gardez-le dans votre gestionnaire de mots de passe)
openssl rand -base64 24 > motdepasse.txt
openssl req -x509 -newkey rsa:4096 -sha256 -days 10000 -nodes \
  -subj "/CN=SPECTRE Capture" -keyout cle.pem -out cert.pem
openssl pkcs12 -export -name spectre -inkey cle.pem -in cert.pem \
  -out spectre.p12 -passout file:motdepasse.txt
rm cle.pem
base64 -i spectre.p12 | pbcopy   # copie la clé encodée dans le presse-papiers
```
Sauvegardez `spectre.p12` + `motdepasse.txt` hors ligne (clé USB chiffrée). **Ne les mettez jamais dans le dépôt** (`.gitignore` les exclut).

Dans GitHub → dépôt → *Settings* → *Secrets and variables* → *Actions* → *New repository secret* :
| Secret | Valeur |
|---|---|
| `SPECTRE_KEYSTORE_B64` | coller (presse-papiers ci-dessus) |
| `SPECTRE_KEYSTORE_PASSWORD` | contenu de `motdepasse.txt` (le retour à la ligne final est ignoré) |
| `SPECTRE_KEY_ALIAS` | `spectre` |

Sans ces secrets, la CI produit un APK **de test** signé avec une clé de debug jetable : utilisable pour essayer, pas pour l'équipe (il faudra le désinstaller avant d'installer la version signée).

## 3. Obtenir l'APK
1. GitHub → *Actions* → *spectre-android* → *Run workflow* (ou n'importe quel push).
2. Quand le job **apk** est vert : en bas de la page du run, artefact `spectre-capture-android-<n>` → zip contenant `spectre-capture-android-release-<n>.apk` et son `.sha256`.
3. Le résumé du run affiche l'empreinte SHA-256 du certificat : notez-la, elle doit rester identique d'une version à l'autre.

## 4. Installer sur un téléphone
1. Déposez l'APK dans un dossier Drive à vous, ou servez-le depuis votre Mac ; montrez le lien sous forme de QR **en personne** (comme les invitations).
2. Sur le téléphone : ouvrir le fichier → Android demande d'autoriser l'installation depuis cette source (Drive / navigateur) → *Autoriser* → *Installer*. Désactivez ensuite cette autorisation.
3. Play Protect peut afficher « application inconnue » : *Installer quand même*. (Normal pour une app hors Play Store.)
4. Premier lancement : créer le verrou (code ou motif Tella), puis carte de dépôt → *Configurer cet appareil (invitation)* → scanner le QR d'invitation → confirmer l'adresse du service.
5. Autoriser caméra et micro. Les notifications sont facultatives : si elles sont autorisées, une notification neutre « Envoi sécurisé en cours » (masquée sur l'écran verrouillé) apparaît pendant un envoi ; l'envoi fonctionne aussi sans.
6. Conseillé : *Paramètres → Batterie → SPECTRE Capture → Sans restriction*, sinon certains fabricants (Xiaomi, Huawei, Samsung) retardent les envois en arrière-plan.

Mise à jour : installer simplement le nouvel APK (même clé) par-dessus ; inscription et file d'envoi sont conservées.

## 5. Comportement à connaître
- L'envoi démarre dès la fin de la vidéo / de l'enregistrement, s'il y a du réseau ; sinon il reprend tout seul quand le réseau revient (vérification au moins toutes les 15 min, et à chaque déverrouillage).
- La copie dans le coffre Tella n'est effacée **qu'après** un reçu du service vérifié (taille + empreinte) et seulement quand le coffre est déverrouillé ; sinon elle l'est au déverrouillage suivant.
- Effacement rapide (panique Tella) : supprime aussi la file d'envoi locale. Les fichiers déjà déposés restent sur Drive.
- Téléphone perdu : `spectreRevokeDevice` (voir `SETUP_GOOGLE_DRIVE.md` §6).

## 6. Construire soi-même (optionnel)
`cd android && ./gradlew -Pfdroid :mobile:assembleSpectreRelease` avec Android SDK 36 et les variables `SPECTRE_KEYSTORE`, `SPECTRE_KEYSTORE_PASSWORD`, `SPECTRE_KEY_ALIAS`. Tests du cœur sans SDK Android : `cd android/spectre-core && gradle test` (Java 17+, Node 22, ffmpeg).
