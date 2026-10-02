--!strict
-- Revenus passifs : impôts et vente automatique (shared/IncomeRules, fonctions pures), avec les
-- valeurs de Config/Economy. Lancés dans Studio par tests/LanceurTests.server.luau.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local IncomeRules = require(Shared:WaitForChild("IncomeRules")) :: any
local Economy = require(Shared:WaitForChild("Config"):WaitForChild("Economy")) :: any
local Population = require(Shared:WaitForChild("Config"):WaitForChild("Population")) :: any

type Result = { name: string, ok: boolean, detail: string }

local tests: { () -> Result } = {}

-- 1. Impôts : payés par les habitants, moitié moins pour ceux des régions conquises, selon la stabilité
table.insert(tests, function(): Result
	local per = Population.taxPerMillion
	local full = IncomeRules.taxes(10000, 0, 1) -- 10 millions d'habitants chez soi
	local conquered = IncomeRules.taxes(10000, 2000, 1) -- + 2 millions conquis
	local unstable = IncomeRules.taxes(10000, 0, 0.5)
	local ok = math.abs(full - 10 * per) < 1e-6
		and math.abs(conquered - (full + 2 * per * Economy.taxes.occupiedFactor)) < 1e-6
		and math.abs(unstable - full / 2) < 1e-6
		and IncomeRules.taxes(0, 0, 1) == 0
	return {
		name = "Impôts d'un cycle",
		ok = ok,
		detail = `10 M d'habitants : {full} ; +2 M conquis : {conquered} ; stabilité x0,5 : {unstable}`,
	}
end)

-- 2. Vente automatique : réserve (base + consommation), surplus vendu, petites quantités ignorées
table.insert(tests, function(): Result
	local A = Economy.autoSell
	local base = A.reserve.Nourriture or A.defaultReserve
	local reserve = IncomeRules.reserve("Nourriture", 2.5)
	local expected = base + math.ceil(A.needCycles * 2.5)
	local sold = IncomeRules.surplus(reserve + 15.7, reserve, 10000)
	local capped = IncomeRules.surplus(reserve + 50000, reserve, 10000)
	local nothing = IncomeRules.surplus(reserve, reserve, 10000)
	local below = IncomeRules.surplus(reserve - 30, reserve, 10000)
	local ok = reserve == expected and sold == 15 and capped == 10000 and nothing == 0 and below == 0
		and IncomeRules.reserve("Gaz", 0) == (A.reserve.Gaz or A.defaultReserve)
	return {
		name = "Vente automatique du surplus",
		ok = ok,
		detail = `réserve nourriture {reserve} (attendu {expected}) ; surplus 15,7 -> {sold} ; énorme -> {capped} ; rien -> {nothing}, {below}`,
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
