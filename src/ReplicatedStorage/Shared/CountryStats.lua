--!strict
-- Statistiques de départ des pays, calculées depuis la configuration :
-- surface totale, nombre de régions, difficulté.

local Config = script.Parent.Config
local MapGeometry = require(Config.MapGeometry)
local Regions = require(Config.Regions)
local CountrySelection = require(Config.CountrySelection)

export type Difficulty = "Facile" | "Moyen" | "Difficile"

local CountryStats = {}

local areas: { [string]: number } = {}
local regionCounts: { [string]: number } = {}

for _, region in Regions do
	local owner = region.startOwner
	local geometry = MapGeometry.countries[region.geometry]
	areas[owner] = (areas[owner] or 0) + (if geometry then geometry.area else 0)
	regionCounts[owner] = (regionCounts[owner] or 0) + 1
end

function CountryStats.area(countryId: string): number
	return areas[countryId] or 0
end

function CountryStats.regionCount(countryId: string): number
	return regionCounts[countryId] or 0
end

function CountryStats.difficulty(countryId: string): Difficulty
	local a = CountryStats.area(countryId)
	if a >= CountrySelection.easyArea then
		return "Facile"
	elseif a >= CountrySelection.mediumArea then
		return "Moyen"
	end
	return "Difficile"
end

-- Pays équilibré, conseillé aux nouveaux joueurs
function CountryStats.isRecommended(countryId: string): boolean
	local a = CountryStats.area(countryId)
	return a >= CountrySelection.recommendedMinArea and a <= CountrySelection.recommendedMaxArea
end

return CountryStats
