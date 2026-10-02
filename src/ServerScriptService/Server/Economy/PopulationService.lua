--!strict
-- Population (Config/Population, shared/PopulationRules) : habitants de chaque région (attribut
-- « Population » de EtatMonde.Regions.<région>, en milliers). À chaque cycle de production, la
-- population de chaque pays mange (nourriture du pays), puis grandit si elle a mangé à sa faim
-- (selon la stabilité) ou diminue en cas de famine. Elle fournit les soldats (Divisions.recruit).
-- Une région conquise garde ses habitants : ils passent au conquérant.
-- Publié sur EtatMonde.Pays.<pays> : « Population » (milliers), « Croissance » (milliers gagnés ou
-- perdus au dernier cycle), « Famine » (vrai si la nourriture a manqué), « DivisionsMax ».
-- Pas de require de Stability (qui dépend des divisions) : la stabilité est lue dans l'attribut
-- « Stabilite » du pays.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local PopulationRules = require(Shared:WaitForChild("PopulationRules")) :: any
local StabilityRules = require(Shared:WaitForChild("StabilityRules")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local Stocks = require(script.Parent:WaitForChild("Stocks"))

local PopulationService = {}

local regionFolders: { [string]: Instance } = {}
local foodCarry: { [string]: number } = {} -- parts de nourriture gardées pour le cycle suivant

local function state(): Instance?
	return ReplicatedStorage:FindFirstChild("EtatMonde")
end

local function regionFolder(regionId: string): Instance?
	local cached = regionFolders[regionId]
	if cached and cached.Parent then
		return cached
	end
	local s = state()
	local regions = s and s:FindFirstChild("Regions")
	local folder = regions and regions:FindFirstChild(regionId)
	if folder then
		regionFolders[regionId] = folder
	end
	return folder
end

local function countryFolder(countryId: string): Instance?
	local s = state()
	local pays = s and s:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
end

local function setIfChanged(folder: Instance, attribute: string, value: any)
	if folder:GetAttribute(attribute) ~= value then
		folder:SetAttribute(attribute, value)
	end
end

-- Habitants d'une région (milliers)
function PopulationService.of(regionId: string): number
	local folder = regionFolder(regionId)
	local value = folder and folder:GetAttribute("Population")
	return if typeof(value) == "number" then value else 0
end

local function set(regionId: string, people: number)
	local folder = regionFolder(regionId)
	if folder then
		folder:SetAttribute("Population", math.floor(math.max(0, people) * 10 + 0.5) / 10)
	end
end

-- Habitants d'un pays (milliers) : ses régions actuelles, conquises comprises
function PopulationService.total(countryId: string): number
	local total = 0
	for regionId in Regions do
		if RegionService.getOwner(regionId) == countryId then
			total += PopulationService.of(regionId)
		end
	end
	return total
end

-- Divisions qu'un pays peut avoir (d'après sa population)
function PopulationService.maxDivisions(countryId: string): number
	return PopulationRules.maxDivisions(PopulationService.total(countryId))
end

local function publish(countryId: string, people: number, change: number?)
	local folder = countryFolder(countryId)
	if not folder then
		return
	end
	setIfChanged(folder, "Population", math.floor(people + 0.5))
	setIfChanged(folder, "DivisionsMax", PopulationRules.maxDivisions(people))
	if change then
		setIfChanged(folder, "Croissance", math.floor(change * 10 + 0.5) / 10)
	end
end

-- Prend `people` milliers d'habitants dans une région (soldats d'une nouvelle division) ;
-- faux s'il n'y en a pas assez
function PopulationService.spend(regionId: string, people: number): boolean
	local current = PopulationService.of(regionId)
	if people > 0 and current < people then
		return false
	end
	set(regionId, current - people)
	local owner = RegionService.getOwner(regionId)
	if owner then
		publish(owner, PopulationService.total(owner))
	end
	return true
end

-- Un cycle : la population de chaque pays mange, puis grandit ou souffre de la faim
function PopulationService.tick()
	local byOwner: { [string]: { string } } = {}
	for regionId in Regions do
		local owner = RegionService.getOwner(regionId)
		if owner then
			local list = byOwner[owner] or {}
			byOwner[owner] = list
			table.insert(list, regionId)
		end
	end
	local s = state()
	local pays = s and s:FindFirstChild("Pays")
	for _, folder in (if pays then pays:GetChildren() else {}) do
		local countryId = folder.Name
		local regions = byOwner[countryId]
		if not regions then
			publish(countryId, 0, 0)
			setIfChanged(folder, "Famine", nil)
			continue
		end
		local before = 0
		for _, regionId in regions do
			before += PopulationService.of(regionId)
		end
		-- repas du cycle (parts d'unité gardées pour le cycle suivant)
		local exact = PopulationRules.food(before) + (foodCarry[countryId] or 0)
		local due = math.floor(exact)
		foodCarry[countryId] = exact - due
		local paid = math.min(due, Stocks.get(countryId, "Nourriture"))
		if paid > 0 then
			Stocks.add(countryId, "Nourriture", -paid)
		end
		local fed = paid >= due
		local stability = folder:GetAttribute("Stabilite")
		local factor = StabilityRules.productionFactor(if typeof(stability) == "number" then stability else 50)
		local after = 0
		for _, regionId in regions do
			local people = PopulationRules.grow(PopulationService.of(regionId), PopulationRules.regionStart(regionId), fed, factor)
			set(regionId, people)
			after += people
		end
		publish(countryId, after, after - before)
		setIfChanged(folder, "Famine", if fed then nil else true)
	end
end

-- Habitants de départ dans toutes les régions (nouvelle partie)
function PopulationService.reset()
	table.clear(foodCarry)
	for regionId in Regions do
		set(regionId, PopulationRules.regionStart(regionId))
	end
	local s = state()
	local pays = s and s:FindFirstChild("Pays")
	for _, folder in (if pays then pays:GetChildren() else {}) do
		publish(folder.Name, PopulationService.total(folder.Name), 0)
		folder:SetAttribute("Famine", nil)
	end
end

-- À appeler après RegionService.init() et CountryAssignment.init() (dossiers des régions et des pays)
function PopulationService.init()
	PopulationService.reset()
end

return PopulationService
