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
