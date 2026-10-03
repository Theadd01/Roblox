--!strict
-- Scénarios automatisés des votes (cahier des charges v2, section 1) : probabilité de « oui » d'un
-- pays IA (affinité, paiement, malus s'il gagne sa guerre) et décompte à la majorité simple
-- (shared/VoteRules, fonctions pures), sans partie en cours.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VoteRules = require(Shared:WaitForChild("VoteRules")) :: any
local Council = require(Shared:WaitForChild("Config"):WaitForChild("Council")) :: any

type Result = { name: string, ok: boolean, detail: string }

local tests: { () -> Result } = {}

local function pct(x: number): string
	return `{math.floor(x * 100 + 0.5)} %`
end

-- 1. Affinité : un allié aime, un ennemi en guerre beaucoup moins ; la réputation compte
table.insert(tests, function(): Result
	local ally = VoteRules.affinity({ relation = "Allie", reputation = 50, commonEnemy = false })
	local enemy = VoteRules.affinity({ relation = "Guerre", reputation = 50, commonEnemy = false })
	local neutral = VoteRules.affinity({ relation = "Paix", reputation = 50, commonEnemy = false })
	local trusted = VoteRules.affinity({ relation = "Paix", reputation = 90, commonEnemy = true })
	return {
		name = "Affinité : allié > neutre > ennemi ; réputation et ennemi commun l'augmentent",
		ok = ally > neutral and neutral > enemy and trusted > neutral and ally <= 100 and enemy >= -100,
		detail = `allié {ally}, neutre {neutral}, ennemi {enemy}, neutre fiable avec ennemi commun {trusted}`,
	}
end)

-- 2. Paiement : plus la somme est élevée, plus la probabilité monte (rendements décroissants)
table.insert(tests, function(): Result
	local function chance(payment: number): number
		return VoteRules.chance({ affinity = -40, payment = payment, winning = 0, war = true })
	end
	local c0, c250, c500, c1000 = chance(0), chance(250), chance(500), chance(1000)
	local gainLow = VoteRules.paymentBonus(500) - VoteRules.paymentBonus(0)
	local gainHigh = VoteRules.paymentBonus(1000) - VoteRules.paymentBonus(500)
	return {
		name = "Paiement : 0 < 250 < 500 < 1 000 crédits, chaque crédit compte un peu moins",
		ok = c0 < c250 and c250 < c500 and c500 < c1000 and gainHigh < gainLow,
		detail = `ennemi : {pct(c0)} sans paiement, {pct(c250)} avec 250, {pct(c500)} avec 500, {pct(c1000)} avec 1 000`,
	}
end)

-- 3. Malus : un pays IA qui gagne sa guerre vote moins pour la trêve
table.insert(tests, function(): Result
	local losing = VoteRules.chance({ affinity = 0, payment = 0, winning = -2, war = true })
	local even = VoteRules.chance({ affinity = 0, payment = 0, winning = 0, war = true })
	local winning = VoteRules.chance({ affinity = 0, payment = 0, winning = 3, war = true })
	local winningOther = VoteRules.chance({ affinity = 0, payment = 0, winning = 3, war = false })
	local full = Council.chance.winning.malus
	return {
		name = "Il gagne sa guerre : -30 % pour une trêve (moitié pour un autre vote), rien s'il perd",
		ok = math.abs((even - winning) - full) < 1e-6 and math.abs((even - winningOther) - full / 2) < 1e-6 and losing == even,
		detail = `perd : {pct(losing)}, égalité : {pct(even)}, gagne : {pct(winning)} (autre vote : {pct(winningOther)})`,
	}
end)

-- 4. Bornes : jamais 0 % ni 100 % sans vote imposé
table.insert(tests, function(): Result
	local low = VoteRules.chance({ affinity = -100, payment = 0, winning = 10, war = true, interest = -1 })
	local high = VoteRules.chance({ affinity = 100, payment = 100000, winning = -10, war = true, interest = 1 })
	return {
		name = "Probabilité bornée entre 3 % et 97 %",
		ok = math.abs(low - Council.chance.minChance) < 1e-6 and math.abs(high - Council.chance.maxChance) < 1e-6,
		detail = `minimum {pct(low)}, maximum {pct(high)}`,
	}
end)

-- 5. Majorité simple : les abstentions ne comptent pas ; égalité = rejet
table.insert(tests, function(): Result
	local _, _, _, passed = VoteRules.tally({ FRA = "Pour", DEU = "Pour", ITA = "Contre", ESP = "Abstention", PRT = "Abstention" })
	local _, _, _, tie = VoteRules.tally({ FRA = "Pour", DEU = "Contre" })
	local yes, no, abstain, rejected = VoteRules.tally({ FRA = "Pour", DEU = "Contre", ITA = "Contre" })
	return {
		name = "Majorité simple : 2 pour 1 contre 2 abstentions passe ; 1-1 est rejeté",
		ok = passed and not tie and not rejected and yes == 1 and no == 2 and abstain == 0,
		detail = `2-1 : {passed} ; 1-1 : {tie} ; 1-2 : {rejected}`,
	}
end)

return function(): { Result }
	local results = {}
	for i, test in tests do
		local ok, value = pcall(test)
		table.insert(results, if ok then value else { name = `Test {i}`, ok = false, detail = "erreur : " .. tostring(value) })
	end
	return results
end
