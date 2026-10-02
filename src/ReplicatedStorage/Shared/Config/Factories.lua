--!strict
-- Bâtiments des régions (onglet Bâtiments ; le dossier d'état garde son nom historique « Usines »).
-- 2 bâtiments par région (4 dans la capitale). Trois familles :
--   usines (recipe) : transforment des ressources à chaque cycle de production (Config/Recipes),
--     selon les stocks du pays (fer + charbon -> acier, terres rares + gaz -> puces) ;
--   exploitations (extracts) : ajoutent de la production par niveau et par cycle, seulement pour les
--     ressources que la région produit déjà (mines, puits) ; les champs de blé se cultivent partout,
--     selon la fertilité du pays (Config/ResourceDeposits) ;
--   camp militaire (camp) : on ne forme des divisions que dans une région qui en a un (chaque pays
--     en a un, offert, dans sa capitale) ; ses niveaux raccourcissent l'entraînement.
-- Le prix d'un nouveau bâtiment monte avec le nombre de bâtiments du pays (costGrowth) : un grand
-- pays a plus de place, mais pas plus d'argent.

export type FactoryType = {
	id: string,
	name: string,
	icon: string,
	description: string,
	recipe: string?, -- usine : recette (Config/Recipes), `batchesPerLevel` lots par niveau
	batchesPerLevel: number?,
	extracts: { [string]: number }?, -- exploitation : ressource -> quantité par niveau et par cycle
	anywhere: boolean?, -- exploitation possible dans toute région (champs de blé)
	fertility: boolean?, -- production x fertilité du pays (fertilityFactors)
	camp: boolean?, -- camp militaire
	buildCost: { [string]: number },
	buildTime: number, -- secondes de chantier
	maxLevel: number,
	upgradeCosts: { [number]: { [string]: number } }, -- coût pour passer AU niveau indiqué
}

local Factories = {
	maxPerRegion = 2, -- bâtiments par région...
	capitalSlots = 4, -- ... et dans la capitale
	freeBuildings = 3, -- au-delà de 3 bâtiments, chaque nouveau coûte...
	costGrowth = 0.12, -- ... 12 % de plus par bâtiment du pays
	campTraining = 0.2, -- camp militaire : entraînement 20 % plus court par niveau au-dessus du premier
	fertilityFactors = { fertile = 1.5, normal = 1, arid = 0.5 } :: { [string]: number }, -- champs de blé
	order = { "Ferme", "Mine", "Puits", "Acierie", "UsinePuces", "CampMilitaire" },
	types = {
		Ferme = {
			id = "Ferme",
			name = "Champs de blé",
			icon = "🌾",
			description = "Du blé à chaque cycle, partout (plus dans un pays fertile).",
			extracts = { Nourriture = 3 },
			anywhere = true,
			fertility = true,
			buildCost = { Credits = 150 },
			buildTime = 20,
			maxLevel = 3,
			upgradeCosts = {
				[2] = { Credits = 150 },
				[3] = { Credits = 250 },
			},
		},
		Mine = {
			id = "Mine",
			name = "Mine",
			icon = "⛏️",
			description = "Extrait le charbon, le minerai de fer et les terres rares de la région.",
			extracts = { Charbon = 1.5, MineraiFer = 1.5, TerresRares = 0.4 },
			buildCost = { Credits = 200 },
			buildTime = 25,
			maxLevel = 3,
			upgradeCosts = {
				[2] = { Credits = 200, Acier = 5 },
				[3] = { Credits = 300, Acier = 10 },
			},
		},
		Puits = {
			id = "Puits",
			name = "Puits de pétrole et de gaz",
			icon = "🛢️",
			description = "Pompe le pétrole et le gaz de la région.",
			extracts = { Petrole = 1, Gaz = 1.5 },
			buildCost = { Credits = 250 },
			buildTime = 25,
			maxLevel = 3,
			upgradeCosts = {
				[2] = { Credits = 250, Acier = 5 },
				[3] = { Credits = 350, Acier = 10 },
			},
		},
		Acierie = {
			id = "Acierie",
			name = "Aciérie",
			icon = "🏭",
			description = "Fabrique de l'acier avec du minerai de fer et du charbon (achetés s'il en manque).",
			recipe = "Acier",
			batchesPerLevel = 1,
			buildCost = { Credits = 300 },
			buildTime = 30,
			maxLevel = 3,
			upgradeCosts = {
				[2] = { Credits = 400, Acier = 20 },
				[3] = { Credits = 600, Acier = 40 },
			},
		},
		UsinePuces = {
			id = "UsinePuces",
			name = "Usine de puces",
			icon = "💾",
			description = "Fabrique des puces électroniques avec des terres rares et du gaz.",
			recipe = "Puces",
			batchesPerLevel = 1,
			buildCost = { Credits = 400, Acier = 10 },
			buildTime = 40,
			maxLevel = 3,
			upgradeCosts = {
				[2] = { Credits = 500, Acier = 20 },
				[3] = { Credits = 700, Acier = 30 },
			},
		},
		CampMilitaire = {
			id = "CampMilitaire",
			name = "Camp militaire",
			icon = "⛺",
			description = "Forme les divisions dans cette région (recrutement). Chaque niveau entraîne plus vite.",
			camp = true,
			buildCost = { Credits = 200 },
			buildTime = 20,
			maxLevel = 3,
			upgradeCosts = {
				[2] = { Credits = 200 },
				[3] = { Credits = 300 },
			},
		},
	} :: { [string]: FactoryType },
}

return Factories
