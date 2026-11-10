# SPECTRE — mode simple (page Pilotage + lien d'invitation)

## Le responsable
- **Page Pilotage** : l'adresse du service (`…/exec`), ouverte connecté à son compte Google. Personne d'autre n'y voit rien (réponse `NOT_FOUND`).
- **Une fois** : mettre l'APK sur Drive (partage « Tous les utilisateurs disposant du lien »), coller ce lien dans « Lien de téléchargement de l'APK » → *Enregistrer*.
- **Inviter** : *Créer un lien d'invitation* → *Copier le message* → l'envoyer (Signal, WhatsApp…). Un lien par personne, une seule utilisation, 48 h.
- **Manif** : taper le nom → *Créer et y envoyer tous les dépôts*. Les téléphones affichent ce nom. *Revenir au dossier principal* ensuite.
- **Téléphone perdu** : *Révoquer* dans la liste.

## Le camarade (Android)
1. Ouvrir le lien reçu → *Télécharger SPECTRE Capture* → installer (autoriser la source, *Installer quand même* si Play Protect avertit).
2. Ouvrir l'appli une fois, créer son code de verrouillage.
3. Revenir au lien → *Ouvrir dans SPECTRE Capture* → *Configurer*. (Variante : copier le message, ouvrir l'appli : elle propose l'invitation toute seule.)
4. Filmer avec **Appareil photo** ou enregistrer avec **Dictaphone** : l'envoi part tout seul.

## Mise à jour du service (pour mémoire)
`backend/apps-script` : `npx -y @google/clasp@2.4.2 push -f`, puis exécuter une fois `spectrePilotageEtat` dans l'éditeur si une nouvelle autorisation est demandée, puis `npx -y @google/clasp@2.4.2 deploy -i <id du déploiement web> -d "…"` (même adresse).
