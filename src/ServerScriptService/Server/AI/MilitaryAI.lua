--!strict
-- IA militaire des pays sans joueur (SYSTEME_MILITAIRE.md, section 8) : elle utilise exactement les
-- outils du joueur (recruter des divisions, nommer des généraux, leur donner un front et une ligne
-- offensive, lancer l'offensive, fortifier), sans tricher sur les règles.
--   housekeeping (à chaque tour, sans coût) : divisions placées sous les ordres des généraux,
--     front de chaque général (face à un ennemi en guerre, sinon au voisin le plus menaçant),
--     quartier général près de son front, objectifs d'offensive en temps de guerre ; sans
--     général, ses divisions libres vont vers la région frontalière la plus menacée ;
--   actions notées (CountryBrain) :
--     Defense : recruter (une division par région frontalière, plus selon la guerre et la
--       personnalité), nommer un général (un pour divisionsPerGeneral divisions), fortifier une
--       région frontalière menacée ;
--     Attaque : lancer l'offensive d'un général quand son armée est landAttackRatio fois plus
--       forte que l'ennemi en face et que son plan est prêt (planification), déclarer la guerre
--       à un voisin faible (rythme mondial : Config/AI.firstAttackDelay, offensiveInterval...).
-- worstDanger : la pire menace sur une de ses régions (au-dessus de 1 : mal défendue), utilisée
-- par DiplomacyAI pour chercher des alliés ou la paix.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local AI = require(Config:WaitForChild("AI")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local DivisionConfig = require(Config:WaitForChild("Divisions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local MilitaryConfig = require(Config:WaitForChild("Military")) :: any
local Terrain = require(Config:WaitForChild("Terrain")) :: any
local RegionTerrain = require(Config:WaitForChild("RegionTerrain")) :: any
local CouncilState = require(Shared:WaitForChild("CouncilState")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local Stocks = require(Server:WaitForChild("Economy"):WaitForChild("Stocks"))
local FactoryService = require(Server:WaitForChild("Economy"):WaitForChild("FactoryService"))
local BuildingRules = require(Shared:WaitForChild("BuildingRules")) :: any
local Military = Server:WaitForChild("Military")
local ArmyService = require(Military:WaitForChild("ArmyService"))
local Divisions = require(Military:WaitForChild("Divisions"))
local Movement = require(Military:WaitForChild("Movement"))
local Armies = require(Military:WaitForChild("Armies"))
local BattlePlans = require(Military:WaitForChild("BattlePlans"))
local Fortifications = require(Military:WaitForChild("Fortifications"))
local DiplomacyService = require(Server:WaitForChild("Politics"):WaitForChild("DiplomacyService"))
local Stability = require(Server:WaitForChild("Politics"):WaitForChild("Stability"))
local BalanceService = require(Server:WaitForChild("Politics"):WaitForChild("BalanceService"))

local CURRENCY: string = Resources.currency.id
local PEACE_THREAT = 0.25 -- un voisin en paix (non allié) compte pour un quart de menace

export type Action = { kind: string, score: number, label: string, run: () -> boolean }

-- Situation militaire d'un pays
type Situation = {
	countryId: string,
	P: any, -- réglages de l'IA de ce pays (Config/AI et sa personnalité)
	owned: { [string]: boolean },
	regions: { string },
	border: { string }, -- ses régions qui touchent (par la terre) un autre pays
	divisions: { Instance }, -- ses divisions prêtes
	all: { Instance }, -- toutes ses divisions (entraînement compris)
	generals: { Instance },
	enemies: { string }, -- pays en guerre avec lui
	dangers: { [string]: number }, -- danger déjà calculé de ses régions (pendant ce tour)
}

local MilitaryAI = {}

local lastOffensive = -math.huge -- dernière guerre déclarée par l'IA (dans le monde)
local lastAttackOf: { [string]: number } = {} -- dernière guerre déclarée par chaque pays

-- « la Belgique », « le Brésil »...
local function theCountry(countryId: string): string
	local country = Countries[countryId]
	return if country then FrenchNames.the(country.name) else countryId
end

local function orgRatio(d: Instance): number
	local org = (d:GetAttribute("Org") :: number?) or 0
	local orgMax = math.max((d:GetAttribute("OrgMax") :: number?) or 1, 1)
	return org / orgMax
end

-- Force estimée d'une division (attaque et défense, selon son organisation et sa force)
local function strengthOf(d: Instance): number
	local t = Divisions.typeOf(d)
	local force = ((d:GetAttribute("Force") :: number?) or 0) / 100
	return (t.soft + t.hard + 0.5 * (t.defense + t.breakthrough)) * (0.4 + 0.6 * orgRatio(d)) * force
end

local function friendly(countryId: string, owner: string?): boolean
	return owner ~= nil and (owner == countryId or DiplomacyService.areAllies(countryId, owner))
end

-- Force des divisions d'un camp (le pays et ses alliés) dans une région
local function regionStrength(regionId: string, countryId: string): number
	local total = 0
	for _, d in Divisions.listIn(regionId) do
		if friendly(countryId, d:GetAttribute("Proprietaire") :: string) and not Divisions.isTraining(d) then
			total += strengthOf(d)
		end
	end
	return total
end

local function situation(countryId: string, P: any): Situation
	local s: Situation = {
		countryId = countryId,
		P = P,
		owned = {},
		regions = {},
		border = {},
		divisions = {},
		all = {},
		generals = Armies.ofCountry(countryId),
		enemies = DiplomacyService.enemiesOf(countryId),
		dangers = {},
	}
	for regionId in Regions do
		if RegionService.getOwner(regionId) == countryId then
			s.owned[regionId] = true
			table.insert(s.regions, regionId)
		end
	end
	table.sort(s.regions)
	for _, regionId in s.regions do
		for _, link in Regions[regionId].neighbors do
			if not link.bySea and not s.owned[link.region] and RegionService.getOwner(link.region) ~= nil then
				table.insert(s.border, regionId)
				break
			end
		end
	end
	for _, d in Divisions.ofCountry(countryId) do
		table.insert(s.all, d)
		if not Divisions.isTraining(d) then
			table.insert(s.divisions, d)
		end
	end
	return s
end

-- Menace sur une de ses régions : divisions étrangères dans les régions voisines (ennemis en guerre
-- en entier, voisins en paix non alliés pour un quart)
local function threatOn(s: Situation, regionId: string): number
	local threat = 0
	for _, link in Regions[regionId].neighbors do
		if link.bySea then
			continue
		end
		local owner = RegionService.getOwner(link.region)
		if owner and not friendly(s.countryId, owner) then
			local weight = if DiplomacyService.atWar(s.countryId, owner) then 1 else PEACE_THREAT
			for _, d in Divisions.listIn(link.region) do
				if not friendly(s.countryId, d:GetAttribute("Proprietaire") :: string) and not Divisions.isTraining(d) then
					threat += strengthOf(d) * weight
				end
			end
		end
	end
	return threat
end

-- Danger sur une région : menace en face / sa défense (terrain, fortifications compris)
local function dangerOf(s: Situation, regionId: string): number
	local cached = s.dangers[regionId]
	if cached then
		return cached
	end
	local threat = threatOn(s, regionId)
	if threat <= 0 then
		s.dangers[regionId] = 0
		return 0
	end
	local terrain = Terrain.types[RegionTerrain.terrain[regionId] or Terrain.default] or Terrain.types[Terrain.default]
	local defense = regionStrength(regionId, s.countryId) * (1 - terrain.attack)
		* (1 + Fortifications.level(regionId) * MilitaryConfig.fortification.defensePerLevel)
	local danger = threat / math.max(defense, 1)
	s.dangers[regionId] = danger
	return danger
end

-- Crédits disponibles au-delà de la réserve que l'IA garde toujours
local function spendable(s: Situation): number
	return Stocks.get(s.countryId, CURRENCY) - s.P.creditReserve
end

local function canPay(s: Situation, cost: { [string]: number }): boolean
	if not Stocks.canAfford(s.countryId, cost) then
		return false
	end
	return (cost[CURRENCY] or 0) <= spendable(s)
end

-- Type de la prochaine recrue : surtout de l'infanterie, un peu d'artillerie, des anti-chars face
-- aux blindés ennemis, des blindés quand le pétrole et l'acier le permettent
local function recruitType(s: Situation): string
	local counts: { [string]: number } = {}
	for _, d in s.all do
		local typeId = d:GetAttribute("Type") :: string
		counts[typeId] = (counts[typeId] or 0) + 1
	end
	local total = math.max(#s.all, 1)
	local enemyArmor = 0
	for _, regionId in s.border do
		for _, link in Regions[regionId].neighbors do
			for _, d in Divisions.listIn(link.region) do
				local t = Divisions.typeOf(d)
				if t.hardness >= 0.5 and not friendly(s.countryId, d:GetAttribute("Proprietaire") :: string) then
					enemyArmor += 1
				end
			end
		end
	end
	local function share(typeId: string): number
		return (counts[typeId] or 0) / total
	end
	local choices = {}
	if enemyArmor > 0 and share("AntiChar") < 0.15 then
		table.insert(choices, "AntiChar")
	end
	if share("Artillerie") < 0.2 then
		table.insert(choices, "Artillerie")
	end
	if share("Blindee") < 0.15 and Stocks.get(s.countryId, "Petrole") >= 40 then
		table.insert(choices, "Blindee")
	end
	table.insert(choices, "Infanterie")
	for _, typeId in choices do
		if canPay(s, DivisionConfig.types[typeId].cost) then
			return typeId
		end
	end
	return "Infanterie"
end

-- Ses régions frontalières, de la plus menacée à la moins menacée
local function byDanger(s: Situation): { string }
	local list = table.clone(s.border)
	local danger: { [string]: number } = {}
	for _, regionId in list do
		danger[regionId] = dangerOf(s, regionId)
	end
	table.sort(list, function(a: string, b: string): boolean
		if danger[a] ~= danger[b] then
			return danger[a] > danger[b]
		end
		return a < b
	end)
	return list
end

-- ---- Housekeeping : réglages sans coût, à chaque tour -------------------------------------------

-- Pays voisin (par la terre) le plus menaçant, en dehors de ses alliés
local function mostThreatening(s: Situation): string?
	local best, bestThreat = nil, 0
	local seen: { [string]: number } = {}
	for _, regionId in s.border do
		for _, link in Regions[regionId].neighbors do
			local owner = RegionService.getOwner(link.region)
			if not link.bySea and owner and not friendly(s.countryId, owner) then
				seen[owner] = (seen[owner] or 0) + regionStrength(link.region, owner)
			end
		end
	end
	for owner, threat in seen do
		if threat > bestThreat or not best then
			best, bestThreat = owner, threat
		end
	end
	return best
end

-- Une région du pays `enemy` qui touche ses régions (pour lui donner un front)
local function borderRegionOf(s: Situation, enemy: string): string?
	for _, regionId in s.border do
		for _, link in Regions[regionId].neighbors do
			if not link.bySea and RegionService.getOwner(link.region) == enemy then
				return link.region
			end
		end
	end
	return nil
end

-- Objectifs d'une offensive : les régions ennemies voisines du front les plus faibles, et sa
-- capitale si elle est proche
local function chooseObjectives(s: Situation, general: Instance, enemy: string)
	local candidates: { [string]: number } = {}
	for _, regionId in BattlePlans.list(general, "Front") do
		for _, link in Regions[regionId].neighbors do
			if not link.bySea and RegionService.getOwner(link.region) == enemy then
				candidates[link.region] = regionStrength(link.region, enemy)
			end
		end
	end
	local list = {}
	for regionId, strength in candidates do
		table.insert(list, { id = regionId, strength = strength - (if regionId == enemy then 5 else 0) })
	end
	table.sort(list, function(a: any, b: any): boolean
		if a.strength ~= b.strength then
			return a.strength < b.strength
		end
		return a.id < b.id
	end)
	for i, entry in list do
		if i > s.P.offensiveDepth then
			break
		end
		BattlePlans.toggleObjective(s.countryId, general.Name, entry.id)
	end
end

function MilitaryAI.housekeeping(countryId: string)
	-- escadrilles et flottes : posture « Défendre » quand elles ne combattent pas
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local armees = state and state:FindFirstChild("Armees")
	for _, army in (if armees then armees:GetChildren() else {}) do
		if army:GetAttribute("Proprietaire") == countryId and army:GetAttribute("Posture") ~= "Defendre"
			and not army:GetAttribute("EnCombat") then
			ArmyService.order(countryId, army.Name, "Defendre")
		end
	end

	local s = situation(countryId, AI)
	if #s.regions == 0 then
		return
	end
	-- 1. sans général : ses divisions libres vont vers la région frontalière la plus menacée
	if #s.generals == 0 then
		local target = byDanger(s)[1]
		if target and dangerOf(s, target) > 0 then
			for _, d in s.divisions do
				if not Divisions.isMoving(d) and not Divisions.inBattle(d) and d:GetAttribute("Region") ~= target
					and dangerOf(s, d:GetAttribute("Region") :: string) < 0.5 then
					Movement.order(countryId, { d }, target)
					break -- une à la fois : le front se garnit peu à peu
				end
			end
		end
		return
	end
	-- 2. divisions sans général : au général qui en a le moins
	for _, d in s.divisions do
		if d:GetAttribute("Armee") == "" or Armies.get(d:GetAttribute("Armee")) == nil then
			local best, bestCount = nil, math.huge
			for _, g in s.generals do
				local count = #Armies.divisionsOf(g)
				if count < bestCount and count < MilitaryConfig.maxDivisionsPerArmy then
					best, bestCount = g, count
				end
			end
			if best then
				Armies.assign(countryId, best.Name, { d })
			end
		elseif d:GetAttribute("Controle") ~= "Plan" then
			d:SetAttribute("Controle", "Plan") -- l'IA ne garde pas de divisions en contrôle manuel
		end
	end
	-- 3. fronts : contre les ennemis en guerre (un général chacun, à tour de rôle), sinon face au
	-- voisin le plus menaçant
	local enemies = {}
	for _, enemy in s.enemies do
		if borderRegionOf(s, enemy) then
			table.insert(enemies, enemy)
		end
	end
	local neighbor = mostThreatening(s)
	for i, general in s.generals do
		local wanted = if #enemies > 0 then enemies[(i - 1) % #enemies + 1] else neighbor
		if wanted and general:GetAttribute("FrontPays") ~= wanted then
			local region = borderRegionOf(s, wanted)
			if region then
				BattlePlans.setFront(countryId, general.Name, region)
			end
		end
		-- quartier général près de son front
		local front = BattlePlans.list(general, "Front")
		local hq = general:GetAttribute("Region") :: string
		if #front > 0 and not table.find(front, hq) and (general:GetAttribute("Destination") or "") == "" then
			for _, regionId in front do
				if not Armies.inRegion(regionId) then
					Armies.move(countryId, general.Name, regionId)
					break
				end
			end
		end
		-- en guerre : une ligne offensive toute prête
		local enemy = general:GetAttribute("FrontPays")
		if typeof(enemy) == "string" and DiplomacyService.atWar(countryId, enemy) and #BattlePlans.list(general, "Objectifs") == 0 then
			chooseObjectives(s, general, enemy)
		end
	end
end

-- ---- Actions notées --------------------------------------------------------------------------

-- Divisions voulues : une par région frontalière, plus en guerre et selon la personnalité
local function wantedDivisions(s: Situation): number
	local wanted = math.max(2, #s.border) + s.P.extraDivisions + (if #s.enemies > 0 then 3 else 0)
	return math.min(Divisions.maxFor(s.countryId), wanted)
end

local function defendActions(s: Situation, actions: { Action })
	local ordered = byDanger(s)
	-- recruter
	local wanted = wantedDivisions(s)
	-- les divisions se forment dans un camp militaire : le plus exposé d'abord, sinon un autre
	local camps: { string } = {}
	for _, regionId in ordered do
		if BuildingRules.campLevel(regionId) > 0 then
			table.insert(camps, regionId)
		end
	end
	for _, regionId in s.regions do
		if BuildingRules.campLevel(regionId) > 0 and not table.find(camps, regionId) then
			table.insert(camps, regionId)
		end
	end
	if #s.all < wanted then
		local typeId = recruitType(s)
		local cost = DivisionConfig.types[typeId].cost
		local region: string? = nil
		for _, regionId in camps do
			if Divisions.occupancy(regionId) < MilitaryConfig.maxDivisionsPerRegion then
				region = regionId
				break
			end
		end
		if region and canPay(s, cost) then
			local deficit = (wanted - #s.all) / wanted
			local regionId, countryId = region :: string, s.countryId
			table.insert(actions, {
				kind = "Defense",
				score = 0.35 + 0.4 * deficit + (if #s.enemies > 0 then 0.2 else 0),
				label = `recrute une {DivisionConfig.types[typeId].label} en {Regions[regionId].name}`,
				run = function(): boolean
					return (Divisions.recruit(countryId, typeId, regionId))
				end,
			})
		end
	end
	-- construire un camp militaire près du front : un pour 5 régions environ, ou quand tous sont pleins
	local campsFull = true
	for _, regionId in camps do
		if Divisions.occupancy(regionId) < MilitaryConfig.maxDivisionsPerRegion then
			campsFull = false
			break
		end
	end
	if #s.all < wanted and (#camps < 1 + math.floor(#s.regions / 5) or campsFull) then
		local site: string? = nil
		for _, regionId in (if #ordered > 0 then ordered else s.regions) do
			if BuildingRules.campLevel(regionId) == 0 and #BuildingRules.inRegion(regionId) < BuildingRules.slots(regionId) then
				site = regionId
				break
			end
		end
		local cost = FactoryService.costFor(s.countryId, "CampMilitaire")
		if site and canPay(s, cost) then
			local regionId, countryId = site :: string, s.countryId
			table.insert(actions, {
				kind = "Defense",
				score = 0.4 + (if campsFull then 0.3 else 0) + (if #s.enemies > 0 then 0.15 else 0),
				label = `construit un camp militaire en {Regions[regionId].name}`,
				run = function(): boolean
					return (FactoryService.build(countryId, regionId, "CampMilitaire"))
				end,
			})
		end
	end
	-- nommer un général
	local neededGenerals = math.min(MilitaryConfig.generals.maxPerCountry, math.ceil(#s.all / s.P.divisionsPerGeneral))
	if #s.all >= 4 and #s.generals < neededGenerals and canPay(s, MilitaryConfig.generals.cost) then
		local region: string? = nil
		for _, regionId in (if #ordered > 0 then ordered else s.regions) do
			if not Armies.inRegion(regionId) then
				region = regionId
				break
			end
		end
		if region then
			local regionId, countryId = region :: string, s.countryId
			table.insert(actions, {
				kind = "Defense",
				score = 0.55,
				label = `nomme un général en {Regions[regionId].name}`,
				run = function(): boolean
					return (Armies.name(countryId, regionId))
				end,
			})
		end
	end
	-- fortifier la région frontalière la plus menacée
	local worst = ordered[1]
	local F = MilitaryConfig.fortification
	if worst and dangerOf(s, worst) >= s.P.fortifyDanger and Fortifications.level(worst) < F.maxLevel and canPay(s, F.cost) then
		local regionId, countryId = worst, s.countryId
		table.insert(actions, {
			kind = "Defense",
			score = 0.3 + 0.15 * math.min(2, dangerOf(s, worst)),
			label = `fortifie {Regions[regionId].name}`,
			run = function(): boolean
				return (Fortifications.build(countryId, regionId))
			end,
		})
	end
end

-- Force de son armée sur un front, et celle de l'ennemi en face (régions voisines du front)
local function frontRatio(s: Situation, general: Instance, enemy: string): number
	local mine = 0
	for _, d in Armies.divisionsOf(general) do
		if not Divisions.isTraining(d) then
			mine += strengthOf(d)
		end
	end
	local theirs = 0
	local counted: { [string]: boolean } = {}
	for _, regionId in BattlePlans.list(general, "Front") do
		for _, link in Regions[regionId].neighbors do
			if not link.bySea and not counted[link.region] and RegionService.getOwner(link.region) == enemy then
				counted[link.region] = true
				theirs += regionStrength(link.region, enemy)
			end
		end
	end
	return mine / math.max(theirs, 1)
end

-- Pays en guerre ou affaiblis (une de leurs régions de départ perdue) : cibles des opportunistes
local function weakCountries(): { [string]: boolean }
	local weak: { [string]: boolean } = {}
	for regionId, region in Regions do
		if RegionService.getOwner(regionId) ~= region.startOwner then
			weak[region.startOwner] = true
		end
	end
	for countryId in weak do
		for _, enemy in DiplomacyService.enemiesOf(countryId) do
			weak[enemy] = true
		end
	end
	return weak
end

local function attackActions(s: Situation, actions: { Action })
	if Stability.get(s.countryId) < s.P.minStabilityToAttack or CouncilState.ceasefireLeft() > 0 then
		return
	end
	-- lancer l'offensive d'un général prêt
	for _, general in s.generals do
		local enemy = general:GetAttribute("FrontPays")
		if typeof(enemy) ~= "string" or not DiplomacyService.atWar(s.countryId, enemy) then
			continue
		end
		if general:GetAttribute("Ordre") == "Offensive" or #BattlePlans.list(general, "Objectifs") == 0 then
			continue
		end
		local planning = (general:GetAttribute("Planification") :: number?) or 0
		local ratio = frontRatio(s, general, enemy)
		-- l'armée entière face au front : le général choisira lui-même les secteurs faibles (et ne lance
		-- pas d'attaque perdue d'avance), d'où une exigence plus basse que pour déclarer une guerre
		local required = s.P.landAttackRatio * s.P.launchRatioShare
		if planning >= MilitaryConfig.planning.max * s.P.planningBeforeLaunch and ratio >= required then
			local generalId, countryId = general.Name, s.countryId
			table.insert(actions, {
				kind = "Attaque",
				score = 0.5 + 0.3 * math.clamp(ratio / required - 1, 0, 1),
				label = `lance l'offensive de {general:GetAttribute("Nom")} contre {theCountry(enemy)}`,
				run = function(): boolean
					return (BattlePlans.launch(countryId, generalId))
				end,
			})
		end
	end
	-- déclarer une nouvelle guerre : rythme mondial, une seule guerre à la fois, un général prêt
	local now = workspace:GetServerTimeNow()
	if #s.enemies > 0 or #s.generals == 0 or MatchState.elapsed() < AI.firstAttackDelay then
		return
	end
	if now - lastOffensive < AI.offensiveInterval or now - (lastAttackOf[s.countryId] or -math.huge) < s.P.attackCooldown then
		return
	end
	local mine = 0
	for _, d in s.divisions do
		mine += strengthOf(d)
	end
	local weak = weakCountries()
	local leader = BalanceService.leader()
	local best: string? = nil
	local bestScore = 0
	local checked: { [string]: boolean } = {}
	for _, regionId in s.border do
		for _, link in Regions[regionId].neighbors do
			local owner = RegionService.getOwner(link.region)
			if link.bySea or not owner or checked[owner] or friendly(s.countryId, owner) then
				continue
			end
			checked[owner] = true
			if not DiplomacyService.canAttack(s.countryId, owner) then
				continue -- trêve, protection de départ...
			end
			-- force de l'ennemi : toutes ses divisions, et celles de ses alliés (tout le bloc entrerait en guerre)
			local theirs = 0
			for _, d in Divisions.ofCountry(owner) do
				theirs += strengthOf(d)
			end
			for _, ally in DiplomacyService.alliesOf(owner) do
				for _, d in Divisions.ofCountry(ally) do
					theirs += strengthOf(d) * s.P.blocDeterrence
				end
			end
			local ratio = mine / math.max(theirs, 1)
			local required = s.P.landAttackRatio * (if weak[owner] then math.max(0.7, s.P.weakTargetEase) else 1)
			if ratio < required then
				continue
			end
			local score = 0.35 + 0.25 * math.clamp(ratio / required - 1, 0, 1)
			if weak[owner] then
				score /= s.P.weakTargetFactor -- un pays déjà affaibli attire plus
			end
			if owner == leader then
				score /= s.P.leaderTargetFactor
			end
			if score > bestScore then
				best, bestScore = owner, score
			end
		end
	end
	if best then
		local target, countryId = best :: string, s.countryId
		table.insert(actions, {
			kind = "Attaque",
			score = math.min(0.9, bestScore),
			label = `déclare la guerre à {theCountry(target)}`,
			run = function(): boolean
				local ok = DiplomacyService.declareWar(countryId, target)
				if ok then
					lastOffensive = workspace:GetServerTimeNow()
					lastAttackOf[countryId] = lastOffensive
				end
				return ok
			end,
		})
	end
end

-- Actions militaires possibles pour un pays, avec leur score
function MilitaryAI.actions(countryId: string, P: any): { Action }
	local actions: { Action } = {}
	local s = situation(countryId, P)
	if #s.regions == 0 then
		return actions
	end
	defendActions(s, actions)
	attackActions(s, actions)
	return actions
end

-- Danger le plus fort sur ses régions (au-dessus de 1 : une de ses régions est mal défendue)
function MilitaryAI.worstDanger(countryId: string, P: any): number
	local s = situation(countryId, P)
	local worst = 0
	for _, regionId in s.border do
		worst = math.max(worst, dangerOf(s, regionId))
	end
	return worst
end

-- Nouvelle partie : l'IA oublie ses guerres passées
function MilitaryAI.reset()
	lastOffensive = -math.huge
	table.clear(lastAttackOf)
end

return MilitaryAI
