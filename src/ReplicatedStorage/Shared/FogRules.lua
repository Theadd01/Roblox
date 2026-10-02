--!strict
-- Règles du brouillard de guerre (Config/Espionage), pour le serveur comme pour le client :
-- régions visibles d'un pays et visibilité d'une force.
-- Un pays voit : ses régions et celles de ses alliés, avec leurs voisines (une rangée de plus par
-- technologie de radar) ; les régions où sont ou
-- vont ses forces (et leurs alliées), avec leurs voisines ; les régions révélées par ses espions
-- (EtatMonde.Renseignements.<pays>, attributs R_<région> = heure de fin).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = script.Parent
local Regions = require(Shared:WaitForChild("Config"):WaitForChild("Regions")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local TechState = require(Shared:WaitForChild("TechState")) :: any

local FogRules = {}

-- Le pays et ses alliés
function FogRules.friends(countryId: string): { [string]: boolean }
	local set = { [countryId] = true }
	for _, ally in DiplomacyState.alliesOf(countryId) do
		set[ally] = true
	end
	return set
end

local function addWithNeighbors(visible: { [string]: boolean }, regionId: unknown)
	local region = if typeof(regionId) == "string" then Regions[regionId] else nil
	if not region then
		return
	end
	visible[regionId :: string] = true
	for _, link in region.neighbors do
		visible[link.region] = true
	end
end

-- Régions visibles d'un pays. getOwner : propriétaire d'une région (serveur ou client)
function FogRules.visibleRegions(countryId: string, getOwner: (regionId: string) -> string?): { [string]: boolean }
	local visible: { [string]: boolean } = {}
	local friends = FogRules.friends(countryId)
	for regionId in Regions do
		local owner = getOwner(regionId)
		if owner and friends[owner] then
			addWithNeighbors(visible, regionId)
		end
	end
	-- radars : chaque rangée en plus étend la vue aux voisines des régions déjà vues
	for _ = 1, TechState.visionRings(countryId) do
		local ring = {}
		for regionId in visible do
			table.insert(ring, regionId)
		end
		for _, regionId in ring do
			addWithNeighbors(visible, regionId)
		end
	end
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local armees = state and state:FindFirstChild("Armees")
	for _, army in (if armees then armees:GetChildren() else {}) do
		if friends[army:GetAttribute("Proprietaire") :: string] then
			addWithNeighbors(visible, army:GetAttribute("Region"))
			local destination = army:GetAttribute("Destination")
			if destination ~= "" then
				addWithNeighbors(visible, destination)
			end
		end
	end
	local renseignements = state and state:FindFirstChild("Renseignements")
	local mine = renseignements and renseignements:FindFirstChild(countryId)
	if mine then
		local now = workspace:GetServerTimeNow()
		for name, expiry in mine:GetAttributes() do
			local regionId = name:match("^R_(.+)$")
			if regionId and typeof(expiry) == "number" and expiry > now then
				visible[regionId] = true
			end
		end
	end
	return visible
end

-- Une force est-elle visible ? (les siennes et celles des alliés toujours ; les autres si leur
-- région ou leur destination est visible)
function FogRules.armyVisible(army: Instance, visible: { [string]: boolean }, friends: { [string]: boolean }): boolean
	if friends[army:GetAttribute("Proprietaire") :: string] then
		return true
	end
	local region = army:GetAttribute("Region")
	local destination = army:GetAttribute("Destination")
	return (typeof(region) == "string" and visible[region] == true)
		or (typeof(destination) == "string" and destination ~= "" and visible[destination] == true)
end

-- Fin de la révélation d'une région par un pays (nil si elle n'est pas révélée)
function FogRules.revealedUntil(countryId: string, regionId: string): number?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local renseignements = state and state:FindFirstChild("Renseignements")
	local mine = renseignements and renseignements:FindFirstChild(countryId)
	local expiry = mine and mine:GetAttribute("R_" .. regionId)
	return if typeof(expiry) == "number" and expiry > workspace:GetServerTimeNow() then expiry else nil
end

return FogRules
