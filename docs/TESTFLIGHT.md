# SPECTRE Capture — Distribution TestFlight à l'équipe

**Ne rien publier avant** : build et tests Mac réussis, tests iPhone réussis, vidéos fictives uniquement jusque-là. Chaque étape ci-dessous nécessite votre compte Apple ; rien n'a été fait en votre nom.

## 1. Compte
- Apple Developer Program : **99 USD/an** (99 CHF en Suisse), inscription **individuelle** avec votre identifiant Apple ; le nom affiché comme développeur dans TestFlight sera votre nom. https://developer.apple.com/programs/
- Rôles App Store Connect : vous (Admin) ; éventuellement un second responsable (App Manager) pour la continuité.

## 2. Identité de l'app
1. developer.apple.com → *Identifiers* → nouvel App ID explicite = votre bundle id (ex. `ch.<votre-nom>.spectrecapture`). Capacités : aucune supplémentaire n'est requise (le Keychain et les tâches d'arrière-plan n'en demandent pas).
2. App Store Connect → *Mes apps* → *+* → nom unique (ex. « SPECTRE Capture Stan »), langue Français, bundle id ci-dessus, SKU libre.
3. `./scripts/configure_signing.sh <bundle_id> <TEAM_ID>`, puis signature automatique dans Xcode.

## 3. Version
Dans la cible *Tella* : *Version* (MARKETING_VERSION, actuellement 3.3.0 hérité de Tella ; choisissez p. ex. `1.0.0`) et *Build* (CURRENT_PROJECT_VERSION) à incrémenter à chaque envoi.

## 4. Conformité export (chiffrement)
`Info.plist` contient `ITSAppUsesNonExemptEncryption = false` (hérité de Tella). L'app n'utilise que du chiffrement standard (HTTPS, AES pour la protection des données locales, CryptoKit), ce qui relève en général de l'exemption. À la question d'Apple sur le chiffrement, répondez en cohérence avec ce réglage (chiffrement standard / exempté). Si vous rendez l'app disponible en France, Apple peut demander une déclaration ANSSI : limitez la disponibilité à la Suisse si ce n'est pas nécessaire.

## 5. Envoi
Xcode → destination *Any iOS Device (arm64)* → *Product > Archive* → *Distribute App* → *TestFlight & App Store* (ou *TestFlight Internal Only*) → *Upload*. Le traitement prend 10–30 min.

## 6. Testeurs
- **Internes** (jusqu'à 100 membres de votre équipe App Store Connect) : disponible immédiatement, sans revue Apple. Recommandé pour une petite équipe de recherche.
- **Externes** (jusqu'à 10 000, par e-mail ou lien public) : la première version passe une *revue bêta* Apple (1–2 jours). Fournissez une note de test ; évitez le lien public.
- Chaque membre installe l'app *TestFlight*, accepte l'invitation, installe SPECTRE Capture, puis est inscrit au dépôt par QR (`docs/SETUP_GOOGLE_DRIVE.md` §5).

## 7. Expiration à 90 jours et plan de mise à jour
- Chaque build TestFlight **expire 90 jours** après l'envoi ; l'app cesse alors de s'ouvrir.
- Calendrier : nouveau build tous les ~60 jours (même si rien ne change), avec incrément du numéro de build. Mettez un rappel.
- Avant expiration : les membres mettent à jour via TestFlight ; la file locale et l'inscription sont conservées (Keychain et Application Support persistent lors d'une mise à jour).
- **Vérifier avant chaque mise à jour** qu'aucune vidéo n'est en attente sur les téléphones (écran d'état SPECTRE).

## 8. Téléphone perdu ou volé
1. Immédiatement : `spectreRevokeDevice('<d_…>')` (`docs/SETUP_GOOGLE_DRIVE.md` §6). Le téléphone ne peut plus déposer ; il n'a de toute façon jamais pu lire le Drive.
2. App Store Connect → TestFlight → retirer le testeur (empêche les mises à jour ; n'efface pas l'app installée).
3. Le membre utilise *Localiser* → *Effacer cet appareil* si possible.
4. Vérifiez le dossier Drive : les dépôts de cet appareil sont identifiables par `_<dev6>_` dans le nom et `appProperties.spectreDeviceId`.
5. Vidéos non encore déposées sur le téléphone perdu : protégées par le code Tella et la protection de données iOS, mais **considérées comme potentiellement perdues**.

## 9. Fin du projet
Supprimez les testeurs, laissez expirer les builds, `spectreRevokeAllDevices`, archivez puis supprimez le projet Apps Script quand vous n'en avez plus besoin.
