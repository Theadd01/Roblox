--!strict
-- Constantes du système militaire terrestre façon Hearts of Iron IV (voir SYSTEME_MILITAIRE.md).
-- Les statistiques des divisions sont dans Config/Divisions, le terrain dans Config/Terrain,
-- les traits des généraux dans Config/Generals. Rien de tout ça n'est écrit en dur dans le code.

local Military = {
	-- Boucle centrale (serveur). Le combat terrestre a son propre tick : Config/CombatConfig.tickSeconds
	tickSeconds = 2, -- référence des valeurs « par tick » ci-dessous (expérience...), en secondes
	aiInterval = 3, -- secondes entre deux réflexions d'un général (IA d'exécution)

	-- Occupation des régions
	maxDivisionsPerRegion = 10, -- limite de stationnement de base (la recherche la relève : TechState.stationingCap)

	-- Divisions de départ de chaque pays (placées sur ses régions au début de la partie)
	starting = {
		perRegion = 0.9, -- environ une division par région...
		min = 2, -- ... au moins 2...
		max = 14, -- ... et au plus 14
		-- composition : 1 division sur `every` est de ce type (le reste : infanterie), pour les
		-- pays qui ont au moins `minDivisions` divisions
		mix = {
			{ type = "Artillerie", every = 5, minDivisions = 5 },
			{ type = "Blindee", every = 7, minDivisions = 7 },
			{ type = "InfanterieMotorisee", every = 9, minDivisions = 9 },
		},
	},
	-- Divisions qu'un pays peut avoir en tout : selon sa population (Config/Population.divisionsPerMillion)

	-- Mouvement entre deux régions (secondes), d'après la distance et la vitesse de la division
	travel = { min = 8, max = 50 },

	-- Organisation
	orgRecovery = 0.02, -- part de l'organisation max regagnée chaque seconde, au repos et ravitaillée
	orgRecoveryMoving = 0.008, -- en mouvement
	rotationBelow = 0.3, -- sous 30 % d'organisation, le général retire la division du combat
	attackOrgMin = 0.7, -- le général ne lance une division à l'attaque qu'à 70 % d'organisation ou plus

	-- Force (effectifs et équipement) : renforts quand la division est ravitaillée chez elle
	reinforcePerMinute = 12, -- points de Force regagnés par minute (sur 100)
	reinforceCostFactor = 0.006, -- coût d'un point = 0,6 % du coût de la division

	-- Retranchement : se construit à l'arrêt, perdu dès que la division bouge
	entrenchSeconds = 180, -- temps pour atteindre le maximum...
	entrenchMax = 0.3, -- ... +30 % de défense

	-- Bonus de planification (plan de bataille préparé mais pas encore lancé)
	planning = {
		max = 0.3, -- jusqu'à +30 % d'attaque...
		buildSeconds = 150, -- ... atteints en 2 min 30
		lossPerTick = 0.01, -- perdus à chaque tick de combat après le lancement
	},

	-- Expérience des divisions (0 à 100) : paliers et bonus de combat
	experience = {
		perCombatTick = 0.15, -- gagnée à chaque tick de combat
		victory = 5, -- en plus après une victoire
		levels = {
			{ min = 75, name = "Élite", bonus = 0.3 },
			{ min = 50, name = "Vétéran", bonus = 0.2 },
			{ min = 25, name = "Régulière", bonus = 0.1 },
			{ min = 0, name = "Novice", bonus = 0 },
		},
	},

	-- Combat (voir server/Military/Combat : fonctions pures)
	combat = {
		hitsPerAttack = 0.25, -- coups tirés par tick et par point d'attaque
		absorbPerPoint = 0.25, -- coups absorbés par tick et par point de défense (ou de percée)
		undefendedMultiplier = 4, -- un coup non absorbé fait 4 fois plus de dégâts
		orgPerHit = 0.5, -- organisation retirée par coup
		strPerHit = 0.08, -- force retirée par coup (sur 100)
		armorDamageTaken = 0.5, -- blindage supérieur à la perforation ennemie : dégâts reçus x0,5...
		armorDamageDealt = 1.3, -- ... et dégâts infligés x1,3
		outOfSupply = 0.5, -- attaque et défense x0,5 sans ravitaillement (réserve épuisée)
		noFuel = 0.5, -- blindés et motorisés sans pétrole : attaque x0,5
		advanceTravelFactor = 0.5, -- après une victoire, l'attaquant entre dans la région 2 fois plus vite
		resultDelay = 6, -- secondes pendant lesquelles le résultat d'une bataille reste affiché
	},

	-- Ravitaillement
	supply = {
		updateSeconds = 2, -- recalcul du réseau de ravitaillement
		reserveSeconds = 60, -- réserve d'une division coupée de son ravitaillement
		attritionPerMinute = 6, -- force perdue par minute (réserve épuisée, ou région surchargée)
		capitalBonus = 6, -- capacité en plus dans la région de la capitale
		portBonus = 3, -- ... dans une région avec un port
		fortificationBonus = 1, -- ... par niveau de fortification
		consumptionSeconds = 10, -- les consommations (nourriture, pétrole) sont prélevées toutes les 10 s
	},

	-- Fortifications (bâtiment d'une région)
	fortification = {
		maxLevel = 3,
		defensePerLevel = 0.2, -- +20 % de défense par niveau
		cost = { Credits = 300, Acier = 20 }, -- coût d'un niveau
		buildSeconds = 60,
	},

	-- Généraux (cahier des charges v2, section 5) : on achète un général dans une de ses régions,
	-- puis on lui rattache des troupes (par type et par nombre, depuis leurs régions) : elles
	-- disparaissent de la carte, le général devient UNE armée (une icône avec un compteur).
	-- Il ignore la limite de stationnement, se déplace à la vitesse de sa troupe la plus lente,
	-- attaque avec toute son armée (en respectant la largeur de front) et donne ses bonus à
	-- toutes ses troupes. Traits dans Config/Generals.
	generals = {
		cost = { Credits = 200 }, -- acheter un général
		maxPerCountry = 5,
		capacity = { 20, 30, 40, 50, 60 }, -- troupes au plus selon le niveau (1 à 5)
		xpPerLevel = 25, -- niveau = 1 + expérience / 25 (5 au plus)
		maxLevel = 5,
		xpPerTick = 0.1, -- expérience par tick de 2 s de bataille de son armée
		xpVictory = 8, -- en plus après une victoire de son armée
		xpRegion = 12, -- en plus quand son armée prend une région
		upgradeCost = { 300, 600, 1000, 1500 }, -- crédits pour passer au niveau 2, 3, 4 et 5
		-- bonus de toutes ses troupes, par niveau au-dessus du premier
		levelBonus = { attack = 0.05, defense = 0.05 },
		-- à chaque niveau gagné, le joueur choisit un bonus (cumulable)
		choiceOrder = { "attack", "defense", "speed", "morale", "recovery" },
		choices = {
			attack = { name = "Attaque", icon = "⚔️", value = 0.1, text = "+10 % de dégâts pour ses troupes" },
			defense = { name = "Défense", icon = "🛡️", value = 0.1, text = "+10 % de défense pour ses troupes" },
			speed = { name = "Vitesse", icon = "🏃", value = 0.15, text = "-15 % de temps de trajet" },
			morale = { name = "Moral", icon = "🎖️", value = 0.15, text = "-15 % de moral perdu au combat" },
			recovery = { name = "Récupération", icon = "❤️", value = 0.5, text = "+50 % de PV regagnés au repos" },
		},
		maxBonus = 1, -- un effet ne dépasse jamais +100 % (traits, niveau et choix ensemble)
		advanceFactor = 0.5, -- après une victoire, l'armée entre dans la région prise 2 fois plus vite
		continueDelay = 1, -- attaque continue : secondes après l'arrivée avant la prochaine attaque
		continueMinOrganisation = 0.35, -- ... si le moral moyen de ses troupes dépasse 35 % du max
		woundedSeconds = 60, -- général vaincu (« blessé », selon la difficulté) : hors combat 60 s
		disorganizedSeconds = 60, -- quartier général pris : il se replie et perd ses bonus un moment
		nameMaxLength = 24,
		roughTerrain = { Montagne = true, Collines = true, Foret = true, Marais = true }, -- trait Montagnard
	},

	-- Soutien aérien simplifié (SYSTEME_MILITAIRE.md, 5.7) : les escadrilles à l'arrêt couvrent les
	-- régions proches ; pas de combat aérien détaillé, un calcul par zone
	air = {
		range = 150, -- studs : une escadrille couvre les batailles à cette distance de sa base
		superiorityBonus = 0.2, -- domination totale du ciel : +20 % d'attaque et de défense
		superiorityAt = 0.6, -- part des chasseurs à partir de laquelle un camp domine le ciel
		supportDamage = 0.125, -- appui au sol : moral (organisation) retiré par seconde, par point d'attaque
		bombingSeconds = 45, -- raid de bombardiers réussi : usines arrêtées et ravitaillement réduit
		bombedSupply = 0.5, -- capacité de ravitaillement d'une région bombardée (x0,5)
	},

	-- Commandes envoyées par les joueurs (RemoteEvent CommandeMilitaire)
	commands = {
		perSecond = 8, -- au plus 8 commandes par seconde et par joueur
		maxIds = 40, -- divisions au plus dans une même commande
	},
}

return Military
