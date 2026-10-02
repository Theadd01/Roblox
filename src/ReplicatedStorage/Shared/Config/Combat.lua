--!strict
-- Règles des raids aériens et navals (escadrilles et flottes, server/Military/BattleService) : le
-- serveur les résout par manches ; à chaque manche, la force frappe les divisions de la région et
-- elles ripostent ; ses unités dont les points de vie sont épuisés disparaissent (les moins chères
-- d'abord). Le combat terrestre des divisions est dans Config/Military (combat) et Config/Divisions.

local Combat = {
	roundInterval = 2, -- secondes entre deux manches
	damageFactor = 0.5, -- part de la puissance d'attaque transformée en dégâts à chaque manche
	randomness = 0.2, -- dégâts tirés au hasard entre 80 % et 120 %
	defenderBonus = 1.2, -- le défenseur connaît le terrain : +20 % d'attaque

	-- attaque par manche et points de vie de chaque unité
	units = {
		Infanterie = { attack = 1, health = 10 },
		Blindes = { attack = 3, health = 25 },
		Artillerie = { attack = 2.5, health = 10 },
		Chasseur = { attack = 3, health = 15 },
		Bombardier = { attack = 5, health = 20 },
		Drone = { attack = 1.5, health = 6 },
		Helicoptere = { attack = 2.5, health = 12 },
		Destroyer = { attack = 4, health = 30 },
		PorteAvions = { attack = 6, health = 60 },
		SousMarin = { attack = 3.5, health = 20 },
		Milice = { attack = 0.8, health = 8 }, -- garnison de la région
	},

	-- Raids aériens et navals : ils usent les divisions de la région mais ne la prennent pas
	-- (seules les divisions conquièrent). Les divisions tirent moins bien sur ces cibles.
	militiaEfficiency = {
		Terre = 1,
		Air = 0.5, -- défense antiaérienne improvisée
		Mer = 0.6, -- batteries côtières
	},
	raid = {
		rounds = 5, -- manches au plus
		orgPerPower = 1, -- organisation retirée à chaque division visée, par point de frappe
		forcePerPower = 0.12, -- force retirée, par point de frappe
		defense = 0.35, -- riposte : (attaque douce + dure) des divisions x defense x militiaEfficiency
	},

	-- Moral (0 à 100) : baisse au combat, remonte au repos si l'armée est ravitaillée
	morale = {
		start = 100,
		roundStress = 2, -- perte à chaque manche de combat
		lossWeight = 50, -- perte supplémentaire : part de l'armée perdue dans la manche x lossWeight
		victory = 15, -- gain après une victoire
		restHome = 3, -- gain par cycle de production, à l'arrêt en territoire ami et ravitaillée
		restAway = 1, -- gain par cycle, ravitaillée mais hors de son territoire
		unsupplied = 4, -- perte par cycle quand l'armée n'est pas ravitaillée
		retreatBelow = 25, -- en dessous, repli automatique (sauf ordre « Tenir la position »)
	},
	-- Efficacité au combat : puissance x (0,5 + moral / 200) ; hors ravitaillement x unsuppliedFactor
	unsuppliedFactor = 0.7,
	defendBonus = 1.25, -- ordre « Défendre » : +25 % quand l'armée défend sa région

	-- Expérience (0 à 100) : bonus de puissance jusqu'à +30 %, et niveau du chef (1 + xp / 25)
	experience = {
		victory = 15,
		survived = 8, -- repli ou défense réussie
		maxBonus = 0.3,
		perLevel = 25,
		ranks = {
			{ min = 75, name = "Élite" },
			{ min = 50, name = "Vétérans" },
			{ min = 25, name = "Aguerris" },
			{ min = 0, name = "Recrues" },
		},
	},

	visibleModels = 6, -- troupes visibles au maximum autour d'un général pendant une bataille
	resultDelay = 6, -- secondes pendant lesquelles le résultat reste affiché
}

return Combat
