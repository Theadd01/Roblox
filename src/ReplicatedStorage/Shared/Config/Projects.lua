--!strict
-- Course aux projets décisifs (fin de partie) : à partir de la phase « Course finale », chaque pays
-- peut mener UN grand projet, étape par étape (chaque étape se paie puis demande un chantier).
-- Le premier pays à terminer un projet le remporte : gros bonus au classement final et un effet
-- pour le reste de la partie ; les autres pays perdent ce qu'ils y avaient investi.
-- Tout le monde voit la progression : un pays en guerre avec le constructeur peut saboter son
-- chantier, et prendre sa capitale lui fait perdre une étape. Voir server/Economy/ProjectService.

export type Project = {
	name: string,
	icon: string,
	effectText: string,
	effect: { kind: string, value: number }, -- kind : "production" | "attack" | "defense"
	stageCost: { [string]: number },
}

local Projects = {}

Projects.unlockPhase = 5 -- numéro de la phase « Course finale » (Config/Match.phases)
Projects.stages = 4 -- étapes pour terminer un projet
Projects.stageTime = 60 -- secondes de chantier par étape
Projects.scoreBonus = 15 -- points ajoutés au score final du pays qui termine le premier

-- Sabotage : seulement contre un pays avec qui tu es en guerre
Projects.sabotage = {
	cost = { Credits = 300 },
	cooldown = 90, -- secondes entre deux sabotages du même pays contre la même cible
}

Projects.order = { "ReseauSatellite", "Supercalculateur", "BouclierAntimissile" }
Projects.list = {
	ReseauSatellite = {
		name = "Réseau satellite",
		icon = "🛰️",
		effectText = "+10 % de production pour tes régions",
		effect = { kind = "production", value = 0.1 },
		stageCost = { Credits = 500, Puces = 5, Acier = 10 },
	},
	Supercalculateur = {
		name = "Supercalculateur militaire",
		icon = "🖥️",
		effectText = "+15 % d'attaque pour toutes tes forces",
		effect = { kind = "attack", value = 0.15 },
		stageCost = { Credits = 500, Puces = 6, TerresRares = 6 },
	},
	BouclierAntimissile = {
		name = "Bouclier antimissile",
		icon = "🛡️",
		effectText = "+30 % de défense pour les miliciens de tes régions",
		effect = { kind = "defense", value = 0.3 },
		stageCost = { Credits = 500, Acier = 15, Petrole = 10 },
	},
} :: { [string]: Project }

-- IA : un pays IA n'investit que s'il garde au moins ces crédits après l'étape
Projects.aiReserve = 600

return Projects
