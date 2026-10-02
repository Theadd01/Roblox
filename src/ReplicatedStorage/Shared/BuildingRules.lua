--!strict
-- Règles des bâtiments (Config/Factories), partagées par le serveur (qui décide) et le client (qui
-- affiche) : emplacements d'une région, bâtiments possibles, production par cycle, coût d'un
-- nouveau bâtiment, camps militaires. Les bâtiments eux-mêmes sont publiés dans
-- ReplicatedStorage.EtatMonde.Usines (attributs Type, Region, Niveau, Statut, Depart...).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = script.Parent.Config
local Factories = require(Config.Factories)
local Recipes = require(Config.Recipes)
local Regions = require(Config.Regions)
local Resources = require(Config.Resources)
local ResourceDeposits = require(Config.ResourceDeposits)
local RegionResources = require(script.Parent.RegionResources)

local BuildingRules = {}

local fertilityClass: { [string]: string } = {}
for _, id in ResourceDeposits.fertile do
	fertilityClass[id] = "fertile"
end
for _, id in ResourceDeposits.arid do
	fertilityClass[id] = "arid"
end

local function resourceName(id: string): string
	local r = Resources.list[id]
	return if r then r.name else id
end

-- Emplacements d'une région : 2, ou 4 dans la capitale d'un pays (la région qui porte son code)
function BuildingRules.slots(regionId: string): number
	local region = Regions[regionId]
	if region and region.startOwner == regionId then
		return Factories.capitalSlots
	end
	return Factories.maxPerRegion
end

-- Fertilité d'une région pour les champs de blé (pays d'origine de la région)
function BuildingRules.fertility(regionId: string): number
	local home = regionId:match("^(%u+)") or regionId
	return Factories.fertilityFactors[fertilityClass[home] or "normal"] or 1
end

-- Ce bâtiment peut-il être construit dans cette région ? (ressources présentes ; sans compter la
-- place ni le propriétaire) ; sinon la raison
function BuildingRules.canBuildIn(typeId: string, regionId: string): (boolean, string?)
	local kind = Factories.types[typeId]
	if not kind or not Regions[regionId] then
		return false, "Bâtiment inconnu."
	end
	local extracts = kind.extracts
	if extracts and not kind.anywhere then
		local production = RegionResources.production(regionId)
		local names = {}
		for _, id in Resources.order do
			if extracts[id] then
				if (production[id] or 0) > 0 then
					return true, nil
				end
				table.insert(names, resourceName(id):lower())
			end
		end
		return false, `Pas de {table.concat(names, ", ")} dans cette région.`
	end
	return true, nil
end

-- Production d'un bâtiment par cycle (exploitations et usines à plein régime ; une région conquise
-- produit moins pour son occupant, voir RegionResources.ownerFactor)
function BuildingRules.outputs(typeId: string, regionId: string, level: number, ownerId: string?): { [string]: number }
	local kind = Factories.types[typeId]
	local result: { [string]: number } = {}
	if not kind then
		return result
	end
	local extracts = kind.extracts
	if extracts then
		local production = RegionResources.production(regionId)
		local factor = level * RegionResources.ownerFactor(regionId, ownerId) * (if kind.fertility then BuildingRules.fertility(regionId) else 1)
		for id, amount in extracts do
			if kind.anywhere or (production[id] or 0) > 0 then
				result[id] = amount * factor
			end
		end
	elseif kind.recipe then
		local recipe = Recipes[kind.recipe :: string]
		local lots = level * (kind.batchesPerLevel or 1)
		for id, amount in recipe.outputs do
			result[id] = amount * lots
		end
	end
	return result
end

-- Matières consommées par cycle (usines à plein régime)
function BuildingRules.inputs(typeId: string, level: number): { [string]: number }
	local kind = Factories.types[typeId]
	local result: { [string]: number } = {}
	if kind and kind.recipe then
		local recipe = Recipes[kind.recipe :: string]
		local lots = level * (kind.batchesPerLevel or 1)
		for id, amount in recipe.inputs do
			result[id] = amount * lots
		end
	end
	return result
end

-- Coût d'un nouveau bâtiment quand le pays en a déjà `owned` (hors bâtiments offerts au départ)
function BuildingRules.buildCost(typeId: string, owned: number): { [string]: number }
	local kind = Factories.types[typeId]
	local factor = 1 + Factories.costGrowth * math.max(0, owned - Factories.freeBuildings)
	local cost: { [string]: number } = {}
	for id, amount in (if kind then kind.buildCost else {}) do
		cost[id] = math.floor(amount * factor + 0.5)
	end
	return cost
end

-- Durée d'entraînement d'une division formée dans un camp de ce niveau (x facteur)
function BuildingRules.campFactor(level: number): number
	return math.max(0.4, 1 - Factories.campTraining * math.max(0, level - 1))
end

-- Bâtiments publiés (EtatMonde.Usines)
function BuildingRules.list(): { Instance }
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local folder = state and state:FindFirstChild("Usines")
	return if folder then folder:GetChildren() else {}
end

-- Bâtiments d'une région
function BuildingRules.inRegion(regionId: string): { Instance }
	local list = {}
	for _, building in BuildingRules.list() do
		if building:GetAttribute("Region") == regionId then
			table.insert(list, building)
		end
	end
	table.sort(list, function(a: Instance, b: Instance): boolean
		return a.Name < b.Name
	end)
	return list
end

-- Bâtiments construits par un pays (régions qu'il possède), sans ceux offerts au départ :
-- ils font monter le prix des suivants. ownerOf(regionId) donne le propriétaire actuel.
function BuildingRules.countBuilt(countryId: string, ownerOf: (string) -> string?): number
	local count = 0
	for _, building in BuildingRules.list() do
		local regionId = building:GetAttribute("Region")
		if typeof(regionId) == "string" and ownerOf(regionId) == countryId and building:GetAttribute("Depart") ~= true then
			count += 1
		end
	end
	return count
end

-- Niveau du camp militaire terminé d'une région (0 : pas de camp, on n'y recrute pas)
function BuildingRules.campLevel(regionId: string): number
	local best = 0
	for _, building in BuildingRules.inRegion(regionId) do
		local kind = Factories.types[building:GetAttribute("Type") :: string]
		if kind and kind.camp and building:GetAttribute("Statut") ~= "Construction" then
			best = math.max(best, (building:GetAttribute("Niveau") :: number?) or 1)
		end
	end
	return best
end

-- Effet d'un bâtiment en texte court : « +4,5 Nourriture par cycle », « 2 Fe + 1 Ch → 1 Ac par cycle »
function BuildingRules.describe(typeId: string, regionId: string, level: number, ownerId: string?, format: (number) -> string): string
	local kind = Factories.types[typeId]
	if not kind then
		return ""
	end
	if kind.camp then
		local faster = math.floor((1 - BuildingRules.campFactor(level)) * 100 + 0.5)
		return if faster > 0 then `recrutement ici · entraînement {faster} % plus court` else "recrutement ici"
	end
	local function side(list: { [string]: number }): string
		local parts = {}
		for _, id in Resources.order do
			if list[id] then
				table.insert(parts, `{format(list[id])} {Resources.list[id].icon}`)
			end
		end
		return table.concat(parts, " + ")
	end
	local outputs = BuildingRules.outputs(typeId, regionId, level, ownerId)
	if kind.recipe then
		return `{side(BuildingRules.inputs(typeId, level))} → {side(outputs)} par cycle`
	end
	local text = side(outputs)
	return if text ~= "" then `+{text} par cycle` else "rien ici"
end

return BuildingRules
