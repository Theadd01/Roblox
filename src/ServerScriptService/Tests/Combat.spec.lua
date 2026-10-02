--!strict
-- Scénarios de combat automatisés (SYSTEME_MILITAIRE.md, section 10, tests 1 à 5).
-- Lancés dans Studio par tests/LanceurTests.server.luau (fenêtre Output) : uniquement les
-- fonctions pures de server/Military/Combat, sans partie en cours.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Combat = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Military"):WaitForChild("Combat"))
local DivisionConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Divisions")) :: any

type Unit = Combat.Unit
type Result = { name: string, ok: boolean, detail: string }

local MAX_TICKS = 300 -- 10 minutes de combat au plus

local nextId = 0
local function unit(typeId: string, ctx: Combat.Context): Unit
	nextId += 1
	local org = DivisionConfig.types[typeId].org
	return Combat.makeUnit(typeId, { id = typeId .. nextId, org = org, orgMax = org, str = 100 }, ctx)
end

local function many(n: number, typeId: string, ctx: Combat.Context): { Unit }
	local list = {}
	for _ = 1, n do
		table.insert(list, unit(typeId, ctx))
	end
	return list
end

local function join(a: { Unit }, b: { Unit }): { Unit }
	local list = table.clone(a)
	for _, u in b do
		table.insert(list, u)
	end
	return list
end

-- Combat jusqu'à la fin (ou `ticks` ticks) : résultat, nombre de ticks, état final
local function fight(battle: Combat.Battle, ticks: number?): (string, number, Combat.Battle)
	local current = battle
	local limit = ticks or MAX_TICKS
	for tick = 1, limit do
		local nextBattle, report = Combat.resolveTick(current)
		current = nextBattle
		if report.result ~= "EnCours" then
			return report.result, tick, current
		end
	end
	return "EnCours", limit, current
end

local function inLine(units: { Unit }): number
	local n = 0
	for _, u in units do
		if u.line then
			n += 1
		end
	end
	return n
end

local function pct(x: number): string
	return string.format("%d %%", math.floor(x * 100 + 0.5))
end

local tests: { () -> Result } = {}

-- 1. 3 infanteries attaquent 1 infanterie en plaine -> l'attaquant gagne
table.insert(tests, function(): Result
	local attack = { attacking = true, terrain = "Plaine" }
	local defend = { attacking = false, terrain = "Plaine" }
	local result, ticks, final = fight({ attackers = many(3, "Infanterie", attack), defenders = many(1, "Infanterie", defend), width = Combat.width("Plaine", 1) })
	return {
		name = "3 infanteries contre 1 en plaine : l'attaquant gagne",
		ok = result == "Victoire",
		detail = `{result} en {ticks} ticks, organisation de l'attaquant {pct(Combat.orgRatio(final.attackers))}`,
	}
end)

-- 2. 3 infanteries attaquent 2 infanteries retranchées en montagne derrière une rivière -> échec
local function mountainDefenders(): { Unit }
	return many(2, "Infanterie", { attacking = false, terrain = "Montagne", entrenchment = 1 })
end
local acrossRiver = { attacking = true, terrain = "Montagne", river = "Riviere" }
local test2Ticks = 0
local test2DefenderOrg = 1

table.insert(tests, function(): Result
	local result, ticks, final = fight({ attackers = many(3, "Infanterie", acrossRiver), defenders = mountainDefenders(), width = Combat.width("Montagne", 1) })
	test2Ticks = ticks
	test2DefenderOrg = Combat.orgRatio(final.defenders)
	return {
		name = "3 infanteries contre 2 retranchées en montagne, derrière une rivière : l'attaque échoue",
		ok = result == "Repli",
		detail = `{result} en {ticks} ticks, organisation du défenseur {pct(test2DefenderOrg)}`,
	}
end)

-- 3. Même attaque depuis 2 régions -> plus de divisions en ligne, résultat meilleur qu'en 2
table.insert(tests, function(): Result
	-- a) les 3 mêmes infanteries, dont une arrive par une autre région, sans rivière
	local attackers = join(many(2, "Infanterie", acrossRiver), many(1, "Infanterie", { attacking = true, terrain = "Montagne" }))
	local _, _, final = fight({ attackers = attackers, defenders = mountainDefenders(), width = Combat.width("Montagne", 2) }, math.max(test2Ticks, 1))
	local defenderOrg = Combat.orgRatio(final.defenders)
	-- b) 6 infanteries : 4 en ligne depuis une seule région (largeur 4), 6 depuis deux (largeur 6)
	local one = Combat.resolveTick({ attackers = many(6, "Infanterie", acrossRiver), defenders = mountainDefenders(), width = Combat.width("Montagne", 1) })
	local two = Combat.resolveTick({ attackers = many(6, "Infanterie", acrossRiver), defenders = mountainDefenders(), width = Combat.width("Montagne", 2) })
	local lineOne, lineTwo = inLine(one.attackers), inLine(two.attackers)
	local hurtOne, hurtTwo = 1 - Combat.orgRatio(one.defenders), 1 - Combat.orgRatio(two.defenders)
	return {
		name = "Même attaque depuis 2 régions : plus de divisions en ligne, meilleur résultat",
		ok = defenderOrg < test2DefenderOrg and lineTwo > lineOne and hurtTwo > hurtOne,
		detail = `défenseur à {pct(defenderOrg)} (contre {pct(test2DefenderOrg)} en 2) ; 6 infanteries : {lineOne} puis {lineTwo} en ligne`,
	}
end)

-- 4. Blindés contre infanterie sans anti-char -> les blindés ne subissent presque rien
local tankLossVsInfantry = 0
table.insert(tests, function(): Result
	local tanks = many(2, "Blindee", { attacking = true, terrain = "Plaine" })
	local battle = { attackers = tanks, defenders = many(2, "Infanterie", { attacking = false, terrain = "Plaine" }), width = Combat.width("Plaine", 1) }
	local after = Combat.resolveTick(battle)
	tankLossVsInfantry = 1 - Combat.orgRatio(after.attackers)
	local result, ticks, final = fight(battle)
	local tankOrg = Combat.orgRatio(final.attackers)
	return {
		name = "Blindés contre infanterie sans anti-char : les blindés ne subissent presque rien",
		ok = result == "Victoire" and tankOrg > 0.75,
		detail = `{result} en {ticks} ticks, organisation des blindés {pct(tankOrg)}`,
	}
end)

-- 5. Blindés contre division anti-char -> le blindage est perforé
table.insert(tests, function(): Result
	local battle = {
		attackers = many(2, "Blindee", { attacking = true, terrain = "Plaine" }),
		defenders = many(2, "AntiChar", { attacking = false, terrain = "Plaine" }),
		width = Combat.width("Plaine", 1),
	}
	local after = Combat.resolveTick(battle)
	local loss = 1 - Combat.orgRatio(after.attackers)
	return {
		name = "Blindés contre anti-char : le blindage est perforé",
		ok = loss > tankLossVsInfantry * 4,
		detail = `perte d'organisation par tick : {string.format("%.1f", loss * 100)} % (contre {string.format("%.1f", tankLossVsInfantry * 100)} % face à l'infanterie)`,
	}
end)

-- Lance tous les scénarios ; renvoie les résultats dans l'ordre
return function(): { Result }
	local results = {}
	for i, test in tests do
		local ok, value = pcall(test)
		if ok then
			table.insert(results, value)
		else
			table.insert(results, { name = `Test {i}`, ok = false, detail = "erreur : " .. tostring(value) })
		end
	end
	return results
end
