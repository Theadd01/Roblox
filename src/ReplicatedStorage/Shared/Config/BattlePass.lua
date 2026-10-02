--!strict
-- Passe de combat de WORLD FRONT.
-- Les récompenses sont exclusivement cosmétiques ou liées à la monnaie cosmétique
-- « Médailles ». Rien ici ne modifie l'économie ou la puissance d'une partie.

export type Reward = {
	label: string,
	medals: number?,
	unlocks: { string }?,
}

export type Level = {
	free: Reward,
	premium: Reward,
}

local BattlePass = {}

BattlePass.season = {
	id = "S0_MOBILISATION",
	name = "Saison 0 — Mobilisation",
	subtitle = "Pré-saison de développement • aucune date limite",
	maxLevel = 20,
	xpPerLevel = 1000,
	premiumProductKey = "PremiumBattlePass",
}

BattlePass.xp = {
	countrySelected = 50,
	activeMinute = 8,
	activeSessionCap = 160,
	factoryBuilt = 25,
	armyCreated = 25,
	battleVictory = 75,
	maxFactoriesPerSession = 10,
	maxArmiesPerSession = 10,
	maxVictoriesPerSession = 20,
}

-- Libellés sûrs pour l'interface. Les identifiants restent stables dans les
-- sauvegardes, tandis que le texte affiché peut évoluer ou être traduit.
BattlePass.unlockLabels = {
	TITLE_CADET = "Cadet",
	BADGE_PREMIUM = "Insigne Premium",
	THEME_STEEL_BLUE = "Thème Acier bleu",
	MARKER_CHEVRON = "Marqueur Chevron",
	UNIFORM_BLACK_BRASS = "Tenue noire et laiton",
	PLATE_BRASS = "Plaque Laiton",
	PLATE_KHAKI = "Plaque Kaki",
	SELECT_RADAR = "Cercle Radar",
	TITLE_LOGISTICIAN = "Logisticien",
	TITLE_STAFF_OFFICER = "Officier d'état-major",
	EMBLEM_STAR = "Emblème Étoile",
	MAP_WALNUT = "Plateau Noyer",
	THEME_STAFF_PAPER = "Thème Papier d'état-major",
	UNIFORM_GRAPHITE = "Uniforme Graphite",
	ARROW_DASHED = "Flèche Pointillés",
	VICTORY_OPERATION = "Effet Opération réussie",
	SELECT_OPERATION_GREEN = "Cercle Vert opérationnel",
	VEHICLE_NICKEL = "Finition Nickel",
	TITLE_STRATEGIST = "Stratège",
	MARKER_TACTICAL_PACK = "Marqueurs tactiques",
	CAPITAL_BEAM = "Balise Faisceau",
	TITLE_MASTER_LOGISTICIAN = "Maître logisticien",
	PLATE_BRONZE = "Plaque Bronze",
	PLATE_RADAR = "Plaque Radar",
	THEME_WAR_ROOM = "Thème Salle de crise",
	MAP_FRAME_DARK_WOOD = "Cadre Bois sombre",
	UNIFORM_CAMPAIGN = "Uniforme Campagne",
	SET_GRAND_COMMANDER = "Ensemble Grand Commandant",
	TITLE_GRAND_COMMANDER = "Grand Commandant",
	TITLE_PLANNER = "Planificateur",
	TITLE_CARTOGRAPHER = "Cartographe",
	TITLE_QUARTERMASTER = "Intendant",
	TITLE_VETERAN = "Vétéran",
	TITLE_HERALD = "Héraut",
	TITLE_BENEFACTOR = "Bienfaiteur",
	BADGE_SUPPORTER = "Insigne de soutien",
	FRAME_HERALD = "Cadre Héraut",
	THEME_CARTOGRAPHER = "Thème Cartographe",
	MARKER_CARTOGRAPHER = "Marqueurs Cartographe",
} :: { [string]: string }

function BattlePass.unlockLabel(id: string): string
	return BattlePass.unlockLabels[id] or id
end

