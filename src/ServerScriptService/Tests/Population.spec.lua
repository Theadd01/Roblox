--!strict
-- Population (étape 33, shared/PopulationRules) : habitants de départ presque égaux, répartis
-- exactement entre les régions, croissance, famine, divisions possibles.
-- Lancés dans Studio par tests/LanceurTests.server.luau.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local PopulationRules = require(Shared:WaitForChild("PopulationRules")) :: any
local Population = require(Config:WaitForChild("Population")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any

type Result = { name: string, ok: boolean, detail: string }

local tests: { () -> Result } = {}

-- 1. Habitants de départ : presque les mêmes pour tous (entre minFactor et maxFactor)
table.insert(tests, function(): Result
	local low, high = Population.start * Population.minFactor, Population.start * Population.maxFactor
	local bad = 0
	for countryId in Countries do
		local people = PopulationRules.countryStart(countryId)
		if people < low - 1 or people > high + 1 then
			bad += 1
		end
	end
	return {
		name = "Habitants de départ équilibrés",
		ok = bad == 0,
		detail = `Chine {PopulationRules.format(PopulationRules.countryStart("CHN"))}, France {PopulationRules.format(PopulationRules.countryStart("FRA"))}, Luxembourg {PopulationRules.format(PopulationRules.countryStart("LUX"))} ; hors bornes : {bad}`,
	}
end)

-- 2. Répartition exacte entre les régions (capitale double, territoires lointains réduits)
table.insert(tests, function(): Result
	local wrong = {}
	for _, countryId in { "FRA", "DNK", "LUX", "RUS" } do
		local sum = 0
		for regionId, region in Regions do
			if region.startOwner == countryId then
				sum += PopulationRules.regionStart(regionId)
			end
		end
		if sum ~= PopulationRules.countryStart(countryId) then
			table.insert(wrong, `{countryId} {sum}/{PopulationRules.countryStart(countryId)}`)
		end
	end
	local capital, other = PopulationRules.regionStart("FRA"), PopulationRules.regionStart("FRA_2")
	return {
		name = "Répartition entre les régions",
		ok = #wrong == 0 and capital > 0 and other > 0,
		detail = if #wrong > 0 then table.concat(wrong, ", ") else `exacte ; Île-de-France {PopulationRules.format(capital)}, FRA_2 {PopulationRules.format(other)}`,
	}
end)

-- 3. Croissance quand elle mange à sa faim, baisse en famine, plafond respecté
table.insert(tests, function(): Result
	local start = 1000
	local fed = PopulationRules.grow(start, start, true, 1)
	local hungry = PopulationRules.grow(start, start, false, 1)
	local capped = PopulationRules.grow(start * Population.maxGrowth, start, true, 1)
	local unstable = PopulationRules.grow(start, start, true, 0.5)
	local ok = fed > start and hungry < start and capped == start * Population.maxGrowth and unstable > start and unstable < fed
	return {
		name = "Croissance et famine",
		ok = ok,
		detail = `nourrie {fed} ; famine {hungry} ; au plafond {capped} ; instable {unstable}`,
	}
end)

-- 4. Divisions possibles selon les habitants, nourriture mangée
table.insert(tests, function(): Result
	local P = Population
	local small, medium, huge = PopulationRules.maxDivisions(500), PopulationRules.maxDivisions(10800), PopulationRules.maxDivisions(99999)
	local food = PopulationRules.food(10000)
	local ok = small == P.minDivisions and medium == math.floor(10.8 * P.divisionsPerMillion) and huge == P.maxDivisions
		and math.abs(food - 10 * P.foodPerMillion) < 1e-6
	return {
		name = "Divisions possibles et repas",
		ok = ok,
		detail = `500 k : {small} ; 10,8 M : {medium} ; énorme : {huge} ; 10 M mangent {food} par cycle`,
	}
end)

return function(): { Result }
	local results = {}
	for _, test in tests do
		local ok, result = pcall(test)
		table.insert(results, if ok then result else { name = "erreur", ok = false, detail = tostring(result) })
	end
	return results
end
