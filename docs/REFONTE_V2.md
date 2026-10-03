# Refonte v2 (inspirée de HOI4) : ce qui a changé

Ce document résume l'application du cahier des charges v2 au jeu existant. Les noms des modules,
des remotes et des dossiers `EtatMonde` d'origine ont été gardés autant que possible. Toutes les
valeurs d'équilibrage sont dans des fichiers de configuration (`ReplicatedStorage/Shared/Config`) :
on équilibre sans toucher à la logique.

## Installer la nouvelle version

Deux façons de faire :

1. **Place corrigée (le plus simple)** : ouvrir `WW3_v2.rbxl` dans Roblox Studio. C'est ta place
   d'origine (`fianl.rbxl`) avec les nouveaux scripts. La carte, l'interface, les modèles et les
   réglages ne changent pas.
   Pour la refaire à partir de ta place :
   ```sh
   lune run tools/lune/patch_place.luau fianl.rbxl build/WW3_v2.rbxl
   ```
   L'outil met à jour 53 scripts, en crée 7 et en supprime 4 (voir plus bas). Il ne touche pas
   aux autres instances.
2. **Rojo** : `rojo serve` dans le dossier du dépôt, puis connecter le plugin Rojo dans Studio.
   `default.project.json` ne synchronise que `ReplicatedStorage.Shared`,
   `ServerScriptService.Server`, `ServerScriptService.Tests` et
   `StarterPlayer.StarterPlayerScripts.Client`. Le reste de la place est ignoré
   (`$ignoreUnknownInstances`).

Scripts créés : `Shared/Config/CombatConfig`, `Shared/VoteRules`,
`Client/Military/TroopPicker`, `Client/UI/ConfirmDialog`, `Client/UI/WarPanel`,
`Tests/Research.spec`, `Tests/Votes.spec`.
Scripts supprimés : `Server/Military/GeneralAI`, `Server/Military/BattlePlans`,
`Client/Military/PlanPanel`, `Client/Military/PlanRenderer`. Les généraux remplacent les anciens
plans de bataille.

## 1. Trêves, paix et événements : seul un joueur les lance

- Les IA ne proposent plus jamais de trêve, de paix ni d'événement mondial :
  - `DiplomacyAI` ne propose plus la paix ;
  - le Conseil ne se réunit plus tout seul ;
  - `WorldEvents.automatic = false` ;
  - `Match.automaticCrisis = false`.

  Les IA gardent tout le reste : guerres, économie, alliances.
- Un joueur propose un vote depuis l'onglet **Diplomatie** :
  - les boutons « 🤝 Paix » et « 🕊️ Trêve » sur chacune de ses guerres ;
  - le bouton « 🏛️ Proposer un vote au Conseil ».

  Il peut proposer une trêve, la paix, un cessez-le-feu mondial, des sanctions, une aide
  humanitaire, la reconnaissance d'une conquête, une taxe sur le pétrole ou un événement mondial.
  Il choisit une **offre** en crédits. Seuls les pays IA qui votent « oui » la touchent ; le reste
  lui est rendu. La fenêtre affiche le soutien estimé des IA avant l'envoi.
- **Qui vote** :
  - pour une trêve ou la paix : les pays des deux camps en guerre ;
  - pour les autres votes : tous les pays.

  Ça passe à la **majorité simple** : plus de « pour » que de « contre », les abstentions ne
  comptent pas. Le résultat montre le détail : le vote de chaque pays, la chance de « oui » de
  chaque IA et les crédits reçus.
- **Vote d'une IA** (`Shared/VoteRules`, réglages dans `Config/Council`), en probabilité de « oui » :
  - on part de `base` ;
  - on ajoute l'affinité envers celui qui propose (alliance, guerre, réputation, ennemi commun) ;
  - on ajoute le bonus du paiement : plus on paie, plus elle dit oui, avec des rendements
    décroissants (`payment.maxBonus`, `payment.scale`) ;
  - on retire un malus si elle **gagne sa guerre** (`winning.malus`) ;
  - on ajoute son intérêt propre (sanctions contre un allié, pétrole, personnalité).

  Le tout est borné entre `minChance` et `maxChance`.
- Remotes : `ProposerVote`, `VoterConseil`, `ConvaincreConseil`. L'ancien remote `ProposerPaix`
  est supprimé.

## 2. Combat terrestre

Toute la logique est dans `Server/Military/Combat` et `BattleManager`. Tous les chiffres sont dans
**`Config/CombatConfig`**.

