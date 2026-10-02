--!strict
-- Bâtiments des régions (Config/Factories, shared/BuildingRules) : construction, amélioration et
-- fonctionnement à chaque cycle de production. Usines (recettes), exploitations (champs de blé,
-- mines, puits) et camps militaires (recrutement, voir Divisions.recruit).
-- État publié dans ReplicatedStorage.EtatMonde.Usines.<id> (un dossier par bâtiment) :
--   Type, Region, Proprietaire (pays qui possède la région), Niveau, Depart (offert au départ),
--   Statut : "Construction" | "Active" | "Partielle" | "Arret" | "Sabotee"
--   FinConstruction (heure serveur), Lots (lots fabriqués au dernier cycle), Manque (ressource manquante)
-- Les joueurs passent par Remotes.ConstruireUsine et Remotes.AmeliorerUsine, validés ici.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Factories = require(Config:WaitForChild("Factories")) :: any
local Recipes = require(Config:WaitForChild("Recipes")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local TechState = require(Shared:WaitForChild("TechState")) :: any
local BuildingRules = require(Shared:WaitForChild("BuildingRules")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local CountryAssignment = require(Server:WaitForChild("Session"):WaitForChild("CountryAssignment"))
local PlayStyle = require(Server:WaitForChild("Session"):WaitForChild("PlayStyle"))
local RateLimiter = require(Server:WaitForChild("Util"):WaitForChild("RateLimiter"))
local Stocks = require(script.Parent:WaitForChild("Stocks"))

local FactoryService = {}

local folder: Folder? = nil -- EtatMonde.Usines
local nextId = 0
local carry: { [string]: { [string]: number } } = {} -- production des exploitations : parts d'unité

local function now(): number
	return workspace:GetServerTimeNow()
end

local function resourceName(id: string): string
	local r = Resources.list[id]
	return if r then r.name else id
end

-- Crée le dossier d'un bâtiment
local function create(countryId: string, regionId: string, typeId: string, buildTime: number, start: boolean?): Folder
	nextId += 1
	local building = Instance.new("Folder")
	building.Name = "U" .. nextId
	building:SetAttribute("Type", typeId)
	building:SetAttribute("Region", regionId)
	building:SetAttribute("Proprietaire", countryId)
	building:SetAttribute("Niveau", 1)
	building:SetAttribute("Statut", if buildTime > 0 then "Construction" else "Active")
	building:SetAttribute("FinConstruction", now() + buildTime)
	building:SetAttribute("Lots", 0)
	building:SetAttribute("Manque", "")
	if start then
		building:SetAttribute("Depart", true)
	end
	building.Parent = folder
	if buildTime > 0 then
		task.delay(buildTime, function()
			if building.Parent then
				building:SetAttribute("Statut", "Active")
			end
		end)
	end
	return building
end

-- Coût du prochain bâtiment de ce type pour ce pays (le prix monte avec le nombre de bâtiments)
function FactoryService.costFor(countryId: string, typeId: string): { [string]: number }
	return BuildingRules.buildCost(typeId, BuildingRules.countBuilt(countryId, RegionService.getOwner))
end

-- Construit un bâtiment (joueurs et IA)
function FactoryService.build(countryId: string, regionId: unknown, factoryType: unknown): (boolean, string?)
	if typeof(regionId) ~= "string" or not Regions[regionId] then
		return false, "Région inconnue."
	end
	if typeof(factoryType) ~= "string" or not Factories.types[factoryType] then
		return false, "Type de bâtiment inconnu."
	end
	if RegionService.getOwner(regionId) ~= countryId then
		return false, "Cette région ne t'appartient pas."
	end
	local here = BuildingRules.inRegion(regionId)
	local slots = BuildingRules.slots(regionId)
	if #here >= slots then
		return false, `Pas plus de {slots} bâtiments dans cette région.`
	end
	local kind = Factories.types[factoryType]
	if kind.camp then
		for _, building in here do
			if building:GetAttribute("Type") == factoryType then
				return false, "Cette région a déjà un camp militaire (améliore-le plutôt)."
			end
		end
	end
	local possible, reason = BuildingRules.canBuildIn(factoryType, regionId)
	if not possible then
		return false, reason
	end
	if not Stocks.spend(countryId, FactoryService.costFor(countryId, factoryType)) then
		return false, "Pas assez de ressources pour construire."
	end
	create(countryId, regionId, factoryType, kind.buildTime)
	return true, nil
end

-- Passe un bâtiment au niveau supérieur
function FactoryService.upgrade(countryId: string, factoryId: unknown): (boolean, string?)
	local factory = if typeof(factoryId) == "string" and folder then folder:FindFirstChild(factoryId) else nil
	if not factory then
		return false, "Bâtiment introuvable."
	end
	local regionId = factory:GetAttribute("Region") :: string
	if RegionService.getOwner(regionId) ~= countryId then
		return false, "Ce bâtiment ne t'appartient pas."
	end
	if factory:GetAttribute("Statut") == "Construction" then
		return false, "Le bâtiment est encore en construction."
	end
	local kind = Factories.types[factory:GetAttribute("Type") :: string]
	local level = factory:GetAttribute("Niveau") :: number
	if level >= kind.maxLevel then
		return false, "Niveau maximum atteint."
	end
	if not Stocks.spend(countryId, kind.upgradeCosts[level + 1]) then
		return false, "Pas assez de ressources pour améliorer."
	end
	factory:SetAttribute("Niveau", level + 1)
	return true, nil
end

-- Exploitation : ajoute sa production (parts d'unité gardées pour le cycle suivant)
local function extract(factory: Instance, owner: string)
	local level = factory:GetAttribute("Niveau") :: number
	local rest = carry[owner] or {}
	carry[owner] = rest
	local gains: { [string]: number } = {}
	for resourceId, amount in BuildingRules.outputs(factory:GetAttribute("Type") :: string, factory:GetAttribute("Region") :: string, level, owner) do
		local exact = amount + (rest[resourceId] or 0)
		gains[resourceId] = math.floor(exact)
		rest[resourceId] = exact - gains[resourceId]
	end
	Stocks.addMany(owner, gains)
	factory:SetAttribute("Lots", level)
	factory:SetAttribute("Manque", "")
	factory:SetAttribute("Statut", "Active")
end

-- Usine : fabrique autant de lots que les stocks le permettent
local function manufacture(factory: Instance, owner: string, kind: any)
	local recipe = Recipes[kind.recipe]
	-- technologie « Usines automatisées » : un lot de plus par usine
	local wanted = (factory:GetAttribute("Niveau") :: number) * (kind.batchesPerLevel or 1) + TechState.extraBatches(owner)
	local batches = wanted
	local missing = ""
	for resourceId, amount in recipe.inputs do
		local possible = math.floor(Stocks.get(owner, resourceId) / amount)
		if possible < batches then
			batches = possible
			missing = resourceId
		end
	end
	if batches > 0 then
		local costs, gains = {}, {}
		for resourceId, amount in recipe.inputs do
			costs[resourceId] = amount * batches
		end
		for resourceId, amount in recipe.outputs do
			gains[resourceId] = amount * batches
		end
		if Stocks.spend(owner, costs) then
			Stocks.addMany(owner, gains)
		else
			batches = 0
		end
	end
	factory:SetAttribute("Lots", batches)
	factory:SetAttribute("Manque", if batches < wanted then resourceName(missing) else "")
	factory:SetAttribute("Statut", if batches == wanted then "Active" elseif batches > 0 then "Partielle" else "Arret")
end

-- Un cycle pour tous les bâtiments en service (appelé par ProductionService)
function FactoryService.process()
	if not folder then
		return
	end
	for _, factory in folder:GetChildren() do
		if factory:GetAttribute("Statut") == "Construction" then
			continue
		end
		-- une région conquise apporte ses bâtiments au conquérant
		local owner = RegionService.getOwner(factory:GetAttribute("Region") :: string)
		if not owner then
			continue
		end
		factory:SetAttribute("Proprietaire", owner)
		-- sabotée par des espions (EspionageService) : arrêtée jusqu'à « SaboteeJusqua »
		local sabotaged = factory:GetAttribute("SaboteeJusqua")
		if typeof(sabotaged) == "number" and sabotaged > workspace:GetServerTimeNow() then
			factory:SetAttribute("Lots", 0)
			factory:SetAttribute("Manque", "sabotage")
			factory:SetAttribute("Statut", "Sabotee")
			continue
		end
		-- arrêtée par un événement mondial (grève, cyberattaque) ou un bombardement : « ArretJusqua »
		local stopped = factory:GetAttribute("ArretJusqua")
		if typeof(stopped) == "number" and stopped > workspace:GetServerTimeNow() then
			factory:SetAttribute("Lots", 0)
			factory:SetAttribute("Manque", tostring(factory:GetAttribute("ArretRaison") or "événement"))
			factory:SetAttribute("Statut", "Arret")
			continue
		end
		local kind = Factories.types[factory:GetAttribute("Type") :: string]
		if not kind then
			continue
		elseif kind.recipe then
			manufacture(factory, owner, kind)
		elseif kind.extracts then
			extract(factory, owner)
		else
			factory:SetAttribute("Statut", "Active") -- camp militaire
		end
	end
end

-- Camps militaires offerts au départ : un dans la capitale de chaque pays
function FactoryService.spawnStarting()
	for countryId in Countries do
		if Regions[countryId] and RegionService.getOwner(countryId) == countryId then
			create(countryId, countryId, "CampMilitaire", 0, true)
		end
	end
end

-- Nouvelle partie : plus aucun bâtiment, sauf les camps de départ
function FactoryService.reset()
	if folder then
		folder:ClearAllChildren()
	end
	table.clear(carry)
	FactoryService.spawnStarting()
end

-- À appeler après Stocks.init() et RegionService.init()
function FactoryService.init()
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local usines = Instance.new("Folder")
	usines.Name = "Usines"
	usines.Parent = state
	folder = usines
	FactoryService.spawnStarting()

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local limiter = RateLimiter.new(0.3)

	local function handle(player: Player, name: string, action: (string) -> (boolean, string?)): (boolean, string?)
		if not limiter:allow(player) then
			return false, "Doucement, réessaie dans un instant."
		end
		local countryId = CountryAssignment.getCountryOf(player)
		if not countryId then
			return false, "Choisis d'abord un pays."
		end
		local ok, message = action(countryId)
		if ok then
			PlayStyle.recordAction(countryId, name)
		end
		return ok, message
	end

	local build = Instance.new("RemoteFunction")
	build.Name = "ConstruireUsine"
	build.OnServerInvoke = function(player: Player, regionId: unknown, factoryType: unknown)
		return handle(player, "ConstruireUsine", function(countryId: string)
			return FactoryService.build(countryId, regionId, factoryType)
		end)
	end
	build.Parent = remotes

	local upgrade = Instance.new("RemoteFunction")
	upgrade.Name = "AmeliorerUsine"
	upgrade.OnServerInvoke = function(player: Player, factoryId: unknown)
		return handle(player, "AmeliorerUsine", function(countryId: string)
			return FactoryService.upgrade(countryId, factoryId)
		end)
	end
	upgrade.Parent = remotes
end

return FactoryService
