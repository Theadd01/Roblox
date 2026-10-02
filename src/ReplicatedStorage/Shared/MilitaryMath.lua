--!strict
-- Calculs militaires partagés (le serveur décide, le client affiche les mêmes valeurs) :
-- moral, expérience, niveau du chef, efficacité au combat, entretien des forces,
-- et les effets des traits des chefs (voir GeneralTraits).

local Config = script.Parent.Config
local Combat = require(Config.Combat)
local Units = require(Config.Units)
local GeneralTraits = require(script.Parent.GeneralTraits)
local TechState = require(script.Parent.TechState)

local MilitaryMath = {}

local function numberAttribute(army: Instance, name: string, default: number): number
	local value = army:GetAttribute(name)
	return if typeof(value) == "number" then value else default
end

function MilitaryMath.morale(army: Instance): number
	return numberAttribute(army, "Moral", Combat.morale.start)
end

function MilitaryMath.experience(army: Instance): number
	return numberAttribute(army, "Experience", 0)
end

function MilitaryMath.isSupplied(army: Instance): boolean
	return army:GetAttribute("Ravitaillee") ~= false
end

-- Niveau du chef d'après l'expérience (1 à 5) : il commande plus de troupes en montant
function MilitaryMath.levelFor(experience: number): number
	return math.clamp(1 + math.floor(experience / Combat.experience.perLevel), 1, 5)
end

-- « Recrues », « Aguerris », « Vétérans », « Élite »
function MilitaryMath.rank(experience: number): string
	for _, r in Combat.experience.ranks do
		if experience >= r.min then
			return r.name
		end
	end
	return "Recrues"
end

-- Multiplicateur de puissance au combat. defending : l'armée défend sa propre région
function MilitaryMath.efficiency(army: Instance, defending: boolean?): number
	local factor = 0.5 + MilitaryMath.morale(army) / 200
	factor *= 1 + MilitaryMath.experience(army) / 100 * Combat.experience.maxBonus
	if not MilitaryMath.isSupplied(army) then
		factor *= Combat.unsuppliedFactor
	end
	if defending and army:GetAttribute("Posture") == "Defendre" then
		factor *= Combat.defendBonus
	end
	-- traits du chef : « Défenseur tenace » en défense, « Foudre de guerre » en attaque
	factor *= 1 + GeneralTraits.bonus(army, if defending then "defense" else "attack")
	return factor
end

-- Attaque d'une unité de ce type dans cette force (traits « Expert blindés », « Maître artilleur »)
function MilitaryMath.unitAttack(army: Instance, typeId: string): number
	-- traits du général, puis technologies du pays (blindés modernes, drones, missiles)
	local owner = army:GetAttribute("Proprietaire")
	local tech = if typeof(owner) == "string" then TechState.unitAttackFactor(owner, typeId) else 1
	return Combat.units[typeId].attack * (1 + GeneralTraits.bonus(army, typeId)) * tech
end

-- Multiplicateur de la durée des trajets (trait « Stratège »)
function MilitaryMath.travelFactor(army: Instance): number
	return 1 - GeneralTraits.bonus(army, "speed")
end

-- Multiplicateur du moral perdu au combat (trait « Meneur d'hommes »)
function MilitaryMath.moraleLossFactor(army: Instance): number
	return 1 - GeneralTraits.bonus(army, "morale")
end

-- Multiplicateur de l'expérience gagnée (trait « Vétéran »)
function MilitaryMath.experienceFactor(army: Instance): number
	return 1 + GeneralTraits.bonus(army, "experience")
end

-- Entretien d'une force par cycle : ressource -> quantité (trait « Logisticien » : moins)
function MilitaryMath.upkeep(army: Instance): { [string]: number }
	local total: { [string]: number } = {}
	for _, typeId in Units.kinds[Units.kindOf(army)].order do
		local n = numberAttribute(army, typeId, 0)
		if n > 0 then
			for resourceId, amount in Units.types[typeId].upkeep do
				total[resourceId] = (total[resourceId] or 0) + amount * n
			end
		end
	end
	-- trait « Logisticien » et technologie « Logistique moderne »
	local owner = army:GetAttribute("Proprietaire")
	local factor = (1 - GeneralTraits.bonus(army, "upkeep")) * (if typeof(owner) == "string" then TechState.upkeepFactor(owner) else 1)
	if factor < 1 then
		for resourceId, amount in total do
			total[resourceId] = math.floor(amount * factor + 0.5)
			if total[resourceId] <= 0 then
				total[resourceId] = nil
			end
		end
	end
	return total
end

return MilitaryMath
