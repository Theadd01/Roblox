--!strict
-- IA des pays : contrats commerciaux (voir ContractService).
--   - répond aux contrats proposés à un pays qu'elle dirige : elle vend si elle a le stock et
--     que le prix est correct, elle achète si elle a besoin de la ressource ou si c'est une affaire ;
--   - propose des contrats de vente aux joueurs à qui une ressource manque (surtout les
--     commerçants : réglage contractEagerness de leur personnalité).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Trade = require(Config:WaitForChild("Trade")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local Market = require(Config:WaitForChild("Market")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local RegionResources = require(Shared:WaitForChild("RegionResources")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local CountryAssignment = require(Server:WaitForChild("Session"):WaitForChild("CountryAssignment"))
local Economy = Server:WaitForChild("Economy")
local Stocks = require(Economy:WaitForChild("Stocks"))
local MarketService = require(Economy:WaitForChild("MarketService"))
local ContractService = require(Economy:WaitForChild("ContractService"))
local PersonalityService = require(script.Parent:WaitForChild("PersonalityService"))
local EconomyAI = require(script.Parent:WaitForChild("EconomyAI"))

local CURRENCY: string = Resources.currency.id
local ANSWER_DELAY = { min = 2, max = 5 }
local QUANTITY = 10 -- unités par livraison proposées par l'IA

export type Action = { kind: string, score: number, label: string, run: () -> boolean }

local TradeAI = {}

local lastProposalOf: { [string]: number } = {} -- dernier contrat proposé par chaque pays IA
local lastProposalTo: { [string]: number } = {} -- dernier contrat proposé par l'IA à chaque joueur
local rng = Random.new()

local function nameOf(countryId: string): string
	return if Countries[countryId] then Countries[countryId].name else countryId
end

local function marketPrice(resourceId: string): number
	return MarketService.price(resourceId) or Market.basePrices[resourceId]
end

-- L'IA de `countryId` accepte-t-elle ce contrat ?
local function evaluate(countryId: string, contract: Instance): boolean
	local P = PersonalityService.settings(countryId)
	local resourceId = contract:GetAttribute("Ressource") :: string
	local quantity = contract:GetAttribute("Quantite") :: number
	local price = contract:GetAttribute("Prix") :: number
	local deliveries = contract:GetAttribute("Livraisons") :: number
	local market = marketPrice(resourceId)
	local stock = Stocks.get(countryId, resourceId)
	local keep = EconomyAI.reserveOf(countryId, resourceId, P)
	if contract:GetAttribute("Vendeur") == countryId then
		-- vendre : du surplus pour au moins 3 livraisons, et un prix correct
		return stock - keep >= quantity * 3 and price >= market * P.sellFloor.min
	end
	-- acheter : de quoi payer 3 livraisons, et un besoin (sous sa réserve) ou une bonne affaire
	local canPay = Stocks.get(countryId, CURRENCY) - P.creditReserve >= price * quantity * 3 * 1.2
	local needs = stock < keep + quantity * deliveries * 0.5 and price <= market * P.buyCeiling.min
	local bargain = price <= market * 0.95
	return canPay and (needs or bargain)
end

local function answer(contract: Instance)
	local seller, buyer = contract:GetAttribute("Vendeur") :: string, contract:GetAttribute("Acheteur") :: string
	local partner = if contract:GetAttribute("ProposePar") == seller then buyer else seller
	if not CountryAssignment.isAIControlled(partner) then
		return -- un joueur répondra lui-même
	end
	task.wait(rng:NextNumber(ANSWER_DELAY.min, ANSWER_DELAY.max))
	if contract.Parent and contract:GetAttribute("Statut") == "Propose" and CountryAssignment.isAIControlled(partner) then
		ContractService.respond(partner, contract.Name, evaluate(partner, contract))
	end
end

-- Joueurs (présents) qui dirigent un pays
local function playerCountries(): { string }
	local list = {}
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	for _, folder in (if pays then pays:GetChildren() else {}) do
		if folder:GetAttribute("Joueur") ~= 0 and folder:GetAttribute("Absent") ~= true then
			table.insert(list, folder.Name)
		end
	end
	return list
end

-- Proposer un contrat de vente à un joueur à qui cette ressource manque
function TradeAI.actions(countryId: string, P: any): { Action }
	local actions: { Action } = {}
	local now = time()
	if now - (lastProposalOf[countryId] or -math.huge) < Trade.aiProposalInterval then
		return actions
	end
	local players = playerCountries()
	if #players == 0 then
		return actions
	end
	-- ressource au plus gros surplus (assez pour toutes les livraisons)
	local bestResource: string? = nil
	local bestSurplus = QUANTITY * Trade.aiDeliveries
	for _, resourceId in Resources.order do
		local surplus = Stocks.get(countryId, resourceId) - EconomyAI.reserveOf(countryId, resourceId, P)
		if surplus >= bestSurplus then
			bestResource, bestSurplus = resourceId, surplus
		end
	end
	if not bestResource then
		return actions
	end
	local resourceId = bestResource :: string
	for _, player in players do
		if now - (lastProposalTo[player] or -math.huge) < Trade.aiPlayerInterval or DiplomacyState.atWar(countryId, player)
			or DiplomacyState.hasEmbargo(countryId, player) or not ContractService.route(countryId, player) then
			continue
		end
		local production = RegionResources.countryProduction(player, RegionService.getOwner)
		if (production[resourceId] or 0) > 0 then
			continue -- il en produit déjà
		end
		local r = Resources.list[resourceId]
		table.insert(actions, {
			kind = "Contrat",
			score = 0.25 + 0.4 * P.contractEagerness,
			label = `propose un contrat à {nameOf(player)} : {QUANTITY} {r.icon} {r.name} par cycle`,
			run = function(): boolean
				lastProposalOf[countryId] = time()
				lastProposalTo[player] = time()
				local factor = if rng:NextNumber() < 0.5 then 1 else 1.1
				return (ContractService.propose(countryId, player, resourceId, true, QUANTITY, Trade.aiDeliveries, factor))
			end,
		})
		break
	end
	return actions
end

-- Nouvelle partie : l'IA oublie ses propositions de contrats
function TradeAI.reset()
	table.clear(lastProposalOf)
	table.clear(lastProposalTo)
end

-- À appeler au démarrage (après ContractService.init)
function TradeAI.start()
	ContractService.onProposal(answer)
end

return TradeAI
