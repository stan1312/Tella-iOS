# SPECTRE Capture Android — vérifications sur téléphone réel

À faire avec un téléphone de test, le service Apps Script déjà déployé et **un dossier Drive de test**, avec des vidéos sans personne identifiable. Cochez au fur et à mesure.

## A. Installation et inscription
- [ ] APK installé (`docs/ANDROID_APK.md` §4) ; nom « SPECTRE Capture », icône neutre, écran noir et blanc.
- [ ] Verrou Tella créé ; l'app redemande le code après mise en arrière-plan.
- [ ] Invitation scannée (QR) → écran de confirmation montrant `script.google.com` → « Appareil configuré ».
- [ ] `spectreListDevices` montre le nouvel appareil.
- [ ] Ouvrir un lien `spectre://enroll?...` depuis une autre app : l'app demande le code puis une confirmation (rien n'est enregistré sans).

## B. Capture et dépôt
- [ ] Accueil : carte « DÉPÔT · DOSSIER PRINCIPAL », puis après `spectreNouvelleManif` le nom de la manif apparaît en revenant à l’accueil.
- [ ] Bouton **Appareil photo** → mode vidéo → filmer 10 s → arrêt : le dépôt démarre seul ; fichier `.mp4` lisible dans Drive, dans le bon dossier.
- [ ] Bouton **Dictaphone** → enregistrer 30 s → arrêt : fichier `.m4a` lisible dans Drive (son correct).
- [ ] Après dépôt vérifié : l'élément disparaît du coffre Tella ; statut « Déposé » dans l'écran de dépôt.
- [ ] Vidéo de 2 à 5 min en 4G : arrive complète (taille identique).

## C. Coupures et arrière-plan
- [ ] Mode avion pendant un envoi → « En attente de réseau » ; réseau rétabli → reprise et dépôt sans doublon dans Drive.
- [ ] Filmer, verrouiller l'écran immédiatement : le dépôt se termine écran verrouillé (vérifier dans Drive). Noter la marque du téléphone si ce n'est pas le cas.
- [ ] Redémarrer le téléphone avec un dépôt en attente, déverrouiller, ouvrir l'app : le dépôt reprend.
- [ ] Notification « Envoi sécurisé en cours » invisible sur l'écran verrouillé.

## D. Sécurité
- [ ] Effacement rapide Tella : coffre et file d'envoi vidés ; les fichiers déjà déposés restent dans Drive.
- [ ] `spectreRevokeDevice` sur l'appareil → nouvelle capture : statut d'erreur « appareil révoqué », aucun fichier créé.
- [ ] Désinstaller/réinstaller : l'app n'est plus inscrite (nouvelle invitation nécessaire).
- [ ] Installer un APK signé avec une autre clé par-dessus : Android refuse.
