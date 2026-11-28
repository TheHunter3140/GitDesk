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

## Nouveautés 1.6.0 — publication publique, confidentialité, arrière-plan, nouveau design
- **Deux dépôts** : le dépôt privé de compilation reste comme avant (tout le détail, les logs). En plus, après une compilation réussie, un **dépôt public séparé** reçoit une release avec le résultat compilé, le **code source nettoyé** et une description. Réglages : Compiler → réglages → Publication publique. Bouton « Publier maintenant » dans le détail d'une compilation.
- **Confidentialité** : avant publication, GitDesk retire du code les jetons (dont ton jeton GitHub exact), clés privées, `.env`, certificats et profils de signature, dossiers `.git`, identifiants d'équipe Apple et adresses noreply GitHub ; commits du dépôt public avec une identité anonyme ; ton jeton n'est jamais écrit dans un fichier. Le code nettoyé n'existe que dans une copie : l'original n'est pas modifié. Ton nom d'utilisateur GitHub reste visible dans l'adresse du dépôt public.
- **Écran allumé** pendant compilation, envoi, publication, copie et téléchargement.
- **Continuer en arrière-plan** : tant qu'une tâche tourne, un son silencieux (désactivable) empêche iOS de suspendre l'app ; mémoire libérée automatiquement en arrière-plan ou en cas d'alerte mémoire.
- **Design** : fond doux, surfaces en verre (Liquid Glass avec un SDK récent, matériau translucide sinon), icônes dégradées, bandeau flottant des tâches en cours, retours haptiques. Gestes identiques partout.
- Le workflow `build.yml` essaie le Xcode stable le plus récent et revient au Xcode par défaut en cas d'échec.

## Nouveautés 1.5.0 — vrai gestionnaire de fichiers
- **Plus de chemins à taper** : l'onglet Fichiers d'un dépôt et l'explorateur général sont maintenant le même gestionnaire. On entre dans un dossier en le touchant, un fil d'Ariane cliquable permet de remonter n'importe où, bouton « parent » et balayage depuis le bord gauche pour revenir. Les « / » ne servent plus à déplacer (un nom avec « / » est refusé).
- **Gestes façon app Fichiers** : appui long = menu (Ouvrir, Aperçu rapide, Copier, Couper, Coller dans…, Déplacer vers…, Copier vers…, Dupliquer, Renommer, Compresser en ZIP, Extraire ici / vers…, Informations, Copier le chemin, Partager, Supprimer) ; balayages sur une ligne (copier/couper, renommer/supprimer) ; **glisser-déposer** d'un ou plusieurs éléments vers un dossier, vers le fil d'Ariane ou le dossier courant ; glisser des fichiers depuis l'app Fichiers d'Apple directement dans la liste.
- **Sélection multiple** avec barre d'actions (copier, couper, déplacer, partager, supprimer, plus), « Tout / Aucun ».
- **Fichiers cachés** (nom commençant par « . ») : bouton œil, réglage mémorisé, compteur « N cachés » en bas ; affichés en grisé.
- **Affichage** : liste ou grille avec miniatures d'images, tri par nom / date / taille / type, ordre, dossiers en premier.
- **Recherche** par nom dans le dossier et ses sous-dossiers ; dans un dépôt, recherche dans le code (touche « Rechercher »).
- **Dépôt** : fichiers modifiés (M), ajoutés (A) et dossiers contenant des changements colorés ; ouverture dans l'éditeur du dépôt.
- **Corbeille** : supprimer envoie à la corbeille (restaurer, vider, ou suppression définitive au choix).
- **Informations** : taille réelle (dossiers compris), dates, permissions, chemin.
- **Actualisation automatique** : un fichier déposé via l'app Fichiers apparaît seul ; la détection du dossier surveillé « Builds » est inchangée.
- Le workflow `.github/workflows/build.yml` est fourni tel quel (IPA non signé, release `gitdesk-latest`).

## Correctif 1.4.1
- Le workflow localise `project.yml` même s'il est dans un sous-dossier du dépôt (cas d'un dossier déposé tel quel sur GitHub).
- Le résumé des logs reconnaît davantage d'erreurs (projet introuvable, fichier absent, commande introuvable).

## Nouveautés 1.4.0
- **Dossier surveillé** : dépose une archive (ZIP, TAR, TAR.GZ) ou un dossier de code source dans Fichiers → GitDesk → Builds. GitDesk le détecte dès que la copie est terminée (app ouverte), le compile automatiquement (réglable), range l'original dans « Traitées » et dépose le résultat dans « Résultats ». Un dossier `Build` / `build` à la racine de Documents est aussi surveillé.
- **Workflow façon Pal** : journal complet copié dans un fichier, **résumé des logs** (erreurs, avertissements, durée, fin du journal) écrit dans le résumé du run et dans les notes de la release, puis **publication dans la release « <projet>-latest »** (remplacée à chaque build ; en cas d'échec : « <projet>-latest-echec » avec le résumé et le journal). L'artefact Actions reste en secours.
- Le workflow de GitDesk lui-même (`.github/workflows/build.yml`) suit le même modèle : l'IPA non signé est publié dans la release **gitdesk-latest**.
- **Plus de limite à 50 Mo** : l'archive est envoyée comme fichier d'une release brouillon (2 Go maximum, envoi depuis le disque), puis supprimée après le build.
- Dossier compressé localement avec conservation des bits d'exécution (gradlew, scripts).
- Téléchargements sécurisés : le jeton n'est plus transmis lors des redirections vers un autre hôte.
- Le lien de création de token demande maintenant `repo` **et** `workflow`.

## Nouveautés 1.3.0
- Onglet **Compiler** : détection du type de projet (XcodeGen, Xcode, Swift Package, Android/Gradle, Gradle/Java, Rust, Go, CMake, Make, Node.js, Python, .NET, sources C / C++ / Java), workflow GitHub Actions généré, suivi en direct, reprise, annulation, résultat téléchargé et partageable.
- Notifications : push via **ntfy** (dernière étape du workflow, fonctionne app fermée) + notification locale quand l'app est active.
- Token GitHub : portées `repo` et `workflow` requises.
