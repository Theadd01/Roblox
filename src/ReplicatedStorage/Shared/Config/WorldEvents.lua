--!strict
-- Événements mondiaux aléatoires (voir server/Session/WorldEventService) : un toutes les 6 à
-- 9 minutes environ, jamais dans les dernières minutes de la partie. Ils touchent le marché, des
-- usines, une région ou un pays, et sont annoncés à tous (bandeau et journal).
--   market    : chocs sur les prix (shocks : ressource -> facteur ; « all » = toutes)
--   factories : les usines de `countries` pays s'arrêtent `duration` secondes (immunité : tech)
--   disaster  : une région ne produit plus pendant `duration` secondes ; stabilité et miliciens
--   discovery : un pays reçoit des ressources

export type Event = {
	id: string,
	weight: number,
	icon: string,
	title: string,
	text: string, -- {countries} : pays touchés ; {region} : région touchée ; {duration} : durée
	kind: string,
	shocks: { [string]: number }?,
	countries: number?,
	duration: number?,
	reason: string?, -- usines arrêtées : cause affichée
	immuneTech: string?, -- technologie qui protège (cyberdéfense)
	stability: number?,
	organisation: number?, -- part de l'organisation qui reste aux divisions de la région (catastrophe)
	amount: number?, -- découverte : quantité
}

local WorldEvents = {}

WorldEvents.firstDelay = 8 * 60 -- secondes de partie avant le premier événement
WorldEvents.interval = { min = 6 * 60, max = 9 * 60 }
WorldEvents.quietEnd = 3 * 60 -- aucun événement dans les 3 dernières minutes

WorldEvents.list = {
	{
		id = "CriseEnergetique",
		weight = 2,
		icon = "⚡",
		title = "Crise énergétique",
		text = "Le pétrole et le gaz s'envolent sur les marchés.",
		kind = "market",
		shocks = { Petrole = 1.35, Gaz = 1.35 },
	},
	{
		id = "Krach",
		weight = 1,
		icon = "📉",
		title = "Krach boursier",
		text = "Panique sur les marchés : tous les prix s'effondrent.",
		kind = "market",
		shocks = { all = 0.8 },
	},
	{
		id = "RecolteRecord",
		weight = 1,
		icon = "🌾",
		title = "Récolte record",
		text = "La nourriture abonde : son prix chute.",
		kind = "market",
		shocks = { Nourriture = 0.7 },
	},
	{
		id = "Cyberattaque",
		weight = 2,
		icon = "💻",
		title = "Cyberattaque mondiale",
		text = "Les usines {countries} sont paralysées pendant {duration}.",
		kind = "factories",
		countries = 3,
		duration = 90,
		reason = "cyberattaque",
		immuneTech = "Cyberdefense",
	},
	{
		id = "Greve",
		weight = 2,
		icon = "🪧",
		title = "Grève dans les usines",
		text = "Les ouvriers {countries} cessent le travail pendant {duration}.",
		kind = "factories",
		countries = 2,
		duration = 90,
		reason = "grève",
		stability = -3,
	},
	{
		id = "Seisme",
		weight = 1,
		icon = "🌋",
		title = "Séisme",
		text = "Un séisme frappe {region} : production arrêtée pendant {duration}.",
		kind = "disaster",
		duration = 120,
		stability = -6,
		organisation = 0.7,
	},
	{
		id = "Inondation",
		weight = 1,
		icon = "🌊",
		title = "Inondations",
		text = "Des inondations ravagent {region} : production arrêtée pendant {duration}.",
		kind = "disaster",
		duration = 120,
		stability = -5,
		organisation = 0.8,
	},
	{
		id = "Cyclone",
		weight = 1,
		icon = "🌀",
		title = "Cyclone",
		text = "Un cyclone dévaste {region} : production arrêtée pendant {duration}.",
		kind = "disaster",
		duration = 120,
		stability = -5,
		organisation = 0.8,
	},
	{
		id = "Gisement",
		weight = 1,
		icon = "⛏️",
		title = "Découverte d'un gisement",
		text = "{countries} découvre un gisement : +{amount} {resource}.",
		kind = "discovery",
		amount = 60,
	},
} :: { Event }

-- Ressources possibles d'un gisement
WorldEvents.discoveryResources = { "Petrole", "Gaz", "Charbon", "MineraiFer", "TerresRares" }

return WorldEvents
