# GitDesk

App iOS (SwiftUI, iOS 16+) : cloner un dépôt GitHub, modifier les fichiers, commit/push, branches, historique, diff, recherche, PR.
Même chaîne que Pal : XcodeGen + GitHub Actions, IPA non signé (`.github/workflows/build.yml`) à signer ensuite.

## Compiler
1. Crée un dépôt GitHub, mets-y tout le contenu de ce dossier (y compris `.github`).
2. Actions → « Build IPA » → Run workflow → télécharge l'artefact `GitDesk-ipa`.
3. Signe et installe comme Pal. Au 1er lancement : colle un token GitHub (portée `repo`).

## Fonctionnement
- Pas de libgit2 : tout passe par l'API REST GitHub (Git Data API). Clone = téléchargement des fichiers de la branche, statut = comparaison des empreintes git locales, commit = blobs + arbre + commit + mise à jour de la branche.
- Fichiers visibles dans l'app Fichiers (Documents/Workspaces/<owner>__<repo>/tree).
- Pull : si tu as modifié un fichier changé aussi à distance, la version distante arrive à côté en `.REMOTE` ; fusionne à la main puis supprime-la avant de commit.
- Limites : dépôts très gros (arbre tronqué par l'API) non gérés, pas de rebase/merge local, pas de sous-modules.

## Nouveautés 1.1.0
- Navigateur GitHub intégré (WKWebView) : onglet « GitHub » dans chaque dépôt (ouvre le dépôt sur le site), globe en haut à gauche de la liste des dépôts (accueil, notifications, PR, issues).
- Fonctions façon Safari : barre d'adresse (saisis `owner/repo`, une URL ou une recherche), précédent/suivant, recharger/arrêter, tirer pour rafraîchir, partage, ouvrir dans Safari, rechercher dans la page, version ordinateur, zoom, copier le lien, téléchargements (feuille de partage → Enregistrer dans Fichiers), boîtes confirm() de GitHub. Session GitHub conservée entre les lancements.
- Bac à sable : par défaut, les liens hors GitHub s'ouvrent dans une fenêtre Safari séparée (réglable : « Limiter à GitHub »).
- Connexion simplifiée : bouton pour créer le token (déjà prérempli) et coller depuis le presse-papiers.
- Ergonomie : recherche intégrée à l'onglet Fichiers, bouton « N modifications · Commit », confirmation avant rétablir/supprimer, retour haptique, bouton « Voir sur GitHub » après un push, undo/redo dans la barre du clavier, messages d'erreur 404/403 expliqués.

## Nouveautés 1.2.0
- Deux parties : **Travail** (dépôts, outils) et **Paramètres**. Logo ajouté.
- **Fichiers** : explorateur complet (Travail → Fichiers et archives, ou « Importer, extraire, copier… » dans un dépôt). Importer des fichiers, un dossier ou une archive depuis l'app Fichiers ; copier / couper / coller (remplacer, garder les deux ou ignorer en cas de doublon), dupliquer, renommer, supprimer, partager, créer dossiers et fichiers, sélection multiple.
- **Extraction** : ZIP, TAR, TAR.GZ/TGZ, GZ (sans ZIP64 ni archives chiffrées). Pas de 7z/RAR.
- **Navigateur** : réglages mémorisés (taille du texte 50–150 %, défaut 85 %, version ordinateur, limitation à GitHub, dernière page), favoris, historique, session GitHub conservée.
- **Téléchargements** : gestionnaire dédié (progression, annulation, ouvrir, partager, extraire), fichiers dans Documents/Téléchargements.
- **Cache et confidentialité** : tailles, vider le cache, cookies, historique, nettoyer le navigateur, tout vider.

## Nouveautés 1.4.0
- **Dossier surveillé** : dépose une archive (ZIP, TAR, TAR.GZ) ou un dossier de code source dans Fichiers → GitDesk → Builds. GitDesk le détecte dès que la copie est terminée (app ouverte), le compile automatiquement (réglable), range l'original dans « Traitées » et dépose le résultat dans « Résultats ». Un dossier `Build` / `build` à la racine de Documents est aussi surveillé.
- **Workflow façon Pal** : journal complet copié dans un fichier, **résumé des logs** (erreurs, avertissements, durée, fin du journal) écrit dans le résumé du run et dans les notes de la release, puis **publication dans la release « <projet>-latest »** (remplacée à chaque build ; en cas d'échec : « <projet>-latest-echec » avec le résumé et le journal). L'artefact Actions reste en secours.
- Le workflow de GitDesk lui-même (`.github/workflows/build.yaml`) suit le même modèle : l'IPA non signé est publié dans la release **gitdesk-latest**.
- **Plus de limite à 50 Mo** : l'archive est envoyée comme fichier d'une release brouillon (2 Go maximum, envoi depuis le disque), puis supprimée après le build.
- Dossier compressé localement avec conservation des bits d'exécution (gradlew, scripts).
- Téléchargements sécurisés : le jeton n'est plus transmis lors des redirections vers un autre hôte.
- Le lien de création de token demande maintenant `repo` **et** `workflow`.

## Nouveautés 1.3.0
- Onglet **Compiler** : détection du type de projet (XcodeGen, Xcode, Swift Package, Android/Gradle, Gradle/Java, Rust, Go, CMake, Make, Node.js, Python, .NET, sources C / C++ / Java), workflow GitHub Actions généré, suivi en direct, reprise, annulation, résultat téléchargé et partageable.
- Notifications : push via **ntfy** (dernière étape du workflow, fonctionne app fermée) + notification locale quand l'app est active.
- Token GitHub : portées `repo` et `workflow` requises.
