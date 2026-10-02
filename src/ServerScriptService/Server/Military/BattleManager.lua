--!strict
-- Batailles terrestres (SYSTEME_MILITAIRE.md, 5.1 à 5.4) : création, suivi, ticks et fin.
--   Une bataille a lieu dans une région ennemie défendue ; on l'attaque depuis une ou plusieurs
--   régions voisines (les attaquants restent chez eux pendant la bataille). Les divisions du
--   défenseur et de ses alliés présentes dans la région la défendent, celles qui arrivent aussi.
--   Chaque tick (Config/Military.tickSeconds, boucle centrale) : Combat.resolveTick (fonctions pures).
--   Fin : l'attaquant n'a plus d'organisation -> l'attaque échoue (« Repli »), il reste chez lui ;
--         le défenseur n'en a plus -> ses divisions reculent vers une région amie voisine (détruites
--         si elles sont encerclées), la région est prise et les attaquants y entrent (« Victoire »).
-- État publié dans ReplicatedStorage.EtatMonde.Batailles.<id> : Region, Attaquant, Defenseur, Etat
-- ("EnCours" | "Victoire" | "Repli"), Genre ("Terre"), Raid (false), Debut, Tick, Largeur,
-- Directions (régions d'où l'on attaque), Terrain, Riviere, NbAttaque, NbDefense, OrgAttaque et
-- OrgDefense (0 à 1), Prevision ("Attaquant" | "Indecis" | "Defenseur") ; gardé quelques secondes
-- après la fin. Attribut Bataille de la région et des divisions engagées (EnLigne : en première
-- ligne, sinon en réserve).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Military = require(Config:WaitForChild("Military")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local RegionTerrain = require(Config:WaitForChild("RegionTerrain")) :: any
local Terrain = require(Config:WaitForChild("Terrain")) :: any
local ProjectState = require(Shared:WaitForChild("ProjectState")) :: any
local CouncilState = require(Shared:WaitForChild("CouncilState")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local DiplomacyService = require(Server:WaitForChild("Politics"):WaitForChild("DiplomacyService"))
local Stability = require(Server:WaitForChild("Politics"):WaitForChild("Stability"))
local BalanceService = require(Server:WaitForChild("Politics"):WaitForChild("BalanceService"))
local Stocks = require(Server:WaitForChild("Economy"):WaitForChild("Stocks"))
local Divisions = require(script.Parent:WaitForChild("Divisions"))
local Movement = require(script.Parent:WaitForChild("Movement"))
local Combat = require(script.Parent:WaitForChild("Combat"))
local BattleService = require(script.Parent:WaitForChild("BattleService"))
local Armies = require(script.Parent:WaitForChild("Armies"))
local BattlePlans = require(script.Parent:WaitForChild("BattlePlans"))
local AirSupport = require(script.Parent:WaitForChild("AirSupport"))

local ESTIMATE_TICKS = 40 -- ticks simulés pour la prévision du vainqueur
local FORCE_PER_CASUALTY = 20 -- points de force perdus = 1 « unité » pour la stabilité (Stability.casualties)

type Fight = {
	id: string,
	folder: Folder,
	region: string,
	attacker: string, -- pays qui a lancé l'attaque
	defender: string, -- propriétaire de la région
	attackers: { [Instance]: string }, -- division -> région d'où elle attaque
	ticks: number,
	started: number,
}

local BattleManager = {}

local folder: Instance? = nil -- EtatMonde.Batailles (créé par BattleService)
local nextId = 0
local fights: { [string]: Fight } = {} -- par région disputée
local engaged: { [Instance]: Fight } = {} -- divisions engagées (attaque ou défense)

local function regionFolder(regionId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local regions = state and state:FindFirstChild("Regions")
	return regions and regions:FindFirstChild(regionId)
end

local function isHostile(countryId: string, owner: string?): boolean
	return owner ~= nil and owner ~= countryId and not DiplomacyService.areAllies(countryId, owner)
end

-- Rivière entre deux régions voisines (Config/RegionTerrain) : "Riviere", "Fleuve" ou nil
local function riverBetween(a: string, b: string): string?
	local key = if a < b then a .. "|" .. b else b .. "|" .. a
	return RegionTerrain.rivers[key]
end

local function terrainOf(regionId: string): string
	return RegionTerrain.terrain[regionId] or Terrain.default
end

local function engage(f: Fight, d: Instance)
	engaged[d] = f
	d:SetAttribute("Bataille", f.id)
end

local function release(d: Instance)
	engaged[d] = nil
	if d.Parent then
		d:SetAttribute("Bataille", nil)
		d:SetAttribute("EnLigne", nil)
	end
end

function BattleManager.isFighting(regionId: string): boolean
	return fights[regionId] ~= nil
end

-- La division mène-t-elle une attaque (et non la défense de sa région) ?
function BattleManager.isAttacking(d: Instance): boolean
	local f = engaged[d]
	return f ~= nil and f.attackers[d] ~= nil
end

-- Défenseurs d'une région : divisions du propriétaire et de ses alliés, prêtes, qui ne partent pas
local function defendersOf(f: Fight): { Instance }
	local list = {}
	for _, d in Divisions.inRegion(f.region) do
		local owner = d:GetAttribute("Proprietaire") :: string
		if not isHostile(f.defender, owner) and not Divisions.isTraining(d) and not Divisions.isMoving(d) then
			table.insert(list, d)
		end
	end
	return list
end

-- Attaquants encore valables : toujours dans leur région de départ, à l'arrêt, en guerre contre le défenseur
local function attackersOf(f: Fight): { Instance }
	local list = {}
	for d, from in f.attackers do
		local owner = d:GetAttribute("Proprietaire") :: string
		if d.Parent and d:GetAttribute("Region") == from and not Divisions.isMoving(d) and DiplomacyService.atWar(owner, f.defender) then
			table.insert(list, d)
		else
			f.attackers[d] = nil
			if engaged[d] == f then
				release(d)
			end
		end
	end
	table.sort(list, function(a: Instance, b: Instance): boolean
		return a.Name < b.Name
	end)
	return list
end

-- Bonus des grands projets (Config/Projects), de la milice d'un pays affaibli (BalanceService) et
-- des traits du général de la division (Config/Generals, voir Armies). encircled : les défenseurs
-- sont coupés de leur ravitaillement (trait « Maître de l'encerclement » des attaquants)
local function countryContext(d: Instance, ctx: Combat.Context, encircled: boolean): Combat.Context
	local owner = d:GetAttribute("Proprietaire") :: string
	local typeId = d:GetAttribute("Type")
	ctx.attackBonus = (ctx.attackBonus or 0) + ProjectState.factor(owner, "attack") - 1
	if not ctx.attacking then
		ctx.defenseBonus = (ctx.defenseBonus or 0) + ProjectState.factor(owner, "defense") - 1
	end
	if typeId == "Milice" then
		ctx.factor = BalanceService.militiaFactor(owner)
	end
	-- traits du général
	local both = 0
	if typeId == "Blindee" or typeId == "Mecanisee" then
		both += Armies.bonus(d, "Blindes")
	elseif typeId == "Artillerie" then
		both += Armies.bonus(d, "Artillerie")
	end
	if ctx.terrain and Military.generals.roughTerrain[ctx.terrain] then
		both += Armies.bonus(d, "rough")
	end
	if ctx.attacking then
		ctx.attackBonus = (ctx.attackBonus :: number) + both + Armies.bonus(d, "attack") + (if encircled then Armies.bonus(d, "encirclement") else 0)
		ctx.defenseBonus = (ctx.defenseBonus or 0) + both
	else
		ctx.attackBonus = (ctx.attackBonus :: number) + both
		ctx.defenseBonus = (ctx.defenseBonus or 0) + both + Armies.bonus(d, "defense")
	end
	ctx.resilience = Armies.bonus(d, "morale")
	-- bonus de planification (plan préparé avant l'attaque, divisions sous contrôle du plan)
	if ctx.attacking then
		ctx.attackBonus = (ctx.attackBonus :: number) + BattlePlans.bonus(d)
	end
	ctx.experience = (d:GetAttribute("Experience") :: number?) or 0
	ctx.supplied = d:GetAttribute("Ravitaillee") ~= false
	ctx.fuel = Stocks.get(owner, "Petrole") > 0
	return ctx
end

local function unitOf(d: Instance, ctx: Combat.Context, encircled: boolean?): Combat.Unit
	local u = Combat.makeUnit(d:GetAttribute("Type") :: string, {
		id = d.Name,
		org = (d:GetAttribute("Org") :: number?) or 0,
		orgMax = (d:GetAttribute("OrgMax") :: number?) or 1,
		str = (d:GetAttribute("Force") :: number?) or 0,
	}, countryContext(d, ctx, encircled == true))
	u.line = d:GetAttribute("EnLigne") == true
	return u
end

-- Expérience d'une division (trait « Vétéran » de son général : plus)
local function divisionExperience(d: Instance, amount: number)
	Divisions.addExperience(d, amount * (1 + Armies.bonus(d, "experience")))
end

-- Région amie voisine où une division vaincue peut reculer (nil : encerclée)
local function retreatTarget(d: Instance, regionId: string): string?
	local owner = d:GetAttribute("Proprietaire") :: string
	local best: string? = nil
	local bestScore = math.huge
	for _, link in Regions[regionId].neighbors do
		local to = link.region
		local toOwner = RegionService.getOwner(to)
		if link.bySea or not toOwner or isHostile(owner, toOwner) then
			continue
		end
		local occupancy = Divisions.occupancy(to)
		if occupancy >= Military.maxDivisionsPerRegion then
			continue
		end
		-- de préférence une région calme et peu occupée
		local score = occupancy + (if fights[to] then 20 else 0)
		if score < bestScore then
			best, bestScore = to, score
		end
	end
	return best
end

local function publish(f: Fight, attackers: { Instance }, defenders: { Instance }, battle: Combat.Battle?)
	local b = f.folder
	local directions: { string } = {}
	local seen: { [string]: boolean } = {}
	local river = false
	for _, d in attackers do
		local from = f.attackers[d]
		if from and not seen[from] then
			seen[from] = true
			table.insert(directions, from)
			river = river or riverBetween(from, f.region) ~= nil
		end
	end
	table.sort(directions)
	b:SetAttribute("Defenseur", f.defender)
	b:SetAttribute("Tick", f.ticks)
	b:SetAttribute("Directions", table.concat(directions, ","))
	b:SetAttribute("Largeur", Combat.width(terrainOf(f.region), math.max(1, #directions)))
	b:SetAttribute("Riviere", river)
	b:SetAttribute("NbAttaque", #attackers)
	b:SetAttribute("NbDefense", #defenders)
	if battle then
		b:SetAttribute("OrgAttaque", Combat.orgRatio(battle.attackers))
		b:SetAttribute("OrgDefense", Combat.orgRatio(battle.defenders))
	end
end

-- Plan de bataille (SYSTEME_MILITAIRE.md, 4.4 : ne pas dégarnir le front) : une division du plan
-- qui serait la dernière à tenir sa région, encore au contact d'un ennemi, n'avance pas
local function lastHolder(d: Instance, captured: string): boolean
	if d:GetAttribute("Controle") ~= "Plan" then
		return false
	end
	local here = d:GetAttribute("Region") :: string
	local owner = d:GetAttribute("Proprietaire") :: string
	local others = 0
	for _, other in Divisions.inRegion(here) do
		if other ~= d and not Divisions.isMoving(other) and other:GetAttribute("Proprietaire") == owner then
			others += 1
		end
	end
	if others > 0 then
		return false
	end
	for _, link in Regions[here].neighbors do
		if not link.bySea and link.region ~= captured and isHostile(owner, RegionService.getOwner(link.region)) then
			return true
		end
	end
	return false
end

-- Fin de bataille. result : "Victoire" (la région est prise) ou "Repli" (l'attaque a échoué)
local function finish(f: Fight, result: string)
	if fights[f.region] ~= f then
		return
	end
	fights[f.region] = nil
	local attackers = attackersOf(f)
	local defenders = defendersOf(f)
	for d, other in engaged do
		if other == f then
			release(d)
		end
	end
	local region = regionFolder(f.region)
	if region and region:GetAttribute("Bataille") == f.id then
		region:SetAttribute("Bataille", nil)
	end
	f.folder:SetAttribute("Etat", result)
	local E = Military.experience
	if result == "Victoire" then
		-- le défenseur recule vers une région amie voisine, ou il est détruit (encerclé)
		for _, d in defenders do
			local to = retreatTarget(d, f.region)
			if to then
				Movement.retreat(d, to)
			else
				Divisions.destroy(d)
			end
		end
		-- la région change de mains : celui qui a lancé l'attaque, s'il y est encore
		local winner = f.attacker
		local stillThere = false
		for _, d in attackers do
			if d:GetAttribute("Proprietaire") == f.attacker then
				stillThere = true
			end
		end
		if not stillThere and attackers[1] then
			winner = attackers[1]:GetAttribute("Proprietaire") :: string
		end
		Movement.capture(f.region, winner)
		-- les attaquants entrent dans la région (les plus organisés d'abord, 10 au plus)
		table.sort(attackers, function(a: Instance, b: Instance): boolean
			return ((a:GetAttribute("Org") :: number?) or 0) > ((b:GetAttribute("Org") :: number?) or 0)
		end)
		local advanced = 0
		for _, d in attackers do
			divisionExperience(d, E.victory)
			if ((d:GetAttribute("Org") :: number?) or 0) > 0 and (advanced == 0 or not lastHolder(d, f.region)) then
				Movement.advance(d, f.region)
				advanced += 1
			end
		end
	else
		-- l'attaque a échoué : les attaquants restent chez eux, la suite de leur route est annulée
		for _, d in attackers do
			d:SetAttribute("Itineraire", nil)
		end
		for _, d in defenders do
			divisionExperience(d, E.victory)
		end
	end
	-- généraux des vainqueurs : expérience
	local winners = if result == "Victoire" then attackers else defenders
	local credited: { [Instance]: boolean } = {}
	for _, d in winners do
		local general = Armies.get(d:GetAttribute("Armee"))
		if general and not credited[general] then
			credited[general] = true
			Armies.addExperience(general, Military.generals.xpVictory)
		end
	end
	BattleService.reportResult(result, f.attacker, f.defender, f.region, nil)
	local battleFolder = f.folder
	task.delay(Military.combat.resultDelay, function()
		battleFolder:Destroy()
	end)
end

-- Un tick d'une bataille
local function tickFight(f: Fight)
	-- la région a changé de mains (révolte, autre bataille...) : le nouveau propriétaire défend
	local owner = RegionService.getOwner(f.region)
	if owner and owner ~= f.defender then
		f.defender = owner
	end
	if CouncilState.ceasefireLeft() > 0 then
		finish(f, "Repli") -- cessez-le-feu du Conseil mondial : les combats s'arrêtent
		return
	end
	local attackers = attackersOf(f)
	if #attackers == 0 then
		finish(f, "Repli")
		return
	end
	-- défenseurs : ceux qui menaient une attaque ailleurs reviennent défendre leur région
	local defenders = defendersOf(f)
	for _, d in defenders do
		local other = engaged[d]
		if other ~= f then
			if other and other.attackers[d] then
				other.attackers[d] = nil
			end
			engage(f, d)
		end
	end
	if #defenders == 0 then
		finish(f, "Victoire")
		return
	end

	local terrain = terrainOf(f.region)
	local region = regionFolder(f.region)
	local fortification = (region and region:GetAttribute("Fortification") :: number?) or 0
	local units: { [string]: Instance } = {}
	local battle: Combat.Battle = { attackers = {}, defenders = {}, width = 0 }
	local directions: { [string]: boolean } = {}
	local count = 0
	-- soutien aérien : escadrilles des deux camps au-dessus de la région (AirSupport)
	local attackerFighters, attackerSupport = AirSupport.cover(f.region, f.attacker)
	local defenderFighters, defenderSupport = AirSupport.cover(f.region, f.defender)
	local air = AirSupport.effects(attackerFighters, attackerSupport, defenderFighters, defenderSupport)
	-- défenseurs coupés de leur ravitaillement (trait « Maître de l'encerclement » des attaquants)
	local encircled = false
	for _, d in defenders do
		if d:GetAttribute("Encerclee") == true then
			encircled = true
		end
	end
	for _, d in attackers do
		local from = f.attackers[d]
		if not directions[from] then
			directions[from] = true
			count += 1
		end
		table.insert(battle.attackers, unitOf(d, {
			attacking = true,
			terrain = terrain,
			river = riverBetween(from, f.region),
			attackBonus = air.attackerBonus,
			defenseBonus = air.attackerBonus,
		}, encircled))
		units[d.Name] = d
	end
	for _, d in defenders do
		table.insert(battle.defenders, unitOf(d, {
			attacking = false,
			terrain = terrain,
			entrenchment = (d:GetAttribute("Retranchement") :: number?) or 0,
			fortification = fortification,
			attackBonus = air.defenderBonus,
			defenseBonus = air.defenderBonus,
		}))
		units[d.Name] = d
	end
	battle.width = Combat.width(terrain, count)

	local after, report = Combat.resolveTick(battle)
	-- appui au sol : de l'organisation en moins pour la ligne ennemie (le combat a pu se jouer là)
	if report.result == "EnCours" then
		AirSupport.applyDamage(after.defenders, air.damageToDefenders)
		AirSupport.applyDamage(after.attackers, air.damageToAttackers)
		local function standing(list: { Combat.Unit }): boolean
			for _, u in list do
				if u.org > 0 then
					return true
				end
			end
			return false
		end
		if not standing(after.defenders) and standing(after.attackers) then
			report.result = "Victoire"
		elseif not standing(after.attackers) then
			report.result = "Repli"
		end
	end
	f.folder:SetAttribute("Superiorite", air.superiority)
	f.folder:SetAttribute("AppuiAttaque", attackerSupport > 0)
	f.folder:SetAttribute("AppuiDefense", defenderSupport > 0)
	f.ticks += 1
	-- nouvel état des divisions ; pertes de force -> stabilité du pays
	local casualties: { [string]: number } = {}
	local commanders: { [Instance]: boolean } = {}
	local planners: { [Instance]: boolean } = {}
	for _, list in { after.attackers, after.defenders } do
		for _, u in list do
			local d = units[u.id]
			if not d or not d.Parent then
				continue
			end
			d:SetAttribute("Org", u.org)
			d:SetAttribute("Force", u.str)
			d:SetAttribute("EnLigne", u.line)
			if u.line then
				divisionExperience(d, Military.experience.perCombatTick)
				local general = Armies.get(d:GetAttribute("Armee"))
				if general then
					commanders[general] = true
					-- le plan sert : son bonus diminue à chaque tick d'attaque
					if f.attackers[d] and d:GetAttribute("Controle") == "Plan" then
						planners[general] = true
					end
				end
			end
			local lost = report.strLost[u.id]
			if lost then
				local country = d:GetAttribute("Proprietaire") :: string
				casualties[country] = (casualties[country] or 0) + lost
			end
		end
	end
	for country, lost in casualties do
		Stability.casualties(country, lost / FORCE_PER_CASUALTY)
	end
	-- les généraux apprennent en commandant
	for general in commanders do
		Armies.addExperience(general, Military.generals.xpPerTick)
	end
	for general in planners do
		BattlePlans.spendPlanning(general)
	end
	-- divisions anéanties (plus de force du tout)
	for _, list in { after.attackers, after.defenders } do
		for _, u in list do
			local d = units[u.id]
			if d and d.Parent and u.str <= 0 then
				release(d)
				f.attackers[d] = nil
				Divisions.destroy(d)
			end
		end
	end
	publish(f, attackersOf(f), defendersOf(f), after)
	-- prévision du vainqueur (un tick sur deux : c'est une petite simulation)
	if f.ticks % 2 == 1 then
		local predicted = Combat.estimate(after, ESTIMATE_TICKS)
		f.folder:SetAttribute("Prevision", if predicted == "Victoire" then "Attaquant" elseif predicted == "Repli" then "Defenseur" else "Indecis")
	end
	if report.result ~= "EnCours" then
		finish(f, report.result)
	end
end

-- Engage une division contre une région ennemie défendue (appelé par Movement)
function BattleManager.attack(d: Instance, from: string, target: string): (boolean, string?)
	if not d.Parent or Divisions.isTraining(d) or not folder then
		return false, "Cette division n'est pas prête."
	end
	local current = engaged[d]
	if current then
		if current.attackers[d] == nil then
			return false, "Elle défend sa région."
		end
		if current.region == target then
			return true, nil
		end
		BattleManager.withdraw(d)
	end
	if ((d:GetAttribute("Org") :: number?) or 0) <= 0 then
		return false, "Organisation à zéro : la division doit d'abord se reposer."
	end
	local countryId = d:GetAttribute("Proprietaire") :: string
	local defender = RegionService.getOwner(target)
	if not defender or not isHostile(countryId, defender) or not DiplomacyService.atWar(countryId, defender) then
		return false, "Pas en guerre avec ce pays."
	end
	local f = fights[target]
	if not f then
		nextId += 1
		local battleFolder = Instance.new("Folder")
		battleFolder.Name = "T" .. nextId
		battleFolder:SetAttribute("Region", target)
		battleFolder:SetAttribute("Attaquant", countryId)
		battleFolder:SetAttribute("Defenseur", defender)
		battleFolder:SetAttribute("Etat", "EnCours")
		battleFolder:SetAttribute("Genre", "Terre")
		battleFolder:SetAttribute("Raid", false)
		battleFolder:SetAttribute("Debut", workspace:GetServerTimeNow())
		battleFolder:SetAttribute("Terrain", terrainOf(target))
		battleFolder:SetAttribute("Prevision", "Indecis")
		local created: Fight = {
			id = battleFolder.Name,
			folder = battleFolder,
			region = target,
			attacker = countryId,
			defender = defender,
			attackers = {},
			ticks = 0,
			started = workspace:GetServerTimeNow(),
		}
		f = created
		fights[target] = created
		local region = regionFolder(target)
		if region then
			region:SetAttribute("Bataille", battleFolder.Name)
		end
		battleFolder.Parent = folder
	end
	local fight = f :: Fight
	fight.attackers[d] = from
	engage(fight, d)
	d:SetAttribute("EnLigne", false)
	d:SetAttribute("Retranchement", 0) -- elle quitte ses positions pour attaquer
	for _, defender in defendersOf(fight) do
		if not engaged[defender] then
			engage(fight, defender)
		end
	end
	publish(fight, attackersOf(fight), defendersOf(fight), nil)
	return true, nil
end

-- La division cesse son attaque (elle reste dans sa région)
function BattleManager.withdraw(d: Instance)
	local f = engaged[d]
	if f and f.attackers[d] then
		f.attackers[d] = nil
		release(d)
	end
end

-- Toutes les batailles avancent d'un tick
local function update()
	local list = {}
	for _, f in fights do
		table.insert(list, f)
	end
	for _, f in list do
		if fights[f.region] == f then
			local ok, err = pcall(tickFight, f)
			if not ok then
				warn(`[Batailles] {f.region} : {err}`)
				finish(f, "Repli")
			end
		end
	end
end

-- Nouvelle partie : plus aucune bataille (le dossier EtatMonde.Batailles est vidé par BattleService)
function BattleManager.reset()
	table.clear(fights)
	table.clear(engaged)
end

-- À appeler après BattleService.init(), Divisions.init() et Movement.init()
function BattleManager.init(loop: any)
	folder = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Batailles")
	loop.every("batailles", Military.tickSeconds, update)
	Movement.setBattleHooks({
		attack = BattleManager.attack,
		withdraw = BattleManager.withdraw,
		isAttacking = BattleManager.isAttacking,
	})
	-- une division détruite quitte sa bataille
	Divisions.onRemoved(function(d: Instance)
		local f = engaged[d]
		if f then
			f.attackers[d] = nil
			engaged[d] = nil
		end
	end)
end

return BattleManager
