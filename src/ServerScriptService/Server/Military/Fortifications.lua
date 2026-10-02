--!strict
-- Fortifications (SYSTEME_MILITAIRE.md, 5.5) : bâtiment d'une région, construit niveau par niveau
-- (Config/Military.fortification : coût, durée, niveau maximum, bonus de défense par niveau).
--   ordre « Fortifier » { region } (RemoteEvent CommandeMilitaire) : dans une de ses régions,
--   hors bataille, un niveau à la fois ;
--   la région garde ses fortifications quand elle change de mains (le chantier en cours, lui,
--   est perdu).
-- État publié dans ReplicatedStorage.EtatMonde.Regions.<id> : Fortification (niveau, 0 à 3) et
-- FortificationFin (heure de fin du chantier en cours ; absent sans chantier).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Military = require(Config:WaitForChild("Military")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local Stocks = require(Server:WaitForChild("Economy"):WaitForChild("Stocks"))

local Fortifications = {}

local building: { [string]: string } = {} -- région -> pays qui construit

local function regionFolder(regionId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local regions = state and state:FindFirstChild("Regions")
	return regions and regions:FindFirstChild(regionId)
end

function Fortifications.level(regionId: string): number
	local folder = regionFolder(regionId)
	return (folder and folder:GetAttribute("Fortification") :: number?) or 0
end

-- Lance la construction du niveau suivant
function Fortifications.build(countryId: string, regionId: unknown): (boolean, string?)
	if typeof(regionId) ~= "string" or not Regions[regionId] then
		return false, "Région inconnue."
	end
	local folder = regionFolder(regionId)
	if not folder then
		return false, "Région inconnue."
	end
	if RegionService.getOwner(regionId) ~= countryId then
		return false, "On ne fortifie que ses propres régions."
	end
	if folder:GetAttribute("Bataille") then
		return false, "Impossible de construire pendant une bataille dans cette région."
	end
	if building[regionId] then
		return false, "Un chantier est déjà en cours ici."
	end
	local F = Military.fortification
	if Fortifications.level(regionId) >= F.maxLevel then
		return false, `Fortifications déjà au maximum (niveau {F.maxLevel}).`
	end
	if not Stocks.spend(countryId, F.cost) then
		return false, "Pas assez de ressources pour fortifier."
	end
	building[regionId] = countryId
	folder:SetAttribute("FortificationFin", workspace:GetServerTimeNow() + F.buildSeconds)
	return true, nil
end

-- Chantiers terminés (ou abandonnés : la région a changé de mains)
local function update(_dt: number, now: number)
	for regionId, countryId in building do
		local folder = regionFolder(regionId)
		if not folder or RegionService.getOwner(regionId) ~= countryId then
			building[regionId] = nil
			if folder then
				folder:SetAttribute("FortificationFin", nil)
			end
		elseif now >= ((folder:GetAttribute("FortificationFin") :: number?) or 0) then
			building[regionId] = nil
			folder:SetAttribute("FortificationFin", nil)
			folder:SetAttribute("Fortification", math.min(Military.fortification.maxLevel, Fortifications.level(regionId) + 1))
		end
	end
end

-- Nouvelle partie : plus aucune fortification
function Fortifications.reset()
	table.clear(building)
	for regionId in Regions do
		local folder = regionFolder(regionId)
		if folder then
			folder:SetAttribute("Fortification", nil)
			folder:SetAttribute("FortificationFin", nil)
		end
	end
end

function Fortifications.init(loop: any, commands: any)
	loop.every("fortifications", 1, update)
	-- Fortifier { region } : un niveau de plus dans une de ses régions
	commands.register("Fortifier", function(countryId: string, data: { [any]: any }): (boolean, string?)
		return Fortifications.build(countryId, data.region)
	end, "Fortifier")
end

return Fortifications
