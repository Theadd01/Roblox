--!strict
-- Scénario automatisé des généraux (SYSTEME_MILITAIRE.md, section 10, test 9) : règle de
-- nomination de server/Military/Armies (fonction pure), sans partie en cours.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Armies = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Military"):WaitForChild("Armies"))
local Military = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Military")) :: any

type Result = { name: string, ok: boolean, detail: string }

local tests: { () -> Result } = {}

-- 9. Deuxième général dans une région qui en a déjà un -> refusé
table.insert(tests, function(): Result
	local first, firstWhy = Armies.nameRule("FRA", "FRA", false, 0)
	local second, secondWhy = Armies.nameRule("FRA", "FRA", true, 1)
	local foreign = Armies.nameRule("FRA", "DEU", false, 1)
	local tooMany = Armies.nameRule("FRA", "FRA", false, Military.generals.maxPerCountry)
	return {
		name = "Deuxième général dans une région qui en a déjà un : refusé",
		ok = first and not second and not foreign and not tooMany,
		detail = `premier : {if first then "accepté" else tostring(firstWhy)} ; second : {tostring(secondWhy)}`,
	}
end)

return function(): { Result }
	local results = {}
	for _, test in tests do
		local ok, value = pcall(test)
		table.insert(results, if ok then value else { name = "Test 9", ok = false, detail = "erreur : " .. tostring(value) })
	end
	return results
end
