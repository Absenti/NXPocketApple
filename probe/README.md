# NXProbe : le test qui décide du projet

Question : une app installée hors App Store peut-elle charger le code d'un jeu qui se trouve dans son dossier `Documents`, et non dans son bundle ? Si oui, on peut ajouter des jeux à l'app sans la réinstaller.

## Construire

```bash
tools/build_zsign.sh        # le moteur de signature, une fois
probe/build_probe.sh
```

Le script produit `probe-out/NXProbe.ipa` et `probe-out/PushProbe.framework`. Il faut Xcode avec le SDK iOS, et le moteur de signature déjà construit (`app/Signing/`) : depuis la phase 0c, la sonde signe elle-même. `SIM=1 probe/build_probe.sh` fait une version pour le simulateur ; `tools/run_probe_simulator.sh` l'installe et l'exécute avec un certificat jetable.

## Lancer sur l'iPhone

1. Installe `NXProbe.ipa` comme une app normale, avec SideStore, AltStore ou Sideloadly. **Pas dans LiveContainer** : il changerait le résultat.
2. Ouvre NXProbe.
3. Appuie sur **Import certificate (.p12)** en haut, choisis le `.p12` exporté depuis les réglages de SideStore, et tape son mot de passe.
4. Le résultat s'affiche à l'écran et est écrit dans **Fichiers → Sur mon iPhone → NXProbe → probe-log.txt**.
5. Envoie la dernière ligne `RESULT:` (ou tout le fichier).

Le certificat et son mot de passe vont dans le trousseau de l'app (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), jamais dans un fichier. La copie temporaire que zsign lit ne vit que le temps de l'appel.

| Test | Ce qu'il vérifie | Attendu |
|---|---|---|
| 1 bundle | un framework dans le bundle, re-signé par l'outil d'installation | PASS (déjà prouvé par nxnative) |
| 2 documents | le même type de framework, copié par l'app dans `Documents/games/`, chargé, puis son code exécuté depuis une autre adresse (`vm_remap`, comme le loader de nxnative) | voir le résultat de 2026-11-10 |
| 3 pushed | optionnel : un framework signé sur l'ordinateur et envoyé dans l'app | PASS si la signature vient de la même équipe que l'app |
| 4 adhoc | contrôle : un fichier avec une signature ad hoc seulement doit être **refusé** | refusé (sinon les tests 2 et 3 ne prouvent rien) |
| 5A | l'app signe elle-même un framework dans `Documents`, avec le certificat qui l'a installée et l'identifiant de signature de l'app, **sans droits**, puis le charge et exécute son code remappé | refusé sur l'iPhone (2026-11-10) |
| 5B | la même chose avec l'identifiant propre du framework (`dev.nxpocket.probe.ResignB`) | refusé |
| **5C** | **5A avec une copie des droits de l'app, tirés de son profil**, dans son propre framework (`ResignC`) | **PASS sur l'iPhone (2026-11-10) : le test décisif de la phase 0c** |

`resignA.xor` et `resignB.xor` sont rangés en XOR dans le bundle pour que l'outil d'installation ne les signe pas : ils doivent arriver dans `Documents` sans aucune signature, et c'est l'app qui les signe. Le test 5A relit l'identifiant de sa propre signature (`dev.nxpocket.probe` sur le simulateur) dans le CodeDirectory de l'exécutable principal, comme le fait le vrai shell.

- `RESULT: RESIGN OK (A refused, C ok)` : la signature doit porter les droits de l'app. **C'est le résultat de l'iPhone.**
- `RESULT: RESIGN OK (A ok, B ok|refused)` : l'identifiant de l'app suffirait, sans droits.
- `RESULT: RESIGN FAILED` : même signé par l'app, le code en dehors du bundle est refusé : il faut une réinstallation par jeu.
- `RESULT: RESIGN INCONCLUSIVE` : une image de test était déjà chargée dans ce processus (dyld ne décharge jamais et rend l'image qu'il a pour un chemin). Ça arrive quand on relance les tests après avoir importé un certificat : **seul le premier passage d'un lancement neuf compte**. Ferme l'app et relance-la.
- `RESULT: RESIGN SKIPPED` : aucun certificat n'a été fourni.
- `RESULT: FEASIBLE` / `BLOCKED` (tests 2/3) : l'ancienne question, réglée.

Si l'app se ferme d'un coup, la dernière ligne du log indique l'étape qui l'a tuée, et le rapport de crash est dans Réglages → Confidentialité → Analyse → Données d'analyse (`NXProbe-*.ips`).