BattlePass.levels = {
	{
		free = { label = "Titre « Cadet »", unlocks = { "TITLE_CADET" } },
		premium = { label = "Insigne Premium + 150 Médailles", medals = 150, unlocks = { "BADGE_PREMIUM" } },
	},
	{
		free = { label = "75 Médailles", medals = 75 },
		premium = { label = "Thème UI « Acier bleu »", unlocks = { "THEME_STEEL_BLUE" } },
	},
	{
		free = { label = "Marqueur « Chevron »", unlocks = { "MARKER_CHEVRON" } },
		premium = { label = "Tenue d'officier noire et laiton", unlocks = { "UNIFORM_BLACK_BRASS" } },
	},
	{
		free = { label = "75 Médailles", medals = 75 },
		premium = { label = "Plaque d'armée « Laiton »", unlocks = { "PLATE_BRASS" } },
	},
	{
		free = { label = "Plaque d'armée « Kaki »", unlocks = { "PLATE_KHAKI" } },
		premium = { label = "150 Médailles", medals = 150 },
	},
	{
		free = { label = "100 Médailles", medals = 100 },
		premium = { label = "Cercle de sélection « Radar »", unlocks = { "SELECT_RADAR" } },
	},
	{
		free = { label = "Titre « Logisticien »", unlocks = { "TITLE_LOGISTICIAN" } },
		premium = { label = "Titre « Officier d'état-major »", unlocks = { "TITLE_STAFF_OFFICER" } },
	},
	{
		free = { label = "Emblème « Étoile »", unlocks = { "EMBLEM_STAR" } },
		premium = { label = "Plateau de carte « Noyer »", unlocks = { "MAP_WALNUT" } },
	},
	{
		free = { label = "100 Médailles", medals = 100 },
		premium = { label = "200 Médailles", medals = 200 },
	},
	{
		free = { label = "Thème UI « Papier d'état-major »", unlocks = { "THEME_STAFF_PAPER" } },
		premium = { label = "Uniforme « Graphite »", unlocks = { "UNIFORM_GRAPHITE" } },
	},
	{
		free = { label = "Flèche « Pointillés »", unlocks = { "ARROW_DASHED" } },
		premium = { label = "Effet « Opération réussie »", unlocks = { "VICTORY_OPERATION" } },
	},
	{
		free = { label = "125 Médailles", medals = 125 },
		premium = { label = "200 Médailles", medals = 200 },
	},
	{
		free = { label = "Cercle « Vert opérationnel »", unlocks = { "SELECT_OPERATION_GREEN" } },
		premium = { label = "Finition véhicule « Nickel »", unlocks = { "VEHICLE_NICKEL" } },
	},
	{
		free = { label = "Titre « Stratège »", unlocks = { "TITLE_STRATEGIST" } },
		premium = { label = "Pack de marqueurs tactiques", unlocks = { "MARKER_TACTICAL_PACK" } },
	},
	{
		free = { label = "125 Médailles", medals = 125 },
		premium = { label = "250 Médailles", medals = 250 },
	},
	{
		free = { label = "Balise de capitale « Faisceau »", unlocks = { "CAPITAL_BEAM" } },
		premium = { label = "Titre « Maître logisticien »", unlocks = { "TITLE_MASTER_LOGISTICIAN" } },
	},
	{
		free = { label = "Plaque d'armée « Bronze »", unlocks = { "PLATE_BRONZE" } },
		premium = { label = "Plaque animée « Radar »", unlocks = { "PLATE_RADAR" } },
	},
	{
		free = { label = "150 Médailles", medals = 150 },
		premium = { label = "Thème UI « Salle de crise »", unlocks = { "THEME_WAR_ROOM" } },
	},
	{
		free = { label = "Cadre de carte « Bois sombre »", unlocks = { "MAP_FRAME_DARK_WOOD" } },
		premium = { label = "300 Médailles", medals = 300 },
	},
	{
		free = {
			label = "Uniforme « Campagne » + 250 Médailles",
			medals = 250,
			unlocks = { "UNIFORM_CAMPAIGN" },
		},
		premium = {
			label = "Ensemble « Grand Commandant » + 500 Médailles",
			medals = 500,
			unlocks = { "SET_GRAND_COMMANDER", "TITLE_GRAND_COMMANDER" },
		},
	},
} :: { Level }

function BattlePass.levelForXp(xp: number): number
	local season = BattlePass.season
	return math.clamp(math.floor(math.max(0, xp) / season.xpPerLevel) + 1, 1, season.maxLevel)
end

function BattlePass.startXpForLevel(level: number): number
	return (math.clamp(level, 1, BattlePass.season.maxLevel) - 1) * BattlePass.season.xpPerLevel
end

function BattlePass.nextLevelXp(level: number): number
	if level >= BattlePass.season.maxLevel then
		return BattlePass.startXpForLevel(level)
	end
	return level * BattlePass.season.xpPerLevel
end

return BattlePass
