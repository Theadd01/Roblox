--!strict
-- Traits des chefs (Config/Generals), partagés par le serveur (qui décide) et le client (qui
-- affiche) : traits d'une force (attribut « Traits » : « Logisticien,Stratege »), bonus selon
-- le niveau du chef, tirage d'un nouveau trait, description.

local Config = script.Parent.Config
local Generals = require(Config.Generals)

local GeneralTraits = {}

-- Traits d'une force (identifiants)
function GeneralTraits.of(army: Instance): { string }
	local text = army:GetAttribute("Traits")
	local list = {}
	if typeof(text) == "string" then
		for id in text:gmatch("[^,]+") do
			if Generals.traits[id] then
				table.insert(list, id)
			end
		end
	end
	return list
end

local function level(army: Instance): number
	local value = army:GetAttribute("Niveau")
	return if typeof(value) == "number" then value else 1
end

-- Bonus d'un trait pour un chef de ce niveau (0,15 = 15 %)
function GeneralTraits.strength(traitId: string, chiefLevel: number): number
	local trait = Generals.traits[traitId]
	return math.min(Generals.maxBonus, trait.base + trait.perLevel * (math.max(1, chiefLevel) - 1))
end

-- Somme des bonus des traits d'une force pour un effet (« attack », « upkeep », « Blindes »...)
function GeneralTraits.bonus(army: Instance, effect: string): number
	local total = 0
	for _, id in GeneralTraits.of(army) do
		if Generals.traits[id].effect == effect then
			total += GeneralTraits.strength(id, level(army))
		end
	end
	return math.min(Generals.maxBonus, total)
end

-- Tire un trait possible pour cette sorte de force, différent de ceux déjà là
function GeneralTraits.pick(kind: string, exclude: { string }, rng: Random): string?
	local choices = {}
	for _, id in Generals.order do
		local trait = Generals.traits[id]
		if table.find(trait.kinds, kind) and not table.find(exclude, id) then
			table.insert(choices, id)
		end
	end
	return if #choices > 0 then choices[rng:NextInteger(1, #choices)] else nil
end

-- « 🛡️ Défenseur tenace (+20 % en défense) »
function GeneralTraits.describe(traitId: string, chiefLevel: number): string
	local trait = Generals.traits[traitId]
	local percent = math.floor(GeneralTraits.strength(traitId, chiefLevel) * 100 + 0.5)
	return `{trait.icon} {trait.name} ({(trait.text:gsub("{n}", tostring(percent)))})`
end

-- Icônes des traits d'une force (pour son étiquette sur la carte)
function GeneralTraits.icons(army: Instance): string
	local icons = {}
	for _, id in GeneralTraits.of(army) do
		table.insert(icons, Generals.traits[id].icon)
	end
	return table.concat(icons, "")
end

return GeneralTraits
