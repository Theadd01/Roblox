--!strict
-- IA militaire des pays sans joueur (SYSTEME_MILITAIRE.md, section 8 ; cahier des charges v2) : elle
-- utilise exactement les outils du joueur (recruter des divisions, acheter des généraux et leur
-- rattacher des troupes, attaquer une région depuis toutes ses régions voisines, lancer un général
-- en offensive continue, fortifier), sans tricher sur les règles. Elle ne propose jamais de trêve,
-- de paix ni d'événement mondial (seuls les joueurs le font : CouncilService).
--   housekeeping (à chaque tour, sans coût) : ses divisions libres vont vers la région frontalière
--     la plus menacée ; ses généraux reçoivent les divisions en surplus (une garnison reste sur
--     chaque région frontalière) et choisissent leurs bonus de niveau ;
--   actions notées (CountryBrain) :
--     Defense : recruter (une division par région frontalière, plus selon la guerre et la
--       personnalité), acheter un général (un pour divisionsPerGeneral divisions), fortifier une
--       région frontalière menacée ;
--     Attaque : en guerre, attaquer la région ennemie voisine la plus faible quand ses divisions
--       voisines sont landAttackRatio fois plus fortes ; lancer un général en offensive continue ;
--       déclarer la guerre à un voisin faible (rythme mondial : Config/AI.firstAttackDelay,
--       offensiveInterval...).
-- worstDanger : la pire menace sur une de ses régions (au-dessus de 1 : mal défendue), utilisée
-- par DiplomacyAI pour chercher des alliés.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local AI = require(Config:WaitForChild("AI")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local DivisionConfig = require(Config:WaitForChild("Divisions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local MilitaryConfig = require(Config:WaitForChild("Military")) :: any
local CombatConfig = require(Config:WaitForChild("CombatConfig")) :: any
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
local BattleManager = require(Military:WaitForChild("BattleManager"))
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

local BASE_VALUE = math.sqrt(CombatConfig.stats(nil).health * CombatConfig.stats(nil).dps)

-- Force estimée d'une division (PV x DPS de son type, selon son moral et ses PV restants)
local function strengthOf(d: Instance): number
	local stats = CombatConfig.stats(d:GetAttribute("Type") :: string)
	local force = ((d:GetAttribute("Force") :: number?) or 0) / 100
	return math.sqrt(stats.health * stats.dps) / BASE_VALUE * (0.4 + 0.6 * orgRatio(d)) * force
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

-- Divisions libres (hors armée d'un général), à l'arrêt et hors bataille
local function idleDivisions(s: Situation): { Instance }
	local list = {}
	for _, d in s.divisions do
		if not Divisions.isAbsorbed(d) and not Divisions.isMoving(d) and not Divisions.inBattle(d) then
			table.insert(list, d)
		end
	end
	return list
end

-- Divisions libres en surplus : une garnison reste sur chaque région frontalière
-- (Config/AI.garrisonPerBorder), les autres peuvent rejoindre l'armée d'un général
local function spareDivisions(s: Situation): { Instance }
	local border: { [string]: boolean } = {}
	for _, regionId in s.border do
		border[regionId] = true
	end
	local kept: { [string]: number } = {}
	local spare = {}
	for _, d in idleDivisions(s) do
		local regionId = d:GetAttribute("Region") :: string
		if border[regionId] and (kept[regionId] or 0) < s.P.garrisonPerBorder then
			kept[regionId] = (kept[regionId] or 0) + 1
		else
			table.insert(spare, d)
		end
	end
	return spare
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
	-- 1. ses divisions libres vont vers la région frontalière la plus menacée (une à la fois : le
	-- front se garnit peu à peu)
	local target = byDanger(s)[1]
	if target and dangerOf(s, target) > 0 then
		for _, d in idleDivisions(s) do
			if d:GetAttribute("Region") ~= target and dangerOf(s, d:GetAttribute("Region") :: string) < 0.5 then
				Movement.order(countryId, { d }, target)
				break
			end
		end
	end
	-- 2. généraux : bonus de niveau, puis les divisions en surplus rejoignent leur armée
	local spare = spareDivisions(s)
	for i, general in s.generals do
		if ((general:GetAttribute("ChoixBonus") :: number?) or 0) > 0 then
			Armies.chooseBonus(countryId, general.Name, if i % 2 == 0 then "defense" else "attack")
		end
		local room = Armies.capacityOf(general) - #Armies.divisionsOf(general)
		if room > 0 and #spare > 0 and general:GetAttribute("Destination") == "" then
			local list = {}
			while room > 0 and #spare > 0 do
				table.insert(list, table.remove(spare) :: Instance)
				room -= 1
			end
			Armies.assign(countryId, general.Name, list)
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
			if Divisions.occupancy(regionId) < Divisions.capacityOf(regionId) then
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
		if Divisions.occupancy(regionId) < Divisions.capacityOf(regionId) then
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
	-- acheter un général (ses divisions en surplus rejoindront son armée : housekeeping)
	local neededGenerals = math.min(MilitaryConfig.generals.maxPerCountry, math.floor(#s.all / s.P.divisionsPerGeneral))
	if #s.generals < neededGenerals and canPay(s, MilitaryConfig.generals.cost) then
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
				label = `achète un général en {Regions[regionId].name}`,
				run = function(): boolean
					return (Armies.buy(countryId, regionId))
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

-- Défense d'une région ennemie : ses divisions x terrain x fortifications
local function defenseOf(regionId: string, owner: string): number
	local terrain = Terrain.types[RegionTerrain.terrain[regionId] or Terrain.default] or Terrain.types[Terrain.default]
	return regionStrength(regionId, owner) / math.max(0.3, 1 + terrain.attack)
		* (1 + CombatConfig.defenderBonus + Fortifications.level(regionId) * MilitaryConfig.fortification.defensePerLevel)
end

-- Régions ennemies (en guerre) à portée d'un général : voisines de ses régions, à moins de
-- `limit` régions de son quartier général ; renvoie région -> distance
local function reachable(s: Situation, from: string, limit: number): { [string]: number }
	local distance: { [string]: number } = { [from] = 0 }
	local targets: { [string]: number } = {}
	local queue = { from }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, link in Regions[current].neighbors do
			local nextId = link.region
			if link.bySea or distance[nextId] or not Regions[nextId] then
				continue
			end
			local owner = RegionService.getOwner(nextId)
			if owner and DiplomacyService.atWar(s.countryId, owner) then
				targets[nextId] = math.min(targets[nextId] or math.huge, distance[current] + 1)
			elseif friendly(s.countryId, owner) and distance[current] + 1 < limit then
				distance[nextId] = distance[current] + 1
				table.insert(queue, nextId)
			end
		end
	end
	return targets
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
	if #s.enemies > 0 then
		-- a) la région ennemie voisine la plus faible, attaquée depuis toutes ses régions voisines
		local best: string? = nil
		local bestScore, bestRatio = 0, 0
		local checked: { [string]: boolean } = {}
		for _, regionId in s.border do
			for _, link in Regions[regionId].neighbors do
				local target = link.region
				local owner = RegionService.getOwner(target)
				if link.bySea or checked[target] or not owner or not DiplomacyService.atWar(s.countryId, owner) or BattleManager.isFighting(target) then
					continue
				end
				checked[target] = true
				local mine = 0
				for _, entry in BattleManager.readyAttackers(s.countryId, target) do
					if orgRatio(entry.d) >= MilitaryConfig.attackOrgMin then
						mine += strengthOf(entry.d)
					end
				end
				local ratio = mine / math.max(defenseOf(target, owner), 0.5)
				if ratio >= s.P.landAttackRatio then
					local score = 0.5 + 0.3 * math.clamp(ratio / s.P.landAttackRatio - 1, 0, 1)
					if score > bestScore then
						best, bestScore, bestRatio = target, score, ratio
					end
				end
			end
		end
		if best then
			local target, countryId = best :: string, s.countryId
			local continuous = bestRatio >= 2 * s.P.landAttackRatio -- bien plus fort : il enchaîne
			table.insert(actions, {
				kind = "Attaque",
				score = bestScore,
				label = `attaque {Regions[target].name}`,
				run = function(): boolean
					return (BattleManager.attackRegion(countryId, target, continuous))
				end,
			})
		end
		-- b) un général à l'arrêt lance son armée en offensive continue vers la région ennemie la
		-- plus faible à sa portée
		for _, general in s.generals do
			if general:GetAttribute("Destination") ~= "" or general:GetAttribute("AttaqueContinue") == true or general:GetAttribute("Blesse") ~= nil then
				continue
			end
			local troops = Armies.divisionsOf(general)
			if #troops < s.P.generalMinTroops then
				continue
			end
			local mine, busy = 0, false
			for _, d in troops do
				busy = busy or Divisions.inBattle(d)
				mine += strengthOf(d)
			end
			if busy then
				continue
			end
			local targetId: string? = nil
			local targetScore = math.huge
			for regionId, distance in reachable(s, general:GetAttribute("Region") :: string, s.P.generalRange) do
				if BattleManager.isFighting(regionId) then
					continue
				end
				local defense = defenseOf(regionId, RegionService.getOwner(regionId) :: string) + distance
				if defense < targetScore then
					targetId, targetScore = regionId, defense
				end
			end
			local ratio = mine / math.max(targetScore, 0.5)
			local required = s.P.landAttackRatio * s.P.launchRatioShare
			if targetId and ratio >= required then
				local target, generalId, countryId = targetId :: string, general.Name, s.countryId
				table.insert(actions, {
					kind = "Attaque",
					score = 0.55 + 0.3 * math.clamp(ratio / required - 1, 0, 1),
					label = `lance l'armée de {general:GetAttribute("Nom")} sur {Regions[target].name}`,
					run = function(): boolean
						return (Armies.move(countryId, generalId, target, true))
					end,
				})
			end
		end
		return
	end
	-- déclarer une nouvelle guerre : rythme mondial, une seule guerre à la fois, un général prêt
	local now = workspace:GetServerTimeNow()
	if #s.divisions < s.P.minDivisionsForWar or MatchState.elapsed() < AI.firstAttackDelay then
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
