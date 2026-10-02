--!strict
-- Production automatique : toutes les Economy.productionInterval secondes, chaque région
-- ajoute sa production au stock de son propriétaire actuel (une région conquise produit
-- donc pour le conquérant), puis les usines fabriquent, les impôts tombent et les surplus des
-- joueurs se vendent tout seuls (TaxService, AutoSellService). L'heure du prochain cycle est
-- publiée dans l'attribut « ProductionSuivante » de ReplicatedStorage.EtatMonde (heure serveur).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Economy = require(Config:WaitForChild("Economy")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local RegionResources = require(Shared:WaitForChild("RegionResources")) :: any
local RegionService = require(script.Parent.Parent:WaitForChild("Map"):WaitForChild("RegionService"))
local Stocks = require(script.Parent:WaitForChild("Stocks"))
local FactoryService = require(script.Parent:WaitForChild("FactoryService"))
local SupplyService = require(script.Parent.Parent:WaitForChild("Military"):WaitForChild("SupplyService"))
local ContractService = require(script.Parent:WaitForChild("ContractService"))
local PopulationService = require(script.Parent:WaitForChild("PopulationService"))
local TaxService = require(script.Parent:WaitForChild("TaxService"))
local AutoSellService = require(script.Parent:WaitForChild("AutoSellService"))
local StabilityRules = require(Shared:WaitForChild("StabilityRules")) :: any
local Politics = script.Parent.Parent:WaitForChild("Politics")
local Stability = require(Politics:WaitForChild("Stability"))
local BalanceService = require(Politics:WaitForChild("BalanceService"))
local ExileService = require(script.Parent.Parent:WaitForChild("Session"):WaitForChild("ExileService"))
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local ProjectState = require(Shared:WaitForChild("ProjectState")) :: any
local TechState = require(Shared:WaitForChild("TechState")) :: any

local ProductionService = {}

-- restes de production (la stabilité donne des parts d'unité, gardées pour le cycle suivant)
local carry: { [string]: { [string]: number } } = {}

-- Un cycle de production pour tous les pays
function ProductionService.tick()
	local totals: { [string]: { [string]: number } } = {}
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local regionStates = state and state:FindFirstChild("Regions")
	local now = workspace:GetServerTimeNow()
	for regionId in Regions do
		local owner = RegionService.getOwner(regionId)
		-- catastrophe naturelle (événement mondial) : la région ne produit plus rien un moment
		local regionState = regionStates and regionStates:FindFirstChild(regionId)
		local disaster = regionState and regionState:GetAttribute("Catastrophe")
		if typeof(disaster) == "number" and disaster > now then
			continue
		end
		if owner then
			local total = totals[owner]
			if not total then
				total = {}
				totals[owner] = total
			end
			-- une région conquise produit moins pour son occupant
			local factor = RegionResources.ownerFactor(regionId, owner)
			for resourceId, amount in RegionResources.production(regionId) do
				total[resourceId] = (total[resourceId] or 0) + amount * factor
			end
		end
	end
	-- l'opinion publique pèse sur la production (voir shared/StabilityRules)
	for countryId, amounts in totals do
		-- projet décisif « réseau satellite » : +10 %
		local factor = StabilityRules.productionFactor(Stability.get(countryId)) * ProjectState.factor(countryId, "production")
		local rest = carry[countryId] or {}
		carry[countryId] = rest
		local given: { [string]: number } = {}
		for resourceId, amount in amounts do
			-- technologies : agriculture intensive, réseau électrique intelligent
			local exact = amount * factor * TechState.productionFactor(countryId, resourceId) + (rest[resourceId] or 0)
			given[resourceId] = math.floor(exact)
			rest[resourceId] = exact - given[resourceId]
		end
		Stocks.addMany(countryId, given)
	end
	-- puis les usines transforment les ressources (fer + charbon -> acier...)
	FactoryService.process()
	-- les contrats entre pays livrent leur ressource
	ContractService.tick()
	-- la population mange, puis grandit (ou souffre de la faim)
	PopulationService.tick()
	-- revenus passifs : impôts payés par les habitants, puis commerce automatique des joueurs
	-- (achat de la nourriture qui manque, vente des surplus)
	TaxService.tick()
	AutoSellService.tick()
	-- enfin, les forces militaires consomment leur entretien (ravitaillement, moral)
	SupplyService.tick()
	-- stabilité (pénuries, guerres, conquêtes, révoltes) et aide aux pays affaiblis
	Stability.tick()
	BalanceService.tick()
	-- résistance dans les régions occupées (gouvernements en exil)
	ExileService.tick()
end

-- Nouvelle partie : plus de restes de production
function ProductionService.reset()
	table.clear(carry)
end

function ProductionService.start()
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local interval: number = Economy.productionInterval
	task.spawn(function()
		while true do
			state:SetAttribute("ProductionSuivante", workspace:GetServerTimeNow() + interval)
			task.wait(interval)
			if MatchState.isRunning() then -- rien ne bouge pendant l'écran de fin de partie
				ProductionService.tick()
			end
		end
	end)
end

return ProductionService
