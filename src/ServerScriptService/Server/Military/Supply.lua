--!strict
-- Ravitaillement des divisions (SYSTEME_MILITAIRE.md, 5.6) :
--   réseau : les régions reliées à une source (la capitale du pays ou celle d'un allié ; capitale
--     perdue : ses ports) par une chaîne de régions amies (les siennes et celles de ses alliés),
--     par la terre, ou par la mer d'un port ami à un autre ; une division hors du réseau est
--     « encerclée » (attribut Encerclee) ;
--   réserve : une division coupée vit sur sa réserve (Config/Military.supply.reserveSeconds), puis
--     n'est plus ravitaillée (Ravitaillee = false) : attaque et défense x0,5 (Combat), organisation
--     qui ne remonte plus (Divisions) et attrition (perte de force) ;
--   capacité : chaque région entretient quelques divisions (terrain, capitale, port, fortifications) ;
--     au-delà, attrition aussi ;
--   consommation : toutes les consumptionSeconds, chaque pays paie la nourriture et le pétrole de
--     ses divisions (Config/Divisions.upkeep) ; sans pétrole, blindés et motorisés se traînent et
--     attaquent moitié moins (Combat, Movement) ; sans nourriture, l'organisation ne remonte plus
--     (attributs PenurieNourriture et PenuriePetrole de EtatMonde.Pays.<pays>) ;
--   renforts : hors bataille et ravitaillée, une division regagne de la force
--     (Config/Military.reinforcePerMinute), payée par le pays (reinforceCostFactor x son coût) ;
--     un pays qui n'a pas pu tout payer n'envoie plus de renforts jusqu'au paiement suivant.
-- Les fonctions network et capacity sont pures (tests/Supply.spec.luau).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Military = require(Config:WaitForChild("Military")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local RegionTerrain = require(Config:WaitForChild("RegionTerrain")) :: any
local Terrain = require(Config:WaitForChild("Terrain")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local DiplomacyService = require(Server:WaitForChild("Politics"):WaitForChild("DiplomacyService"))
local Stability = require(Server:WaitForChild("Politics"):WaitForChild("Stability"))
local Stocks = require(Server:WaitForChild("Economy"):WaitForChild("Stocks"))
local Divisions = require(script.Parent:WaitForChild("Divisions"))
local Armies = require(script.Parent:WaitForChild("Armies"))
local AirSupport = require(script.Parent:WaitForChild("AirSupport"))

local SAFETY_REFRESH = 60 -- secondes : tous les réseaux sont recalculés de temps en temps, par précaution
local REBUILD_BUDGET = 15 -- réseaux recalculés au plus à chaque mise à jour (la charge est étalée)
local REFILL_RATE = 2 -- une division ravitaillée regagne sa réserve deux fois plus vite qu'elle ne la vide
local FORCE_PER_CASUALTY = 20 -- comme BattleManager : 20 points de force perdus = 1 « unité » pour la stabilité

local Supply = {}

local networks: { [string]: { [string]: boolean } } = {} -- pays -> régions ravitaillées
local dirty: { [string]: boolean } = {} -- pays dont le réseau est à recalculer
local safetyClock = 0
local consumptionClock = 0
local debts: { [string]: { [string]: number } } = {} -- pays -> ressource -> quantité due
local broke: { [string]: boolean } = {} -- pays qui n'a pas pu tout payer : pas de renforts

-- Régions atteignables depuis les sources par les régions praticables (pur : seulement la carte).
-- Si le réseau touche la mer (un de ses ports), tous les ports praticables sont ravitaillés par
-- bateau, puis les régions reliées à ces ports (territoires d'outre-mer, têtes de pont).
function Supply.network(sources: { string }, passable: (regionId: string) -> boolean): { [string]: boolean }
	local reached: { [string]: boolean } = {}
	local queue = {}
	for _, regionId in sources do
		if Regions[regionId] and not reached[regionId] then
			reached[regionId] = true
			table.insert(queue, regionId)
		end
	end
	local head = 1
	local seaDone = false
	local function bySea()
		-- le réseau a un port : les autres ports praticables sont ravitaillés par la mer
		seaDone = true
		local coastal = false
		for regionId in reached do
			if Regions[regionId].port then
				coastal = true
				break
			end
		end
		if not coastal then
			return
		end
		for regionId, region in Regions do
			if region.port and not reached[regionId] and passable(regionId) then
				reached[regionId] = true
				table.insert(queue, regionId)
			end
		end
	end
	while head <= #queue or not seaDone do
		if head > #queue then
			bySea()
			continue
		end
		local current = queue[head]
		head += 1
		for _, link in Regions[current].neighbors do
			local nextId = link.region
			if reached[nextId] or not Regions[nextId] or not passable(nextId) then
				continue
			end
			-- par la mer : seulement d'un port à un autre
			if link.bySea and not (Regions[current].port and Regions[nextId].port) then
				continue
			end
			reached[nextId] = true
			table.insert(queue, nextId)
		end
	end
	return reached
end

-- Divisions qu'une région entretient sans attrition (pur)
function Supply.capacity(regionId: string, isCapital: boolean, fortification: number): number
	local S = Military.supply
	local terrain = Terrain.types[RegionTerrain.terrain[regionId] or Terrain.default] or Terrain.types[Terrain.default]
	local region = Regions[regionId]
	return terrain.supply + (if isCapital then S.capitalBonus else 0) + (if region and region.port then S.portBonus else 0)
		+ fortification * S.fortificationBonus
end

local function friendly(countryId: string, owner: string?): boolean
	return owner ~= nil and (owner == countryId or DiplomacyService.areAllies(countryId, owner))
end

-- Sources d'un pays : sa capitale et celles de ses alliés ; capitale perdue : ses ports, sinon ses régions
local function sourcesOf(countryId: string): { string }
	local sources = {}
	if RegionService.getOwner(countryId) == countryId then
		table.insert(sources, countryId)
	end
	for _, ally in DiplomacyService.alliesOf(countryId) do
		if RegionService.getOwner(ally) == ally then
			table.insert(sources, ally)
		end
	end
	if RegionService.getOwner(countryId) ~= countryId then
		local owned, ports = {}, {}
		for regionId, region in Regions do
			if RegionService.getOwner(regionId) == countryId then
				table.insert(owned, regionId)
				if region.port then
					table.insert(ports, regionId)
				end
			end
		end
		for _, regionId in (if #ports > 0 then ports else owned) do
			table.insert(sources, regionId)
		end
	end
	return sources
end

local function buildNetwork(countryId: string): { [string]: boolean }
	local reached = Supply.network(sourcesOf(countryId), function(regionId: string): boolean
		return friendly(countryId, RegionService.getOwner(regionId))
	end)
	networks[countryId] = reached
	return reached
end

-- Réseau d'un pays (calculé la première fois, puis recalculé quand il est marqué à refaire)
local function networkOf(countryId: string): { [string]: boolean }
	return networks[countryId] or buildNetwork(countryId)
end

-- Le réseau d'un pays et ceux de ses alliés sont à refaire (région prise, alliance changée...)
local function markWithAllies(countryId: string)
	dirty[countryId] = true
	for _, ally in DiplomacyService.alliesOf(countryId) do
		dirty[ally] = true
	end
end

local function countryFolder(countryId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
end

local function regionFolder(regionId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local regions = state and state:FindFirstChild("Regions")
	return regions and regions:FindFirstChild(regionId)
end

-- Dette d'un pays (fractions de ressources pas encore payées : les stocks sont des nombres entiers)
local function owe(countryId: string, resourceId: string, amount: number)
	local debt = debts[countryId] or {}
	debts[countryId] = debt
	debt[resourceId] = (debt[resourceId] or 0) + amount
end

-- Nourriture et pétrole des divisions, et renforts, payés pays par pays (parties entières dues)
local function consume(seconds: number)
	for _, d in Divisions.all() do
		if Divisions.isTraining(d) then
			continue
		end
		local countryId = d:GetAttribute("Proprietaire") :: string
		local thrift = 1 - Armies.bonus(d, "upkeep") -- général « Logisticien » : moins de consommation
		for resourceId, perMinute in Divisions.typeOf(d).upkeep do
			owe(countryId, resourceId, perMinute * seconds / 60 * thrift)
		end
	end
	table.clear(broke)
	for countryId, debt in debts do
		local shortages: { [string]: boolean } = {}
		for resourceId, amount in debt do
			local due = math.floor(amount)
			if due <= 0 then
				continue
			end
			local have = Stocks.get(countryId, resourceId)
			local paid = math.min(have, due)
			Stocks.add(countryId, resourceId, -paid)
			debt[resourceId] = amount - due -- ce qui n'a pas pu être payé est perdu (pénurie)
			if paid < due then
				shortages[resourceId] = true
				broke[countryId] = true -- plus de renforts jusqu'au prochain paiement
			end
		end
		local folder = countryFolder(countryId)
		if folder then
			folder:SetAttribute("PenurieNourriture", if shortages.Nourriture then true else nil)
			folder:SetAttribute("PenuriePetrole", if shortages.Petrole then true else nil)
		end
	end
end

local function update(dt: number, _now: number)
	-- réseaux à refaire : quelques-uns à chaque fois, pour ne pas ralentir le serveur
	safetyClock += dt
	if safetyClock >= SAFETY_REFRESH then
		safetyClock = 0
		for countryId in networks do
			dirty[countryId] = true
		end
	end
	local budget = REBUILD_BUDGET
	for countryId in dirty do
		if budget <= 0 then
			break
		end
		dirty[countryId] = nil
		buildNetwork(countryId)
		budget -= 1
	end
	consumptionClock += dt
	if consumptionClock >= Military.supply.consumptionSeconds then
		consume(consumptionClock)
		consumptionClock = 0
	end

	local S = Military.supply
	-- divisions à l'arrêt par région (elles se partagent la capacité de la région) ; l'armée d'un
	-- général a sa propre logistique : elle n'y compte pas (mais elle doit rester reliée au réseau)
	local present: { [string]: number } = {}
	for _, d in Divisions.all() do
		if not Divisions.isMoving(d) and not Divisions.isAbsorbed(d) then
			local regionId = d:GetAttribute("Region") :: string
			present[regionId] = (present[regionId] or 0) + 1
		end
	end
	local casualties: { [string]: number } = {}
	for _, d in Divisions.all() do
		if Divisions.isTraining(d) then
			continue
		end
		local countryId = d:GetAttribute("Proprietaire") :: string
		local regionId = d:GetAttribute("Region") :: string
		local connected = networkOf(countryId)[regionId] == true
		local reserve = (d:GetAttribute("Reserve") :: number?) or S.reserveSeconds
		if connected then
			reserve = math.min(S.reserveSeconds, reserve + dt * REFILL_RATE)
		else
			reserve = math.max(0, reserve - dt)
		end
		local supplied = reserve > 0
		if d:GetAttribute("Encerclee") ~= (not connected or nil) then
			d:SetAttribute("Encerclee", if connected then nil else true)
		end
		if d:GetAttribute("Ravitaillee") ~= supplied then
			d:SetAttribute("Ravitaillee", supplied)
		end
		-- réserve publiée à la seconde près (moins de messages vers les joueurs)
		local shown = math.ceil(reserve)
		if d:GetAttribute("Reserve") ~= shown then
			d:SetAttribute("Reserve", shown)
		end
		-- attrition : sans ravitaillement, ou dans une région qui ne peut pas entretenir tout le monde
		local attrition = if supplied then 0 else 1
		if not Divisions.isMoving(d) then
			local count = present[regionId] or 0
			local region = regionFolder(regionId)
			local fortification = (region and region:GetAttribute("Fortification") :: number?) or 0
			local capacity = Supply.capacity(regionId, RegionService.getOwner(regionId) == regionId, fortification)
				* (if AirSupport.isBombed(regionId) then Military.air.bombedSupply else 1) -- dépôts bombardés
			if count > capacity then
				attrition += (count - capacity) / count
			end
		end
		local force = (d:GetAttribute("Force") :: number?) or 0
		if attrition > 0 then
			local lost = math.min(force, S.attritionPerMinute / 60 * dt * attrition)
			d:SetAttribute("Force", force - lost)
			casualties[countryId] = (casualties[countryId] or 0) + lost
			if force - lost <= 0 then
				Divisions.destroy(d) -- anéantie par l'attrition
			end
		elseif force < 100 and not Divisions.inBattle(d) and not broke[countryId] then
			-- renforts : la force remonte, aux frais du pays (une part du coût de la division par point)
			-- bonus « Récupération » de son général : plus vite
			local gained = math.min(100 - force, Military.reinforcePerMinute / 60 * dt * (1 + Armies.bonus(d, "recovery")))
			d:SetAttribute("Force", force + gained)
			for resourceId, amount in Divisions.typeOf(d).cost do
				owe(countryId, resourceId, amount * Military.reinforceCostFactor * gained)
			end
		end
	end
	for countryId, lost in casualties do
		Stability.casualties(countryId, lost / FORCE_PER_CASUALTY)
	end
end

-- Nouvelle partie : réseaux à recalculer, plus de pénurie
function Supply.reset()
	table.clear(networks)
	table.clear(dirty)
	table.clear(debts)
	table.clear(broke)
	safetyClock = 0
	consumptionClock = 0
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	for _, folder in (if pays then pays:GetChildren() else {}) do
		folder:SetAttribute("PenurieNourriture", nil)
		folder:SetAttribute("PenuriePetrole", nil)
	end
end

-- À appeler après Divisions.init() ; loop : MilitaryLoop
function Supply.init(loop: any)
	loop.every("ravitaillement", Military.supply.updateSeconds, update)
	-- une région change de mains, une alliance se fait ou se défait : ces réseaux sont à refaire
	RegionService.onOwnerChanged(function(_regionId: string, newOwner: string, oldOwner: string?)
		markWithAllies(newOwner)
		if oldOwner then
			markWithAllies(oldOwner)
		end
	end)
	DiplomacyService.onAlliance(function(_bloc: string, joined: { string })
		for _, countryId in joined do
			markWithAllies(countryId)
		end
	end)
	DiplomacyService.onBetrayal(function(traitor: string, victims: { string })
		dirty[traitor] = true
		for _, countryId in victims do
			markWithAllies(countryId)
		end
	end)
	DiplomacyService.onBlocDissolved(function(_bloc: string, members: { string })
		for _, countryId in members do
			dirty[countryId] = true
		end
	end)
end

return Supply
