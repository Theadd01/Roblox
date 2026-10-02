--!strict
-- Contrats commerciaux entre pays (joueurs et IA) : une ressource livrée à chaque cycle de
-- production, à prix fixe, pendant un nombre de livraisons choisi (Config/Trade).
-- État publié dans ReplicatedStorage.EtatMonde.Contrats.<id> :
--   Vendeur, Acheteur, Ressource, Quantite (par livraison), Prix (par unité), Livraisons, Restantes,
--   ProposePar, Statut (« Propose » | « Actif » | « Bloque » | « Termine » | « Rompu » | « Refuse » | « Expire »),
--   Voie (« Terre » | « Mer »), Frais (part de la valeur payée en plus par l'acheteur),
--   Info (dernière livraison, ou raison d'un blocage ou d'une rupture), Expire (proposition)
-- Routes : par la terre si les deux pays ont une frontière commune, sinon par la mer (un port de
-- chaque côté). Une flotte ennemie dans un port de l'un des deux coupe la route maritime (blocus) ;
-- des combats sur le sol de l'un des deux coupent la route terrestre. En guerre : frais de transport.
-- Guerre ou embargo entre les deux pays : plus de contrat possible, ceux en cours sont rompus.
-- Remotes : ProposerContrat(partenaire, ressource, vendre, quantité, livraisons, facteurPrix),
--           RepondreContrat(id, accepte), AnnulerContrat(id).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Trade = require(Config:WaitForChild("Trade")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Units = require(Config:WaitForChild("Units")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local CouncilState = require(Shared:WaitForChild("CouncilState")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local CountryAssignment = require(Server:WaitForChild("Session"):WaitForChild("CountryAssignment"))
local PlayStyle = require(Server:WaitForChild("Session"):WaitForChild("PlayStyle"))
local StatsService = require(Server:WaitForChild("Session"):WaitForChild("StatsService"))
local RateLimiter = require(Server:WaitForChild("Util"):WaitForChild("RateLimiter"))
local Stocks = require(script.Parent:WaitForChild("Stocks"))
local MarketService = require(script.Parent:WaitForChild("MarketService"))

local CURRENCY: string = Resources.currency.id

local ContractService = {}

local folder: Folder? = nil -- EtatMonde.Contrats
local nextId = 0
local failures: { [Instance]: number } = {}
local proposalListeners: { (contract: Instance) -> () } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function nameOf(countryId: string): string
	return if Countries[countryId] then Countries[countryId].name else countryId
end

local function isOpen(contract: Instance): boolean
	local status = contract:GetAttribute("Statut")
	return status == "Propose" or status == "Actif" or status == "Bloque"
end

-- Contrats proposés ou en cours d'un pays
local function openContractsOf(countryId: string): number
	local count = 0
	if folder then
		for _, contract in folder:GetChildren() do
			if isOpen(contract) and (contract:GetAttribute("Vendeur") == countryId or contract:GetAttribute("Acheteur") == countryId) then
				count += 1
			end
		end
	end
	return count
end

local function ownedRegions(countryId: string): { string }
	local list = {}
	for regionId in Regions do
		if RegionService.getOwner(regionId) == countryId then
			table.insert(list, regionId)
		end
	end
	return list
end

-- Route commerciale entre deux pays : « Terre » (frontière commune), « Mer » (un port de chaque côté) ou nil
function ContractService.route(a: string, b: string): string?
	local regionsA = ownedRegions(a)
	local portA, portB = false, false
	for _, regionId in regionsA do
		portA = portA or Regions[regionId].port ~= nil
		for _, link in Regions[regionId].neighbors do
			if not link.bySea and RegionService.getOwner(link.region) == b then
				return "Terre"
			end
		end
	end
	for _, regionId in ownedRegions(b) do
		portB = portB or Regions[regionId].port ~= nil
	end
	return if portA and portB then "Mer" else nil
end

local function atWarWithAnyone(countryId: string): boolean
	return #DiplomacyState.enemiesOf(countryId) > 0
end

-- Frais de transport d'un contrat (part de la valeur livrée)
local function feeFor(seller: string, buyer: string, way: string): number
	local fee = if way == "Mer" then Trade.seaFee else 0
	if atWarWithAnyone(seller) or atWarWithAnyone(buyer) then
		fee += Trade.warFee
	end
	return fee
end

-- La route est-elle coupée ? (raison, ou nil si elle est ouverte)
local function cutReason(seller: string, buyer: string, way: string): string?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	if way == "Mer" then
		-- blocus : une flotte en guerre avec l'un des deux, à l'arrêt dans un port de l'un des deux
		local armees = state and state:FindFirstChild("Armees")
		for _, force in (if armees then armees:GetChildren() else {}) do
			if Units.kindOf(force) == "Mer" and force:GetAttribute("Destination") == "" then
				local owner = force:GetAttribute("Proprietaire") :: string
				local here = force:GetAttribute("Region") :: string
				local portOwner = RegionService.getOwner(here)
				if (portOwner == seller or portOwner == buyer) and portOwner ~= owner
					and (DiplomacyState.atWar(owner, seller) or DiplomacyState.atWar(owner, buyer)) then
					return `blocus de {Regions[here].name} par {nameOf(owner)}`
				end
			end
		end
	else
		-- combats sur le sol de l'un des deux
		local regions = state and state:FindFirstChild("Regions")
		for _, region in (if regions then regions:GetChildren() else {}) do
			if region:GetAttribute("Bataille") and (region:GetAttribute("Proprietaire") == seller or region:GetAttribute("Proprietaire") == buyer) then
				return `combats en {Regions[region.Name] and Regions[region.Name].name or region.Name}`
			end
		end
	end
	return nil
end

-- Contrat possible entre ces deux pays ? (raison sinon)
local function blocked(seller: string, buyer: string): string?
	if DiplomacyState.atWar(seller, buyer) then
		return "les deux pays sont en guerre"
	end
	if DiplomacyState.hasEmbargo(seller, buyer) then
		return "embargo"
	end
	if CouncilState.sanctioned(seller) or CouncilState.sanctioned(buyer) then
		return "sanctions du Conseil mondial"
	end
	return nil
end

local function finish(contract: Instance, status: string, info: string?)
	contract:SetAttribute("Statut", status)
	if info then
		contract:SetAttribute("Info", info)
	end
	failures[contract] = nil
	task.delay(Trade.resultDelay, function()
		if contract.Parent and not isOpen(contract) then
			contract:Destroy()
		end
	end)
end

local function has(list: { any }, value: any): boolean
	return table.find(list, value) ~= nil
end

-- `proposer` propose un contrat à `partner` : il vend (sell = vrai) ou achète
function ContractService.propose(proposer: string, partner: unknown, resourceId: unknown, sell: unknown, quantity: unknown, deliveries: unknown, priceFactor: unknown): (boolean, string?)
	local f = folder
	if not f then
		return false, "Commerce indisponible."
	end
	if typeof(partner) ~= "string" or not Countries[partner] or partner == proposer then
		return false, "Partenaire inconnu."
	end
	if typeof(resourceId) ~= "string" or not Resources.list[resourceId] then
		return false, "Ressource inconnue."
	end
	if typeof(sell) ~= "boolean" or not has(Trade.quantities, quantity) or not has(Trade.deliveries, deliveries) or not has(Trade.priceFactors, priceFactor) then
		return false, "Contrat invalide."
	end
	local seller = if sell then proposer else partner
	local buyer = if sell then partner else proposer
	local reason = blocked(seller, buyer)
	if reason then
		return false, `Contrat impossible : {reason}.`
	end
	local way = ContractService.route(seller, buyer)
	if not way then
		return false, "Pas de route commerciale : il faut une frontière commune, ou un port de chaque côté."
	end
	if openContractsOf(proposer) >= Trade.maxContracts or openContractsOf(partner) >= Trade.maxContracts then
		return false, `Pas plus de {Trade.maxContracts} contrats par pays.`
	end
	local market = MarketService.price(resourceId :: string)
	if not market then
		return false, "Prix inconnu."
	end
	nextId += 1
	local contract = Instance.new("Folder")
	contract.Name = "C" .. nextId
	contract:SetAttribute("Vendeur", seller)
	contract:SetAttribute("Acheteur", buyer)
	contract:SetAttribute("Ressource", resourceId)
	contract:SetAttribute("Quantite", quantity)
	contract:SetAttribute("Prix", math.max(0.1, math.floor(market * (priceFactor :: number) * 10 + 0.5) / 10))
	contract:SetAttribute("Livraisons", deliveries)
	contract:SetAttribute("Restantes", deliveries)
	contract:SetAttribute("ProposePar", proposer)
	contract:SetAttribute("Voie", way)
	contract:SetAttribute("Frais", feeFor(seller, buyer, way))
	contract:SetAttribute("Statut", "Propose")
	contract:SetAttribute("Info", "")
	contract:SetAttribute("Expire", now() + Trade.proposalDuration)
	contract.Parent = f
	task.delay(Trade.proposalDuration, function()
		if contract.Parent and contract:GetAttribute("Statut") == "Propose" then
			finish(contract, "Expire", "sans réponse")
		end
	end)
	for _, listener in proposalListeners do
		task.spawn(listener, contract)
	end
	return true, nil
end

-- Le partenaire accepte ou refuse une proposition de contrat
function ContractService.respond(countryId: string, contractId: unknown, accept: unknown): (boolean, string?)
	local contract = if folder and typeof(contractId) == "string" then folder:FindFirstChild(contractId) else nil
	if not contract or contract:GetAttribute("Statut") ~= "Propose" then
		return false, "Proposition introuvable."
	end
	local seller, buyer = contract:GetAttribute("Vendeur") :: string, contract:GetAttribute("Acheteur") :: string
	local proposer = contract:GetAttribute("ProposePar")
	if countryId ~= seller and countryId ~= buyer or countryId == proposer then
		return false, "Ce contrat ne t'est pas proposé."
	end
	if accept ~= true then
		finish(contract, "Refuse", nil)
		return true, nil
	end
	local reason = blocked(seller, buyer)
	if reason then
		finish(contract, "Rompu", reason)
		return false, `Contrat impossible : {reason}.`
	end
	contract:SetAttribute("Statut", "Actif")
	contract:SetAttribute("Info", "première livraison au prochain cycle")
	StatsService.recordContract(seller, buyer)
	return true, nil
end

-- Un des deux pays annule un contrat en cours (ou retire sa proposition)
function ContractService.cancel(countryId: string, contractId: unknown): (boolean, string?)
	local contract = if folder and typeof(contractId) == "string" then folder:FindFirstChild(contractId) else nil
	if not contract or not isOpen(contract) then
		return false, "Contrat introuvable."
	end
	if contract:GetAttribute("Vendeur") ~= countryId and contract:GetAttribute("Acheteur") ~= countryId then
		return false, "Ce contrat ne te concerne pas."
	end
	finish(contract, "Rompu", `annulé par {nameOf(countryId)}`)
	return true, nil
end

-- Livraisons : à chaque cycle de production (appelé par ProductionService)
function ContractService.tick()
	if not folder then
		return
	end
	for _, contract in folder:GetChildren() do
		local status = contract:GetAttribute("Statut")
		if status ~= "Actif" and status ~= "Bloque" then
			continue
		end
		local seller, buyer = contract:GetAttribute("Vendeur") :: string, contract:GetAttribute("Acheteur") :: string
		local reason = blocked(seller, buyer)
		if reason then
			finish(contract, "Rompu", reason)
			continue
		end
		local way = contract:GetAttribute("Voie") :: string
		local cut = cutReason(seller, buyer, way)
		if cut then
			contract:SetAttribute("Statut", "Bloque")
			contract:SetAttribute("Info", `route coupée : {cut}`)
			continue
		end
		local resourceId = contract:GetAttribute("Ressource") :: string
		local quantity = contract:GetAttribute("Quantite") :: number
		local value = math.floor(quantity * (contract:GetAttribute("Prix") :: number) + 0.5)
		local fee = feeFor(seller, buyer, way)
		contract:SetAttribute("Frais", fee)
		local total = value + math.ceil(value * fee)
		local missing: string? = nil
		if Stocks.get(seller, resourceId) < quantity then
			missing = `{nameOf(seller)} n'a pas assez de {Resources.list[resourceId].name}`
		elseif Stocks.get(buyer, CURRENCY) < total then
			missing = `{nameOf(buyer)} n'a pas assez de crédits`
		end
		if missing then
			failures[contract] = (failures[contract] or 0) + 1
			contract:SetAttribute("Statut", "Actif")
			if failures[contract] >= Trade.maxFailures then
				finish(contract, "Rompu", missing)
			else
				contract:SetAttribute("Info", `livraison manquée : {missing}`)
			end
			continue
		end
		failures[contract] = 0
		Stocks.add(seller, resourceId, -quantity)
		Stocks.add(buyer, resourceId, quantity)
		Stocks.add(buyer, CURRENCY, -total)
		Stocks.add(seller, CURRENCY, value)
		StatsService.recordSale(seller, resourceId, quantity, value)
		local left = (contract:GetAttribute("Restantes") :: number) - 1
		contract:SetAttribute("Restantes", left)
		contract:SetAttribute("Statut", "Actif")
		contract:SetAttribute("Info", `livré : {quantity} contre {value} crédits` .. (if fee > 0 then ` (+{math.ceil(value * fee)} de frais)` else ""))
		if left <= 0 then
			finish(contract, "Termine", "toutes les livraisons sont faites")
		end
	end
end

-- listener(contrat) : un contrat vient d'être proposé (l'IA y répond)
function ContractService.onProposal(listener: (contract: Instance) -> ())
	table.insert(proposalListeners, listener)
end

-- Nouvelle partie : plus aucun contrat
function ContractService.reset()
	if folder then
		folder:ClearAllChildren()
	end
	table.clear(failures)
end

-- À appeler après Stocks.init() et MarketService.init()
function ContractService.init()
	local contrats = Instance.new("Folder")
	contrats.Name = "Contrats"
	contrats.Parent = ReplicatedStorage:WaitForChild("EtatMonde")
	folder = contrats

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local limiter = RateLimiter.new(0.5)
	local function remote(name: string, action: (string, ...any) -> (boolean, string?))
		local r = Instance.new("RemoteFunction")
		r.Name = name
		r.OnServerInvoke = function(player: Player, ...: any)
			if not limiter:allow(player) then
				return false, "Doucement, réessaie dans un instant."
			end
			local countryId = CountryAssignment.getCountryOf(player)
			if not countryId then
				return false, "Choisis d'abord un pays."
			end
			local ok, message = action(countryId, ...)
			if ok then
				PlayStyle.recordAction(countryId, name)
			end
			return ok, message
		end
		r.Parent = remotes
	end
	remote("ProposerContrat", ContractService.propose)
	remote("RepondreContrat", ContractService.respond)
	remote("AnnulerContrat", ContractService.cancel)
end

return ContractService
