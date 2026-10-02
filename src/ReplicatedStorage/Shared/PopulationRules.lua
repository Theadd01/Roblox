--!strict
-- Règles de la population (Config/Population), partagées par le serveur (qui décide) et le client
-- (qui affiche). Habitants en milliers. Fonctions pures (tests/Population.spec.luau).

local Config = script.Parent.Config
local Population = require(Config.Population)
local Regions = require(Config.Regions)
local MapGeometry = require(Config.MapGeometry)

local PopulationRules = {}

-- Habitants de départ d'un pays (milliers) : presque les mêmes pour tous, nuancés par sa
-- population réelle (échelle logarithmique, entre minFactor et maxFactor)
function PopulationRules.countryStart(countryId: string): number
	local P = Population
	local real = P.real[countryId] or 10
	local factor = math.clamp(1 + P.spread * math.log10(real / 10), P.minFactor, P.maxFactor)
	return math.floor(P.start * factor + 0.5)
end

-- habitants de départ de chaque région : ceux du pays, partagés selon la taille des régions
-- (racine de la surface ; capitale double, territoires lointains réduits)
local regionStart: { [string]: number } = {}
do
	local weights: { [string]: { [string]: number } } = {}
	for regionId, region in Regions do
		local owner = region.startOwner :: string
		local shape = MapGeometry.countries[region.geometry]
		local weight = math.sqrt(if shape then math.max(shape.area, 1) else 1)
		if regionId == owner then
			weight *= Population.capitalWeight
		end
		if (regionId:match("^(%u+)") or regionId) ~= owner then
			weight *= Population.territoryWeight
		end
		local list = weights[owner] or {}
		weights[owner] = list
		list[regionId] = weight
	end
	for owner, list in weights do
		local total = 0
		for _, weight in list do
			total += weight
		end
		local people = PopulationRules.countryStart(owner)
		local given, biggest, biggestWeight = 0, owner, -1
		for regionId, weight in list do
			local part = math.floor(people * weight / total)
			regionStart[regionId] = part
			given += part
			if weight > biggestWeight then
				biggest, biggestWeight = regionId, weight
			end
		end
		regionStart[biggest] = (regionStart[biggest] or 0) + people - given -- total exact
	end
end

-- Habitants de départ d'une région (milliers)
function PopulationRules.regionStart(regionId: string): number
	return regionStart[regionId] or 0
end

-- Nourriture mangée par cycle par `people` milliers d'habitants
function PopulationRules.food(people: number): number
	return math.max(0, people) / 1000 * Population.foodPerMillion
end

-- Habitants d'une région après un cycle : croissance si la population mange à sa faim (plus lente
-- en approchant du maximum, x effet de la stabilité), baisse en cas de famine
function PopulationRules.grow(people: number, start: number, fed: boolean, stabilityFactor: number): number
	local P = Population
	if not fed then
		return math.max(0, people * (1 - P.famine))
	end
	local cap = start * P.maxGrowth
	if cap <= 0 or people >= cap then
		return people
	end
	local room = (1 - people / cap) / (1 - 1 / P.maxGrowth) -- 1 au départ, 0 au maximum
	return math.min(cap, people * (1 + P.growth * math.max(0, stabilityFactor) * math.min(1, room)))
end

-- Divisions qu'un pays peut avoir avec `people` milliers d'habitants
function PopulationRules.maxDivisions(people: number): number
	local P = Population
	return math.clamp(math.floor(people / 1000 * P.divisionsPerMillion), P.minDivisions, P.maxDivisions)
end

-- « 10,8 M » / « 850 k »
function PopulationRules.format(people: number): string
	if people >= 1000 then
		return (string.format("%.1f M", people / 1000):gsub("%.", ","))
	end
	return `{math.floor(people + 0.5)} k`
end

return PopulationRules
