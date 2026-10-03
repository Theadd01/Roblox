--!strict
-- IA des pays sans joueur (voir server/AI). Réglages par défaut : la personnalité de chaque
-- pays (Config/Personalities) en remplace une partie.
-- À chaque tour, l'IA note chaque action possible de 0 à 1 (score d'utilité)
-- et exécute les meilleures : vendre ses surplus, acheter ses manques, construire
-- ou améliorer des usines (version 1), recruter, défendre et attaquer (version 2).

local AI = {
	turnInterval = 20, -- secondes entre deux tours d'un même pays (les pays jouent l'un après l'autre)
	startDelay = 20, -- secondes avant les premiers tours (le temps de choisir son pays)
	actionsPerTurn = 3, -- actions au plus par tour...
	maxPerKind = { Commerce = 2, Industrie = 1, Defense = 2, Attaque = 2, Diplomatie = 1, Contrat = 1 } :: { [string]: number }, -- ... et par famille
	minScore = 0.3, -- une action notée en dessous n'est pas faite

	-- Stock gardé : quelques cycles de consommation (usines, entretien des armées), acheté
	-- en urgence s'il manque, plus une réserve de précaution, achetée seulement à prix normal
	reserveCycles = 12,
	reserves = {
		Nourriture = 60,
		Petrole = 20,
		Acier = 20,
	} :: { [string]: number },
	creditReserve = 400, -- crédits que l'IA garde toujours
	surplusFactor = 1.5, -- l'IA vend ce qui dépasse 1,5 fois sa réserve
	minTrade = 5, -- pas d'échange plus petit

	-- Prix acceptés, en part du prix de base ; tirés au hasard entre ces bornes à chaque tour
	sellFloor = { min = 0.9, max = 1.1 }, -- l'IA ne vend pas en dessous...
	surplusDiscount = 0.1, -- ... sauf avec un gros surplus : jusqu'à 10 % de moins
	buyCeiling = { min = 1.15, max = 1.5 }, -- ni n'achète au-dessus ce qui fait tourner le pays (plus si le manque est grave)
	reserveCeiling = { min = 0.95, max = 1.05 }, -- ni au-dessus pour ses réserves de précaution et ses projets
	maxPriceImpact = 0.03, -- un échange de l'IA fait bouger le prix de 3 % au plus

	-- Usines : l'IA construit ou agrandit seulement si ses régions fournissent
	-- au moins cette part des matières premières nécessaires
	minInputCoverage = 0.5,

	-- Armées (armées de terre). Les forces se comparent en puissance x points de vie.
	maxArmies = 3, -- armées de terre au plus par pays IA
	recruitBatch = 3, -- troupes recrutées au plus par action
	upkeepShare = 0.7, -- l'entretien des armées peut prendre 70 % de la production du pays...
	upkeepHorizon = 60, -- ... plus les importations que ses crédits paient pendant 60 cycles
	adjacentThreat = 0.5, -- une armée étrangère à l'arrêt à côté compte pour moitié (en marche vers soi : en entier)
	safetyMargin = 1.3, -- l'IA veut une défense 30 % plus forte que la menace
	attackRatio = 2.5, -- l'IA n'attaque qu'avec une force 2,5 fois supérieure
	attackMorale = 70, -- moral minimum pour lancer une attaque
	warChest = 500, -- pour préparer une attaque, crédits gardés en plus du coût de l'armée
	valueScale = 80, -- production (en crédits par cycle) d'une région très intéressante
	peaceTroops = 0, -- troupes gardées en temps de paix (0 : seulement en cas de menace)...
	peaceArmyDelay = 120, -- ... levées après les 2 premières minutes, si le pays garde warChest crédits
	weakTargetFactor = 1, -- attrait d'un pays en guerre ou affaibli (moins de 1 : il attire plus)
	weakTargetEase = 1, -- marge demandée face à lui (moins de 1 : attaque avec moins d'avance)
	warMemory = 180, -- secondes pendant lesquelles un pays qui a combattu reste « en guerre »
	enemyTargetFactor = 0.5, -- attrait d'un pays déjà en guerre avec lui (moins de 1 : il attire plus)
	blocDeterrence = 0.6, -- chaque allié de la cible la rend moins attirante (tout le bloc entrerait en guerre)
	leaderTargetFactor = 0.7, -- en guerre contre le leader de la partie : il attire plus
	minStabilityToAttack = 35, -- en dessous, l'IA ne lance plus de conquête (effort de guerre réduit)
	lowStabilityPeace = 40, -- en dessous, elle cherche davantage la paix

	-- Armée de terre (divisions, SYSTEME_MILITAIRE.md 8, cahier des charges v2) : l'IA utilise les
	-- mêmes outils que le joueur (recrutement, généraux, attaques, fortifications), sans tricher
	landAttackRatio = 1.5, -- attaque une région quand ses divisions voisines sont 1,5 fois plus fortes que la défense
	extraDivisions = 0, -- divisions voulues en plus d'une par région frontalière
	divisionsPerGeneral = 10, -- un général pour 10 divisions environ
	garrisonPerBorder = 1, -- divisions gardées sur chaque région frontalière (le surplus rejoint les généraux)
	generalMinTroops = 4, -- un général n'attaque qu'avec 4 troupes au moins...
	generalRange = 6, -- ... une région ennemie à 6 régions au plus de son quartier général
	launchRatioShare = 0.75, -- un général attaque à landAttackRatio x 0,75 (son armée enchaîne ensuite)
	minDivisionsForWar = 4, -- pas de nouvelle guerre avec moins de 4 divisions prêtes
	fortifyDanger = 1.3, -- fortifie une région frontalière quand l'ennemi en face est 1,3 fois plus fort

	-- Diplomatie (voir DiplomacyAI) : envie de s'allier (0 à 1). L'IA ne propose jamais la paix, une
	-- trêve ni un événement : elle vote sur ce que proposent les joueurs (CouncilService, CouncilAI, Config/Council)
	allianceWillingness = 0.45,
	peaceWillingness = 0.45, -- pour son vote sur une paix ou une trêve proposée par un joueur
	proposalInterval = 120, -- secondes entre deux propositions d'alliance d'un même pays IA
	proposalRepeat = 300, -- secondes avant de refaire une proposition au même pays
	longWar = 240, -- une guerre plus longue que ça pèse (l'IA pense davantage à la paix)
	minWarDuration = 240, -- avant 4 minutes de guerre, l'IA ne pense presque pas à la paix (offensives à préparer)

	-- Contrats (voir TradeAI) : envie de proposer des contrats de vente aux joueurs (0 à 1)
	contractEagerness = 0.3,

	-- Rythme des conquêtes dans le monde
	firstAttackDelay = 300, -- aucune attaque de l'IA pendant les 5 premières minutes...
	preparationTime = 120, -- ... mais elle prépare ses armées 2 minutes avant
	offensiveInterval = 90, -- une nouvelle offensive de l'IA au plus toutes les 90 s dans le monde
	maxOffensives = 3, -- offensives de l'IA en cours en même temps, au plus
	attackCooldown = 300, -- un pays IA attend 5 minutes entre deux attaques...
	followUpCooldown = 40, -- ... mais en guerre, il enchaîne les régions du même ennemi (pays découpés en régions)
}

return AI
