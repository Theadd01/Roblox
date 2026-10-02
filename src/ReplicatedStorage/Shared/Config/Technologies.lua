--!strict
-- Arbre technologique à niveaux (cahier des charges v2, section 4), façon Hearts of Iron IV :
-- un onglet par catégorie (Infanterie, Blindés, Artillerie, Aviation, Marine, Économie, Industrie,
-- Renseignement) ; chaque technologie est une carte placée sur une grille (column, row), reliée à
-- ses prérequis (une technologie à un niveau donné) par des flèches.
-- Chaque technologie a plusieurs niveaux : on paie un niveau, il dure `time` secondes, puis le
-- pays passe à ce niveau. Les effets d'un niveau sont des TOTAUX (le niveau 3 remplace le 2) et
-- valent pour tout le pays, tout de suite, unités existantes comprises.
-- Les lignes d'équipement (base = true) commencent au niveau 1, gratuit : on recherche les
-- niveaux 2 à 5. File de recherche : `slots` emplacements en parallèle (plus avec la technologie
-- « Centres de recherche »). Les IA cherchent plus lentement selon la difficulté
-- (Config/Match.difficulties.researchSpeed). Effets lus avec shared/TechState ; voir
-- server/Economy/ResearchService.
-- Les espions peuvent voler un niveau (server/Politics/EspionageService).
--
-- Sortes d'effets (value : total au niveau atteint) :
--   divisionHealth / divisionDamage (types : divisions) : PV / dégâts en plus (0,2 = +20 %)
--   divisionMorale (types) : moral perdu au combat en moins
--   unitHealth / unitAttack (types : unités aériennes, navales, anciennes armées) : PV / attaque
--   upkeep : entretien des forces (-0,2 = -20 %) ; production (resource, ou toutes) ; income : impôts
--   factoryBatches : lots en plus par usine ; recruitTime : entraînement des divisions (-0,15)
--   stationing : divisions en plus par région (limite de stationnement)
--   researchSlots : emplacements de recherche en plus ; researchSpeed : vitesse de recherche
--   vision, revealCost, revealDuration, sabotageDefense : renseignement

export type Effect = {
	kind: string,
	value: number,
	types: { string }?,
	resource: string?,
}
export type Level = {
	cost: { [string]: number },
	time: number, -- secondes
	effects: { Effect },
	text: string, -- effet du niveau, en clair
}
export type Requirement = { id: string, level: number }
export type Tech = {
	id: string,
	branch: string,
	icon: string,
	name: string,
	column: number, -- place dans l'arbre (colonne : profondeur, de gauche à droite)
	row: number, -- ligne, de haut en bas
	base: boolean?, -- niveau 1 acquis d'office (lignes d'équipement)
	requires: { Requirement },
	levels: { Level },
	effectText: string, -- résumé de ce que fait la technologie
}

local Technologies = {}

Technologies.slots = 3 -- recherches en parallèle au départ
Technologies.cancelRefund = 0.5 -- une recherche annulée rend la moitié de son coût

Technologies.branches = {
	{ id = "Infanterie", icon = "⚔️", name = "Infanterie" },
	{ id = "Blindes", icon = "🛡️", name = "Blindés" },
	{ id = "Artillerie", icon = "💥", name = "Artillerie" },
	{ id = "Aviation", icon = "✈️", name = "Aviation" },
	{ id = "Marine", icon = "⚓", name = "Marine" },
	{ id = "Economie", icon = "💰", name = "Économie" },
	{ id = "Industrie", icon = "🏭", name = "Industrie" },
	{ id = "Renseignement", icon = "🕵️", name = "Renseignement" },
}

-- Paliers des lignes d'équipement (cahier des charges : niveau 2 +20 % PV / +15 % dégâts,
-- niveau 3 +40 / +30, niveau 4 +65 / +50, niveau 5 +100 / +75) et leur coût (faible, moyen,
-- élevé, très élevé) ; `extra` : ressources en plus selon la branche
local UNIT_STEPS = {
	{ health = 0.2, damage = 0.15, credits = 250, time = 30 },
	{ health = 0.4, damage = 0.3, credits = 600, time = 50 },
	{ health = 0.65, damage = 0.5, credits = 1200, time = 75 },
	{ health = 1, damage = 0.75, credits = 2200, time = 100 },
}

