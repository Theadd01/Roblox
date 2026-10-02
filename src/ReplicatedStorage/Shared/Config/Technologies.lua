--!strict
-- Arbre technologique : trois branches (militaire, renseignement, économie). Une recherche à la
-- fois par pays : on paie, puis la recherche dure `time` secondes. Les puces (💻) sont la clé
-- des technologies avancées. Effets lus avec shared/TechState ; voir server/Economy/ResearchService.
-- Les espions peuvent aussi voler une technologie (server/Politics/EspionageService).

export type Effect = {
	kind: string, -- "unitAttack" | "upkeep" | "production" | "factoryBatches" | "vision" | "revealCost" | "revealDuration" | "sabotageDefense"
	value: number,
	types: { string }?, -- unitAttack : types d'unités concernés
	resource: string?, -- production : ressource concernée (nil = toutes)
}
export type Tech = {
	id: string,
	branch: string,
	icon: string,
	name: string,
	effectText: string,
	requires: { string },
	cost: { [string]: number },
	time: number,
	effects: { Effect },
}

local Technologies = {}

Technologies.branches = {
	{ id = "Militaire", icon = "🎖️", name = "Militaire" },
	{ id = "Renseignement", icon = "🕵️", name = "Renseignement" },
	{ id = "Economie", icon = "🏭", name = "Économie" },
}

Technologies.list = {
	-- militaire
	{
		id = "Logistique",
		branch = "Militaire",
		icon = "🚚",
		name = "Logistique moderne",
		effectText = "−20 % d'entretien pour toutes tes forces",
		requires = {},
		cost = { Credits = 400, Puces = 3 },
		time = 60,
		effects = { { kind = "upkeep", value = -0.2 } },
	},
	{
		id = "BlindesModernes",
		branch = "Militaire",
		icon = "🛡️",
		name = "Blindés modernes",
		effectText = "+25 % d'attaque pour tes blindés",
		requires = { "Logistique" },
		cost = { Credits = 600, Puces = 6, Acier = 15 },
		time = 90,
		effects = { { kind = "unitAttack", value = 0.25, types = { "Blindes" } } },
	},
	{
		id = "Drones",
		branch = "Militaire",
		icon = "🛸",
		name = "Drones armés",
		effectText = "+30 % d'attaque pour tes drones et hélicoptères",
		requires = { "Logistique" },
		cost = { Credits = 600, Puces = 8 },
		time = 90,
		effects = { { kind = "unitAttack", value = 0.3, types = { "Drone", "Helicoptere" } } },
	},
	{
		id = "Missiles",
		branch = "Militaire",
		icon = "🚀",
		name = "Missiles de précision",
		effectText = "+25 % d'attaque pour ton artillerie, tes bombardiers et tes destroyers",
		requires = { "Drones" },
		cost = { Credits = 900, Puces = 12, TerresRares = 8 },
		time = 120,
		effects = { { kind = "unitAttack", value = 0.25, types = { "Artillerie", "Bombardier", "Destroyer" } } },
	},
	-- renseignement
	{
		id = "Radars",
		branch = "Renseignement",
		icon = "📡",
		name = "Radars",
		effectText = "Tu vois une rangée de régions de plus autour de ton territoire",
		requires = {},
		cost = { Credits = 500, Puces = 5 },
		time = 60,
		effects = { { kind = "vision", value = 1 } },
	},
	{
		id = "SatellitesEspions",
		branch = "Renseignement",
		icon = "🛰️",
		name = "Satellites espions",
		effectText = "Révéler une région coûte 2 fois moins et dure 2 fois plus longtemps",
		requires = { "Radars" },
		cost = { Credits = 800, Puces = 10 },
		time = 90,
		effects = { { kind = "revealCost", value = -0.5 }, { kind = "revealDuration", value = 1 } },
	},
	{
		id = "Cyberdefense",
		branch = "Renseignement",
		icon = "🔐",
		name = "Cyberdéfense",
		effectText = "Les sabotages et vols contre toi réussissent 2 fois moins",
		requires = { "Radars" },
		cost = { Credits = 700, Puces = 8 },
		time = 90,
		effects = { { kind = "sabotageDefense", value = -0.5 } },
	},
	-- économie
	{
		id = "Agriculture",
		branch = "Economie",
		icon = "🌾",
		name = "Agriculture intensive",
		effectText = "+25 % de nourriture produite",
		requires = {},
		cost = { Credits = 400, Acier = 10 },
		time = 60,
		effects = { { kind = "production", value = 0.25, resource = "Nourriture" } },
	},
	{
		id = "Automatisation",
		branch = "Economie",
		icon = "🤖",
		name = "Usines automatisées",
		effectText = "Chaque usine fabrique un lot de plus par cycle",
		requires = {},
		cost = { Credits = 700, Puces = 6, Acier = 20 },
		time = 90,
		effects = { { kind = "factoryBatches", value = 1 } },
	},
	{
		id = "ReseauIntelligent",
		branch = "Economie",
		icon = "⚡",
		name = "Réseau électrique intelligent",
		effectText = "+10 % de production pour toutes les ressources",
		requires = { "Automatisation" },
		cost = { Credits = 900, Puces = 12 },
		time = 120,
		effects = { { kind = "production", value = 0.1 } },
	},
} :: { Tech }

-- Vol de technologie par espionnage
Technologies.steal = {
	cost = { Credits = 500 },
	success = 0.4,
	caught = 0.5,
	cooldown = 120, -- secondes entre deux vols du même pays contre le même pays
}

function Technologies.get(id: string): Tech?
	for _, tech in Technologies.list do
		if tech.id == id then
			return tech
		end
	end
	return nil
end

return Technologies
