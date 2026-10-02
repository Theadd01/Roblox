--!strict
-- Économie équilibrée (étape 32) : chaque pays produit la même valeur, selon ses spécialités
-- (shared/RegionResources, Config/Economy.national). Lancés dans Studio par tests/LanceurTests.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local RegionResources = require(Shared:WaitForChild("RegionResources")) :: any
local Economy = require(Config:WaitForChild("Economy")) :: any
local Market = require(Config:WaitForChild("Market")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any

type Result = { name: string, ok: boolean, detail: string }

local function value(production: { [string]: number }): number
	local total = 0
	for id, amount in production do
		total += amount * (Market.basePrices[id] or 0)
	end
	return total
end

local tests: { () -> Result } = {}

-- 1. Tous les pays produisent à peu près la même valeur
table.insert(tests, function(): Result
	local V = Economy.national.value
	local low, high, lowId, highId, bad = math.huge, 0, "", "", 0
	for countryId in Countries do
		local v = value(RegionResources.national(countryId))
		if v < low then
			low, lowId = v, countryId
		end
		if v > high then
			high, highId = v, countryId
		end
		if v < V * 0.9 or v > V * 1.15 then
			bad += 1
		end
	end
	return {
		name = "Même valeur pour tous les pays",
		ok = bad == 0,
		detail = `valeur visée {V} ; plus faible {lowId} {math.floor(low)}, plus forte {highId} {math.floor(high)} ; hors marge : {bad}`,
	}
end)

-- 2. Les régions d'un pays (territoires compris) produisent exactement la production nationale
table.insert(tests, function(): Result
	local wrong = {}
	for _, countryId in { "FRA", "DNK", "USA", "RUS", "LUX" } do
		local sum: { [string]: number } = {}
		for regionId, region in Regions do
			if region.startOwner == countryId then
				for id, amount in RegionResources.production(regionId) do
					sum[id] = (sum[id] or 0) + amount
				end
			end
		end
		for id, amount in RegionResources.national(countryId) do
			if math.abs((sum[id] or 0) - amount) > 0.05 then
				table.insert(wrong, `{countryId} {id} {sum[id] or 0}/{amount}`)
			end
		end
	end
	return { name = "Répartition entre les régions", ok = #wrong == 0, detail = if #wrong > 0 then table.concat(wrong, ", ") else "exacte (FRA, DNK, USA, RUS, LUX)" }
end)

-- 3. Spécialités : la France fait du blé sans pétrole, l'Iran du pétrole et peu de blé
table.insert(tests, function(): Result
	local fra, irn, sau = RegionResources.national("FRA"), RegionResources.national("IRN"), RegionResources.national("SAU")
	local saudiTop = RegionResources.sorted(sau)[1]
	local ok = (fra.Nourriture or 0) >= 15 and (fra.Petrole or 0) == 0
		and (irn.Petrole or 0) > 0 and (irn.Nourriture or 0) <= 5
		and saudiTop == "Petrole"
	return {
		name = "Spécialités nationales",
		ok = ok,
		detail = `France blé {fra.Nourriture} pétrole {fra.Petrole or 0} ; Iran blé {irn.Nourriture} pétrole {irn.Petrole} gaz {irn.Gaz} ; Arabie : surtout {saudiTop}`,
	}
end)

-- 4. Une région conquise produit moins pour son occupant
table.insert(tests, function(): Result
	local own = RegionResources.ownerFactor("FRA_2", "FRA")
	local occupied = RegionResources.ownerFactor("FRA_2", "DEU")
	return {
		name = "Production d'une région conquise",
		ok = own == 1 and occupied == Economy.occupiedProduction,
		detail = `chez soi x{own}, occupée x{occupied}`,
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
