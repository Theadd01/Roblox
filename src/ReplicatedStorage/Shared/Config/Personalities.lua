--!strict
-- Personnalités des pays IA (voir CLAUDE.md, « IA des pays »).
-- Chaque pays reçoit une personnalité au début de la partie, tirée au hasard selon `chance`,
-- modifiée seulement par la géographie (traits plus bas) : jamais selon la réputation d'un
-- pays réel. Une personnalité :
--   - remplace certains réglages de Config/AI (overrides) ;
--   - multiplie le score de chaque famille d'actions (weights) :
--     Commerce (vendre, acheter), Industrie (usines), Defense (se protéger), Attaque (conquérir).

export type Personality = {
	id: string,
	name: string,
	icon: string,
	description: string,
	chance: number, -- poids du tirage au sort
	weights: { [string]: number },
	overrides: { [string]: any },
}

local list: { [string]: Personality } = {
	Agressif = {
		id = "Agressif",
		name = "Agressif",
		icon = "⚔️",
		description = "Recrute beaucoup, attaque les voisins faibles",
		chance = 18,
		weights = { Commerce = 0.9, Industrie = 0.8, Defense = 1.1, Attaque = 1.4 },
		overrides = {
			peaceTroops = 5, -- garde une armée même en paix
			attackRatio = 2, -- attaque dès qu'il est 2 fois plus fort
			landAttackRatio = 1.2, -- divisions : offensive dès 1,2 contre 1
			extraDivisions = 3,
			warChest = 200,
			attackCooldown = 180,
			upkeepShare = 0.9,
			allianceWillingness = 0.3,
			peaceWillingness = 0.25,
			reserves = { Nourriture = 80, Petrole = 30, Acier = 30 },
		},
	},
	Industriel = {
		id = "Industriel",
		name = "Industriel",
		icon = "🏭",
		description = "Développe ses usines en priorité, armée défensive",
		chance = 22,
		weights = { Commerce = 1, Industrie = 1.5, Defense = 1, Attaque = 0.6 },
		overrides = {
			minInputCoverage = 0.25, -- construit même s'il doit acheter une bonne part des matières
			attackRatio = 4,
			landAttackRatio = 2,
			warChest = 1500,
			maxPerKind = { Commerce = 2, Industrie = 2, Defense = 2, Attaque = 1, Diplomatie = 1, Contrat = 1 },
			peaceWillingness = 0.55,
		},
	},
	Commercant = {
		id = "Commercant",
		name = "Commerçant",
		icon = "💰",
		description = "Vend ses surplus, cherche des contrats, évite les guerres",
		chance = 25,
		weights = { Commerce = 1.3, Industrie = 1, Defense = 1, Attaque = 0.3 },
		overrides = {
			sellFloor = { min = 0.85, max = 1.05 }, -- vend plus facilement
			surplusDiscount = 0.15,
			attackRatio = 6, -- n'attaque presque jamais
			landAttackRatio = 3,
			warChest = 3000,
			maxPerKind = { Commerce = 3, Industrie = 1, Defense = 2, Attaque = 1, Diplomatie = 1, Contrat = 1 },
			contractEagerness = 0.7, -- cherche des contrats
			peaceWillingness = 0.65,
		},
	},
	Defensif = {
		id = "Defensif",
		name = "Défensif",
		icon = "🛡️",
		description = "Fortifie ses frontières, garde une armée prête",
		chance = 22,
		weights = { Commerce = 1, Industrie = 1, Defense = 1.4, Attaque = 0.4 },
		overrides = {
			peaceTroops = 4,
			safetyMargin = 1.8, -- veut une défense bien plus forte que la menace
			attackRatio = 4,
			landAttackRatio = 2, -- divisions : offensive seulement à 2 contre 1
			extraDivisions = 2,
			fortifyDanger = 1, -- fortifie dès que l'ennemi en face est aussi fort
			attackCooldown = 600,
			creditReserve = 500,
			allianceWillingness = 0.6, -- cherche des alliés
			peaceWillingness = 0.55,
			reserves = { Nourriture = 90, Petrole = 30, Acier = 30 },
		},
	},
	Opportuniste = {
		id = "Opportuniste",
		name = "Opportuniste",
		icon = "🎯",
		description = "Attaque les pays déjà en guerre ou affaiblis",
		chance = 13,
		weights = { Commerce = 1, Industrie = 0.9, Defense = 1, Attaque = 1.2 },
		overrides = {
			attackRatio = 3.5, -- prudent face à un pays en paix...
			landAttackRatio = 1.6,
			weakTargetEase = 0.5, -- ... mais deux fois moins exigeant face à un pays en guerre ou affaibli
			weakTargetFactor = 0.3, -- et il le préfère nettement comme cible
			allianceWillingness = 0.35,
			peaceWillingness = 0.3,
		},
	},
}

local Personalities = {
	order = { "Agressif", "Industriel", "Commercant", "Defensif", "Opportuniste" },
	list = list,

	-- Traits géographiques qui font pencher le tirage (multiplient `chance`)
	traits = {
		steel = { Industriel = 2 }, -- ses régions produisent du fer et du charbon
		exporter = { Commercant = 1.6 }, -- ses régions produisent beaucoup (hors nourriture)
		small = { Defensif = 1.5, Agressif = 0.5, Opportuniste = 0.7 }, -- petit pays (petite garnison)
		large = { Agressif = 1.3, Opportuniste = 1.3 }, -- grand pays
	} :: { [string]: { [string]: number } },
	exporterValue = 40, -- production hors nourriture (en crédits par cycle) d'un gros exportateur
	smallArea = 1600, -- surface de départ d'un petit pays (au plus, studs²)
	largeArea = 19600, -- surface de départ d'un grand pays (au moins)
}

return Personalities