local function pct(x: number): string
	return `{math.floor(x * 100 + 0.5)} %`
end

local function withExtra(credits: number, extra: { [string]: number }?, step: number): { [string]: number }
	local cost: { [string]: number } = { Credits = credits }
	if extra then
		for resourceId, amount in extra do
			cost[resourceId] = amount * step
		end
	end
	return cost
end

-- Ligne d'équipement de divisions : niveau 1 gratuit, puis les 4 paliers
local function divisionLine(types: { string }, extra: { [string]: number }?): { Level }
	local levels: { Level } = { { cost = {}, time = 0, effects = {}, text = "Équipement de base" } }
	for step, s in UNIT_STEPS do
		table.insert(levels, {
			cost = withExtra(s.credits, extra, step),
			time = s.time,
			effects = {
				{ kind = "divisionHealth", value = s.health, types = types },
				{ kind = "divisionDamage", value = s.damage, types = types },
			},
			text = `+{pct(s.health)} de PV, +{pct(s.damage)} de dégâts`,
		})
	end
	return levels
end

-- Ligne d'équipement des unités aériennes ou navales (et des anciennes armées de terre)
local function unitLine(types: { string }, extra: { [string]: number }?): { Level }
	local levels: { Level } = { { cost = {}, time = 0, effects = {}, text = "Équipement de base" } }
	for step, s in UNIT_STEPS do
		table.insert(levels, {
			cost = withExtra(s.credits, extra, step),
			time = s.time,
			effects = {
				{ kind = "unitHealth", value = s.health, types = types },
				{ kind = "unitAttack", value = s.damage, types = types },
			},
			text = `+{pct(s.health)} de PV, +{pct(s.damage)} d'attaque`,
		})
	end
	return levels
end

-- Niveaux d'une technologie à un seul effet : values[i] = total au niveau i
local function simple(kind: string, values: { number }, costs: { { [string]: number } }, times: { number }, text: (number) -> string, extra: { [string]: any }?): { Level }
	local levels: { Level } = {}
	for i, value in values do
		local effect: Effect = { kind = kind, value = value }
		if extra then
			effect.types = extra.types
			effect.resource = extra.resource
		end
		table.insert(levels, { cost = costs[i], time = times[i], effects = { effect }, text = text(value) })
	end
	return levels
end

local INFANTRY = { "Infanterie", "InfanterieMotorisee", "Montagne", "Milice" }
local ARMOR = { "Blindee", "Mecanisee" }
local AIR = { "Chasseur", "Bombardier", "Helicoptere" }
local NAVY = { "Destroyer", "PorteAvions", "SousMarin" }

