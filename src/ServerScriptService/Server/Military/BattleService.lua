--!strict
-- Raids aériens et navals : une escadrille ou une flotte qui arrive dans une région ennemie en
-- guerre frappe les divisions qui s'y trouvent (organisation et un peu de force), sans prendre la
-- région (seules les divisions conquièrent, voir BattleManager). Résolution par manches (Config/Combat) :
--   - la puissance du raid dépend du moral, de l'expérience et du ravitaillement (MilitaryMath) ;
--     les divisions ripostent moins bien contre l'air et la mer (Combat.militiaEfficiency) ;
--   - le raid dure Combat.raid.rounds manches au plus ; moral trop bas (sauf « Tenir la position »)
--     ou ordre « Se replier » : repli ; force anéantie : défaite (son chef est capturé).
-- État publié dans ReplicatedStorage.EtatMonde.Batailles.<id> (Region, Armee, Attaquant, Defenseur,
-- Manche, Genre, Raid = true, Cibles, Etat = "EnCours" | "Victoire" | "Defaite" | "Repli"), gardé
-- quelques secondes après la fin. Les batailles terrestres (BattleManager) partagent ce dossier et
-- passent leur résultat par reportResult : onResult les reçoit toutes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Combat = require(Config:WaitForChild("Combat")) :: any
local Units = require(Config:WaitForChild("Units")) :: any
local MilitaryMath = require(Shared:WaitForChild("MilitaryMath")) :: any
local ProjectState = require(Shared:WaitForChild("ProjectState")) :: any
local GeneralTraits = require(Shared:WaitForChild("GeneralTraits")) :: any
local Generals = require(Config:WaitForChild("Generals")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local DiplomacyService = require(Server:WaitForChild("Politics"):WaitForChild("DiplomacyService"))
local Stability = require(Server:WaitForChild("Politics"):WaitForChild("Stability"))
local Divisions = require(script.Parent:WaitForChild("Divisions"))
local AirSupport = require(script.Parent:WaitForChild("AirSupport"))

type ResultListener = (result: string, attacker: string, defender: string, regionId: string, army: Instance?) -> ()

local BattleService = {}

local folder: Folder? = nil -- EtatMonde.Batailles
local nextId = 0
local rng = Random.new()
local retreatHandler: ((army: Instance) -> ())? = nil
local resultListeners: { ResultListener } = {}
local retreatOrders: { [Instance]: boolean } = {} -- ordres « Se replier » donnés en plein raid
local raids: { [string]: boolean } = {} -- régions qui subissent un raid

local function count(army: Instance, typeId: string): number
	return (army:GetAttribute(typeId) :: number?) or 0
end

local function armySize(army: Instance): number
	local total = 0
	for _, typeId in Units.kinds[Units.kindOf(army)].order do
		total += count(army, typeId)
	end
	return total
end

-- Puissance d'attaque brute (troupes x attaque), avant moral, expérience et ravitaillement
local function rawPower(army: Instance): number
	local power = 0
	for _, typeId in Units.kinds[Units.kindOf(army)].order do
		power += count(army, typeId) * MilitaryMath.unitAttack(army, typeId)
	end
	return power
end

-- Retire des unités tant que les dégâts couvrent leurs points de vie (les moins chères d'abord).
-- Renvoie les dégâts restants, pas encore suffisants pour abattre une unité de plus.
local function applyDamage(army: Instance, damage: number): number
	for _, typeId in Units.kinds[Units.kindOf(army)].lossOrder do
		local health = Combat.units[typeId].health
		local n = count(army, typeId)
		while n > 0 and damage >= health do
			n -= 1
			damage -= health
		end
		army:SetAttribute(typeId, n)
		if n > 0 then
			return damage
		end
	end
	return damage
end

-- Expérience (trait « Vétéran » : plus) ; au niveau Generals.secondTraitLevel, le chef gagne un second trait
local function addExperience(army: Instance, amount: number)
	local xp = math.min(100, MilitaryMath.experience(army) + amount * MilitaryMath.experienceFactor(army))
	army:SetAttribute("Experience", xp)
	local level = MilitaryMath.levelFor(xp)
	army:SetAttribute("Niveau", level)
	local traits = GeneralTraits.of(army)
	if level >= Generals.secondTraitLevel and #traits < 2 then
		local extra = GeneralTraits.pick(Units.kindOf(army), traits, rng)
		if extra then
			table.insert(traits, extra)
			army:SetAttribute("Traits", table.concat(traits, ","))
		end
	end
end

local function changeMorale(army: Instance, delta: number)
	army:SetAttribute("Moral", math.clamp(MilitaryMath.morale(army) + delta, 0, 100))
end

-- Divisions du défenseur et de ses alliés à l'arrêt dans la région (les cibles du raid)
local function targetsOf(regionId: string, defender: string): { Instance }
	local list = {}
	for _, d in Divisions.inRegion(regionId) do
		local owner = d:GetAttribute("Proprietaire") :: string
		if (owner == defender or DiplomacyService.areAllies(owner, defender)) and not Divisions.isMoving(d) then
			table.insert(list, d)
		end
	end
	return list
end

-- Riposte des divisions visées (attaque douce + dure, selon leur organisation)
local function returnFire(targets: { Instance }, kind: string): number
	local power = 0
	for _, d in targets do
		local t = Divisions.typeOf(d)
		local org = (d:GetAttribute("Org") :: number?) or 0
		local orgMax = math.max((d:GetAttribute("OrgMax") :: number?) or 1, 1)
		power += (t.soft + t.hard) * (0.3 + 0.7 * org / orgMax)
	end
	return power * Combat.raid.defense * Combat.militiaEfficiency[kind]
end

-- Région qui subit un raid en ce moment ?
function BattleService.isFighting(regionId: string): boolean
	return raids[regionId] == true
end

-- Fonction appelée pour faire reculer une force (fournie par ArmyService)
function BattleService.setRetreatHandler(handler: (army: Instance) -> ())
	retreatHandler = handler
end

-- listener(résultat, attaquant, défenseur, région, force) à la fin de chaque bataille ou raid
-- (résultat : « Victoire », « Repli » ou « Defaite », du point de vue de l'attaquant ; force :
-- l'escadrille ou la flotte d'un raid, nil pour une bataille terrestre)
function BattleService.onResult(listener: ResultListener)
	table.insert(resultListeners, listener)
end

-- Résultat d'une bataille (raids ici, batailles terrestres par BattleManager)
function BattleService.reportResult(result: string, attacker: string, defender: string, regionId: string, army: Instance?)
	for _, listener in resultListeners do
		task.spawn(listener, result, attacker, defender, regionId, army)
	end
end

-- Ordre « Se replier » pendant un raid : pris en compte à la manche suivante
function BattleService.orderRetreat(army: Instance)
	retreatOrders[army] = true
end

-- Lance le raid de `army` (escadrille ou flotte qui vient d'arriver) sur `regionId`
function BattleService.start(army: Instance, regionId: string)
	local defender = RegionService.getOwner(regionId)
	local attacker = army:GetAttribute("Proprietaire") :: string
	if not defender or defender == attacker or not folder or raids[regionId] then
		return
	end
	local kind = Units.kindOf(army)
	nextId += 1
	local battle = Instance.new("Folder")
	battle.Name = "R" .. nextId
	battle:SetAttribute("Region", regionId)
	battle:SetAttribute("Armee", army.Name)
	battle:SetAttribute("Attaquant", attacker)
	battle:SetAttribute("Defenseur", defender)
	battle:SetAttribute("Manche", 0)
	battle:SetAttribute("Etat", "EnCours")
	battle:SetAttribute("Genre", kind)
	battle:SetAttribute("Raid", true)
	battle:SetAttribute("Cibles", #targetsOf(regionId, defender))
	battle.Parent = folder
	army:SetAttribute("EnCombat", battle.Name)
	retreatOrders[army] = nil
	raids[regionId] = true

	task.spawn(function()
		local attackerPool = 0 -- dégâts reçus pas encore suffisants pour abattre une unité
		local result = "Victoire"
		for round = 1, Combat.raid.rounds do
			task.wait(Combat.roundInterval)
			if not battle.Parent then
				raids[regionId] = nil
				return -- nouvelle partie : le raid a été effacé, sans résultat
			end
			if not army.Parent then
				result = "Defaite"
				break
			end
			-- repli ordonné, ou moral trop bas (sauf « Tenir la position »)
			if retreatOrders[army] or (MilitaryMath.morale(army) < Combat.morale.retreatBelow and army:GetAttribute("Posture") ~= "Tenir") then
				result = "Repli"
				break
			end
			local targets = targetsOf(regionId, defender)
			battle:SetAttribute("Cibles", #targets)
			if #targets == 0 then
				break -- plus rien à frapper : raid terminé
			end
			local function roll(power: number): number
				return power * Combat.damageFactor * rng:NextNumber(1 - Combat.randomness, 1 + Combat.randomness)
			end
			-- frappe : réparties entre les divisions visées (projet « supercalculateur » : + attaque)
			local strike = roll(rawPower(army) * MilitaryMath.efficiency(army, false) * ProjectState.factor(attacker, "attack")) / #targets
			for _, d in targets do
				local org = (d:GetAttribute("Org") :: number?) or 0
				local force = (d:GetAttribute("Force") :: number?) or 0
				local forceLost = math.min(force, strike * Combat.raid.forcePerPower)
				d:SetAttribute("Org", math.max(0, org - strike * Combat.raid.orgPerPower))
				d:SetAttribute("Force", force - forceLost)
				Stability.casualties(d:GetAttribute("Proprietaire") :: string, forceLost / 20)
				if force - forceLost <= 0 then
					Divisions.destroy(d)
				end
			end
			-- riposte, et moral de la force qui baisse
			attackerPool += roll(returnFire(targets, kind))
			local before = armySize(army)
			attackerPool = applyDamage(army, attackerPool)
			local lost = before - armySize(army)
			Stability.casualties(attacker, lost)
			changeMorale(army, -(Combat.morale.roundStress + (if before > 0 then lost / before * Combat.morale.lossWeight else 0)) * MilitaryMath.moraleLossFactor(army))
			battle:SetAttribute("Manche", round)
			if armySize(army) == 0 then
				result = "Defaite"
				break
			end
		end

		raids[regionId] = nil
		retreatOrders[army] = nil
		battle:SetAttribute("Etat", result)
		BattleService.reportResult(result, attacker, defender, regionId, army)
		if result == "Victoire" then
			-- bombardiers : usines arrêtées et ravitaillement réduit un moment (AirSupport)
			if kind == "Air" and count(army, "Bombardier") > 0 then
				AirSupport.bomb(regionId)
			end
			addExperience(army, Combat.experience.victory)
			changeMorale(army, Combat.morale.victory)
			army:SetAttribute("EnCombat", nil)
		elseif result == "Repli" then
			addExperience(army, Combat.experience.survived)
			army:SetAttribute("EnCombat", nil)
			if retreatHandler and army.Parent then
				retreatHandler(army)
			end
		elseif army.Parent then
			army:Destroy() -- force anéantie : son chef est capturé
		end
		task.delay(Combat.resultDelay, function()
			battle:Destroy()
		end)
	end)
end

-- Nouvelle partie : toutes les batailles et tous les raids sont effacés (les raids s'arrêtent sans résultat)
function BattleService.reset()
	if folder then
		folder:ClearAllChildren()
	end
	table.clear(retreatOrders)
	table.clear(raids)
end

-- À appeler au démarrage du serveur (après la création de EtatMonde)
function BattleService.init()
	local batailles = Instance.new("Folder")
	batailles.Name = "Batailles"
	batailles.Parent = ReplicatedStorage:WaitForChild("EtatMonde")
	folder = batailles
end

return BattleService
