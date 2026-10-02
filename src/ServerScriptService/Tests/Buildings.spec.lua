--!strict
-- Bâtiments (étape 34, shared/BuildingRules) : emplacements, bâtiments possibles selon les
-- ressources de la région, production, prix croissant, camps militaires.
-- Lancés dans Studio par tests/LanceurTests.server.luau.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local BuildingRules = require(Shared:WaitForChild("BuildingRules")) :: any
local RegionResources = require(Shared:WaitForChild("RegionResources")) :: any
local Factories = require(Config:WaitForChild("Factories")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any

type Result = { name: string, ok: boolean, detail: string }

local tests: { () -> Result } = {}

-- 1. Emplacements : 4 dans la capitale, 2 ailleurs
table.insert(tests, function(): Result
	local capital, other = BuildingRules.slots("FRA"), BuildingRules.slots("FRA_2")
	return {
		name = "Emplacements",
		ok = capital == Factories.capitalSlots and other == Factories.maxPerRegion,
		detail = `capitale {capital}, autre région {other}`,
	}
end)

-- 2. Bâtiments possibles : champs partout, puits seulement là où il y a du pétrole ou du gaz
table.insert(tests, function(): Result
	local farm = BuildingRules.canBuildIn("Ferme", "FRA")
	local franceWell, reason = BuildingRules.canBuildIn("Puits", "FRA")
	local oilRegion: string? = nil
	for regionId, region in Regions do
		if region.startOwner == "IRN" and (RegionResources.production(regionId).Petrole or 0) > 0 then
			oilRegion = regionId
			break
		end
	end
	local iranWell = oilRegion ~= nil and BuildingRules.canBuildIn("Puits", oilRegion)
	return {
		name = "Bâtiments selon les ressources",
		ok = farm and not franceWell and iranWell == true,
		detail = `champs en France : {farm} ; puits en France : {franceWell} ({reason}) ; puits en Iran ({oilRegion}) : {iranWell}`,
	}
end)

-- 3. Production : champs selon la fertilité et le niveau, moitié moins pour un occupant
table.insert(tests, function(): Result
	local per = Factories.types.Ferme.extracts.Nourriture
	local fertile = Factories.fertilityFactors.fertile
	local one = BuildingRules.outputs("Ferme", "FRA_2", 1, "FRA").Nourriture
	local two = BuildingRules.outputs("Ferme", "FRA_2", 2, "FRA").Nourriture
	local occupied = BuildingRules.outputs("Ferme", "FRA_2", 1, "DEU").Nourriture
	local chips = BuildingRules.outputs("UsinePuces", "FRA", 2, "FRA").Puces
	local chipInputs = BuildingRules.inputs("UsinePuces", 2)
	local ok = math.abs(one - per * fertile) < 1e-6 and math.abs(two - 2 * one) < 1e-6 and math.abs(occupied - one / 2) < 1e-6
		and chips == 2 and chipInputs.TerresRares == 2 and chipInputs.Gaz == 2
	return {
		name = "Production des bâtiments",
		ok = ok,
		detail = `champs en France niv. 1 : {one}, niv. 2 : {two}, occupés : {occupied} ; usine de puces niv. 2 : {chips} puces`,
	}
end)

-- 4. Prix qui monte avec le nombre de bâtiments, camps plus rapides
table.insert(tests, function(): Result
	local base = Factories.types.Ferme.buildCost.Credits
	local early = BuildingRules.buildCost("Ferme", Factories.freeBuildings).Credits
	local later = BuildingRules.buildCost("Ferme", Factories.freeBuildings + 5).Credits
	local expected = math.floor(base * (1 + Factories.costGrowth * 5) + 0.5)
	local c1, c2, c3 = BuildingRules.campFactor(1), BuildingRules.campFactor(2), BuildingRules.campFactor(3)
	local ok = early == base and later == expected and c1 == 1 and c2 < c1 and c3 < c2
	return {
		name = "Prix croissant et camps",
		ok = ok,
		detail = `champs : {early} puis {later} (attendu {expected}) ; entraînement camp niv. 1/2/3 : x{c1} x{c2} x{c3}`,
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