## Test 3 (optionnel)

Il faut signer `probe-out/PushProbe.framework` avec **le même certificat** que celui qui a installé NXProbe :

```bash
codesign --force --sign "Apple Development: <ton identité>" probe-out/PushProbe.framework
```

Ensuite, copie le dossier dans l'app : **Finder → ton iPhone → Fichiers → NXProbe**. Le dossier peut aller à la racine ou dans `Pushed/`. Relance l'app.

La structure vient de `dm/ios/probe` de [nxnative](https://github.com/seedds/nxnative) (MIT).

## Résultat (2026-11-10), premier passage

iPhone 15 Pro, iOS 27.0.1, installé avec SideStore et un Apple ID gratuit : **BLOCKED**.
- Tests 1 et 2c : le framework dans le bundle se charge, et son code remappé tourne.
- Test 2 : la copie dans `Documents` est refusée (`code signature invalid`, errno=1). Pourtant elle est identique octet pour octet et a la même signature « iPhone Developer » et la même équipe.
- Test 2b : impossible de créer le lien physique (EPERM).
- Test 4 : le fichier ad hoc est refusé.

## Résultat dans LiveContainer (2026-11-10)

Même iPhone, NXProbe lancé **dans** LiveContainer (mode sans JIT) : **FEASIBLE**.
- Les tests 2 et 2b se chargent depuis `Documents`.
- Le test 4 (ad hoc) est toujours refusé.

LiveContainer re-signe chaque binaire sur l'iPhone avec l'identifiant de signature de l'app hôte.

## Résultat de la phase 0c (2026-11-10) : RESIGN OK

Même iPhone, hors LiveContainer, premier passage d'un lancement neuf : **`RESULT: RESIGN OK (A refused, C ok)`**.
- 5A et 5B : refusés (`code signature invalid`, errno=1).
- 5C : `resign_a() = 48`, puis le `__dmx0` remappé renvoie 44. Le code signé par l'app se charge depuis `Documents` et s'exécute.
- Signature : 7 à 20 Mo/s, donc 10 à 30 s pour un framework de 200 Mo.

Deux passages ratés avant d'en arriver là, et ce qu'ils ont appris :
1. **5C identique à 5A** (`entitlements 181 bytes (none)` sur les deux) : zsign n'écrit jamais de droits dans une dylib. Corrigé par `patches/zsign/0001-dylib-entitlements.patch`.
2. **L'app se fermait au lancement** : 5C passait la vérification de signature, puis le noyau tuait l'app (`SIGKILL CODESIGNING`, « Invalid Page ») parce que zsign signe le fichier sur place par un mmap inscriptible. Le shim réécrit maintenant le binaire signé dans un fichier neuf. Détails dans `docs/SIGNING.md`.

Un deuxième passage dans le même processus montrait « 5A PASS » : c'était l'image de 5C, rendue par dyld au même chemin. La sonde donne désormais son propre framework à 5C et signale ce cas par `SKIP` / `RESIGN INCONCLUSIVE`.

## Ce que la phase 0c a changé dans la sonde

L'app signe désormais elle-même, avec zsign (voir `tools/zsign_shim.cpp` et `docs/SIGNING.md`). Les deux frameworks de test sortent du bundle sans signature, sont signés dans `Documents`, et leur CodeDirectory est relu avant le chargement : si ce n'est pas l'identifiant demandé, le test le dit au lieu d'accuser iOS.

Le temps de signature est mesuré et extrapolé : 49 808 octets en 48 ms, soit environ 1 MB/s, donc environ 3 minutes pour un framework de 200 Mo. Le PLAN.md demandait un binaire factice de 200 Mo généré au moment du test ; la mesure est faite par extrapolation à la place, parce qu'un IPA ne peut pas transporter 200 Mo et qu'aucun compilateur n'est disponible sur l'appareil pour en fabriquer un valide sur place.

## Ce que le simulateur dit, et ne dit pas

`tools/run_probe_simulator.sh` exécute la sonde sur le simulateur avec un certificat jetable. Ça vérifie le **code** de la sonde : qu'elle retire le XOR, écrive le framework, le signe, relise l'identifiant et tente le chargement. Sur le simulateur, les tests 2 et 4 passent (rien n'y est contrôlé pour du code ad hoc), mais **une signature faite avec un certificat non Apple y est refusée** (`code signature invalid`, errno=1). Le simulateur valide donc quelque chose, et sa réponse ne peut pas être celle de l'iPhone : un `RESIGN FAILED` sur le simulateur ne dit rien, seule la ligne du téléphone compte.