Technologies.list = {
	-- ---- Infanterie --------------------------------------------------------------------------
	{
		id = "EquipementInfanterie", branch = "Infanterie", icon = "⚔️", name = "Équipement d'infanterie",
		column = 1, row = 1, base = true, requires = {},
		levels = divisionLine(INFANTRY, nil),
		effectText = "PV et dégâts de l'infanterie, des motorisés, des troupes de montagne et des milices",
	},
	{
		id = "DoctrineInfanterie", branch = "Infanterie", icon = "🎖️", name = "Doctrine d'infanterie",
		column = 2, row = 1, requires = { { id = "EquipementInfanterie", level = 2 } },
		levels = simple("divisionMorale", { 0.1, 0.2, 0.3 }, { { Credits = 400 }, { Credits = 800 }, { Credits = 1400, Puces = 4 } }, { 40, 60, 80 },
			function(v: number): string
				return `-{pct(v)} de moral perdu au combat`
			end, { types = INFANTRY }),
		effectText = "L'infanterie tient plus longtemps avant de se replier",
	},
	{
		id = "ArmesAntichar", branch = "Infanterie", icon = "🎯", name = "Armes antichar",
		column = 2, row = 2, requires = { { id = "EquipementInfanterie", level = 3 } },
		levels = (function(): { Level }
			local list: { Level } = {}
			for i, value in { 0.2, 0.4, 0.65 } do
				table.insert(list, {
					cost = { Credits = 500 * i, Acier = 8 * i },
					time = 40 + 20 * i,
					effects = {
						{ kind = "divisionHealth", value = value, types = { "AntiChar" } },
						{ kind = "divisionDamage", value = value, types = { "AntiChar" } },
					},
					text = `+{pct(value)} de PV et de dégâts pour l'antichar`,
				})
			end
			return list
		end)(),
		effectText = "PV et dégâts des divisions antichar",
	},
	-- ---- Blindés -----------------------------------------------------------------------------
	{
		id = "BlindesModernes", branch = "Blindes", icon = "🛡️", name = "Blindés",
		column = 1, row = 1, base = true, requires = {},
		levels = divisionLine(ARMOR, { Acier = 6, Petrole = 4 }),
		effectText = "PV et dégâts des blindés et des mécanisés",
	},
	{
		id = "Mecanisation", branch = "Blindes", icon = "🚜", name = "Mécanisation",
		column = 2, row = 1, requires = { { id = "BlindesModernes", level = 2 } },
		levels = (function(): { Level }
			local list: { Level } = {}
			for i, value in { 0.15, 0.3, 0.5 } do
				table.insert(list, {
					cost = { Credits = 450 * i, Acier = 10 * i, Puces = 2 * i },
					time = 45 + 20 * i,
					effects = {
						{ kind = "divisionHealth", value = value, types = { "InfanterieMotorisee", "Mecanisee" } },
						{ kind = "divisionDamage", value = value, types = { "InfanterieMotorisee", "Mecanisee" } },
					},
					text = `+{pct(value)} de PV et de dégâts pour les motorisés et mécanisés`,
				})
			end
			return list
		end)(),
		effectText = "Les motorisés et mécanisés en plus de leur ligne d'équipement",
	},
	-- ---- Artillerie --------------------------------------------------------------------------
	{
		id = "Artillerie", branch = "Artillerie", icon = "💥", name = "Artillerie",
		column = 1, row = 1, base = true, requires = {},
		levels = divisionLine({ "Artillerie" }, { Acier = 6 }),
		effectText = "PV et dégâts de l'artillerie",
	},
	{
		id = "Missiles", branch = "Artillerie", icon = "🚀", name = "Missiles de précision",
		column = 2, row = 1, requires = { { id = "Artillerie", level = 3 } },
		levels = (function(): { Level }
			local list: { Level } = {}
			for i, value in { 0.25, 0.45, 0.7 } do
				table.insert(list, {
					cost = { Credits = 600 * i, Puces = 6 * i, TerresRares = 4 * i },
					time = 60 + 20 * i,
					effects = {
						{ kind = "divisionDamage", value = value * 0.5, types = { "Artillerie" } },
						{ kind = "unitAttack", value = value, types = { "Artillerie", "Bombardier", "Destroyer" } },
					},
					text = `+{pct(value * 0.5)} de dégâts pour l'artillerie, +{pct(value)} d'attaque pour les bombardiers et destroyers`,
				})
			end
			return list
		end)(),
		effectText = "Frappes à longue portée : artillerie, bombardiers, destroyers",
	},
	-- ---- Aviation ----------------------------------------------------------------------------
	{
		id = "Aviation", branch = "Aviation", icon = "✈️", name = "Aviation",
		column = 1, row = 1, base = true, requires = {},
		levels = unitLine(AIR, { Puces = 2, Petrole = 4 }),
		effectText = "PV et attaque des chasseurs, bombardiers et hélicoptères",
	},
	{
		id = "Drones", branch = "Aviation", icon = "🛸", name = "Drones armés",
		column = 2, row = 1, requires = { { id = "Aviation", level = 2 } },
		levels = simple("unitAttack", { 0.3, 0.5, 0.75 }, { { Credits = 500, Puces = 6 }, { Credits = 900, Puces = 10 }, { Credits = 1500, Puces = 16 } }, { 60, 80, 100 },
			function(v: number): string
				return `+{pct(v)} d'attaque pour les drones et hélicoptères`
			end, { types = { "Drone", "Helicoptere" } }),
		effectText = "Attaque des drones et des hélicoptères",
	},
	-- ---- Marine ------------------------------------------------------------------------------
	{
		id = "Marine", branch = "Marine", icon = "⚓", name = "Marine",
		column = 1, row = 1, base = true, requires = {},
		levels = unitLine(NAVY, { Acier = 10, Petrole = 4 }),
		effectText = "PV et attaque des destroyers, porte-avions et sous-marins",
	},
	{
		id = "SousMarins", branch = "Marine", icon = "🐋", name = "Guerre sous-marine",
		column = 2, row = 1, requires = { { id = "Marine", level = 2 } },
		levels = simple("unitAttack", { 0.25, 0.5, 0.8 }, { { Credits = 500, Acier = 12 }, { Credits = 900, Acier = 20 }, { Credits = 1500, Acier = 30, Puces = 6 } }, { 50, 70, 90 },
			function(v: number): string
				return `+{pct(v)} d'attaque pour les sous-marins`
			end, { types = { "SousMarin" } }),
		effectText = "Attaque des sous-marins",
	},
	-- ---- Économie ----------------------------------------------------------------------------
	{
		id = "Fiscalite", branch = "Economie", icon = "💰", name = "Fiscalité moderne",
		column = 1, row = 1, requires = {},
		levels = simple("income", { 0.1, 0.2, 0.35, 0.5 }, { { Credits = 300 }, { Credits = 600 }, { Credits = 1100 }, { Credits = 1800 } }, { 40, 60, 80, 100 },
			function(v: number): string
				return `+{pct(v)} d'impôts (revenus)`
			end),
		effectText = "Revenus : plus d'impôts",
	},
	{
		id = "Agriculture", branch = "Economie", icon = "🌾", name = "Agriculture intensive",
		column = 1, row = 2, requires = {},
		levels = simple("production", { 0.25, 0.4, 0.6 }, { { Credits = 400, Acier = 10 }, { Credits = 700, Acier = 15 }, { Credits = 1100, Acier = 25 } }, { 60, 75, 90 },
			function(v: number): string
				return `+{pct(v)} de nourriture produite`
			end, { resource = "Nourriture" }),
		effectText = "Production de nourriture",
	},
	{
		id = "Mobilisation", branch = "Economie", icon = "🪖", name = "Mobilisation",
		column = 2, row = 1, requires = { { id = "Fiscalite", level = 2 } },
		levels = simple("recruitTime", { -0.15, -0.3, -0.45 }, { { Credits = 400 }, { Credits = 800 }, { Credits = 1300 } }, { 40, 60, 80 },
			function(v: number): string
				return `-{pct(-v)} de temps d'entraînement des divisions`
			end),
		effectText = "Vitesse de recrutement des divisions",
	},
	{
		id = "Logistique", branch = "Economie", icon = "🚚", name = "Logistique moderne",
		column = 2, row = 2, requires = {},
		levels = simple("upkeep", { -0.2, -0.3, -0.4 }, { { Credits = 400, Puces = 3 }, { Credits = 700, Puces = 5 }, { Credits = 1100, Puces = 8 } }, { 60, 75, 90 },
			function(v: number): string
				return `-{pct(-v)} d'entretien pour toutes tes forces`
			end),
		effectText = "Entretien des forces",
	},
	{
		id = "Garnisons", branch = "Economie", icon = "🏕️", name = "Logistique de garnison",
		column = 3, row = 2, requires = { { id = "Logistique", level = 1 } },
		levels = simple("stationing", { 2, 5 }, { { Credits = 800, Acier = 15 }, { Credits = 1600, Acier = 30 } }, { 60, 90 },
			function(v: number): string
				return `{10 + v} divisions au plus par région (au lieu de 10)`
			end),
		effectText = "Capacité de stationnement des régions : 10 -> 12 -> 15",
	},
	-- ---- Industrie ---------------------------------------------------------------------------
	{
		id = "Automatisation", branch = "Industrie", icon = "🤖", name = "Usines automatisées",
		column = 1, row = 1, requires = {},
		levels = simple("factoryBatches", { 1, 2, 3 }, { { Credits = 700, Puces = 6, Acier = 20 }, { Credits = 1200, Puces = 10, Acier = 30 }, { Credits = 2000, Puces = 16, Acier = 40 } }, { 90, 110, 130 },
			function(v: number): string
				return `chaque usine fabrique {v} lot{if v > 1 then "s" else ""} de plus par cycle`
			end),
		effectText = "Production des usines",
	},
	{
		id = "ReseauIntelligent", branch = "Industrie", icon = "⚡", name = "Réseau électrique intelligent",
		column = 2, row = 1, requires = { { id = "Automatisation", level = 1 } },
		levels = simple("production", { 0.1, 0.2, 0.3 }, { { Credits = 900, Puces = 12 }, { Credits = 1400, Puces = 16 }, { Credits = 2100, Puces = 22 } }, { 100, 120, 140 },
			function(v: number): string
				return `+{pct(v)} de production pour toutes les ressources`
			end),
		effectText = "Production de toutes les ressources",
	},
	{
		id = "CentresRecherche", branch = "Industrie", icon = "🔬", name = "Centres de recherche",
		column = 1, row = 2, requires = {},
		levels = {
			{ cost = { Credits = 600, Puces = 4 }, time = 60, effects = { { kind = "researchSlots", value = 1 }, { kind = "researchSpeed", value = 0.1 } }, text = "4 recherches en parallèle, +10 % de vitesse de recherche" },
			{ cost = { Credits = 1400, Puces = 10 }, time = 90, effects = { { kind = "researchSlots", value = 2 }, { kind = "researchSpeed", value = 0.2 } }, text = "5 recherches en parallèle, +20 % de vitesse de recherche" },
		},
		effectText = "Emplacements et vitesse de recherche",
	},
	-- ---- Renseignement -----------------------------------------------------------------------
	{
		id = "Radars", branch = "Renseignement", icon = "📡", name = "Radars",
		column = 1, row = 1, requires = {},
		levels = simple("vision", { 1, 2 }, { { Credits = 500, Puces = 5 }, { Credits = 1000, Puces = 10 } }, { 60, 90 },
			function(v: number): string
				return `tu vois {v} rangée{if v > 1 then "s" else ""} de régions de plus autour de ton territoire`
			end),
		effectText = "Vision autour de ton territoire",
	},
	{
		id = "SatellitesEspions", branch = "Renseignement", icon = "🛰️", name = "Satellites espions",
		column = 2, row = 1, requires = { { id = "Radars", level = 1 } },
		levels = {
			{ cost = { Credits = 800, Puces = 10 }, time = 90, effects = { { kind = "revealCost", value = -0.5 }, { kind = "revealDuration", value = 1 } }, text = "révéler une région coûte 2 fois moins et dure 2 fois plus longtemps" },
		},
		effectText = "Révélation des régions",
	},
	{
		id = "Cyberdefense", branch = "Renseignement", icon = "🔐", name = "Cyberdéfense",
		column = 2, row = 2, requires = { { id = "Radars", level = 1 } },
		levels = {
			{ cost = { Credits = 700, Puces = 8 }, time = 90, effects = { { kind = "sabotageDefense", value = -0.5 } }, text = "les sabotages et vols contre toi réussissent 2 fois moins ; immunité aux cyberattaques" },
		},
		effectText = "Protection contre l'espionnage",
	},
} :: { Tech }

-- Vol de technologie par espionnage : un niveau d'une technologie que la cible a et pas toi
Technologies.steal = {
	cost = { Credits = 500 },
	success = 0.4,
	caught = 0.5,
	cooldown = 120, -- secondes entre deux vols du même pays contre le même pays
}

local byId: { [string]: Tech } = {}
for _, tech in Technologies.list do
	byId[tech.id] = tech
end

function Technologies.get(id: string): Tech?
	return byId[id]
end

-- Niveau maximum d'une technologie
function Technologies.maxLevel(tech: Tech): number
	return #tech.levels
end

-- Niveau de départ (1 pour les lignes d'équipement, 0 sinon)
function Technologies.startLevel(tech: Tech): number
	return if tech.base then 1 else 0
end

return Technologies
