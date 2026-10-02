--!strict
-- Personnalité de chaque pays (Config/Personalities) : tirée au début de la partie et publiée
-- dans l'attribut « Personnalite » de ReplicatedStorage.EtatMonde.Pays.<code>.
-- Le tirage ne tient compte que de la géographie du pays (fer et charbon, exportations, taille).
-- settings(pays) donne les réglages de son IA : ceux de Config/AI, sauf ce que sa
-- personnalité remplace ; weights(pays) donne le poids de chaque famille d'actions.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local AI = require(Config:WaitForChild("AI")) :: any
local Personalities = require(Config:WaitForChild("Personalities")) :: any
local Market = require(Config:WaitForChild("Market")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local RegionResources = require(Shared:WaitForChild("RegionResources")) :: any
local CountryStats = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("CountryStats")) :: any

local PersonalityService = {}

-- réglages de chaque personnalité : ses remplacements, et Config/AI pour le reste
local settingsById: { [string]: any } = {}
for id, personality in Personalities.list do
	settingsById[id] = setmetatable(table.clone(personality.overrides), { __index = AI })
end

local rng = Random.new()

local function countryFolder(countryId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
end

-- Traits géographiques d'un pays, d'après ses régions de départ
local function traitsOf(countryId: string): { string }
	local production: { [string]: number } = {}
	for regionId, region in Regions do
		if region.startOwner == countryId then
			for resourceId, amount in RegionResources.production(regionId) do
				production[resourceId] = (production[resourceId] or 0) + amount
			end
		end
	end
	local traits = {}
	if (production.MineraiFer or 0) > 0 and (production.Charbon or 0) > 0 then
		table.insert(traits, "steel")
	end
	local exports = 0
	for resourceId, amount in production do
		if resourceId ~= "Nourriture" then
			exports += amount * (Market.basePrices[resourceId] or 0)
		end
	end
	if exports >= Personalities.exporterValue then
		table.insert(traits, "exporter")
	end
	local area = CountryStats.area(countryId)
	if area <= Personalities.smallArea then
		table.insert(traits, "small")
	elseif area >= Personalities.largeArea then
		table.insert(traits, "large")
	end
	return traits
end

-- Tirage au sort, pondéré par les chances de chaque personnalité et les traits du pays
local function draw(countryId: string): string
	local traits = traitsOf(countryId)
	local chances: { [string]: number } = {}
	local total = 0
	for _, id in Personalities.order do
		local chance = Personalities.list[id].chance
		for _, trait in traits do
			chance *= Personalities.traits[trait][id] or 1
		end
		chances[id] = chance
		total += chance
	end
	local roll = rng:NextNumber(0, total)
	for _, id in Personalities.order do
		roll -= chances[id]
		if roll <= 0 then
			return id
		end
	end
	return Personalities.order[#Personalities.order]
end

-- Tire la personnalité de chaque pays (au démarrage, après la création de EtatMonde.Pays)
function PersonalityService.assign()
	local pays = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Pays")
	for _, folder in pays:GetChildren() do
		folder:SetAttribute("Personnalite", draw(folder.Name))
	end
end

-- Donne une personnalité à un pays (par exemple celle qui ressemble le plus au style d'un joueur)
function PersonalityService.set(countryId: string, personalityId: string)
	local folder = countryFolder(countryId)
	if folder and Personalities.list[personalityId] then
		folder:SetAttribute("Personnalite", personalityId)
	end
end

-- Personnalité d'un pays (nil si elle n'a pas encore été tirée)
function PersonalityService.get(countryId: string): string?
	local folder = countryFolder(countryId)
	local id = folder and folder:GetAttribute("Personnalite")
	return if typeof(id) == "string" and Personalities.list[id] then id else nil
end

-- Réglages de l'IA de ce pays
function PersonalityService.settings(countryId: string): any
	local id = PersonalityService.get(countryId)
	return if id then settingsById[id] else AI
end

-- Poids de chaque famille d'actions pour ce pays (1 par défaut)
function PersonalityService.weights(countryId: string): { [string]: number }
	local id = PersonalityService.get(countryId)
	return if id then Personalities.list[id].weights else {}
end

return PersonalityService
