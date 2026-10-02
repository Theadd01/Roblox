--!strict
-- Propriétaires des régions. Seul le serveur décide qui possède quoi.
-- L'état est publié dans ReplicatedStorage.EtatMonde.Regions : un dossier par région
-- avec l'attribut « Proprietaire » (code du pays). Les clients ne font que le lire.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any

local RegionService = {}

local ownerListeners: { (regionId: string, newOwner: string, oldOwner: string?, reason: string) -> () } = {}

-- Dossiers d'état mémorisés à leur création (près de 700 régions : chercher chaque dossier par son
-- nom à chaque appel coûterait cher à l'IA). Une copie du module chargée par la barre de commande
-- de Studio n'a pas cette table : elle retrouve alors le dossier dans ReplicatedStorage.
local folders: { [string]: Instance } = {}

local function folderFor(regionId: string): Instance?
	local cached = folders[regionId]
	if cached then
		return cached
	end
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local regions = state and state:FindFirstChild("Regions")
	return regions and regions:FindFirstChild(regionId)
end

function RegionService.init()
	local state = Instance.new("Folder")
	state.Name = "EtatMonde"
	local regionsFolder = Instance.new("Folder")
	regionsFolder.Name = "Regions"
	regionsFolder.Parent = state

	for id, region in Regions do
		local folder = Instance.new("Folder")
		folder.Name = id
		folder:SetAttribute("Proprietaire", region.startOwner)
		folder.Parent = regionsFolder
		folders[id] = folder
	end

	state.Parent = ReplicatedStorage
end

function RegionService.getOwner(regionId: string): string?
	local folder = folderFor(regionId)
	if not folder then
		return nil
	end
	local owner = folder:GetAttribute("Proprietaire")
	return if typeof(owner) == "string" then owner else nil
end

-- Change le propriétaire d'une région (après vérification des deux codes).
-- reason : « Conquete » (par défaut), « Revolte » ou « Soulevement » (pour les messages)
function RegionService.setOwner(regionId: string, countryId: string, reason: string?): boolean
	local folder = folderFor(regionId)
	if not folder or not Countries[countryId] then
		warn(`[RegionService] changement refusé : région {regionId}, pays {countryId}`)
		return false
	end
	local previous = folder:GetAttribute("Proprietaire")
	folder:SetAttribute("Proprietaire", countryId)
	if previous ~= countryId then
		for _, listener in ownerListeners do
			task.spawn(listener, regionId, countryId, if typeof(previous) == "string" then previous else nil, reason or "Conquete")
		end
	end
	return true
end

-- Nouvelle partie : chaque région revient à son pays de départ, sans résistance ni bataille.
-- Les écouteurs ne sont pas prévenus : ce n'est pas une conquête.
function RegionService.reset()
	for id, region in Regions do
		local folder = folderFor(id)
		if folder then
			folder:SetAttribute("Proprietaire", region.startOwner)
			folder:SetAttribute("Resistance", nil)
			folder:SetAttribute("Bataille", nil)
		end
	end
end

-- listener(région, nouveau propriétaire, ancien propriétaire, raison) : une région change de mains
function RegionService.onOwnerChanged(listener: (regionId: string, newOwner: string, oldOwner: string?, reason: string) -> ())
	table.insert(ownerListeners, listener)
end

return RegionService
