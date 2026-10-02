--!strict
-- Impôts : à chaque cycle de production, chaque pays (joueur ou IA) reçoit des crédits payés par
-- ses habitants (Config/Population.taxPerMillion), sans rien faire. Les habitants d'une région
-- conquise paient moins (Config/Economy.taxes), et le tout suit la stabilité (voir shared/IncomeRules).
-- Le montant du dernier cycle est publié dans l'attribut « Impots » de EtatMonde.Pays.<pays>.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local IncomeRules = require(Shared:WaitForChild("IncomeRules")) :: any
local StabilityRules = require(Shared:WaitForChild("StabilityRules")) :: any
local TechState = require(Shared:WaitForChild("TechState")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local Stability = require(Server:WaitForChild("Politics"):WaitForChild("Stability"))
local Stocks = require(script.Parent:WaitForChild("Stocks"))
local PopulationService = require(script.Parent:WaitForChild("PopulationService"))

local CURRENCY: string = Resources.currency.id

type Payers = { home: number, occupied: number }

local TaxService = {}

local carry: { [string]: number } = {} -- parts de crédit gardées pour le cycle suivant

local function countries(): { Instance }
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return if pays then pays:GetChildren() else {}
end

-- Un cycle d'impôts pour tous les pays
function TaxService.tick()
	local payers: { [string]: Payers } = {}
	for regionId, region in Regions do
		local owner = RegionService.getOwner(regionId)
		if not owner then
			continue
		end
		local p = payers[owner]
		if not p then
			p = { home = 0, occupied = 0 }
			payers[owner] = p
		end
		local people = PopulationService.of(regionId)
		if region.startOwner == owner then
			p.home += people
		else
			p.occupied += people
		end
	end
	for _, folder in countries() do
		local countryId = folder.Name
		local p = payers[countryId]
		local amount = 0
		if p then
			local factor = StabilityRules.productionFactor(Stability.get(countryId))
			-- recherche « Fiscalité moderne » : plus d'impôts
			local exact = IncomeRules.taxes(p.home, p.occupied, factor) * TechState.incomeFactor(countryId) + (carry[countryId] or 0)
			amount = math.floor(exact)
			carry[countryId] = exact - amount
			if amount > 0 then
				Stocks.add(countryId, CURRENCY, amount)
			end
		end
		if folder:GetAttribute("Impots") ~= amount then
			folder:SetAttribute("Impots", amount)
		end
	end
end

-- Nouvelle partie : plus de restes ni de montant affiché
function TaxService.reset()
	table.clear(carry)
	for _, folder in countries() do
		folder:SetAttribute("Impots", nil)
	end
end

return TaxService
