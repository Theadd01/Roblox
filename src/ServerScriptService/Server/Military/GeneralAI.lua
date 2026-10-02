--!strict
-- Exécution automatique des plans par les généraux (SYSTEME_MILITAIRE.md, 4.4), toutes les
-- Config/Military.aiInterval secondes, pour chaque général qui a un plan (BattlePlans) :
--   1. front : ses régions face au pays visé (recalculé : le front suit les conquêtes) ;
--   2. repli : si l'ennemi prend une région du front et qu'une ligne de repli existe, l'armée s'y
--      replie et s'y retranche (ordre « Tenir ») ;
--   3. répartition : au moins 1 division par région du front, plus là où l'ennemi est nombreux en
--      face, jamais plus de 10 par région ;
--   4. offensive lancée : attaque les régions ennemies voisines du front qui mènent aux objectifs,
--      de préférence faibles, attaquables de plusieurs côtés, sur un terrain favorable, ou coupées
--      de leur ravitaillement ; sans dégarnir le front ; une région vidée est occupée ; tous les
--      objectifs pris : la ligne offensive devient le nouveau front ;
--   5. repos : une division attaquante sous 30 % d'organisation sort du combat, une fraîche la
--      remplace si possible.
-- Seules les divisions sous contrôle du plan (Controle = "Plan") obéissent ; un ordre direct du
-- joueur les en sort (Movement), « Ajouter à son armée » les y remet (Armies).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Military = require(Config:WaitForChild("Military")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Terrain = require(Config:WaitForChild("Terrain")) :: any
local RegionTerrain = require(Config:WaitForChild("RegionTerrain")) :: any
local CouncilState = require(Shared:WaitForChild("CouncilState")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local DiplomacyService = require(Server:WaitForChild("Politics"):WaitForChild("DiplomacyService"))
local Divisions = require(script.Parent:WaitForChild("Divisions"))
local Movement = require(script.Parent:WaitForChild("Movement"))
local Armies = require(script.Parent:WaitForChild("Armies"))
local BattlePlans = require(script.Parent:WaitForChild("BattlePlans"))
local Combat = require(script.Parent:WaitForChild("Combat"))

local MAX_TARGETS = 3 -- attaques lancées en même temps par une armée, au plus
local GROUPS = 3 -- généraux répartis en 3 groupes qui réfléchissent l'un après l'autre
local ABANDON_AFTER = 6 -- ticks de bataille avant d'abandonner une attaque que la prévision donne perdue
local PATH_LIMIT = 12 -- distance (en régions) prise en compte vers un objectif

local GeneralAI = {}

local lastFront: { [Instance]: { [string]: boolean } } = {} -- front du tour précédent (détection d'une percée)

local function orgRatio(d: Instance): number
	local org = (d:GetAttribute("Org") :: number?) or 0
	local orgMax = math.max((d:GetAttribute("OrgMax") :: number?) or 1, 1)
	return org / orgMax
end

local function hostile(countryId: string, owner: string?): boolean
	return owner ~= nil and owner ~= countryId and not DiplomacyService.areAllies(countryId, owner)
end

-- Distance (en régions, par la terre) de chaque région à l'objectif le plus proche (pur : la carte)
function GeneralAI.distances(objectives: { string }, limit: number): { [string]: number }
	local distance: { [string]: number } = {}
	local queue = {}
	for _, regionId in objectives do
		if Regions[regionId] then
			distance[regionId] = 0
			table.insert(queue, regionId)
		end
	end
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		local d = distance[current]
		if d >= limit then
			continue
		end
		for _, link in Regions[current].neighbors do
			if not link.bySea and distance[link.region] == nil and Regions[link.region] then
				distance[link.region] = d + 1
				table.insert(queue, link.region)
			end
		end
	end
	return distance
end

-- Divisions de l'armée qui obéissent au plan
local function planDivisions(general: Instance): { Instance }
	local list = {}
	for _, d in Armies.divisionsOf(general) do
		if d:GetAttribute("Controle") == "Plan" and not Divisions.isTraining(d) then
			table.insert(list, d)
		end
	end
	return list
end

-- Menace en face d'une région du front : divisions ennemies dans ses voisines
local function threatOf(regionId: string, countryId: string): number
	local threat = 0
	for _, link in Regions[regionId].neighbors do
		if not link.bySea and hostile(countryId, RegionService.getOwner(link.region)) then
			threat += #Movement.defenders(link.region, countryId)
		end
	end
	return threat
end

local function sendTo(countryId: string, d: Instance, regionId: string): boolean
	local ok = Movement.order(countryId, { d }, regionId, true)
	return ok
end

-- 3. Répartition des divisions libres sur le front (au moins 1 par région, plus face aux menaces)
local function distribute(general: Instance, countryId: string, front: { string }, army: { Instance })
	if #front == 0 then
		return
	end
	-- où sont (ou vont) les divisions de l'armée
	local assigned: { [string]: number } = {}
	local free: { Instance } = {}
	local idleOn: { [string]: { Instance } } = {} -- divisions à l'arrêt sur chaque région du front
	local frontSet: { [string]: boolean } = {}
	for _, regionId in front do
		frontSet[regionId] = true
		assigned[regionId] = 0
		idleOn[regionId] = {}
	end
	for _, d in army do
		if Divisions.inBattle(d) then
			local here = d:GetAttribute("Region") :: string
			if frontSet[here] then
				assigned[here] += 1
			end
			continue
		end
		local place = (if Divisions.isMoving(d) then d:GetAttribute("Destination") else d:GetAttribute("Region")) :: string
		if frontSet[place] then
			assigned[place] += 1
			if not Divisions.isMoving(d) then
				table.insert(idleOn[place], d)
			end
		elseif not Divisions.isMoving(d) then
			table.insert(free, d)
		end
	end
	-- besoin de chaque région : 1, plus une part des divisions selon la menace en face
	local threats: { [string]: number } = {}
	local totalThreat = 0
	for _, regionId in front do
		threats[regionId] = threatOf(regionId, countryId)
		totalThreat += threats[regionId]
	end
	local spare = math.max(0, #army - #front)
	local wanted: { [string]: number } = {}
	for _, regionId in front do
		local share = if totalThreat > 0 then threats[regionId] / totalThreat else 1 / #front
		wanted[regionId] = math.min(Military.maxDivisionsPerRegion, 1 + math.floor(spare * share + 0.5))
	end
	-- régions du front qui en manquent, les plus menacées d'abord
	local needy = table.clone(front)
	table.sort(needy, function(a: string, b: string): boolean
		local da, db = wanted[a] - assigned[a], wanted[b] - assigned[b]
		if da ~= db then
			return da > db
		end
		return threats[a] > threats[b]
	end)
	for _, regionId in needy do
		local target = Regions[regionId].city
		local function distanceTo(d: Instance): number
			local region = Regions[d:GetAttribute("Region") :: string]
			local city = region and region.city
			return if city and target then (city.lon - target.lon) ^ 2 + (city.lat - target.lat) ^ 2 else 0
		end
		while assigned[regionId] < wanted[regionId] do
			-- d'abord une division libre (hors du front), sinon une division d'une région du front
			-- qui en a plus qu'il ne lui en faut ; la plus proche
			local pool: { Instance }? = nil
			local bestIndex, bestDistance = 0, math.huge
			local source: string? = nil
			for i, d in free do
				local dist = distanceTo(d)
				if dist < bestDistance then
					pool, bestIndex, bestDistance, source = free, i, dist, nil
				end
			end
			if not pool then
				for other, list in idleOn do
					if other ~= regionId and assigned[other] > wanted[other] then
						for i, d in list do
							local dist = distanceTo(d)
							if dist < bestDistance then
								pool, bestIndex, bestDistance, source = list, i, dist, other
							end
						end
					end
				end
			end
			if not pool then
				break -- plus personne à envoyer
			end
			local d = table.remove(pool, bestIndex) :: Instance
			if sendTo(countryId, d, regionId) then
				assigned[regionId] += 1
				if source then
					assigned[source] -= 1
				end
			end
		end
	end
end

-- 2. Percée de l'ennemi sur le front : repli sur la ligne de repli (si elle existe)
local function checkBreak(general: Instance, countryId: string, front: { string }, army: { Instance }): boolean
	local previous = lastFront[general]
	local current: { [string]: boolean } = {}
	for _, regionId in front do
		current[regionId] = true
	end
	lastFront[general] = current
	if not previous then
		return false
	end
	local enemy = general:GetAttribute("FrontPays")
	local broken = false
	for regionId in previous do
		if not current[regionId] and RegionService.getOwner(regionId) == enemy then
			broken = true -- l'ennemi a pris une région du front
			break
		end
	end
	local fallback = BattlePlans.list(general, "Repli")
	if not broken or #fallback == 0 then
		return false
	end
	-- repli : les divisions se répartissent sur la ligne de repli et s'y retranchent
	local i = 0
	for _, d in army do
		if Divisions.isTraining(d) then
			continue
		end
		i += 1
		local regionId = fallback[(i - 1) % #fallback + 1]
		if Divisions.inBattle(d) then
			Movement.stop({ d }) -- les attaquants cessent leur attaque
		end
		if d:GetAttribute("Region") ~= regionId then
			sendTo(countryId, d, regionId)
		end
	end
	general:SetAttribute("Ordre", "Tenir")
	return true
end

-- Valeur d'une cible pour l'offensive (plus c'est haut, mieux c'est)
local function targetScore(regionId: string, countryId: string, distance: number, directions: number): number
	local defenders = Movement.defenders(regionId, countryId)
	local strength = 0
	local encircled = false
	for _, d in defenders do
		strength += orgRatio(d) * ((d:GetAttribute("Force") :: number?) or 0) / 100
		if d:GetAttribute("Encerclee") == true then
			encircled = true
		end
	end
	local terrain = Terrain.types[RegionTerrain.terrain[regionId] or Terrain.default] or Terrain.types[Terrain.default]
	return -distance * 10 -- vers les objectifs d'abord
		- strength * 4 -- faible
		+ directions * 3 -- attaquable de plusieurs côtés (largeur de bataille)
		+ terrain.attack * 10 -- terrain favorable (malus de l'attaquant faible)
		+ (if encircled then 5 else 0) -- défenseurs coupés de leur ravitaillement
		+ (if #defenders == 0 then 8 else 0) -- région vide : on l'occupe
end

-- Rivière entre deux régions voisines (comme BattleManager)
local function riverBetween(a: string, b: string): string?
	return RegionTerrain.rivers[if a < b then a .. "|" .. b else b .. "|" .. a]
end

local function unitFrom(d: Instance, ctx: Combat.Context): Combat.Unit
	ctx.experience = (d:GetAttribute("Experience") :: number?) or 0
	ctx.supplied = d:GetAttribute("Ravitaillee") ~= false
	return Combat.makeUnit(d:GetAttribute("Type") :: string, {
		id = d.Name,
		org = (d:GetAttribute("Org") :: number?) or 0,
		orgMax = (d:GetAttribute("OrgMax") :: number?) or 1,
		str = (d:GetAttribute("Force") :: number?) or 0,
	}, ctx)
end

-- Issue probable d'une attaque (simulation rapide avec les fonctions de Combat) : "Victoire",
-- "Repli" (perdue d'avance) ou "EnCours" (indécise)
local function odds(countryId: string, target: string, attackers: { { d: Instance, from: string } }): string
	local defenders = Movement.defenders(target, countryId)
	if #defenders == 0 then
		return "Victoire"
	end
	local terrain = RegionTerrain.terrain[target] or Terrain.default
	local directions: { [string]: boolean } = {}
	local count = 0
	local battle: Combat.Battle = { attackers = {}, defenders = {}, width = 0 }
	for _, entry in attackers do
		if not directions[entry.from] then
			directions[entry.from] = true
			count += 1
		end
		table.insert(battle.attackers, unitFrom(entry.d, { attacking = true, terrain = terrain, river = riverBetween(entry.from, target) }))
	end
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local regions = state and state:FindFirstChild("Regions")
	local region = regions and regions:FindFirstChild(target)
	local fortification = (region and region:GetAttribute("Fortification") :: number?) or 0
	for _, d in defenders do
		table.insert(battle.defenders, unitFrom(d, {
			attacking = false,
			terrain = terrain,
			entrenchment = (d:GetAttribute("Retranchement") :: number?) or 0,
			fortification = fortification,
		}))
	end
	battle.width = Combat.width(terrain, count)
	return (Combat.estimate(battle, 60))
end

-- 4 et 5. Offensive : choix des attaques, envoi des divisions, repos des épuisées
local function attack(general: Instance, countryId: string, front: { string }, army: { Instance })
	local enemy = general:GetAttribute("FrontPays") :: string
	if not DiplomacyService.atWar(countryId, enemy) or CouncilState.ceasefireLeft() > 0 then
		general:SetAttribute("Ordre", "Front") -- paix ou cessez-le-feu : on tient le front
		return
	end
	-- objectifs encore aux mains de l'ennemi
	local objectives = {}
	for _, regionId in BattlePlans.list(general, "Objectifs") do
		if hostile(countryId, RegionService.getOwner(regionId)) then
			table.insert(objectives, regionId)
		end
	end
	if #objectives == 0 then
		-- ligne offensive atteinte : elle devient le nouveau front
		general:SetAttribute("Objectifs", nil)
		general:SetAttribute("Ordre", "Front")
		return
	end
	-- 5. repos : les attaquants épuisés sortent du combat ; une attaque qui tourne mal (prévision
	-- au défenseur après quelques ticks) est arrêtée pour ménager l'armée
	for _, d in army do
		if not Divisions.inBattle(d) then
			continue
		end
		local id = d:GetAttribute("Bataille")
		local state = ReplicatedStorage:FindFirstChild("EtatMonde")
		local battles = state and state:FindFirstChild("Batailles")
		local battle = if typeof(id) == "string" and battles then battles:FindFirstChild(id) else nil
		local battleRegion = battle and battle:GetAttribute("Region")
		if not battle or battleRegion == d:GetAttribute("Region") then
			continue -- elle défend sa région : elle reste
		end
		local losing = battle:GetAttribute("Prevision") == "Defenseur" and ((battle:GetAttribute("Tick") :: number?) or 0) >= ABANDON_AFTER
		if losing or orgRatio(d) < Military.rotationBelow then
			Movement.stop({ d })
		end
	end
	local distance = GeneralAI.distances(objectives, PATH_LIMIT)
	-- divisions disponibles par région du front (pas en route, pas déjà en bataille, assez organisées)
	local ready: { [string]: { Instance } } = {}
	local present: { [string]: number } = {}
	for _, d in army do
		local here = d:GetAttribute("Region") :: string
		if not Divisions.isMoving(d) then
			present[here] = (present[here] or 0) + 1
		end
		if not Divisions.isMoving(d) and not Divisions.inBattle(d) and orgRatio(d) >= Military.attackOrgMin then
			ready[here] = ready[here] or {}
			table.insert(ready[here], d)
		end
	end
	-- cibles : régions ennemies voisines des régions où l'armée se tient
	local candidates: { [string]: { string } } = {} -- cible -> régions d'où l'attaquer
	for here in present do
		for _, link in Regions[here].neighbors do
			local target = link.region
			if link.bySea or not Regions[target] then
				continue
			end
			local owner = RegionService.getOwner(target)
			if not hostile(countryId, owner) or not DiplomacyService.atWar(countryId, owner :: string) then
				continue
			end
			if distance[target] == nil then
				continue -- ne mène pas vers les objectifs
			end
			candidates[target] = candidates[target] or {}
			table.insert(candidates[target], here)
		end
	end
	local ranked = {}
	for target, origins in candidates do
		table.insert(ranked, { target = target, score = targetScore(target, countryId, distance[target], #origins), origins = origins })
	end
	table.sort(ranked, function(a: any, b: any): boolean
		return a.score > b.score
	end)
	local launched = 0
	for _, entry in ranked do
		if launched >= MAX_TARGETS then
			break
		end
		local sent = 0
		-- région vide : une seule division suffit pour l'occuper
		local limit = if #Movement.defenders(entry.target, countryId) == 0 then 1 else math.huge
		-- pas d'attaque perdue d'avance : on simule le combat avec les divisions disponibles
		-- (et celles qui attaquent déjà cette région)
		local group: { { d: Instance, from: string } } = {}
		for _, from in entry.origins do
			for _, d in ready[from] or {} do
				table.insert(group, { d = d, from = from })
			end
		end
		if #group == 0 or (limit > 1 and odds(countryId, entry.target, group) == "Repli") then
			continue
		end
		for _, from in entry.origins do
			local list = ready[from] or {}
			-- les attaquants restent chez eux pendant la bataille : le front n'est pas dégarni ;
			-- après la victoire, la dernière division d'une région encore au contact de l'ennemi
			-- n'avance pas (BattleManager)
			while #list > 0 and sent < limit do
				local d = table.remove(list) :: Instance
				if sendTo(countryId, d, entry.target) then
					sent += 1
				end
			end
		end
		if sent > 0 then
			launched += 1
		end
	end
end

local phase = 0 -- les généraux réfléchissent par groupes, à tour de rôle (la charge est étalée)

local function think()
	-- propriétaires des régions, une fois pour tous les généraux (le calcul des fronts va plus vite)
	local ownerOf: { [string]: string } = {}
	local ownedBy: { [string]: { string } } = {}
	for regionId in Regions do
		local owner = RegionService.getOwner(regionId)
		if owner then
			ownerOf[regionId] = owner
			ownedBy[owner] = ownedBy[owner] or {}
			table.insert(ownedBy[owner], regionId)
		end
	end
	local function owner(regionId: string): string?
		return ownerOf[regionId]
	end
	phase = (phase + 1) % GROUPS
	for index, general in Armies.all() do
		if index % GROUPS ~= phase or not BattlePlans.hasPlan(general) then
			continue
		end
		local countryId = general:GetAttribute("Proprietaire") :: string
		local enemy = general:GetAttribute("FrontPays") :: string
		-- 1. front (il suit la frontière avec le pays visé)
		local front = BattlePlans.frontRegions(countryId, enemy, owner, ownedBy[countryId] or {})
		local published = if #front > 0 then table.concat(front, ",") else nil
		if general:GetAttribute("Front") ~= published then
			general:SetAttribute("Front", published)
		end
		local enemyLeft = ownedBy[enemy] ~= nil
		if not enemyLeft then
			BattlePlans.clear(general) -- le pays visé n'existe plus : plan terminé
			continue
		end
		local army = planDivisions(general)
		local order = general:GetAttribute("Ordre")
		if checkBreak(general, countryId, front, army) then
			continue
		end
		if order == "Tenir" then
			continue -- elles restent où elles sont et se retranchent
		end
		if order == "Offensive" then
			attack(general, countryId, front, army)
		end
		distribute(general, countryId, front, army)
	end
	for general in lastFront do
		if not general.Parent then
			lastFront[general] = nil
		end
	end
end

function GeneralAI.reset()
	table.clear(lastFront)
end

function GeneralAI.init(loop: any)
	-- chaque général réfléchit toutes les Config/Military.aiInterval secondes, un groupe à la fois
	loop.every("generaux-ia", Military.aiInterval / GROUPS, function()
		think()
	end)
end

return GeneralAI
