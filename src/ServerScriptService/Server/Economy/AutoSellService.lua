--!strict
-- Commerce automatique (Config/Economy.autoSell), à chaque cycle de production, au prix du marché
-- (MarketService : les prix bougent, frais de guerre et sanctions comptés) :
--   achat : tous les pays (joueurs et IA) achètent ce qui leur manque pour quelques cycles
--     (nourriture des habitants et des divisions, pétrole des divisions, matières des usines),
--     sans descendre sous un seuil de crédits ni payer trop cher ; un joueur peut le couper ;
--   vente : les pays des joueurs vendent ce qui dépasse leur réserve, pour chaque ressource où elle
--     est active (l'IA vend elle-même ses surplus, voir EconomyAI).
-- Réserve de vente = réserve de base + quelques cycles de consommation (plus haute que le stock
-- visé à l'achat : pas d'aller-retour).
-- Réglages : Remotes.VenteAutomatique(ressource, active) -> attribut « VenteAuto_<ressource> » ;
-- Remotes.AchatAutomatique(actif) -> attribut « AchatAutoNourriture ».
-- Publié sur EtatMonde.Pays.<pays> des joueurs : « VentesAuto » et « AchatsAuto » (crédits du dernier
-- cycle), « VentesAutoDetail » et « AchatsAutoDetail » (« Nourriture:15,Petrole:3 »),
-- « ReserveAuto_<ressource> » (stock gardé).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Economy = require(Config:WaitForChild("Economy")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local Market = require(Config:WaitForChild("Market")) :: any
local Factories = require(Config:WaitForChild("Factories")) :: any
local Recipes = require(Config:WaitForChild("Recipes")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local IncomeRules = require(Shared:WaitForChild("IncomeRules")) :: any
local MilitaryMath = require(Shared:WaitForChild("MilitaryMath")) :: any
local PopulationRules = require(Shared:WaitForChild("PopulationRules")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local CountryAssignment = require(Server:WaitForChild("Session"):WaitForChild("CountryAssignment"))
local Divisions = require(Server:WaitForChild("Military"):WaitForChild("Divisions"))
local RateLimiter = require(Server:WaitForChild("Util"):WaitForChild("RateLimiter"))
local Stocks = require(script.Parent:WaitForChild("Stocks"))
local MarketService = require(script.Parent:WaitForChild("MarketService"))
local PopulationService = require(script.Parent:WaitForChild("PopulationService"))

local CURRENCY: string = Resources.currency.id

type Needs = { [string]: { [string]: number } }

local AutoSellService = {}

local function countries(): { Instance }
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return if pays then pays:GetChildren() else {}
end

local function children(name: string): { Instance }
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local folder = state and state:FindFirstChild(name)
	return if folder then folder:GetChildren() else {}
end

local function setIfChanged(folder: Instance, attribute: string, value: any)
	if folder:GetAttribute(attribute) ~= value then
		folder:SetAttribute(attribute, value)
	end
end

-- Consommation d'un cycle de chaque pays : matières de ses usines, entretien de ses divisions
-- (Config/Divisions.upkeep, par minute) et de ses forces aériennes et navales, repas de ses habitants
local function allNeeds(): Needs
	local needs: Needs = {}
	local function add(countryId: unknown, resourceId: string, amount: number)
		if typeof(countryId) ~= "string" or amount <= 0 then
			return
		end
		local need = needs[countryId] or {}
		needs[countryId] = need
		need[resourceId] = (need[resourceId] or 0) + amount
	end
	for _, factory in children("Usines") do
		local regionId = factory:GetAttribute("Region")
		local kind = Factories.types[factory:GetAttribute("Type") :: string]
		local recipe = kind and kind.recipe and Recipes[kind.recipe]
		if typeof(regionId) ~= "string" or not recipe or factory:GetAttribute("Statut") == "Construction" then
			continue
		end
		local lots = ((factory:GetAttribute("Niveau") :: number?) or 1) * (kind.batchesPerLevel or 1)
		for resourceId, amount in recipe.inputs do
			add(RegionService.getOwner(regionId), resourceId, amount * lots)
		end
	end
	local minutes = Economy.productionInterval / 60
	for _, d in Divisions.all() do
		for resourceId, perMinute in Divisions.typeOf(d).upkeep do
			add(d:GetAttribute("Proprietaire"), resourceId, perMinute * minutes)
		end
	end
	for _, army in children("Armees") do
		for resourceId, amount in MilitaryMath.upkeep(army) do
			add(army:GetAttribute("Proprietaire"), resourceId, amount)
		end
	end
	-- habitants : un seul passage sur les régions
	local people: { [string]: number } = {}
	for regionId in Regions do
		local owner = RegionService.getOwner(regionId)
		if owner then
			people[owner] = (people[owner] or 0) + PopulationService.of(regionId)
		end
	end
	for countryId, count in people do
		add(countryId, "Nourriture", PopulationRules.food(count))
	end
	return needs
end

-- Achat de ce qui manque pour `buyCycles` cycles de consommation, sans descendre sous `creditFloor`
-- ni payer plus de `maxBuyPrice` fois le prix de base ; renvoie (crédits dépensés, détail)
local function buyNeeds(countryId: string, need: { [string]: number }): (number, { string })
	local A = Economy.autoSell
	local spent = 0
	local bought: { string } = {}
	for _, resourceId in Resources.order do
		local perCycle = need[resourceId] or 0
		local missing = math.min(math.ceil(perCycle * A.buyCycles) - Stocks.get(countryId, resourceId), Market.maxQuantity)
		local price = MarketService.price(resourceId) or 0
		if missing < 1 or price <= 0 or price > Market.basePrices[resourceId] * A.maxBuyPrice then
			continue
		end
		-- marge de 20 % : le prix monte pendant l'achat, et la guerre ajoute des frais
		local affordable = math.floor((Stocks.get(countryId, CURRENCY) - A.creditFloor) / (price * 1.2))
		local amount = math.min(missing, affordable)
		if amount < 1 then
			continue
		end
		local before = Stocks.get(countryId, CURRENCY)
		if MarketService.buy(countryId, resourceId, amount) then
			spent += before - Stocks.get(countryId, CURRENCY)
			table.insert(bought, `{resourceId}:{amount}`)
		end
	end
	return spent, bought
end

-- Vente de ce qui dépasse la réserve (ressources où la vente automatique est active) ;
-- renvoie (crédits gagnés, détail)
local function sellSurplus(folder: Instance, need: { [string]: number }): (number, { string })
	local countryId = folder.Name
	local earned = 0
	local sold: { string } = {}
	for _, resourceId in Resources.order do
		local reserve = IncomeRules.reserve(resourceId, need[resourceId] or 0)
		setIfChanged(folder, "ReserveAuto_" .. resourceId, reserve)
		if not IncomeRules.autoSellEnabled(folder, resourceId) then
			continue
		end
		local amount = IncomeRules.surplus(Stocks.get(countryId, resourceId), reserve, Market.maxQuantity)
		if amount <= 0 then
			continue
		end
		local before = Stocks.get(countryId, CURRENCY)
		if MarketService.sell(countryId, resourceId, amount) then
			earned += Stocks.get(countryId, CURRENCY) - before
			table.insert(sold, `{resourceId}:{amount}`)
		end
	end
	return earned, sold
end

-- Un cycle de commerce automatique pour tous les pays
function AutoSellService.tick()
	local needs = allNeeds()
	for _, folder in countries() do
		local countryId = folder.Name
		local need = needs[countryId] or {}
		local ai = CountryAssignment.isAIControlled(countryId)
		-- achats d'abord : l'IA achète toujours ce qui manque, un joueur peut le couper
		local spent, bought = 0, {}
		if ai or IncomeRules.autoBuyEnabled(folder) then
			spent, bought = buyNeeds(countryId, need)
		end
		if ai then
			-- l'IA vend elle-même ses surplus (EconomyAI) ; rien à afficher
			setIfChanged(folder, "VentesAuto", nil)
			setIfChanged(folder, "VentesAutoDetail", nil)
			setIfChanged(folder, "AchatsAuto", nil)
			setIfChanged(folder, "AchatsAutoDetail", nil)
			continue
		end
		local earned, sold = sellSurplus(folder, need)
		setIfChanged(folder, "AchatsAuto", spent)
		setIfChanged(folder, "AchatsAutoDetail", table.concat(bought, ","))
		setIfChanged(folder, "VentesAuto", earned)
		setIfChanged(folder, "VentesAutoDetail", table.concat(sold, ","))
	end
end

-- Efface les réglages et les montants affichés d'un pays (nouvelle partie, joueur parti)
local function clear(folder: Instance)
	for _, resourceId in Resources.order do
		folder:SetAttribute(IncomeRules.autoSellAttribute(resourceId), nil)
		folder:SetAttribute("ReserveAuto_" .. resourceId, nil)
	end
	for _, attribute in { "VentesAuto", "VentesAutoDetail", "AchatAutoNourriture", "AchatsAuto", "AchatsAutoDetail" } do
		folder:SetAttribute(attribute, nil)
	end
end

function AutoSellService.reset()
	for _, folder in countries() do
		clear(folder)
	end
end

local function folderOf(countryId: string): Instance?
	for _, folder in countries() do
		if folder.Name == countryId then
			return folder
		end
	end
	return nil
end

-- À appeler après CountryAssignment.init() (dossier Remotes) et MarketService.init()
function AutoSellService.init()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local limiter = RateLimiter.new(0.2)
	-- vérifications communes : rythme, pays du joueur
	local function countryOf(player: Player): (Instance?, string?)
		if not limiter:allow(player) then
			return nil, "Doucement, réessaie dans un instant."
		end
		local countryId = CountryAssignment.getCountryOf(player)
		local folder = countryId and folderOf(countryId)
		if not folder then
			return nil, "Choisis d'abord un pays."
		end
		return folder, nil
	end

	local sellRemote = Instance.new("RemoteFunction")
	sellRemote.Name = "VenteAutomatique"
	sellRemote.OnServerInvoke = function(player: Player, resourceId: unknown, enabled: unknown): (boolean, string?)
		local folder, problem = countryOf(player)
		if not folder then
			return false, problem
		end
		if typeof(resourceId) ~= "string" or not Resources.list[resourceId] then
			return false, "Ressource inconnue."
		end
		if typeof(enabled) ~= "boolean" then
			return false, "Réglage invalide."
		end
		folder:SetAttribute(IncomeRules.autoSellAttribute(resourceId), enabled)
		return true, nil
	end
	sellRemote.Parent = remotes

	local buyRemote = Instance.new("RemoteFunction")
	buyRemote.Name = "AchatAutomatique"
	buyRemote.OnServerInvoke = function(player: Player, enabled: unknown): (boolean, string?)
		local folder, problem = countryOf(player)
		if not folder then
			return false, problem
		end
		if typeof(enabled) ~= "boolean" then
			return false, "Réglage invalide."
		end
		folder:SetAttribute("AchatAutoNourriture", enabled)
		return true, nil
	end
	buyRemote.Parent = remotes

	-- le pays d'un joueur qui part retrouve les réglages de départ (pour le prochain joueur)
	CountryAssignment.onReleased(function(_player: Player, countryId: string)
		local folder = folderOf(countryId)
		if folder then
			clear(folder)
		end
	end)
end

return AutoSellService