- **Une boucle serveur par bataille**, avec un tick toutes les `tickSeconds = 0.5` s. Les modèles
  ne font qu'animer : le client anime au plus `animatedShotsPerSide` tirs par camp et par tick, en
  changeant de tireurs à chaque tick.
- **Ciblage en rotation** : chaque soldat engagé reçoit une cible, le défenseur le moins visé en
  premier. Plus aucun soldat ne reste inactif. L'artillerie (`rear`) n'est visée qu'en dernier.
- **Dégâts d'un tick** : `DPS × tick × (1 + recherche + général + …) × terrain × efficacité
  (vsArmor / vsSoft) × avantage du nombre`, divisés par la défense de la cible. Le défenseur a
  `defenderBonus = +15 %`, plus le retranchement et les fortifications.

| Unité | PV | DPS | Particularité |
|---|---|---|---|
| Infanterie | 40 | 12 | |
| Blindés | 120 | 25 | blindé, ×1,5 contre l'infanterie |
| Artillerie | 30 | 35 | à l'arrière |

  Les autres types de divisions (motorisée, mécanisée, montagne, antichar, milice) ont aussi leur
  ligne dans `units`.
- **Largeur de front** : `frontWidth = 20` soldats par camp. Les réserves remplacent les tombés.
  Le déploiement est progressif (`deployment`) : un 10 contre 10 en plaine dure environ 20 s, et un
  soldat meurt en 2 à 4 s contre un égal. On peut le vérifier avec
  `lune run tools/lune/simulate_combat.luau`.
- **Attaque depuis toutes les régions voisines** : un clic sur « Attaquer » engage les divisions
  de toutes ses régions qui touchent la cible (par exemple 2 × 10 = 20). La limite de 10 par
  région ne compte que pour le stationnement.
- **Avantage du nombre** (`numbers`) et **moral** (`morale`) : sous `routBelow`, tout le camp se
  replie au lieu de se battre jusqu'au dernier.
- **Soldat à 0 PV** : il se replie dans une région amie voisine avec `retreatHealth = 25 %` de ses
  PV. S'il n'en a aucune, il meurt.
- **Prise immédiate** : la région change de propriétaire dès qu'il ne reste plus aucun défenseur,
  et les attaquants y entrent tout de suite.
- **« Attaque continue »** (`continuous`) : après une victoire, l'armée enchaîne sur la région
  ennemie voisine la moins défendue.

## 3. Cliquer sur une région ennemie

Un clic sur une région étrangère ouvre `Client/UI/WarPanel`. Il affiche le pays, les troupes
visibles et le terrain, avec un seul bouton :

- « **Déclarer la guerre** » ;
- ou « **Attaquer** » si on est déjà en guerre ;
- ou la raison du blocage (allié, trêve, protection de départ), avec un raccourci vers la
  Diplomatie.

La confirmation se fait en un clic (`ConfirmDialog`). Le serveur utilise la même fonction que le
menu Diplomatie (`DeclarerGuerre`), puis la commande `AttaquerRegion`. Si un général est
sélectionné, l'attaque passe par `DeplacerGeneral`.

## 4. Recherche (arbre à niveaux)

Les réglages sont dans `Config/Technologies`. Les effets sont lus avec `Shared/TechState`, le
serveur est `Economy/ResearchService` et l'interface `UI/Tabs/ResearchTab`.

- **Onglets** : Infanterie, Blindés, Artillerie, Aviation, Marine, Économie, Industrie et
  Renseignement.
- **Cartes** : chaque carte affiche le nom, le niveau, le coût, la durée et l'effet. Des flèches
  la relient à ses prérequis.
- **File de recherche** : `Technologies.slots = 3` recherches en parallèle, avec barres de
  progression. La technologie « Centres de recherche » ajoute des emplacements. Remotes :
  `Rechercher` et `AnnulerRecherche`.
- **Équipement des unités** : niveaux 1 à 5. Le niveau 1 est gratuit.

| Niveau | PV | Dégâts |
|---|---|---|
| 2 | +20 % | +15 % |
| 3 | +40 % | +30 % |
| 4 | +65 % | +50 % |
| 5 | +100 % | +75 % |

  Les effets valent pour **tout le pays, unités existantes comprises**.
- **Technologies économiques** : production, impôts, vitesse de recrutement, et stationnement
  (10 → 12 → 15 divisions par région).
- **Recherche des IA** : elles cherchent plus lentement selon la difficulté
  (`Match.difficulties.*.researchSpeed`).
- **Anciennes sauvegardes** : les niveaux sont publiés en attributs, et l'ancien format est
  encore lu.

## 5. Généraux (armées)

Les réglages sont dans `Config/Military.generals`. Le serveur est `Military/Armies`, l'interface
`Military/GeneralPanel` et `Military/TroopPicker`.

- **Créer une armée** : on achète un général dans l'onglet Armée, puis on choisit ses troupes par
  type et par nombre, dans ses régions. Ces troupes quittent la carte et rejoignent son armée, qui
  s'affiche comme une seule unité avec un compteur.
- **Panneau du général** :
  - nom, niveau et barre d'expérience ;
  - liste des troupes, à libérer ou à supprimer ;
  - ajouter des troupes, améliorer le général, le renommer ou le renvoyer ;
  - capacité : `capacity = {20, 30, 40, 50, 60}` selon le niveau.
- **Expérience** : il en gagne au combat, plus encore à chaque victoire et à chaque région prise.
  À chaque niveau, le joueur choisit un bonus : attaque, défense, vitesse, moral ou récupération.
  On peut aussi monter de niveau avec des crédits (`upgradeCost`).
- **Déplacement de l'armée** :
  - elle ignore la limite de 10 divisions par région ;
  - elle se déplace à la vitesse de sa troupe la plus lente ;
  - elle respecte la largeur de front au combat ;
  - elle peut attaquer en continu.
- **Défaite** : selon la difficulté (`generalDefeat`), le général vaincu est **blessé** (hors
  combat `woundedSeconds`) ou **mort**.
- Les traits, le ravitaillement, le moral (déroute) et le terrain s'appliquent aussi aux armées.

Commandes (RemoteEvent `CommandeMilitaire`) : `NommerGeneral`, `AbsorberTroupes`,
`AssignerDivisions`, `RetirerDivisions`, `LibererTroupes`, `SupprimerTroupes`, `DeplacerGeneral`,
`AttaqueContinueGeneral`, `AmeliorerGeneral`, `ChoisirBonusGeneral`, `RenommerGeneral` et
`RenvoyerGeneral`.

## IA

- **Armée** (`AI/MilitaryAI`) : elle utilise les mêmes outils que le joueur.
  - Elle recrute et achète des généraux, puis leur confie ses divisions en surplus. Une garnison
    reste sur chaque région frontalière.
  - Elle choisit les bonus de niveau de ses généraux.
  - Elle attaque depuis toutes ses régions voisines quand elle est assez forte
    (`landAttackRatio`), et lance ses généraux en attaque continue.
- **Recherche** (`AI/ResearchAI`) : elle suit le nouvel arbre, plus lentement selon la difficulté.
- **Conseil** (`AI/CouncilAI`) : elle vote, et ne propose jamais rien.

## Réglages utiles

| Réglage | Fichier | Rôle |
|---|---|---|
| `tickSeconds`, `frontWidth`, `defenderBonus`, `retreatHealth`, `units`, `deployment`, `numbers`, `morale` | `Config/CombatConfig` | combat |
| `maxDivisionsPerRegion`, `generals` | `Config/Military` | stationnement et généraux |
| `slots`, `list` (coûts, durées, effets) | `Config/Technologies` | recherche |
| `chance`, `affinity`, `paymentSteps`, `voteDuration`, `truceDuration` | `Config/Council` | votes |
| `difficulty`, `difficulties`, `automaticCrisis` | `Config/Match` | difficulté |
| `automatic`, `proposable` | `Config/WorldEvents` | événements |

La difficulté se règle avec l'attribut `Difficulte` de Workspace (`Facile`, `Normal` ou
`Difficile`). Sans cet attribut, c'est `Match.difficulty` qui compte.

## Tests

- **Dans Studio** : le script `ServerScriptService.Tests.LanceurTests` lance toutes les suites
  `*.spec`.
- **Hors de Studio** (avec [Lune](https://lune-org.github.io/docs)) :
  ```sh
  lune run tools/lune/run_tests.luau            # toutes les suites
  lune run tools/lune/run_tests.luau Combat     # une suite
  lune run tools/lune/simulate_combat.luau      # durées de combat
  ```
  Les suites sont Buildings, Combat, Economy, Generals, Income, Population, Research, Supply et
  Votes. Toutes réussissent.

## Limites connues

- La logique est testée hors de Studio, mais l'interface et les animations n'ont pas pu être
  essayées dans un vrai serveur Roblox. Fais une partie de test dans Studio (Play, ou Local Server
  à 2 joueurs pour les votes).
- L'analyse de types (luau-lsp, nouveau solveur) signale encore quelques « Function only returns
  1 value » sur des `pcall`. Ce sont des faux positifs : le code d'origine en avait déjà de
  semblables.
