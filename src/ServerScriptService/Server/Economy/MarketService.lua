--!strict
-- Marché mondial : achat et vente au prix du marché, qui suit l'offre et la demande.
-- Chaque achat fait monter le prix, chaque vente le fait baisser (voir MarketMath) ; toutes les
-- Market.priceInterval secondes, les prix reviennent vers leur prix de base et bougent un peu.
-- État publié dans ReplicatedStorage.EtatMonde.Marche :
--   <ressource>             prix courant (crédits par unité)
--   Historique_<ressource>  derniers prix « 12.10,12.31,... » pour le graphique
--   RatioVente              part de la valeur reversée à la vente
--   Volume_<ressource>      unités échangées pendant la dernière minute (Bourse mondiale)
-- Position de chaque pays (achats au marché, pour la spéculation) : attributs « PositionQ_<ressource> »
-- (quantité achetée encore détenue) et « PositionP_<ressource> » (prix moyen payé) de EtatMonde.Pays.<code>.
-- Remotes.Acheter(ressource, quantité, coûtMax) et Remotes.Vendre(ressource, quantité, recetteMin) :
-- si le prix a bougé au-delà de ce que le joueur a vu, l'échange est refusé.
-- Un pays en guerre paie des frais de transport (Trade.marketWarFee) : achats plus chers, ventes moins payées.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Market = require(Config:WaitForChild("Market")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local MarketMath = require(Shared:WaitForChild("MarketMath")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local Trade = require(Config:WaitForChild("Trade")) :: any
local Council = require(Config:WaitForChild("Council")) :: any
local CouncilState = require(Shared:WaitForChild("CouncilState")) :: any
local Server = script.Parent.Parent
local CountryAssignment = require(Server:WaitForChild("Session"):WaitForChild("CountryAssignment"))
local PlayStyle = require(Server:WaitForChild("Session"):WaitForChild("PlayStyle"))
local StatsService = require(Server:WaitForChild("Session"):WaitForChild("StatsService"))
local RateLimiter = require(Server:WaitForChild("Util"):WaitForChild("RateLimiter"))
local Stocks = require(script.Parent:WaitForChild("Stocks"))

local CURRENCY: string = Resources.currency.id
local PRICE_MOVED = "Le prix a bougé : vérifie le nouveau prix et réessaie."

local MarketService = {}

local folder: Folder? = nil -- EtatMonde.Marche
local prices: { [string]: number } = {}
local histories: { [string]: { number } } = {}
local volumeNow: { [string]: number } = {} -- unités échangées depuis le dernier recalcul
local volumes: { [string]: { number } } = {} -- par recalcul, sur la dernière minute
local rng = Random.new()

local function round2(x: number): number
	return math.floor(x * 100 + 0.5) / 100
end

local function clampPrice(resourceId: string, price: number): number
	local base = Market.basePrices[resourceId]
	return math.clamp(price, base * Market.minFactor, base * Market.maxFactor)
end

local function publishPrice(resourceId: string)
	if folder then
		folder:SetAttribute(resourceId, round2(prices[resourceId]))
	end
end

local function publishHistory(resourceId: string)
	if folder then
		local parts = {}
		for _, value in histories[resourceId] do
			table.insert(parts, string.format("%.2f", value))
		end
		folder:SetAttribute("Historique_" .. resourceId, table.concat(parts, ","))
	end
end

function MarketService.price(resourceId: string): number?
	return prices[resourceId]
end

local function checkOrder(resourceId: unknown, quantity: unknown): (boolean, string?)
	if typeof(resourceId) ~= "string" or not Resources.list[resourceId] or not prices[resourceId] then
		return false, "Ressource inconnue."
	end
	if typeof(quantity) ~= "number" or quantity ~= quantity or quantity % 1 ~= 0 then
		return false, "Quantité invalide."
	end
	if quantity < 1 or quantity > Market.maxQuantity then
		return false, `La quantité doit être entre 1 et {Market.maxQuantity}.`
	end
	return true, nil
end

-- Achat : on paie en crédits, on reçoit la ressource, le prix monte.
-- maxCost (facultatif) : coût vu par le joueur ; au-delà, l'achat est refusé.
function MarketService.buy(countryId: string, resourceId: unknown, quantity: unknown, maxCost: unknown): (boolean, string?)
	local ok, err = checkOrder(resourceId, quantity)
	if not ok then
		return false, err
	end
	local id, amount = resourceId :: string, quantity :: number
	local liquidity = Market.liquidity[id]
	local cost = MarketMath.buyCost(prices[id], amount, liquidity)
	if #DiplomacyState.enemiesOf(countryId) > 0 then
		cost = MarketMath.withWarFee(cost, Trade.marketWarFee, true)
	end
	if CouncilState.sanctioned(countryId) then
		cost = MarketMath.withWarFee(cost, Council.sanctionFee, true) -- sanctions du Conseil mondial
	end
	if maxCost ~= nil and (typeof(maxCost) ~= "number" or cost > maxCost) then
		return false, PRICE_MOVED
	end
	if not Stocks.spend(countryId, { [CURRENCY] = cost }) then
		return false, "Pas assez de crédits."
	end
	Stocks.add(countryId, id, amount)
	prices[id] = clampPrice(id, MarketMath.priceAfterBuy(prices[id], amount, liquidity))
	publishPrice(id)
	volumeNow[id] = (volumeNow[id] or 0) + amount
	-- position : quantité achetée et prix moyen payé (pour suivre la spéculation)
	local country = folder and folder.Parent and folder.Parent:FindFirstChild("Pays") and folder.Parent.Pays:FindFirstChild(countryId)
	if country then
		local held = (country:GetAttribute("PositionQ_" .. id) :: number?) or 0
		local average = (country:GetAttribute("PositionP_" .. id) :: number?) or 0
		country:SetAttribute("PositionQ_" .. id, held + amount)
		country:SetAttribute("PositionP_" .. id, round2((held * average + cost) / (held + amount)))
	end
	return true, nil
end

-- Vente : on cède la ressource, on reçoit des crédits, le prix baisse.
-- minRevenue (facultatif) : recette vue par le joueur ; en dessous, la vente est refusée.
function MarketService.sell(countryId: string, resourceId: unknown, quantity: unknown, minRevenue: unknown): (boolean, string?)
	local ok, err = checkOrder(resourceId, quantity)
	if not ok then
		return false, err
	end
	local id, amount = resourceId :: string, quantity :: number
	local liquidity = Market.liquidity[id]
	local revenue = MarketMath.sellRevenue(prices[id], amount, liquidity, Market.sellRatio)
	if #DiplomacyState.enemiesOf(countryId) > 0 then
		revenue = MarketMath.withWarFee(revenue, Trade.marketWarFee, false)
	end
	if CouncilState.sanctioned(countryId) then
		revenue = MarketMath.withWarFee(revenue, Council.sanctionFee, false)
	end
	if minRevenue ~= nil and (typeof(minRevenue) ~= "number" or revenue < minRevenue) then
		return false, PRICE_MOVED
	end
	if not Stocks.spend(countryId, { [id] = amount }) then
		return false, "Pas assez de stock à vendre."
	end
	Stocks.add(countryId, CURRENCY, revenue)
	StatsService.recordSale(countryId, id, amount, revenue)
	prices[id] = clampPrice(id, MarketMath.priceAfterSell(prices[id], amount, liquidity))
	publishPrice(id)
	volumeNow[id] = (volumeNow[id] or 0) + amount
	-- la position diminue d'autant (au même prix moyen)
	local country = folder and folder.Parent and folder.Parent:FindFirstChild("Pays") and folder.Parent.Pays:FindFirstChild(countryId)
	if country then
		local held = (country:GetAttribute("PositionQ_" .. id) :: number?) or 0
		if held > 0 then
			country:SetAttribute("PositionQ_" .. id, math.max(0, held - amount))
		end
	end
	return true, nil
end

-- Choc sur un prix (résolution du Conseil mondial, événement mondial) : prix x factor
function MarketService.shock(resourceId: string, factor: number)
	if prices[resourceId] then
		prices[resourceId] = clampPrice(resourceId, prices[resourceId] * factor)
		publishPrice(resourceId)
	end
end

-- Recalcul périodique : retour vers le prix de base + petite variation au hasard
local function tick(publish: boolean)
	for id, base in Market.basePrices do
		local p = prices[id]
		p += (base - p) * Market.reversion
		p *= 1 + rng:NextNumber(-1, 1) * Market.volatility * math.sqrt(3)
		p = clampPrice(id, p)
		prices[id] = p
		local history = histories[id]
		table.insert(history, p)
		if #history > Market.historyLength then
			table.remove(history, 1)
		end
		-- volume de la dernière minute
		local traded = volumes[id] or {}
		volumes[id] = traded
		table.insert(traded, volumeNow[id] or 0)
		volumeNow[id] = 0
		if #traded > Market.variationPoints then
			table.remove(traded, 1)
		end
		if publish then
			publishPrice(id)
			publishHistory(id)
			if folder then
				local total = 0
				for _, v in traded do
					total += v
				end
				folder:SetAttribute("Volume_" .. id, total)
			end
		end
	end
end

-- Nouvelle partie : prix de départ, historique simulé, positions des pays effacées
function MarketService.reset()
	for id, base in Market.basePrices do
		prices[id] = base
		histories[id] = {}
		volumeNow[id] = 0
		volumes[id] = {}
	end
	for _ = 1, Market.historyLength do
		tick(false)
	end
	for id in Market.basePrices do
		publishPrice(id)
		publishHistory(id)
		if folder then
			folder:SetAttribute("Volume_" .. id, 0)
		end
	end
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	for _, country in (if pays then pays:GetChildren() else {}) do
		for id in Market.basePrices do
			country:SetAttribute("PositionQ_" .. id, nil)
			country:SetAttribute("PositionP_" .. id, nil)
		end
	end
end

-- À appeler après Stocks.init()
function MarketService.init()
	local marche = Instance.new("Folder")
	marche.Name = "Marche"
	marche:SetAttribute("RatioVente", Market.sellRatio)
	folder = marche

	for id, base in Market.basePrices do
		prices[id] = base
		histories[id] = {}
	end
	-- historique de départ (10 minutes simulées) pour que le graphique vive dès le lancement
	for _ = 1, Market.historyLength do
		tick(false)
	end
	for id in Market.basePrices do
		publishPrice(id)
		publishHistory(id)
	end
	marche.Parent = ReplicatedStorage:WaitForChild("EtatMonde")

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local limiter = RateLimiter.new(0.2)
	local function remote(name: string, action: (string, unknown, unknown, unknown) -> (boolean, string?))
		local r = Instance.new("RemoteFunction")
		r.Name = name
		r.OnServerInvoke = function(player: Player, resourceId: unknown, quantity: unknown, limit: unknown)
			if not limiter:allow(player) then
				return false, "Doucement, réessaie dans un instant."
			end
			local countryId = CountryAssignment.getCountryOf(player)
			if not countryId then
				return false, "Choisis d'abord un pays."
			end
			local ok, message = action(countryId, resourceId, quantity, limit)
			if ok then
				PlayStyle.recordAction(countryId, name, resourceId, quantity)
			end
			return ok, message
		end
		r.Parent = remotes
	end
	remote("Acheter", MarketService.buy)
	remote("Vendre", MarketService.sell)

	task.spawn(function()
		while true do
			task.wait(Market.priceInterval)
			tick(true)
		end
	end)
end

return MarketService
