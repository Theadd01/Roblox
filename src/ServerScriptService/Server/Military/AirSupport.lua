--!strict
-- Soutien aérien simplifié (SYSTEME_MILITAIRE.md, 5.7) : pas de combat aérien détaillé, un calcul
-- par zone. Les escadrilles à l'arrêt (hors raid) couvrent les batailles à moins de
-- Config/Military.air.range studs de leur base :
--   supériorité aérienne : le camp qui aligne le plus de chasseurs (part >= superiorityAt) gagne
--     jusqu'à +superiorityBonus d'attaque et de défense ;
--   appui au sol : bombardiers, drones et hélicoptères retirent de l'organisation à la ligne
--     ennemie à chaque tick, moins efficacement si l'ennemi domine le ciel ;
--   bombardement : un raid de bombardiers réussi arrête un moment les usines de la région et
--     réduit sa capacité de ravitaillement (attribut Bombardee de EtatMonde.Regions.<id>).
-- effects et applyDamage sont pures (testables sans partie).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Military = require(Config:WaitForChild("Military")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Units = require(Config:WaitForChild("Units")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any
local MilitaryMath = require(Shared:WaitForChild("MilitaryMath")) :: any
local Server = script.Parent.Parent
local DiplomacyService = require(Server:WaitForChild("Politics"):WaitForChild("DiplomacyService"))

local SUPPORT_TYPES = { "Bombardier", "Drone", "Helicoptere" }

export type Effects = {
	attackerBonus: number, -- bonus d'attaque et de défense de l'attaquant (supériorité aérienne)
	defenderBonus: number,
	damageToDefenders: number, -- organisation retirée par tick à la ligne du défenseur (appui au sol)
	damageToAttackers: number,
	superiority: string, -- "Attaquant", "Defenseur" ou "" (ciel disputé ou vide)
}

local AirSupport = {}

local function anchorOf(regionId: string): Vector3?
	local region = Regions[regionId]
	local city = region and region.city
	return if city then MapProjection.toVector3(city.lon, city.lat, MapSettings.regionTop) else nil
end

-- Chasseurs et appui au sol d'un camp (le pays et ses alliés) au-dessus d'une région
function AirSupport.cover(regionId: string, countryId: string): (number, number)
	local here = anchorOf(regionId)
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local armees = state and state:FindFirstChild("Armees")
	if not here or not armees then
		return 0, 0
	end
	local fighters, support = 0, 0
	for _, army in armees:GetChildren() do
		local owner = army:GetAttribute("Proprietaire")
		if army:GetAttribute("Genre") ~= "Air" or typeof(owner) ~= "string" then
			continue
		end
		if owner ~= countryId and not DiplomacyService.areAllies(countryId, owner) then
			continue
		end
		if army:GetAttribute("Destination") ~= "" or army:GetAttribute("EnCombat") or army:GetAttribute("Ravitaillee") == false then
			continue
		end
		local base = anchorOf(army:GetAttribute("Region") :: string)
		if not base or (base - here).Magnitude > Military.air.range then
			continue
		end
		fighters += ((army:GetAttribute("Chasseur") :: number?) or 0) * MilitaryMath.unitAttack(army, "Chasseur")
		for _, typeId in SUPPORT_TYPES do
			support += ((army:GetAttribute(typeId) :: number?) or 0) * MilitaryMath.unitAttack(army, typeId)
		end
	end
	return fighters, support
end

-- Effets sur une bataille, d'après les chasseurs et l'appui de chaque camp (pur)
function AirSupport.effects(attackerFighters: number, attackerSupport: number, defenderFighters: number, defenderSupport: number): Effects
	local A = Military.air
	local total = attackerFighters + defenderFighters
	local share = if total > 0 then attackerFighters / total else 0.5
	local superiority = ""
	if total > 0 and share >= A.superiorityAt then
		superiority = "Attaquant"
	elseif total > 0 and share <= 1 - A.superiorityAt then
		superiority = "Defenseur"
	end
	-- l'appui au sol passe moins bien sous des chasseurs ennemis
	local attackerReach = if total > 0 then 0.4 + 0.6 * share else 1
	local defenderReach = if total > 0 then 0.4 + 0.6 * (1 - share) else 1
	return {
		attackerBonus = A.superiorityBonus * math.clamp((share - 0.5) * 2, 0, 1),
		defenderBonus = A.superiorityBonus * math.clamp((0.5 - share) * 2, 0, 1),
		damageToDefenders = attackerSupport * A.supportDamage * attackerReach,
		damageToAttackers = defenderSupport * A.supportDamage * defenderReach,
		superiority = superiority,
	}
end

-- Retire `damage` organisation à la ligne d'un camp, partagée selon la largeur (pur : modifie les
-- copies d'unités que Combat.resolveTick vient de rendre)
function AirSupport.applyDamage(units: { any }, damage: number)
	if damage <= 0 then
		return
	end
	local width = 0
	for _, u in units do
		if u.line and u.org > 0 then
			width += u.width
		end
	end
	if width <= 0 then
		return
	end
	for _, u in units do
		if u.line and u.org > 0 then
			u.org = math.max(0, u.org - damage * u.width / width * u.orgLoss)
		end
	end
end

-- Raid de bombardiers réussi : usines de la région arrêtées, ravitaillement réduit un moment
function AirSupport.bomb(regionId: string)
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	if not state then
		return
	end
	local untilTime = workspace:GetServerTimeNow() + Military.air.bombingSeconds
	local regions = state:FindFirstChild("Regions")
	local region = regions and regions:FindFirstChild(regionId)
	if region then
		region:SetAttribute("Bombardee", untilTime)
	end
	local usines = state:FindFirstChild("Usines")
	for _, factory in (if usines then usines:GetChildren() else {}) do
		if factory:GetAttribute("Region") == regionId then
			factory:SetAttribute("ArretJusqua", untilTime)
			factory:SetAttribute("ArretRaison", "bombardement")
		end
	end
end

-- La région est-elle sous les bombes en ce moment ?
function AirSupport.isBombed(regionId: string): boolean
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local regions = state and state:FindFirstChild("Regions")
	local region = regions and regions:FindFirstChild(regionId)
	local untilTime = region and region:GetAttribute("Bombardee")
	return typeof(untilTime) == "number" and untilTime > workspace:GetServerTimeNow()
end

-- Units n'est utilisé que pour vérifier les types d'appui (Config/Units)
for _, typeId in SUPPORT_TYPES do
	assert(Units.types[typeId], `[AirSupport] type d'unité inconnu : {typeId}`)
end

return AirSupport
