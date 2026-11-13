# NXPocketApple : plan d'implémentation (version robuste)

Ce plan est destiné à l'agent qui code (DeepSeek). Claude fait la revue à la fin de chaque phase. **Arrête-toi à la fin de chaque phase**, puis livre :
- le diff ;
- les commandes lancées et leur sortie ;
- ce qui n'a pas pu être testé.

Ne passe pas à la phase suivante sans revue.

## 0. But et règles

**But.** Une app iPhone et iPad, NXPocketApple, qui reçoit des jeux Switch déjà convertis par l'ordinateur de l'utilisateur, et les ajoute à sa bibliothèque **sans être réinstallée**.
- Le jeu est lancé depuis l'app : ce n'est jamais une nouvelle app.
- L'ordinateur fait la conversion avec nxnative : déchiffrement avec les `prod.keys` de l'utilisateur, réécriture du code, shaders.
- L'app stocke les données du jeu dans `Documents`, sans réinstallation.
- Pour le code du jeu, l'app fait comme LiveContainer : elle **re-signe sur l'iPhone** chaque framework reçu, avec le certificat de l'utilisateur exporté de SideStore, puis le charge depuis `Documents`. Il n'y a pas de réinstallation. La phase 0a a montré que ça marche sous iOS 27.

**Règles absolues.**
- Aucune clé, aucun firmware, aucun fichier de jeu, aucune donnée extraite d'un jeu dans le dépôt, les tests ou les fixtures. Les `prod.keys` restent sur l'ordinateur de l'utilisateur, qui les fournit et en est responsable.
- Le certificat de l'utilisateur (.p12 exporté de SideStore) et son mot de passe sont stockés **uniquement** dans le Keychain de l'app, avec `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Jamais dans un fichier, jamais dans les logs, jamais envoyés sur le réseau. Le mot de passe de l'Apple ID n'est jamais demandé.
- Pas de ldid (licence AGPL). Le seul outil de signature est zsign (voir 0c).
- Le moteur (nxnative) n'est jamais modifié directement. Un changement du moteur est un patch dans `patches/` (voir 1.3).
- Les commits se font avec l'identité git de l'utilisateur. Jamais `--no-verify`, jamais de push sur `main`.
- Les textes destinés à l'utilisateur sont en français et en anglais (fichiers de chaînes, pas en dur dans le code).
- Fichiers Swift : moins de 800 lignes chacun.

**Vocabulaire.**
- *Moteur* : nxnative, plus les patches de NX2Apple, plus les nôtres.
- *Shell* : l'app iOS qui contient la bibliothèque et lance les jeux. NX2Apple en a déjà une : `frontend-ios/` pour les vues, `engine/dm/ios/Shell/` pour la colle avec le moteur.
- *Framework de jeu* : `DmGame<title ID>.framework`. Il est produit par `scripts/build_ipa_from_nsp.py --shell-framework <dossier>`. Il contient l'hôte du moteur, le code réécrit du jeu, ses tables, son profil, ses shaders et son icône. Il ne contient pas les données du jeu (RomFS).
- *Données du jeu* : `romfs.img`, `aoc/` (DLC), dans `Documents/games/<title ID>/`.

## Phase 0 : chargement depuis Documents (fait, résultat : BLOCKED)

`probe/` (voir `probe/README.md`) a été lancé sur un iPhone 15 Pro sous iOS 27.0.1, installé avec SideStore (Apple ID gratuit, certificat « iPhone Developer », profil d'équipe valable 7 jours).
- Un framework dans le bundle se charge, et son code tourne une fois remappé par `vm_remap`.
- **La copie du même framework dans `Documents` est refusée**, alors qu'elle est identique octet pour octet, qu'elle a la même signature et la même équipe. L'erreur est `code signature invalid`, errno=1.
- Un framework ad hoc est refusé (le contrôle fonctionne).
- Créer un lien physique vers le fichier du bundle est interdit (EPERM).

Conclusion provisoire : une **copie** d'un fichier déjà signé ne se charge pas hors du bundle. Ne tente aucun exploit ni contournement non documenté.

## Phase 0a : test LiveContainer (fait, résultat : FEASIBLE)

NXProbe a été lancé **dans** LiveContainer (mode sans JIT, certificat importé depuis SideStore), sur le même iPhone sous iOS 27.0.1.
- Test 2 : la copie dans `Documents` **se charge**, et son code remappé tourne (44).
- Test 2b : le lien physique se charge aussi.
- Test 4 : le fichier ad hoc est toujours refusé. La vérification des signatures est donc active.
- Ligne `[sig]` : LiveContainer a re-signé **chaque** binaire (l'app et les deux frameworks) avec le certificat de l'utilisateur, et avec **le même identifiant de signature que l'app hôte** (`com.kdt.livecontainer.<TEAM>`). SideStore, lui, donne à chaque framework son propre identifiant (`dev.nxpocket.probe.Probe`). C'est la seule différence visible avec la phase 0.

**Hypothèse à confirmer en 0c** : hors du bundle, iOS n'accepte que du code dont l'identifiant de signature est celui de l'app (ou qui a été signé sur l'appareil d'une autre manière que nous ne voyons pas encore).

## Phase 0c : re-signature sur l'appareil dans notre propre app (à écrire en premier, puis revue, puis test par l'utilisateur)

Ajoute au prototype (installé normalement par SideStore, **pas** dans LiveContainer) :

1. **zsign** en bibliothèque statique pour iOS. Prends la version qu'utilise LiveContainer (la version de Feather modifiée par khcrysalis, basée sur zhlynn/zsign). Note dans `NOTICE` le dépôt, le commit et la licence. Si la licence n'est pas compatible avec un projet MIT, arrête-toi et signale-le.
2. **Import du certificat** : un bouton ouvre le sélecteur de fichiers pour choisir un `.p12`, puis demande son mot de passe. Les deux vont dans le Keychain (règle 0). Affiche le nom du certificat, son équipe et sa date d'expiration. Sous SideStore, le .p12 s'exporte depuis ses réglages : documente le chemin exact que tu trouves dans le code ou l'interface de SideStore, sans l'inventer.
3. **Deux frameworks à signer**, construits par `build_probe.sh` et rangés en XOR dans le bundle comme `adhoc.xor`, pour que SideStore ne les signe pas :
   - `ResignA` : `resign_a()` = 48, une section `__dmx0` ;
   - `ResignB` : `resign_b()` = 49, une section `__dmx0`.

   Ils ont des noms d'installation différents, pour que dyld ne les confonde pas.
4. Test 5A : re-signer `ResignA` dans `Documents/resign/` avec **l'identifiant de signature de l'app** (lu dans le CodeDirectory de l'exécutable principal, comme le fait `sig_info`), puis le charger et lancer le code remappé.
5. Test 5B : la même chose avec `ResignB` et son **propre** identifiant (`dev.nxpocket.probe.ResignB`).
6. Logue la ligne `[sig]` de chaque fichier après signature, et le temps de signature. Logue aussi le temps pour signer un binaire factice de 200 Mo, généré au moment du test (aucune donnée de jeu).
7. Verdict : `RESULT: RESIGN OK (A ok, B ok|refused)` ou `RESULT: RESIGN FAILED - <raison>`.

Si 5A réussit, le plan continue avec la signature sur l'appareil (3.3), en utilisant l'identifiant de 5A. Si 5A et 5B échouent tous les deux, arrête-toi pour la revue : le repli est la réinstallation (annexe A).

## Annexe A (repli seulement) : réinstallation par SideStore

On ne l'utilise que si la phase 0c échoue. L'app recopie son bundle en y ajoutant les frameworks reçus, le zippe, le sert sur `127.0.0.1` et ouvre l'URL d'installation de SideStore (le schéma exact est à lire dans le code source de SideStore). Au redémarrage, elle vérifie que les frameworks sont bien dans le bundle, et ne vide la file d'attente qu'à ce moment. `Documents` est conservé. Ne l'implémente pas tant que Claude ne l'a pas demandé.

## Phase 1 : dépôt et base

1.1 Prépare le dépôt :
- `git init` dans `NXPocketApple/` ;
- un `.gitignore` qui ignore `probe/build/`, `probe-out/`, `engine/`, `build/`, `*.ipa`, `DerivedData/`, et `*.keys`, `*.p12`, `*.mobileprovision` (pour qu'un fichier sensible ne soit jamais ajouté par erreur) ;
- une licence MIT avec un `NOTICE` qui crédite nxnative (seedds, MIT) et NX2Apple (MIT) ;
- un `README.md` court : ce que fait l'app, ce qu'elle ne fait pas (aucune clé ni aucun jeu fourni), et l'avertissement légal.

1.2 Ajoute NX2Apple comme sous-module git dans `third_party/NX2Apple`, épinglé sur un commit ou un tag précis. Le moteur s'obtient avec ses outils : `python3 third_party/NX2Apple/tools/engine.py sync`, qui construit `third_party/NX2Apple/engine/`. Script d'aide : `tools/bootstrap.sh` (sous-module, puis sync, puis vérification).

1.3 Nos patches du moteur vont dans `patches/NNNN-*.patch`, avec une série `patches/series`, appliquée par `tools/apply_patches.sh` au-dessus de `engine/`.
- Chaque patch a un en-tête `Reason:`.
- Le script échoue clairement si un patch ne s'applique plus.
- Il est idempotent : il vérifie d'abord avec `git apply --check -R` si le patch est déjà appliqué.

1.4 Récupère les vues : le shell utilise le package Swift `third_party/NX2Apple/frontend-ios` tel quel, via un chemin local. On ne le copie pas. Ce qui nous est propre va dans `app/Sources/NXPocketApple*`.

1.5 L'app : un projet XcodeGen dans `app/project.yml`. Il part du modèle `engine/dm/ios/project-shell.yml` et du script `engine/dm/ios/tools/build_shell.sh`. Lis les deux en entier avant d'écrire quoi que ce soit.
- Différence 1 : le shell peut être construit **sans aucun framework de jeu intégré**. Aujourd'hui, `build_shell.sh` en exige au moins un (`DM_SHELL_FRAMEWORKS`). Chaque framework embarque son propre hôte (voir `ShellGlue.h`), donc le shell lui-même n'a pas besoin de l'hôte. Vérifie-le dans `ShellMain.m`. Si c'est faux, arrête-toi et signale-le dans la revue.
- Différence 2 : la bibliothèque lit aussi `Documents/games/*/DmGame*.framework`, des frameworks re-signés sur l'appareil (phases 3.3 et 3.4).
- Identifiant de bundle par défaut : `dev.nxpocketapple.app`. Il ne doit jamais changer pour une installation donnée, sinon `Documents` est perdu.
- `UIFileSharingEnabled` et `LSSupportsOpeningDocumentsInPlace` sont à `true`.
- La demande « Increased Memory Limit » est reprise comme dans `build_shell.sh`.

**Critère de fin.** `tools/bootstrap.sh && tools/build_app.sh --sim` produit une app qui démarre sur le simulateur avec une bibliothèque vide. `tools/build_app.sh --device-unsigned` produit une IPA non signée (`CODE_SIGNING_ALLOWED=NO`, puis signature ad hoc comme `probe/build_probe.sh`).

## Phase 2 : le format de paquet de jeu

Un dossier `<title ID>.nxgame/`. Pas de zip : les RomFS font plusieurs Go, et un dossier se copie et se reprend fichier par fichier.

```
0100XXXXXXXXXXXX.nxgame/
  package.json
  DmGame0100XXXXXXXXXXXX.framework/   (sortie de --shell-framework, intacte)
  data/romfs.img                       (image RomFS complète, format de dm/tools/romfs_image.py)
  data/aoc/...                         (optionnel, DLC)
```

`package.json` (schéma 1, validé côté ordinateur **et** côté app) :

```json
{
  "schema": 1,
  "title_id": "0100XXXXXXXXXXXX",
  "name": "…", "version": "1.2.1",
  "framework": "DmGame0100XXXXXXXXXXXX.framework",
  "chain": "<la chaîne de shaders, celle du game.manifest.json du framework>",
  "min_os": "26.0",
  "romfs_id": "<l'identité de romfs.img, celle que lit ShellHost/RomfsIdentity.swift>",
  "files": [ { "path": "DmGame…/DmGame…", "size": 123, "sha256": "…" } ],
  "created_by": "nxpocket-desktop 0.1"
}
```

- **Garde le framework le plus petit possible.** Il est re-signé sur l'iPhone à chaque import et à chaque renouvellement du certificat, donc tout ce qui est des données doit sortir du framework et aller dans `data/` :
  - les bibliothèques de shaders (`msl/`) ;
  - l'archive de pipelines (`pso/`).

  `EngineLaunchPlan` et `docs/launcher-c-plan.md` (le tableau `DM_MSL_DIR` / `DM_PSO_BUNDLE`) disent que `Documents/games/<id>/msl` et `/pso` passent avant ceux du framework. Vérifie-le dans le code, puis déplace-les côté ordinateur. Le framework ne garde que le code, les tables, le profil et l'icône. Indique sa taille pour un vrai jeu dans la revue.
- `files` liste **tous** les fichiers du framework avec leur SHA-256. Pour `data/`, on donne seulement la taille, plus `romfs_id`. On ne recalcule pas un SHA-256 de 15 Go sur un téléphone.
- Les valeurs `chain`, `title_id`, `min_os` et `name` sont reprises de `game.manifest.json` du framework (schéma lu par `frontend-ios/Sources/ShellHost/GameManifest.swift`). On ne les recalcule pas, et le paquet est refusé si elles ne sont pas cohérentes avec ce fichier.
- Le code est écrit **deux fois** : en Python (`desktop/nxpocket/package.py`) et en Swift (`app/Sources/NXPocketImport/Package.swift`). Les deux implémentations lisent les mêmes fixtures de test, qui contiennent de faux fichiers et aucun binaire de jeu.

**Critère de fin.** Tests unitaires des deux côtés : un paquet valide, une taille fausse, un hash faux, un `title_id` incohérent, un chemin en `..` ou absolu (refusé), un lien symbolique (refusé), un `schema` inconnu (refusé).

## Phase 3 : l'app iOS (le cœur)

### 3.1 Réception et import atomique

- Tout paquet arrive d'abord dans `Documents/.incoming/<uuid>/`. Seule la fin d'un import le fait passer dans `Documents/games/<title ID>/`.
- Étapes d'un import :
  1. valider `package.json` ;
  2. vérifier tailles et hashes ;
  3. vérifier le framework (3.2) ;
  4. re-signer le framework (3.3) ;
  5. déplacer le tout avec `rename` vers `Documents/games/<title ID>/` ;
  6. le premier lancement sert de test de chargement (3.5).
- Mise à jour d'un jeu déjà présent : on remplace le framework et les données par un `rename` vers un dossier temporaire, puis on remplace. **Les sauvegardes (`save*`) ne sont jamais touchées.** Relis `GameDeletion.swift` et `BackupExclusion.swift`, et réutilise-les.
- Un import interrompu (l'app tuée ou un crash) est nettoyé au démarrage suivant : on supprime `.incoming/*` plus vieux qu'une heure. Un dossier `games/<id>` n'est jamais à moitié écrit.
- Si l'espace libre (`volumeAvailableCapacityForImportantUsage`) est inférieur à la taille du paquet plus 1 Go, l'import est refusé avant de commencer, avec un message clair.
- Les données du jeu sont marquées `isExcludedFromBackup` (`BackupExclusion`).

### 3.2 Contrôle du code reçu (sécurité)

Le framework reçu va s'exécuter avec les droits de l'app. Avant de le signer, il faut vérifier que :
- l'exécutable est un Mach-O 64 bits arm64, de type `MH_DYLIB`, sans fat binary, avec un `LC_BUILD_VERSION` iOS et un minos ≤ la version d'iOS en cours ;
- chaque `LC_LOAD_DYLIB`, `LC_LOAD_WEAK_DYLIB` et `LC_REEXPORT_DYLIB` pointe vers `/usr/lib/` ou `/System/Library/`, ou vers `@rpath/`, `@loader_path/` ou `@executable_path/` résolus **à l'intérieur** du framework ou des Frameworks de l'app ;
- il n'y a aucun Mach-O caché ailleurs dans le paquet que l'exécutable du framework ;
- il n'y a aucun lien symbolique.

Écris ce parseur Mach-O minimal en Swift (`MachOInspector.swift`), sans dépendance, testé sur des Mach-O construits en test avec `clang` dans un script, jamais sur des binaires de jeu.

### 3.3 Signature sur l'appareil (comme LiveContainer, validée en 0c)

- On signe avec zsign, avec le certificat du Keychain et **l'identifiant validé en 0c** (normalement celui de l'app).
  - On ne signe que le framework : son exécutable et `_CodeSignature/CodeResources`.
  - ~~Aucun droit (entitlement) : un framework ne peut pas en porter.~~ **Faux, mesuré le 2026-11-10** : signé sans
    droits, le framework est refusé dans `Documents` (tests 5A, 5B). Sa signature doit porter **une copie des droits
    de l'app**, tirés de son profil (test 5C : chargé, code remappé exécuté). Cette copie n'accorde rien de plus : les
    droits d'un processus sont ceux de son exécutable principal (voir 3.4).
  - Le binaire signé est réécrit dans un fichier neuf avant le `dlopen` : signé sur place par un mmap inscriptible,
    il passe la vérification puis tue l'app (`SIGKILL CODESIGNING`, « Invalid Page »). Voir `docs/SIGNING.md`.
  - On ne signe **jamais** l'app elle-même : c'est le rôle de SideStore.
- Après la signature, on vérifie l'en-tête : `LC_CODE_SIGNATURE` présent, CodeDirectory avec l'équipe et l'identifiant attendus. On réutilise le code de `sig_info` du prototype.
- **L'équipe du certificat doit être celle de l'app.** L'équipe de l'app se lit dans `TeamIdentifier`, dans `embedded.mobileprovision` (voir `profile_info`). Si ce n'est pas la même, le certificat est refusé, avec un message qui explique pourquoi (il faut exporter le certificat du compte qui a installé l'app).
- **Re-signature automatique.** Dans `Documents/games/<id>/.signing.json`, on garde l'empreinte SHA-256 du certificat qui a signé le jeu, et sa date d'expiration. Au démarrage et avant chaque lancement :
  - si le certificat du Keychain est différent, ou si celui du jeu expire dans moins de 24 heures, on re-signe tous les jeux concernés, avec une barre de progression ;
  - si le certificat du Keychain est expiré, ou si son équipe n'est plus celle de l'app, le jeu passe dans l'état « Certificat à mettre à jour » et ne se lance pas.
- Le cas Apple ID gratuit est le cas normal. Tous les 7 jours, SideStore rafraîchit l'app, et le certificat peut changer. L'utilisateur réexporte alors le .p12 et le réimporte. Mesure si le certificat change vraiment à chaque rafraîchissement, et documente ce que tu observes.

### 3.4 Bibliothèque, lancement et ressources

- `GameCatalogue` (`frontend-ios/Sources/ShellHost/GameCatalogue.swift`) lit `Bundle.main.privateFrameworksURL`. Ajoute une deuxième racine, `Documents/games/*/DmGame*.framework`, **par composition dans notre code** si l'API le permet, sinon par un patch minimal de NX2Apple. En cas de doublon de `title_id`, le bundle passe en premier.
- `ShellMain.m` fait déjà le `dlopen` d'un chemin. Vérifie qu'il accepte un chemin dans `Documents`. S'il suppose un chemin du bundle (rpath, `@executable_path`), corrige-le par un patch (1.3), avec un test.
- **Un seul jeu par processus.** Un framework chargé ne se décharge pas. Après la fermeture d'un jeu, l'app se termine ou redémarre proprement, comme le fait le shell aujourd'hui. Vérifie le comportement actuel et ne l'invente pas.
- **Ressources** : un framework chargé n'a pas de droits propres (sa signature porte une copie de ceux de l'app, 3.3), il hérite de ceux de l'app. Le budget mémoire est donc celui de notre app : environ 3,3 Go sans « Increased Memory Limit », 6 à 8 Go avec (voir `ENTITLEMENTS.md` de NX2Apple).
  - L'app demande `com.apple.developer.kernel.increased-memory-limit` dans son profil d'entitlements.
  - Le README utilisateur explique la procédure GetMoreRam de ce même fichier pour un Apple ID gratuit sous SideStore.
  - Le code tourne nativement, sans JIT ni traduction. La signature a lieu une fois, à l'import ou au renouvellement. Elle ne coûte rien pendant le jeu.

### 3.5 Résistance aux crashs

- Avant un `dlopen`, écris `Documents/.launching` (title ID, horodatage), avec `fsync`. Efface-le quand le jeu a démarré (le premier rendu) ou quand il se ferme proprement.
- Si `.launching` existe au démarrage de l'app :
  - le jeu est marqué « le dernier lancement a échoué », avec le texte de `log.txt` (`LogReader`) ;
  - on ne lance rien automatiquement ;
  - le bouton propose « Re-signer et réessayer ».
- Si `dlopen` échoue, le texte de `dlerror()` est affiché tel quel dans l'état « cassé » du jeu.

### 3.6 Écrans à ajouter (dans le style de ShellUI)

- **Réglages → Certificat** : importer (.p12 et mot de passe), voir le nom, l'équipe et l'expiration, supprimer.
- **Réglages → Mémoire** : montrer si « Increased Memory Limit » est actif (le budget réel lu par `os_proc_available_memory`), avec un lien vers la procédure.
- **Réglages → Recevoir des jeux** : le code d'appairage et l'état du serveur (phase 4).
- **Import en cours** : progression et annulation (l'annulation nettoie `.incoming/<uuid>`).
- Les états d'un jeu en plus de ceux qui existent : « Certificat à mettre à jour », « À re-signer », « Le dernier lancement a échoué ».

**Critère de fin de la phase 3.**
- Les tests unitaires (import, validation Mach-O, équipe du certificat, re-signature au bon moment, nettoyage de `.incoming`) passent.
- Sur le simulateur, un paquet de test est importé à la main dans `Documents`. Ce paquet contient un faux framework construit par un script de test, avec une fonction exportée qui ne lance aucun vrai jeu. La bibliothèque l'affiche.
- Sur l'appareil : un jeu reçu, re-signé sur l'iPhone, puis lancé depuis `Documents`. C'est un test manuel documenté, fait par l'utilisateur avec un de ses jeux.

## Phase 4 : l'outil côté ordinateur et le transfert

### 4.1 `desktop/nxpocket` (Python 3.12, CLI)

- `nxpocket build <dossier du jeu> -k <prod.keys> -o <dossier de sortie>` :
  - appelle `engine/scripts/build_ipa_from_nsp.py <dossier> -k <keys> --shell-framework <tmp> --romfs separate` (vérifie les options exactes avec `--help` ; ne les invente pas) ;
  - assemble `<title ID>.nxgame` (phase 2) à partir du framework et de l'image RomFS dont le script affiche le chemin.
  - **`--delete-source`** : supprime les NSP/XCI d'origine et le dossier de travail **seulement après** que le paquet a été construit et vérifié (relecture des tailles et des hashes). Sans cette option, rien n'est supprimé. Le chemin des `prod.keys` n'est jamais copié, journalisé ou mis dans le paquet.
- `nxpocket push <paquet> [--usb <UDID> | --wifi <hôte>]` : voir 4.2.
- `nxpocket doctor` : Xcode, SDK iOS, moteur synchronisé, version de la chaîne.

### 4.2 Transfert (deux voies, la même logique d'import dans l'app)

> **Décision du 2026-11-11.** Le Wi-Fi passe par `devicectl`, comme le câble : un iPhone qui fait confiance au Mac
> est joignable sur le même réseau (mesuré : 33 Mo/s, autant qu'en USB). Le récepteur à code d'appairage décrit
> au point 2 est retiré : l'app n'ouvre aucun port réseau.

1. **USB (recommandé, le plus rapide).** Utilise `pymobiledevice3` (house_arrest vers le `Documents` de `dev.nxpocketapple.app`). On copie dans `Documents/.incoming/<uuid>/`, puis on écrit en dernier un fichier `Documents/.incoming/<uuid>/.complete`. L'app surveille `.incoming` et n'importe qu'un dossier qui contient `.complete`. Regarde comment `engine/scripts/push_romfs.sh` copie les fichiers et reprends sa méthode.
2. **Wi-Fi.** L'app lance un serveur `NWListener` (Network.framework) seulement quand l'écran « Recevoir des jeux » est ouvert, annoncé en Bonjour `_nxpocket._tcp`.
   - **Appairage** : l'app affiche un code à 6 chiffres. L'ordinateur et l'app en dérivent une clé (HKDF-SHA256 sur le code plus un sel aléatoire envoyé par l'app). Cette clé est stockée dans le Keychain de l'app et dans `~/.config/nxpocket/` sur l'ordinateur. Chaque requête porte un HMAC-SHA256 (méthode, chemin, horodatage, hash du corps). Une requête non signée, ou vieille de plus de 60 secondes, est refusée. Le serveur n'accepte aucune connexion sans appairage.
   - Envoi par morceaux de 8 Mo, reprenable : `PUT /upload/<uuid>/<chemin>?offset=`, puis `POST /commit/<uuid>`.
   - `isIdleTimerDisabled` est activé pendant le transfert. Le texte précise de garder l'app ouverte (iOS suspend les apps en arrière-plan).
   - Le Wi-Fi est une **porte d'entrée pour du code**. Ne l'ouvre jamais par défaut, et ne l'écoute jamais en arrière-plan.

**Critère de fin.**
- `nxpocket build` produit un paquet valide pour un jeu de l'utilisateur (test manuel par l'utilisateur ; aucune donnée de jeu dans le dépôt).
- `push --usb` et `push --wifi` livrent un paquet de test au simulateur (Wi-Fi) ou à l'appareil (USB).
- Tests unitaires : HMAC, refus d'une requête rejouée, reprise d'un envoi coupé, refus d'un `.incoming` sans `.complete`.

## Phase 5 : finitions

- Supprimer un jeu (réutiliser `GameDeletion`, qui garde les sauvegardes), voir l'espace occupé par jeu.
- Une option « Supprimer aussi les sauvegardes », avec confirmation.
- Un journal d'import lisible (`Documents/import-log.txt`, 256 Ko maximum, rotation).
- Le README utilisateur : installer l'app avec SideStore, exporter le .p12 de SideStore et l'importer, activer « Increased Memory Limit » (GetMoreRam), construire et envoyer un jeu, le renouvellement tous les 7 jours.

## Phase 6 (plus tard, ne pas commencer) : tout sur l'iPhone

Gardée pour mémoire. La décision viendra après la phase 5.
- L'utilisateur importe ses `prod.keys` dans le Keychain.
- `nx_extract` (LibHac) compilé pour iOS avec .NET NativeAOT.
- `patch_nso.py` exécuté par un Python intégré (iOS est supporté depuis Python 3.13), avec capstone compilé pour iOS.
- Le framework de jeu écrit par un générateur Mach-O à nous : uniquement des sections, comme `gen_embed.py`.
- Les shaders : le traducteur Ryujinx en NativeAOT, SPIRV-Cross, puis Metal compilé sur l'appareil.
- L'hôte du moteur précompilé et fourni dans l'app.

L'import, la signature et le chargement des phases 3 et 4 sont réutilisés tels quels : seul le producteur du framework change.

## Commandes de vérification (à rapporter à chaque revue)

```bash
tools/bootstrap.sh
python3 -m unittest discover -s desktop/tests
xcodebuild test -project app/NXPocket.xcodeproj -scheme NXPocket -destination 'platform=iOS Simulator,name=iPhone 17'
tools/build_app.sh --device-unsigned
git diff --check
```

Pour chaque revue, indique :
- le commit testé ;
- la version de Xcode et du SDK ;
- le simulateur ;
- les commandes et leur résultat ;
- **ce qui n'a pas pu être testé**, en particulier tout ce qui demande un vrai iPhone.
