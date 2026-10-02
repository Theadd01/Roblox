--!strict
-- Batailles terrestres (cahier des charges v2, section 2) : création, suivi, ticks et fin.
--   Une bataille a lieu dans une région ennemie défendue ; on l'attaque depuis TOUTES ses régions
--   voisines (attackRegion : chaque région voisine engage ses divisions ; 2 régions x 10 = 20
--   soldats) ; les attaquants restent chez eux pendant la bataille (la limite de 10 par région ne
--   vaut que pour le stationnement). Un général attaque avec toute son armée (Armies). Les
--   divisions du défenseur et de ses alliés présentes dans la région la défendent.
--   UNE boucle par bataille : un tick toutes les Config/CombatConfig.tickSeconds, résolu par
--   Combat.resolveTick (fonctions pures) ; les modèles des clients ne font que l'animer.
--   Soldat à 0 PV : il se replie dans une région amie voisine avec retreatHealth de ses PV (un
--   attaquant reste dans sa région, un soldat d'un général reste dans son armée), ou il meurt
--   s'il n'en a aucune.
--   Fin : plus aucun défenseur debout (ou repli du défenseur à bout de moral) -> la région change
--   de propriétaire tout de suite (« Victoire ») et les vainqueurs y avancent ; plus d'attaquant
--   (ou repli de l'attaquant) -> l'attaque échoue (« Repli »), ils restent chez eux.
--   Attaque continue (attribut AttaqueContinue des divisions) : après une victoire, les divisions
--   qui ont avancé attaquent la région ennemie voisine suivante, tant qu'elles ont des effectifs
--   et du moral (Config/CombatConfig.continuous).
-- État publié dans ReplicatedStorage.EtatMonde.Batailles.<id> : Region, Attaquant, Defenseur, Etat
-- ("EnCours" | "Victoire" | "Repli"), Genre ("Terre"), Raid (false), Debut, Tick, Largeur,
-- Directions (régions d'où l'on attaque), Terrain, Riviere, NbAttaque, NbDefense, OrgAttaque et
-- OrgDefense (0 à 1), PVAttaque et PVDefense (0 à 1), EnLigneAttaque, EnLigneDefense,
-- PertesAttaque, PertesDefense, Prevision ("Attaquant" | "Indecis" | "Defenseur") ; gardé quelques
-- secondes après la fin. Attributs des divisions engagées : Bataille, EnLigne (au front, sinon en
-- réserve), Cible (division visée), Force (PV en %), Org (moral).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Military = require(Config:WaitForChild("Military")) :: any
local CombatConfig = require(Config:WaitForChild("CombatConfig")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local RegionTerrain = require(Config:WaitForChild("RegionTerrain")) :: any
local Terrain = require(Config:WaitForChild("Terrain")) :: any
local ProjectState = require(Shared:WaitForChild("ProjectState")) :: any
local CouncilState = require(Shared:WaitForChild("CouncilState")) :: any
local TechState = require(Shared:WaitForChild("TechState")) :: any
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
local AirSupport = require(script.Parent:WaitForChild("AirSupport"))

local ESTIMATE_TICKS = 80 -- ticks simulés pour la prévision du vainqueur (40 s)
local ESTIMATE_EVERY = 4 -- une prévision tous les 4 ticks (2 s)
local FORCE_PER_CASUALTY = 20 -- points de PV perdus = 1 « unité » pour la stabilité (Stability.casualties)
local CONTINUE_CHECK = 1 -- secondes entre deux vérifications de l'attaque continue

type Memory = { line: boolean, target: string? }

type Fight = {
	id: string,
	folder: Folder,
	region: string,
	attacker: string, -- pays qui a lancé l'attaque
	defender: string, -- propriétaire de la région
	attackers: { [Instance]: string }, -- division -> région d'où elle attaque
	out: { [Instance]: boolean }, -- défenseurs tombés restés dans la région (blessés d'un général)
	memory: { [string]: Memory }, -- ligne et cible de chaque soldat (d'un tick à l'autre)
	elapsed: number,
	sides: any, -- état du déploiement et de la rotation des cibles (Combat)
	ticks: number,
	losses: { attackers: number, defenders: number },
	started: number,
}

local BattleManager = {}

local folder: Instance? = nil -- EtatMonde.Batailles (créé par BattleService)
local nextId = 0
local fights: { [string]: Fight } = {} -- par région disputée
local engaged: { [Instance]: Fight } = {} -- divisions engagées (attaque ou défense)
local continueClock = 0

local function now(): number
	return workspace:GetServerTimeNow()
end

local function regionFolder(regionId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local regions = state and state:FindFirstChild("Regions")
	return regions and regions:FindFirstChild(regionId)
end

local function isHostile(countryId: string, owner: string?): boolean
	return owner ~= nil and owner ~= countryId and not DiplomacyService.areAllies(countryId, owner)
end

local function friendly(countryId: string, owner: string?): boolean
	return owner ~= nil and (owner == countryId or DiplomacyService.areAllies(countryId, owner))
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
		d:SetAttribute("Cible", nil)
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
-- (les soldats d'un général tombés pendant la bataille restent à l'arrière de son armée)
local function defendersOf(f: Fight): { Instance }
	local list = {}
	for _, d in Divisions.inRegion(f.region) do
		local owner = d:GetAttribute("Proprietaire") :: string
		if not isHostile(f.defender, owner) and not Divisions.isTraining(d) and not Divisions.isMoving(d) and not f.out[d] then
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

-- Bonus des grands projets (Config/Projects), de la recherche (niveau des unités, Config/
-- Technologies), de la milice d'un pays affaibli (BalanceService) et du général de la division
-- (niveau, bonus choisis, traits : Armies). encircled : les défenseurs sont coupés de leur
-- ravitaillement (trait « Maître de l'encerclement » des attaquants)
local function countryContext(d: Instance, ctx: Combat.Context, encircled: boolean): Combat.Context
	local owner = d:GetAttribute("Proprietaire") :: string
	local typeId = d:GetAttribute("Type") :: string
	ctx.attackBonus = (ctx.attackBonus or 0) + ProjectState.factor(owner, "attack") - 1
	if not ctx.attacking then
		ctx.defenseBonus = (ctx.defenseBonus or 0) + ProjectState.factor(owner, "defense") - 1
	end
	ctx.health = TechState.divisionHealthBonus(owner, typeId)
	ctx.damage = TechState.divisionDamageBonus(owner, typeId)
	if typeId == "Milice" then
		ctx.factor = BalanceService.militiaFactor(owner)
	end
	-- général : bonus de son niveau, bonus choisis et traits
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
		ctx.defenseBonus = (ctx.defenseBonus or 0) + both + Armies.bonus(d, "defense") * 0.5
	else
		ctx.attackBonus = (ctx.attackBonus :: number) + both + Armies.bonus(d, "attack") * 0.5
		ctx.defenseBonus = (ctx.defenseBonus or 0) + both + Armies.bonus(d, "defense")
	end
	-- moral perdu en moins : général « Meneur d'hommes » / bonus Moral, recherche « Doctrine »
	ctx.resilience = Armies.bonus(d, "morale") + TechState.divisionMoraleBonus(owner, typeId)
	ctx.experience = (d:GetAttribute("Experience") :: number?) or 0
	ctx.supplied = d:GetAttribute("Ravitaillee") ~= false
	ctx.fuel = Stocks.get(owner, "Petrole") > 0
	return ctx
end

local function unitOf(f: Fight, d: Instance, ctx: Combat.Context, encircled: boolean?): Combat.Unit
	local u = Combat.makeUnit(d:GetAttribute("Type") :: string, {
		id = d.Name,
		org = (d:GetAttribute("Org") :: number?) or 0,
		orgMax = (d:GetAttribute("OrgMax") :: number?) or 1,
		str = (d:GetAttribute("Force") :: number?) or 0,
	}, countryContext(d, ctx, encircled == true))
	local memory = f.memory[d.Name]
	if memory then
		u.line = memory.line
		u.target = memory.target
	end
	return u
end

-- Expérience d'une division (trait « Vétéran » de son général : plus)
local function divisionExperience(d: Instance, amount: number)
	Divisions.addExperience(d, amount * (1 + Armies.bonus(d, "experience")))
end

-- Région amie voisine où une division vaincue peut reculer (nil : encerclée). Les soldats d'un
-- général n'occupent pas de place : il suffit d'une région amie voisine.
local function retreatTarget(d: Instance, regionId: string): string?
	local owner = d:GetAttribute("Proprietaire") :: string
	local absorbed = Armies.isAbsorbed(d)
	local best: string? = nil
	local bestScore = math.huge
	for _, link in Regions[regionId].neighbors do
		local to = link.region
		local toOwner = RegionService.getOwner(to)
		if link.bySea or not friendly(owner, toOwner) then
			continue
		end
		local occupancy = Divisions.occupancy(to)
		if not absorbed and occupancy >= Divisions.capacityOf(to) then
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
	b:SetAttribute("Largeur", CombatConfig.frontWidth)
	b:SetAttribute("Riviere", river)
	b:SetAttribute("NbAttaque", #attackers)
	b:SetAttribute("NbDefense", #defenders)
	b:SetAttribute("PertesAttaque", f.losses.attackers)
	b:SetAttribute("PertesDefense", f.losses.defenders)
	if battle then
		local function inLine(units: { Combat.Unit }): number
			local n = 0
			for _, u in units do
				if u.line and u.hp > 0 then
					n += 1
				end
			end
			return n
		end
		b:SetAttribute("OrgAttaque", Combat.orgRatio(battle.attackers))
		b:SetAttribute("OrgDefense", Combat.orgRatio(battle.defenders))
		b:SetAttribute("PVAttaque", Combat.healthRatio(battle.attackers))
		b:SetAttribute("PVDefense", Combat.healthRatio(battle.defenders))
		b:SetAttribute("EnLigneAttaque", inLine(battle.attackers))
		b:SetAttribute("EnLigneDefense", inLine(battle.defenders))
	end
end

-- Un soldat tombé (0 PV) : il se replie avec retreatHealth de ses PV, ou meurt sans région amie
-- voisine. Un attaquant est déjà dans une région amie voisine (la sienne) ; un soldat d'un général
-- reste dans son armée.
local function fallen(f: Fight, d: Instance, attacking: boolean)
	if not d.Parent then
		return
	end
	local health = CombatConfig.retreatHealth * 100
	if attacking then
		f.attackers[d] = nil
		release(d)
		d:SetAttribute("Force", health)
		d:SetAttribute("AttaqueContinue", nil)
		return
	end
	local to = retreatTarget(d, f.region)
	if not to then
		release(d)
		Armies.casualty(d) -- l'armée d'un général peut être anéantie
		Divisions.destroy(d) -- encerclé : il meurt
		return
	end
	release(d)
	d:SetAttribute("Force", health)
	if Armies.isAbsorbed(d) then
		f.out[d] = true -- blessé, à l'arrière de l'armée de son général
	else
		Movement.retreat(d, to)
	end
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
	local G = Military.generals
	local generals: { [Instance]: boolean } = {} -- généraux des attaquants (même blessés ou désorganisés)
	for _, d in attackers do
		local general = Armies.get(d:GetAttribute("Armee"))
		if general then
			generals[general] = true
		end
	end
	if result == "Victoire" then
		-- le défenseur recule vers une région amie voisine, ou il est détruit (encerclé) ; les
		-- armées des généraux reculent avec leur général (Armies, au changement de propriétaire)
		for _, d in defenders do
			if Armies.isAbsorbed(d) then
				continue
			end
			local to = retreatTarget(d, f.region)
			if to then
				Movement.retreat(d, to)
			else
				Divisions.destroy(d)
			end
		end
		-- la région change de mains tout de suite : celui qui a lancé l'attaque, s'il y est encore
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
		-- les vainqueurs avancent dans la région prise : les généraux avec toute leur armée, les
		-- autres divisions jusqu'à la limite de stationnement (les plus organisées d'abord)
		for general in generals do
			Armies.addExperience(general, G.xpVictory + G.xpRegion)
			Armies.advance(general, f.region)
		end
		table.sort(attackers, function(a: Instance, b: Instance): boolean
			return ((a:GetAttribute("Org") :: number?) or 0) > ((b:GetAttribute("Org") :: number?) or 0)
		end)
		for _, d in attackers do
			divisionExperience(d, E.victory)
			if Armies.isAbsorbed(d) then
				continue
			end
			if Divisions.occupancy(f.region) < Divisions.capacityOf(f.region) then
				Movement.advance(d, f.region)
			else
				d:SetAttribute("AttaqueContinue", nil) -- plus de place : l'offensive s'arrête là pour elle
			end
		end
	else
		-- l'attaque a échoué : les attaquants restent chez eux, la suite de leur route est annulée
		for _, d in attackers do
			d:SetAttribute("Itineraire", nil)
			d:SetAttribute("AttaqueContinue", nil)
		end
		for general in generals do
			Armies.stopOffensive(general)
		end
		for _, d in defenders do
			divisionExperience(d, E.victory)
		end
		-- généraux des défenseurs : expérience
		local credited: { [Instance]: boolean } = {}
		for _, d in defenders do
			local general = Armies.commanderOf(d)
			if general and not credited[general] then
				credited[general] = true
				Armies.addExperience(general, G.xpVictory)
			end
		end
	end
	-- les blessés des armées des généraux reprennent leur place
	table.clear(f.out)
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
	if CouncilState.ceasefireLeft() > 0 or DiplomacyService.truceLeft(f.attacker, f.defender) > 0 then
		finish(f, "Repli") -- cessez-le-feu ou trêve : les combats s'arrêtent
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
	local battle: Combat.Battle = { attackers = {}, defenders = {}, width = CombatConfig.frontWidth, elapsed = f.elapsed, sides = f.sides }
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
		table.insert(battle.attackers, unitOf(f, d, {
			attacking = true,
			terrain = terrain,
			river = riverBetween(from, f.region),
			attackBonus = air.attackerBonus,
			defenseBonus = air.attackerBonus,
		}, encircled))
		units[d.Name] = d
	end
	for _, d in defenders do
		table.insert(battle.defenders, unitOf(f, d, {
			attacking = false,
			terrain = terrain,
			entrenchment = (d:GetAttribute("Retranchement") :: number?) or 0,
			fortification = fortification,
			attackBonus = air.defenderBonus,
			defenseBonus = air.defenderBonus,
		}))
		units[d.Name] = d
	end

	local after, report = Combat.resolveTick(battle)
	f.elapsed = after.elapsed or (f.elapsed + CombatConfig.tickSeconds)
	f.sides = after.sides
	-- appui au sol : du moral en moins pour la ligne ennemie (Config/Military.air.supportDamage par seconde)
	if report.result == "EnCours" then
		AirSupport.applyDamage(after.defenders, air.damageToDefenders * CombatConfig.tickSeconds)
		AirSupport.applyDamage(after.attackers, air.damageToAttackers * CombatConfig.tickSeconds)
	end
	f.folder:SetAttribute("Superiorite", air.superiority)
	f.folder:SetAttribute("AppuiAttaque", attackerSupport > 0)
	f.folder:SetAttribute("AppuiDefense", defenderSupport > 0)
	f.ticks += 1
	-- nouvel état des divisions (PV, moral, ligne, cible) ; pertes de PV -> stabilité du pays
	local casualties: { [string]: number } = {}
	local commanders: { [Instance]: boolean } = {}
	local function sync(list: { Combat.Unit })
		for _, u in list do
			local d = units[u.id]
			if not d or not d.Parent then
				continue
			end
			f.memory[u.id] = { line = u.line, target = u.target }
			d:SetAttribute("Org", u.org)
			if report.strLost[u.id] then
				d:SetAttribute("Force", u.str)
			end
			if d:GetAttribute("EnLigne") ~= u.line then
				d:SetAttribute("EnLigne", u.line)
			end
			if d:GetAttribute("Cible") ~= u.target then
				d:SetAttribute("Cible", u.target)
			end
			if u.line then
				divisionExperience(d, Military.experience.perCombatTick * CombatConfig.tickSeconds / Military.tickSeconds)
				local general = Armies.commanderOf(d)
				if general then
					commanders[general] = true
				end
			end
			local lost = report.strLost[u.id]
			if lost then
				local country = d:GetAttribute("Proprietaire") :: string
				casualties[country] = (casualties[country] or 0) + lost
			end
		end
	end
	sync(after.attackers)
	sync(after.defenders)
	for country, lost in casualties do
		Stability.casualties(country, lost / FORCE_PER_CASUALTY)
	end
	-- les généraux apprennent en commandant
	for general in commanders do
		Armies.addExperience(general, Military.generals.xpPerTick * CombatConfig.tickSeconds / Military.tickSeconds)
	end
	-- soldats tombés : repli avec 25 % de PV, ou mort
	for id in report.down do
		local d = units[id]
		if d then
			local attacking = f.attackers[d] ~= nil
			if attacking then
				f.losses.attackers += 1
			else
				f.losses.defenders += 1
			end
			f.memory[id] = nil
			fallen(f, d, attacking)
		end
	end
	publish(f, attackersOf(f), defendersOf(f), after)
	-- prévision du vainqueur (une petite simulation, de temps en temps)
	if f.ticks % ESTIMATE_EVERY == 1 then
		after.attackers = Combat.withoutDown(after.attackers)
		after.defenders = Combat.withoutDown(after.defenders)
		local predicted = Combat.estimate(after, ESTIMATE_TICKS)
		f.folder:SetAttribute("Prevision", if predicted == "Victoire" then "Attaquant" elseif predicted == "Repli" then "Defenseur" else "Indecis")
	end
	if report.result ~= "EnCours" then
		finish(f, report.result)
	end
end

-- Engage une division contre une région ennemie défendue (appelé par Movement, attackRegion et
-- Armies). from : la région d'où elle attaque (la sienne, voisine de la cible)
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
		return false, "Moral à zéro : la division doit d'abord se reposer."
	end
	if ((d:GetAttribute("Force") :: number?) or 0) < 5 then
		return false, "Division trop affaiblie : elle doit d'abord se renforcer."
	end
	local countryId = d:GetAttribute("Proprietaire") :: string
	local defender = RegionService.getOwner(target)
	if not defender or not isHostile(countryId, defender) or not DiplomacyService.atWar(countryId, defender) then
		return false, "Pas en guerre avec ce pays."
	end
	local f = fights[target]
	if f and isHostile(countryId, f.attacker) then
		return false, "Une autre bataille est déjà en cours dans cette région."
	end
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
		battleFolder:SetAttribute("Debut", now())
		battleFolder:SetAttribute("Terrain", terrainOf(target))
		battleFolder:SetAttribute("Prevision", "Indecis")
		local created: Fight = {
			id = battleFolder.Name,
			folder = battleFolder,
			region = target,
			attacker = countryId,
			defender = defender,
			attackers = {},
			out = {},
			memory = {},
			elapsed = 0,
			sides = nil,
			ticks = 0,
			losses = { attackers = 0, defenders = 0 },
			started = now(),
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
	for _, d2 in defendersOf(fight) do
		if not engaged[d2] then
			engage(fight, d2)
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

-- Divisions prêtes à attaquer `target` depuis les régions voisines (par la terre) qui sont à
-- `countryId` : à l'arrêt, prêtes, hors de l'armée d'un général, sans bataille de défense, avec
-- du moral et des PV. only : seulement ces divisions (attaque continue)
function BattleManager.readyAttackers(countryId: string, target: string, only: { [Instance]: boolean }?): { { d: Instance, from: string } }
	local list = {}
	local region = Regions[target]
	if not region then
		return list
	end
	for _, link in region.neighbors do
		local from = link.region
		if link.bySea or RegionService.getOwner(from) ~= countryId then
			continue
		end
		for _, d in Divisions.inRegion(from) do
			if only and not only[d] then
				continue
			end
			-- une division qui défend sa région, ou qui attaque déjà ailleurs, reste à sa bataille
			local current = engaged[d]
			if d:GetAttribute("Proprietaire") ~= countryId or Divisions.isTraining(d) or Divisions.isMoving(d)
				or Armies.isAbsorbed(d) or (current and (current.attackers[d] == nil or current.region ~= target)) then
				continue
			end
			if ((d:GetAttribute("Org") :: number?) or 0) <= 0 or ((d:GetAttribute("Force") :: number?) or 0) < 5 then
				continue
			end
			table.insert(list, { d = d, from = from })
		end
	end
	return list
end

-- Attaque d'une région ennemie depuis toutes ses régions voisines (bouton « Attaquer » de la fiche
-- de région, IA). continuous : les divisions enchaînent ensuite les régions voisines.
-- Renvoie le nombre de divisions engagées.
function BattleManager.attackRegion(countryId: string, target: unknown, continuous: boolean?, only: { [Instance]: boolean }?): (boolean, string?, number)
	if typeof(target) ~= "string" or not Regions[target] then
		return false, "Région inconnue.", 0
	end
	local owner = RegionService.getOwner(target)
	if not owner or not isHostile(countryId, owner) then
		return false, "Cette région n'est pas ennemie.", 0
	end
	if not DiplomacyService.atWar(countryId, owner) then
		return false, "Pas en guerre avec ce pays : déclare-lui d'abord la guerre.", 0
	end
	local ceasefire = CouncilState.ceasefireLeft()
	if ceasefire > 0 then
		return false, `Cessez-le-feu du Conseil mondial : encore {math.ceil(ceasefire)} s.`, 0
	end
	local ready = BattleManager.readyAttackers(countryId, target, only)
	if #ready == 0 then
		return false, "Aucune division prête dans tes régions voisines de celle-ci.", 0
	end
	local sent = 0
	local lastError: string? = nil
	for _, entry in ready do
		local ok, why = BattleManager.attack(entry.d, entry.from, target)
		if ok then
			sent += 1
			entry.d:SetAttribute("Itineraire", nil)
			entry.d:SetAttribute("Controle", "Manuel")
			entry.d:SetAttribute("AttaqueContinue", if continuous then true else nil)
		else
			lastError = why
		end
	end
	if sent == 0 then
		return false, lastError or "Aucune division n'a pu attaquer.", 0
	end
	return true, nil, sent
end

-- Prochaine cible d'une offensive continue depuis `from` : la région ennemie voisine (en guerre,
-- par la terre) la moins défendue
function BattleManager.nextTarget(countryId: string, from: string): string?
	local best: string? = nil
	local bestScore = math.huge
	for _, link in Regions[from].neighbors do
		local owner = RegionService.getOwner(link.region)
		if link.bySea or not owner or not isHostile(countryId, owner) or not DiplomacyService.atWar(countryId, owner) then
			continue
		end
		local other = fights[link.region]
		if other and isHostile(countryId, other.attacker) then
			continue
		end
		local score = #Movement.defenders(link.region, countryId)
		if score < bestScore or (score == bestScore and best and link.region < best) then
			best, bestScore = link.region, score
		end
	end
	return best
end

-- Attaque continue des divisions (pas des généraux : voir Armies) : celles qui ont avancé dans une
-- région prise attaquent la région ennemie voisine suivante, tant qu'elles ont des effectifs et
-- du moral ; sinon l'offensive s'arrête
local function continueOffensives()
	if CouncilState.ceasefireLeft() > 0 then
		return
	end
	local C = CombatConfig.continuous
	local groups: { [string]: { country: string, region: string, list: { Instance } } } = {}
	for _, d in Divisions.all() do
		if d:GetAttribute("AttaqueContinue") ~= true or Armies.isAbsorbed(d) or engaged[d] or Divisions.isMoving(d) or Divisions.isTraining(d) then
			continue
		end
		local arrived = (d:GetAttribute("Arrivee") :: number?) or 0
		if now() - arrived < C.delay then
			continue
		end
		local country = d:GetAttribute("Proprietaire") :: string
		local regionId = d:GetAttribute("Region") :: string
		local key = country .. "|" .. regionId
		local group = groups[key]
		if not group then
			group = { country = country, region = regionId, list = {} }
			groups[key] = group
		end
		table.insert(group.list, d)
	end
	for _, group in groups do
		local org, orgMax = 0, 0
		for _, d in group.list do
			org += (d:GetAttribute("Org") :: number?) or 0
			orgMax += (d:GetAttribute("OrgMax") :: number?) or 1
		end
		local target = BattleManager.nextTarget(group.country, group.region)
		local ok = false
		if target and #group.list >= C.minDivisions and orgMax > 0 and org / orgMax >= C.minOrganisation then
			local only: { [Instance]: boolean } = {}
			for _, d in group.list do
				only[d] = true
			end
			ok = (BattleManager.attackRegion(group.country, target, true, only))
		end
		if not ok then
			-- plus de cible, d'effectifs ou de moral : l'offensive s'arrête
			for _, d in group.list do
				d:SetAttribute("AttaqueContinue", nil)
			end
		end
	end
end

-- Toutes les batailles avancent d'un tick
local function update(dt: number)
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
	continueClock += dt
	if continueClock >= CONTINUE_CHECK then
		continueClock = 0
		local ok, err = pcall(continueOffensives)
		if not ok then
			warn(`[Batailles] attaque continue : {err}`)
		end
	end
end

-- Nouvelle partie : plus aucune bataille (le dossier EtatMonde.Batailles est vidé par BattleService)
function BattleManager.reset()
	table.clear(fights)
	table.clear(engaged)
end

-- À appeler après BattleService.init(), Divisions.init(), Movement.init() et Armies.init()
function BattleManager.init(loop: any, commands: any)
	folder = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Batailles")
	loop.every("batailles", CombatConfig.tickSeconds, update)
	Movement.setBattleHooks({
		attack = BattleManager.attack,
		withdraw = BattleManager.withdraw,
		isAttacking = BattleManager.isAttacking,
	})
	Armies.setBattleHooks({
		attack = BattleManager.attack,
		withdraw = BattleManager.withdraw,
		nextTarget = BattleManager.nextTarget,
		isFighting = BattleManager.isFighting,
	})
	-- une division détruite quitte sa bataille
	Divisions.onRemoved(function(d: Instance)
		local f = engaged[d]
		if f then
			f.attackers[d] = nil
			f.out[d] = nil
			f.memory[d.Name] = nil
			engaged[d] = nil
		end
	end)
	-- AttaquerRegion { region, continu } : toutes ses divisions des régions voisines attaquent
	commands.register("AttaquerRegion", function(countryId: string, data: { [any]: any }): (boolean, string?)
		local ok, message, sent = BattleManager.attackRegion(countryId, data.region, data.continu == true)
		if ok then
			return true, `{sent} division{if sent > 1 then "s" else ""} à l'attaque{if data.continu == true then " (attaque continue)" else ""}.`
		end
		return false, message
	end, "DeplacerArmee")
end

return BattleManager
