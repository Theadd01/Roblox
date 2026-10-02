--!strict
-- Flux de ressources d'un pays par cycle de production :
--   regions   : production des régions possédées
--   factories : consommation (-) et production (+) des bâtiments (usines au dernier cycle,
--               exploitations : champs, mines, puits)
--   army      : entretien des forces militaires (-)
--   population : nourriture mangée par les habitants (-), voir shared/PopulationRules
--   total     : somme des quatre
-- et le décompte de ses usines par état.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local BuildingRules = require(Shared:WaitForChild("BuildingRules")) :: any
local Factories = require(Config:WaitForChild("Factories")) :: any
local RegionResources = require(Shared:WaitForChild("RegionResources")) :: any
local Client = script.Parent.Parent
local RegionView = require(Client:WaitForChild("Map"):WaitForChild("RegionView"))
local FactoryState = require(script.Parent:WaitForChild("FactoryState"))
local ArmyState = require(script.Parent:WaitForChild("ArmyState"))
local MilitaryMath = require(Shared:WaitForChild("MilitaryMath")) :: any
local PopulationRules = require(Shared:WaitForChild("PopulationRules")) :: any
local Economy = require(Config:WaitForChild("Economy")) :: any
local MilitaryState = require(Client:WaitForChild("Military"):WaitForChild("MilitaryState"))

export type Flows = {
	regions: { [string]: number },
	factories: { [string]: number },
	army: { [string]: number },
	population: { [string]: number },
	total: { [string]: number },
	counts: { total: number, running: number, stopped: number, building: number },
}

local CountryFlows = {}

function CountryFlows.compute(countryId: string): Flows
	local regions = RegionResources.countryProduction(countryId, RegionView.getOwner)
	local factories: { [string]: number } = {}
	local counts = { total = 0, running = 0, stopped = 0, building = 0 }

	for _, factory in FactoryState.ownedBy(countryId) do
		counts.total += 1
		local status = factory:GetAttribute("Statut")
		if status == "Construction" then
			counts.building += 1
			continue
		end
		if status == "Arret" then
			counts.stopped += 1
		else
			counts.running += 1
		end
		-- bâtiment (shared/BuildingRules) : usines au nombre de lots du dernier cycle, exploitations
		-- selon leur niveau (rien s'il est arrêté)
		local typeId = factory:GetAttribute("Type") :: string
		local kind = Factories.types[typeId]
		local level = if kind and kind.recipe then (factory:GetAttribute("Lots") :: number?) or 0
			elseif status == "Arret" or status == "Sabotee" then 0
			else (factory:GetAttribute("Niveau") :: number?) or 1
		if kind and level > 0 then
			local regionId = factory:GetAttribute("Region") :: string
			-- les lots d'une usine valent des niveaux (1 lot par niveau)
			local scale = if kind.recipe then level / (kind.batchesPerLevel or 1) else level
			for resourceId, amount in BuildingRules.inputs(typeId, scale) do
				factories[resourceId] = (factories[resourceId] or 0) - amount
			end
			for resourceId, amount in BuildingRules.outputs(typeId, regionId, scale, countryId) do
				factories[resourceId] = (factories[resourceId] or 0) + amount
			end
		end
	end

	local army: { [string]: number } = {}
	for _, force in ArmyState.ownedBy(countryId) do
		for id, amount in MilitaryMath.upkeep(force) do
			army[id] = (army[id] or 0) - amount
		end
	end

	-- divisions : nourriture et pétrole (Config/Divisions.upkeep, par minute)
	local minutes = Economy.productionInterval / 60
	for _, d in MilitaryState.list() do
		if d:GetAttribute("Proprietaire") == countryId then
			for id, perMinute in MilitaryState.typeOf(d).upkeep do
				army[id] = (army[id] or 0) - perMinute * minutes
			end
		end
	end

	-- habitants (attribut « Population » du pays, publié par le serveur)
	local country = ReplicatedStorage:FindFirstChild("EtatMonde")
	country = country and country:FindFirstChild("Pays")
	country = country and country:FindFirstChild(countryId)
	local people = country and country:GetAttribute("Population")
	local population: { [string]: number } = {}
	if typeof(people) == "number" and people > 0 then
		population.Nourriture = -PopulationRules.food(people)
	end

	local total: { [string]: number } = {}
	for _, source in { regions, factories, army, population } do
		for id, amount in source do
			total[id] = (total[id] or 0) + amount
		end
	end
	for id, amount in total do
		total[id] = math.floor(amount * 10 + 0.5) / 10
	end
	return { regions = regions, factories = factories, army = army, population = population, total = total, counts = counts }
end

return CountryFlows
