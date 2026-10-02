--!strict
-- Divisions terrestres (SYSTEME_MILITAIRE.md, section 3) : création, entraînement, organisation,
-- expérience, renforts, destruction ; divisions de départ de chaque pays. 1 division = 1 modèle 3D.
-- État publié dans ReplicatedStorage.EtatMonde.Divisions.<id> (un dossier par division) :
--   Type, Nom, Proprietaire, Region, Destination ("" à l'arrêt), Depart, Arrivee, Provenance,
--   Itineraire (régions restantes après Destination), Org, OrgMax, Force (0 à 100), Experience,
--   Armee (général qui la commande, "" sans), Controle ("Plan" ou "Manuel"), Retranchement (0 à 1),
--   Ravitaillee, Reserve (secondes de réserve hors ravitaillement), Bataille (bataille en cours),
--   EnLigne (en première ligne de la bataille, sinon en réserve), Entrainement (heure de fin
--   d'entraînement ; absent quand la division est prête)
-- Seul ce module change la région d'une division (setRegion) : il tient l'index par région.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local DivisionConfig = require(Config:WaitForChild("Divisions")) :: any
local Military = require(Config:WaitForChild("Military")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local Stocks = require(Server:WaitForChild("Economy"):WaitForChild("Stocks"))
local PopulationService = require(Server:WaitForChild("Economy"):WaitForChild("PopulationService"))
local BuildingRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BuildingRules")) :: any

local Divisions = {}

local folder: Folder? = nil
local nextId = 0
local numbers: { [string]: { [string]: number } } = {} -- pays -> type -> dernier numéro donné
local byRegion: { [string]: { [Instance]: boolean } } = {}
local arriving: { [string]: { [Instance]: boolean } } = {} -- région -> divisions en route vers elle
local destinationOf: { [Instance]: string } = {}
local entrenching: { [Instance]: number } = {} -- retranchement en cours (valeur exacte, non publiée)
local removedListeners: { (division: Instance) -> () } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function indexAdd(d: Instance, regionId: string)
	local set = byRegion[regionId]
	if not set then
		set = {}
		byRegion[regionId] = set
	end
	set[d] = true
end

local function indexRemove(d: Instance, regionId: unknown)
	if typeof(regionId) == "string" and byRegion[regionId] then
		byRegion[regionId][d] = nil
	end
end

-- Index des divisions en route vers chaque région (suit l'attribut Destination)
local function trackDestination(d: Instance)
	local old = destinationOf[d]
	if old and arriving[old] then
		arriving[old][d] = nil
	end
	destinationOf[d] = nil
	local destination = d:GetAttribute("Destination")
	if d.Parent and typeof(destination) == "string" and destination ~= "" then
		arriving[destination] = arriving[destination] or {}
		arriving[destination][d] = true
		destinationOf[d] = destination
	end
end

local function idNumber(d: Instance): number
	return tonumber(d.Name:match("%d+")) or 0
end

function Divisions.get(id: unknown): Instance?
	return if typeof(id) == "string" and folder then folder:FindFirstChild(id) else nil
end

function Divisions.all(): { Instance }
	return if folder then folder:GetChildren() else {}
end

-- Divisions présentes dans une région (dans l'ordre de création)
function Divisions.inRegion(regionId: string): { Instance }
	local list = {}
	for d in byRegion[regionId] or {} do
		if d.Parent then
			table.insert(list, d)
		end
	end
	table.sort(list, function(a: Instance, b: Instance): boolean
		return idNumber(a) < idNumber(b)
	end)
	return list
end

-- Divisions présentes dans une région, sans tri (plus rapide : pour les calculs de l'IA)
function Divisions.listIn(regionId: string): { Instance }
	local list = {}
	for d in byRegion[regionId] or {} do
		if d.Parent then
			table.insert(list, d)
		end
	end
	return list
end

-- Place occupée dans une région : divisions qui y restent (pas celles qui en partent) et divisions
-- en route vers elle
function Divisions.occupancy(regionId: string): number
	local count = 0
	for d in byRegion[regionId] or {} do
		if d.Parent and d:GetAttribute("Destination") == "" then
			count += 1
		end
	end
	for d in arriving[regionId] or {} do
		if d.Parent then
			count += 1
		end
	end
	return count
end

function Divisions.ofCountry(countryId: string): { Instance }
	local list = {}
	for _, d in Divisions.all() do
		if d:GetAttribute("Proprietaire") == countryId then
			table.insert(list, d)
		end
	end
	return list
end

function Divisions.typeOf(d: Instance): any
	return DivisionConfig.types[d:GetAttribute("Type") :: string] or DivisionConfig.types.Infanterie
end

function Divisions.isTraining(d: Instance): boolean
	return d:GetAttribute("Entrainement") ~= nil
end

function Divisions.isMoving(d: Instance): boolean
	return d:GetAttribute("Destination") ~= ""
end

function Divisions.inBattle(d: Instance): boolean
	return d:GetAttribute("Bataille") ~= nil
end

-- Change la région d'une division (et l'index par région)
function Divisions.setRegion(d: Instance, regionId: string)
	indexRemove(d, d:GetAttribute("Region"))
	d:SetAttribute("Region", regionId)
	indexAdd(d, regionId)
end

-- Palier d'expérience (Config/Military.experience.levels) : nom et bonus de combat
function Divisions.experienceLevel(xp: number): any
	for _, level in Military.experience.levels do
		if xp >= level.min then
			return level
		end
	end
	return Military.experience.levels[#Military.experience.levels]
end

function Divisions.addExperience(d: Instance, amount: number)
	local xp = (d:GetAttribute("Experience") :: number?) or 0
	d:SetAttribute("Experience", math.min(100, xp + amount))
end

-- Nombre de divisions qu'un pays peut avoir (entraînement compris) : selon sa population
-- (Config/Population.divisionsPerMillion)
function Divisions.maxFor(countryId: string): number
	return PopulationService.maxDivisions(countryId)
end

-- Crée une division (sans vérification : déjà faite par l'appelant)
function Divisions.create(countryId: string, typeId: string, regionId: string, trainSeconds: number?): Instance
	local t = DivisionConfig.types[typeId]
	numbers[countryId] = numbers[countryId] or {}
	local number = (numbers[countryId][typeId] or 0) + 1
	numbers[countryId][typeId] = number
	nextId += 1
	local d = Instance.new("Folder")
	d.Name = "D" .. nextId
	d:SetAttribute("Type", typeId)
	d:SetAttribute("Nom", DivisionConfig.fullName(typeId, number))
	d:SetAttribute("Proprietaire", countryId)
	d:SetAttribute("Destination", "")
	d:SetAttribute("Depart", 0)
	d:SetAttribute("Arrivee", 0)
	d:SetAttribute("Provenance", regionId)
	d:SetAttribute("OrgMax", t.org)
	d:SetAttribute("Org", t.org)
	d:SetAttribute("Force", 100)
	d:SetAttribute("Experience", 0)
	d:SetAttribute("Armee", "")
	d:SetAttribute("Controle", "Manuel")
	d:SetAttribute("Retranchement", 0)
	d:SetAttribute("Ravitaillee", true)
	d:SetAttribute("Reserve", Military.supply.reserveSeconds)
	if trainSeconds and trainSeconds > 0 then
		d:SetAttribute("Entrainement", now() + trainSeconds)
	end
	Divisions.setRegion(d, regionId)
	d.Destroying:Connect(function()
		indexRemove(d, d:GetAttribute("Region"))
		local destination = destinationOf[d]
		if destination and arriving[destination] then
			arriving[destination][d] = nil
		end
		destinationOf[d] = nil
		entrenching[d] = nil
	end)
	d:GetAttributeChangedSignal("Destination"):Connect(function()
		trackDestination(d)
	end)
	d.Parent = folder
	return d
end

-- Détruit une division (anéantie, capturée, dissoute)
function Divisions.destroy(d: Instance)
	if not d.Parent then
		return
	end
	for _, listener in removedListeners do
		task.spawn(listener, d)
	end
	indexRemove(d, d:GetAttribute("Region"))
	d:Destroy()
end

-- listener(division) juste avant qu'une division disparaisse
function Divisions.onRemoved(listener: (division: Instance) -> ())
	table.insert(removedListeners, listener)
end

-- Une région change de camp sans bataille (révolte, soulèvement) : les divisions qui n'y sont plus
-- chez elles partent vers une région amie voisine où il reste de la place, sinon elles sont perdues ;
-- puis le pays lève `militia` divisions de milice sur place. friendly(pays) : la région lui est amie
function Divisions.liberate(regionId: string, newOwner: string, militia: number, friendly: (countryId: string, regionId: string) -> boolean)
	for _, d in Divisions.inRegion(regionId) do
		local owner = d:GetAttribute("Proprietaire") :: string
		if friendly(owner, regionId) then
			continue
		end
		local target: string? = nil
		for _, link in Regions[regionId].neighbors do
			if not link.bySea and friendly(owner, link.region) and Divisions.occupancy(link.region) < Military.maxDivisionsPerRegion then
				target = link.region
				break
			end
		end
		if target then
			d:SetAttribute("Destination", "")
			d:SetAttribute("Itineraire", nil)
			Divisions.setRegion(d, target)
		else
			Divisions.destroy(d)
		end
	end
	for _ = 1, militia do
		if Divisions.occupancy(regionId) < Military.maxDivisionsPerRegion then
			Divisions.create(newOwner, "Milice", regionId, 0)
		end
	end
end

-- Recrute une division dans une de ses régions (entraînement, puis prête à servir)
function Divisions.recruit(countryId: string, typeId: unknown, regionId: unknown): (boolean, string?)
	local t = if typeof(typeId) == "string" then DivisionConfig.types[typeId] else nil
	if not t or not t.recruitable then
		return false, "Type de division inconnu."
	end
	if typeof(regionId) ~= "string" or not Regions[regionId] then
		return false, "Région inconnue."
	end
	if RegionService.getOwner(regionId) ~= countryId then
		return false, "On ne recrute que dans ses propres régions."
	end
	-- les divisions se forment dans un camp militaire (onglet Bâtiments) ; ses niveaux vont plus vite
	local camp = BuildingRules.campLevel(regionId)
	if camp <= 0 then
		return false, "Il faut un camp militaire dans cette région pour y former des divisions (onglet Bâtiments)."
	end
	if Divisions.occupancy(regionId) >= Military.maxDivisionsPerRegion then
		return false, `Cette région a déjà {Military.maxDivisionsPerRegion} divisions (maximum).`
	end
	if #Divisions.ofCountry(countryId) >= Divisions.maxFor(countryId) then
		return false, `Ton pays ne peut pas avoir plus de {Divisions.maxFor(countryId)} divisions (il faut plus d'habitants).`
	end
	-- soldats pris aux habitants de la région (Config/Divisions.manpower, en milliers)
	local men = t.manpower or 0
	if PopulationService.of(regionId) < men then
		return false, "Pas assez d'habitants dans cette région pour former cette division."
	end
	if not Stocks.spend(countryId, t.cost) then
		return false, "Pas assez de ressources pour cette division."
	end
	PopulationService.spend(regionId, men)
	Divisions.create(countryId, typeId :: string, regionId, t.trainSeconds * BuildingRules.campFactor(camp))
	return true, nil
end

-- Régions frontalières d'un pays (voisines par la terre d'une région étrangère), les plus exposées d'abord
local function placementOrder(countryId: string, owned: { string }): { string }
	local border, inner = {}, {}
	local exposure: { [string]: number } = {}
	for _, regionId in owned do
		local foreign = 0
		for _, link in Regions[regionId].neighbors do
			local owner = RegionService.getOwner(link.region)
			if not link.bySea and owner and owner ~= countryId then
				foreign += 1
			end
		end
		exposure[regionId] = foreign
		if foreign > 0 then
			table.insert(border, regionId)
		else
			table.insert(inner, regionId)
		end
	end
	table.sort(border, function(a: string, b: string): boolean
		if exposure[a] == exposure[b] then
			return a < b
		end
		return exposure[a] > exposure[b]
	end)
	-- la capitale passe avant les autres régions intérieures
	table.sort(inner, function(a: string, b: string): boolean
		if (a == countryId) ~= (b == countryId) then
			return a == countryId
		end
		return a < b
	end)
	local order = {}
	for _, r in border do
		table.insert(order, r)
	end
	for _, r in inner do
		table.insert(order, r)
	end
	return order
end

-- Divisions de départ : environ une par région, d'abord sur les frontières (Config/Military.starting)
function Divisions.spawnStarting()
	local S = Military.starting
	for countryId in Countries do
		local owned = {}
		for regionId, region in Regions do
			if region.startOwner == countryId then
				table.insert(owned, regionId)
			end
		end
		if #owned == 0 then
			continue
		end
		local count = math.clamp(math.floor(#owned * S.perRegion + 0.5), S.min, S.max)
		-- composition : un peu d'artillerie, de blindés et de motorisés pour les grands pays
		local types = {}
		for _, rule in S.mix do
			if count >= rule.minDivisions then
				for _ = 1, math.floor(count / rule.every) do
					table.insert(types, rule.type)
				end
			end
		end
		while #types < count do
			table.insert(types, "Infanterie")
		end
		local order = placementOrder(countryId, owned)
		for i, typeId in types do
			local regionId = order[(i - 1) % #order + 1]
			if Divisions.occupancy(regionId) < Military.maxDivisionsPerRegion then
				local d = Divisions.create(countryId, typeId, regionId, 0)
				d:SetAttribute("Retranchement", 1) -- en début de partie, elles tiennent déjà leurs positions
			end
		end
	end
end

local function countryFolder(countryId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
end

-- Une division attaque-t-elle une région voisine ? (elle est engagée hors de sa région)
local function attacking(d: Instance): boolean
	local id = d:GetAttribute("Bataille")
	if typeof(id) ~= "string" then
		return false
	end
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local battles = state and state:FindFirstChild("Batailles")
	local battle = battles and battles:FindFirstChild(id)
	return battle ~= nil and battle:GetAttribute("Region") ~= d:GetAttribute("Region")
end

-- Chaque seconde : fin des entraînements, retranchement des divisions immobiles, organisation
-- qui remonte hors combat
local function update(dt: number, t: number)
	for _, d in Divisions.all() do
		local training = d:GetAttribute("Entrainement")
		if typeof(training) == "number" then
			if t >= training then
				d:SetAttribute("Entrainement", nil)
			end
			continue
		end
		-- retranchement : se construit à l'arrêt (même en défendant), perdu dès qu'elle bouge ou
		-- attaque ; publié par paliers de 5 % (moins de messages vers les joueurs)
		local published = (d:GetAttribute("Retranchement") :: number?) or 0
		local progress = entrenching[d] or published
		if published < 1 and not Divisions.isMoving(d) and not attacking(d) then
			progress = math.min(1, math.max(progress, published) + dt / Military.entrenchSeconds)
			entrenching[d] = progress
			local step = math.floor(progress * 20) / 20
			if step > published then
				d:SetAttribute("Retranchement", step)
			end
		else
			entrenching[d] = nil
		end
		if Divisions.inBattle(d) then
			continue
		end
		local org = (d:GetAttribute("Org") :: number?) or 0
		local orgMax = (d:GetAttribute("OrgMax") :: number?) or 0
		-- pas d'organisation qui remonte sans ravitaillement, ni quand le pays manque de nourriture (Supply)
		local country = countryFolder(d:GetAttribute("Proprietaire") :: string)
		local hungry = country ~= nil and country:GetAttribute("PenurieNourriture") == true
		if org < orgMax and d:GetAttribute("Ravitaillee") ~= false and not hungry then
			local rate = if Divisions.isMoving(d) then Military.orgRecoveryMoving else Military.orgRecovery
			d:SetAttribute("Org", math.min(orgMax, org + orgMax * rate * dt))
		end
	end
end

-- Nouvelle partie : plus aucune division, puis les divisions de départ
function Divisions.reset()
	if folder then
		folder:ClearAllChildren()
	end
	table.clear(byRegion)
	table.clear(arriving)
	table.clear(destinationOf)
	table.clear(entrenching)
	table.clear(numbers)
	Divisions.spawnStarting()
end

-- À appeler après RegionService.init() et Stocks.init() ; loop : MilitaryLoop
function Divisions.init(loop: any)
	local divisions = Instance.new("Folder")
	divisions.Name = "Divisions"
	divisions.Parent = ReplicatedStorage:WaitForChild("EtatMonde")
	folder = divisions
	Divisions.spawnStarting()
	loop.every("divisions", 1, update)
end

return Divisions
