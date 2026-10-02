--!strict
-- IA des pays, version 1 : décisions économiques.
-- Analyse la situation d'un pays (production de ses régions, consommation de ses usines
-- et de ses armées, stocks) et propose des actions notées de 0 à 1 (score d'utilité) :
--   - vendre un surplus, quand le prix est bon, sans faire chuter le cours ;
--   - acheter ce qui manque (matières des usines, entretien des armées, réserves) ;
--   - construire ou agrandir le bâtiment le plus vite rentabilisé (champs, mines, puits, usines).
-- Chaque action passe par les mêmes fonctions serveur que les joueurs
-- (MarketService, FactoryService), qui revérifient tout.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local AI = require(Config:WaitForChild("AI")) :: any
local Market = require(Config:WaitForChild("Market")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local Factories = require(Config:WaitForChild("Factories")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local MarketMath = require(Shared:WaitForChild("MarketMath")) :: any
local MilitaryMath = require(Shared:WaitForChild("MilitaryMath")) :: any
local RegionResources = require(Shared:WaitForChild("RegionResources")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local Economy = Server:WaitForChild("Economy")
local Stocks = require(Economy:WaitForChild("Stocks"))
local MarketService = require(Economy:WaitForChild("MarketService"))
local FactoryService = require(Economy:WaitForChild("FactoryService"))
local PopulationService = require(Economy:WaitForChild("PopulationService"))
local Divisions = require(Server:WaitForChild("Military"):WaitForChild("Divisions"))
local EconomyConfig = require(Config:WaitForChild("Economy")) :: any
local PopulationRules = require(Shared:WaitForChild("PopulationRules")) :: any
local BuildingRules = require(Shared:WaitForChild("BuildingRules")) :: any

local CURRENCY: string = Resources.currency.id

-- Prix acceptés par un pays, en part du prix de base
type Profile = { sellFloor: number, buyCeiling: number, reserveCeiling: number }

export type Action = {
	kind: string, -- famille d'actions : "Commerce", "Industrie", "Defense" ou "Attaque" (voir AI.maxPerKind)
	score: number, -- 0 à 1
	label: string, -- décision affichée (« vend 12 🛢️ Pétrole »)
	run: () -> boolean, -- exécute l'action ; faux si elle a été refusée
}

-- Situation d'un pays, par cycle de production
type Situation = {
	countryId: string,
	P: any, -- réglages de l'IA de ce pays (Config/AI et sa personnalité)
	regions: { string }, -- ses régions, la région d'origine en premier
	production: { [string]: number },
	consumption: { [string]: number }, -- matières des usines + entretien des armées
	planned: { [string]: number }, -- ressources mises de côté pour agrandir une usine
	factories: { Instance },
	building: boolean, -- une usine est en chantier
}


local EconomyAI = {}

local function children(name: string): { Instance }
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local folder = state and state:FindFirstChild(name)
	return if folder then folder:GetChildren() else {}
end

local function add(total: { [string]: number }, resourceId: string, amount: number)
	total[resourceId] = (total[resourceId] or 0) + amount
end

local function situation(countryId: string, P: any): Situation
	local regions = {}
	local production: { [string]: number } = {}
	for regionId in Regions do
		if RegionService.getOwner(regionId) == countryId then
			table.insert(regions, regionId)
			local factor = RegionResources.ownerFactor(regionId, countryId) -- région conquise : moitié moins
			for resourceId, amount in RegionResources.production(regionId) do
				add(production, resourceId, amount * factor)
			end
		end
	end
	table.sort(regions, function(a: string, b: string): boolean
		if (a == countryId) ~= (b == countryId) then
			return a == countryId
		end
		return a < b
	end)

	local consumption: { [string]: number } = {}
	local factories = {}
	local building = false
	for _, factory in children("Usines") do
		if RegionService.getOwner(factory:GetAttribute("Region") :: string) ~= countryId then
			continue
		end
		table.insert(factories, factory)
		if factory:GetAttribute("Statut") == "Construction" then
			building = true
		end
		-- une usine en chantier compte déjà : l'IA prévoit ses matières
		for resourceId, amount in BuildingRules.inputs(factory:GetAttribute("Type") :: string, factory:GetAttribute("Niveau") :: number) do
			add(consumption, resourceId, amount)
		end
	end
	for _, army in children("Armees") do
		if army:GetAttribute("Proprietaire") == countryId then
			for resourceId, amount in MilitaryMath.upkeep(army) do
				add(consumption, resourceId, amount)
			end
		end
	end
	-- divisions (Config/Divisions.upkeep, par minute) et habitants (Config/Population) : à nourrir
	local minutes = EconomyConfig.productionInterval / 60
	for _, d in Divisions.ofCountry(countryId) do
		for resourceId, perMinute in Divisions.typeOf(d).upkeep do
			add(consumption, resourceId, perMinute * minutes)
		end
	end
	add(consumption, "Nourriture", PopulationRules.food(PopulationService.total(countryId)))

	return {
		countryId = countryId,
		P = P,
		regions = regions,
		production = production,
		consumption = consumption,
		planned = {},
		factories = factories,
		building = building,
	}
end

-- Besoin pour faire tourner le pays : quelques cycles de matières (usines) et d'entretien (armées)
local function operatingNeed(s: Situation, resourceId: string): number
	return s.P.reserveCycles * (s.consumption[resourceId] or 0)
end

-- Stock que l'IA veut garder : besoin de fonctionnement + réserve de précaution + projets
local function reserve(s: Situation, resourceId: string): number
	return operatingNeed(s, resourceId) + (s.P.reserves[resourceId] or 0) + (s.planned[resourceId] or 0)
end

-- Valeur d'un niveau de bâtiment par cycle, au prix du marché : sa production moins ses matières
-- (achetées s'il en manque) ; une ressource dont le pays manque vaut un peu plus
local function levelValue(s: Situation, typeId: string, regionId: string): number
	local value = 0
	for resourceId, amount in BuildingRules.outputs(typeId, regionId, 1, s.countryId) do
		local price = MarketService.price(resourceId) or 0
		if (s.production[resourceId] or 0) < (s.consumption[resourceId] or 0) then
			price *= 1.3
		end
		value += price * amount
	end
	for resourceId, amount in BuildingRules.inputs(typeId, 1) do
		value -= (MarketService.price(resourceId) or 0) * amount
	end
	return value
end

-- Note d'un investissement (0 à 1) : vite rentabilisé = bonne note (PAYBACK cycles = 0)
local PAYBACK = 60
local function investScore(value: number, cost: { [string]: number }): number
	if value <= 0 then
		return 0
	end
	return math.clamp(1 - (cost[CURRENCY] or 0) / value / PAYBACK, 0, 1)
end

local function resourceLabel(resourceId: string, quantity: number): string
	local r = Resources.list[resourceId]
	return `{quantity} {r.icon} {r.name}`
end

-- Quantité maximale d'un échange : le prix ne doit ni dépasser `limit`,
-- ni bouger de plus de AI.maxPriceImpact
local function tradeCap(price: number, limit: number, liquidity: number): number
	local toLimit = liquidity * math.abs(math.log(limit / price))
	local impact = liquidity * math.log(1 + AI.maxPriceImpact)
	return math.floor(math.min(toLimit, impact))
end

-- Garde la réserve de crédits intacte
local function canSpend(s: Situation, credits: number): boolean
	return Stocks.get(s.countryId, CURRENCY) - credits >= s.P.creditReserve
end

local function sellActions(countryId: string, s: Situation, profile: Profile, actions: { Action })
	for _, resourceId in Resources.order do
		local stock = Stocks.get(countryId, resourceId)
		local keep = reserve(s, resourceId)
		if stock <= math.max(keep * s.P.surplusFactor, s.P.minTrade) then
			continue
		end
		local price = MarketService.price(resourceId)
		local base = Market.basePrices[resourceId]
		-- plus le surplus est gros, plus l'IA accepte de vendre moins cher
		local fill = math.min(1, (stock - keep) / (keep + 50))
		local floorPrice = base * profile.sellFloor * (1 - s.P.surplusDiscount * fill)
		if not price or price <= floorPrice then
			continue -- prix trop bas : l'IA attend
		end
		local quantity = math.min(math.floor(stock - keep), tradeCap(price, floorPrice, Market.liquidity[resourceId]))
		if quantity < s.P.minTrade then
			continue
		end
		-- plus le surplus est gros et le prix haut, plus la vente est intéressante
		local opportunity = math.clamp((price / base - 0.9) / 0.4, 0, 1)
		table.insert(actions, {
			kind = "Commerce",
			score = 0.35 + 0.35 * fill + 0.3 * opportunity,
			label = "vend " .. resourceLabel(resourceId, quantity),
			run = function(): boolean
				return (MarketService.sell(countryId, resourceId, quantity))
			end,
		})
	end
end

local function buyActions(countryId: string, s: Situation, profile: Profile, actions: { Action })
	for _, resourceId in Resources.order do
		local stock = Stocks.get(countryId, resourceId)
		local keep = reserve(s, resourceId)
		local missing = keep - stock
		local price = MarketService.price(resourceId)
		if missing < s.P.minTrade or not price then
			continue
		end
		local base = Market.basePrices[resourceId]
		local liquidity = Market.liquidity[resourceId]
		-- ce qui manque pour faire tourner le pays est urgent : l'IA accepte de payer plus cher ;
		-- le reste (précaution, projets) attend un prix normal
		local operating = operatingNeed(s, resourceId)
		local urgent = operating - stock >= s.P.minTrade
		local urgency = if urgent then math.clamp((operating - stock) / operating, 0, 1) else 0
		local ceiling = if urgent then base * profile.buyCeiling * (1 + 0.3 * urgency) else base * profile.reserveCeiling
		local budget = Stocks.get(countryId, CURRENCY) - s.P.creditReserve
		if price >= ceiling or budget <= 0 then
			continue
		end
		local wanted = if urgent then operating - stock else missing
		local affordable = math.floor(liquidity * math.log(1 + budget / (price * liquidity)))
		local quantity = math.min(math.ceil(wanted), tradeCap(price, ceiling, liquidity), affordable)
		if quantity < s.P.minTrade then
			continue
		end
		local need = if urgent then 0.45 + 0.5 * urgency else 0.3 + 0.2 * math.clamp(missing / keep, 0, 1)
		table.insert(actions, {
			kind = "Commerce",
			score = need - 0.2 * math.clamp(price / base - 1, 0, 1),
			label = "achète " .. resourceLabel(resourceId, quantity),
			run = function(): boolean
				local cost = MarketMath.buyCost(MarketService.price(resourceId) :: number, quantity, liquidity)
				if not canSpend(s, cost) then
					return false
				end
				return (MarketService.buy(countryId, resourceId, quantity, cost))
			end,
		})
	end
end

local function factoryActions(countryId: string, s: Situation, actions: { Action })
	-- améliorer le bâtiment le plus rentable (pas les camps : voir MilitaryAI)
	local upgrade: Instance? = nil
	local upgradeScore, upgradeCost = 0, {}
	for _, factory in s.factories do
		local typeId = factory:GetAttribute("Type") :: string
		local kind = Factories.types[typeId]
		local level = (factory:GetAttribute("Niveau") :: number?) or 1
		if not kind or kind.camp or factory:GetAttribute("Statut") == "Construction" or level >= kind.maxLevel then
			continue
		end
		local cost = kind.upgradeCosts[level + 1]
		local score = investScore(levelValue(s, typeId, factory:GetAttribute("Region") :: string), cost)
		if score > upgradeScore and canSpend(s, cost[CURRENCY] or 0) and Stocks.canAfford(countryId, cost) then
			upgrade, upgradeScore, upgradeCost = factory, score, cost
		end
	end
	if upgrade then
		local factoryId = upgrade.Name
		local kind = Factories.types[upgrade:GetAttribute("Type") :: string]
		local cost = upgradeCost
		table.insert(actions, {
			kind = "Industrie",
			score = 0.3 + 0.5 * upgradeScore,
			label = `agrandit : {kind.icon} {kind.name} (niveau {(upgrade:GetAttribute("Niveau") :: number) + 1})`,
			run = function(): boolean
				return canSpend(s, cost[CURRENCY] or 0) and (FactoryService.upgrade(countryId, factoryId))
			end,
		})
	end

	-- construire le bâtiment le plus rentable là où il y a de la place (un seul chantier à la fois)
	if s.building then
		return
	end
	local owned = BuildingRules.countBuilt(countryId, RegionService.getOwner)
	local bestRegion: string? = nil
	local bestType, bestScore, bestCost = "", 0, {}
	for _, regionId in s.regions do
		if #BuildingRules.inRegion(regionId) >= BuildingRules.slots(regionId) then
			continue
		end
		for _, typeId in Factories.order do
			local kind = Factories.types[typeId]
			if kind.camp or not BuildingRules.canBuildIn(typeId, regionId) then
				continue
			end
			local cost = BuildingRules.buildCost(typeId, owned)
			local score = investScore(levelValue(s, typeId, regionId), cost)
			if score > bestScore and canSpend(s, cost[CURRENCY] or 0) and Stocks.canAfford(countryId, cost) then
				bestRegion, bestType, bestScore, bestCost = regionId, typeId, score, cost
			end
		end
	end
	if bestRegion then
		local regionId, typeId, cost = bestRegion :: string, bestType, bestCost
		local kind = Factories.types[typeId]
		table.insert(actions, {
			kind = "Industrie",
			score = 0.25 + 0.55 * bestScore,
			label = `construit : {kind.icon} {kind.name} ({Regions[regionId].name})`,
			run = function(): boolean
				return canSpend(s, cost[CURRENCY] or 0) and (FactoryService.build(countryId, regionId, typeId))
			end,
		})
	end
end

-- Stock que l'IA de ce pays veut garder pour une ressource (fonctionnement, précaution, projets)
function EconomyAI.reserveOf(countryId: string, resourceId: string, P: any): number
	return reserve(situation(countryId, P), resourceId)
end

-- Actions économiques possibles pour un pays, avec leur score
function EconomyAI.actions(countryId: string, profile: Profile, P: any): { Action }
	local actions: { Action } = {}
	local s = situation(countryId, P)
	if #s.regions == 0 then
		return actions
	end
	sellActions(countryId, s, profile, actions)
	buyActions(countryId, s, profile, actions)
	factoryActions(countryId, s, actions)
	return actions
end

return EconomyAI
