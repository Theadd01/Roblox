--!strict
-- Scénarios de combat automatisés (cahier des charges v2, section 2 : objectifs de durée,
-- répartition des cibles, largeur de front, défenseur, nombre, arrière, moral).
-- Lancés dans Studio par Tests/LanceurTests (fenêtre Output) et hors de Studio par
-- tools/lune/run_tests.luau : uniquement les fonctions pures de server/Military/Combat.
-- Chaque tick, comme BattleManager, les soldats tombés quittent la bataille (repli ou mort).

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Combat = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Military"):WaitForChild("Combat"))
local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local DivisionConfig = require(Config:WaitForChild("Divisions")) :: any
local CombatConfig = require(Config:WaitForChild("CombatConfig")) :: any

type Unit = Combat.Unit
type Result = { name: string, ok: boolean, detail: string }

local MAX_TICKS = 600 -- 5 minutes de combat au plus

local nextId = 0
local function unit(typeId: string, ctx: Combat.Context): Unit
	nextId += 1
	local org = DivisionConfig.types[typeId].org
	return Combat.makeUnit(typeId, { id = string.format("%s%03d", typeId, nextId), org = org, orgMax = org, str = 100 }, ctx)
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

local ATTACK: Combat.Context = { attacking = true, terrain = "Plaine" }
local DEFEND: Combat.Context = { attacking = false, terrain = "Plaine" }

type Outcome = {
	result: string,
	seconds: number,
	firstDown: number?, -- secondes avant le premier soldat tombé
	attackersLeft: number,
	defendersLeft: number,
	routed: string?,
	maxLine: number, -- soldats engagés en même temps, au plus (attaquants)
	idle: number, -- ticks où un attaquant engagé n'avait pas de cible alors qu'un défenseur était en ligne
	rearHit: boolean, -- un soldat de l'arrière a été visé alors que la première ligne tenait
}

-- Combat jusqu'à la fin, en retirant chaque tick les soldats tombés
local function fight(attackers: { Unit }, defenders: { Unit }): Outcome
	local battle = Combat.newBattle(attackers, defenders)
	local outcome: Outcome = { result = "EnCours", seconds = 0, firstDown = nil, attackersLeft = 0, defendersLeft = 0, routed = nil, maxLine = 0, idle = 0, rearHit = false }
	for tick = 1, MAX_TICKS do
		local nextBattle, report = Combat.resolveTick(battle)
		outcome.seconds = tick * CombatConfig.tickSeconds
		local line, defendersInLine, frontInLine = 0, 0, 0
		local rearIds: { [string]: boolean } = {}
		for _, u in nextBattle.defenders do
			if u.line then
				defendersInLine += 1
				if u.rear then
					rearIds[u.id] = true
				else
					frontInLine += 1
				end
			end
		end
		for _, u in nextBattle.attackers do
			if u.line then
				line += 1
				if not u.target and defendersInLine > 0 then
					outcome.idle += 1
				end
			end
		end
		for _, target in report.shots do
			if rearIds[target] and frontInLine > 0 then
				outcome.rearHit = true
			end
		end
		outcome.maxLine = math.max(outcome.maxLine, line)
		if next(report.down) and not outcome.firstDown then
			outcome.firstDown = outcome.seconds
		end
		nextBattle.attackers = Combat.withoutDown(nextBattle.attackers)
		nextBattle.defenders = Combat.withoutDown(nextBattle.defenders)
		battle = nextBattle
		if report.result ~= "EnCours" then
			outcome.result = report.result
			outcome.routed = report.routed
			break
		end
	end
	outcome.attackersLeft = #battle.attackers
	outcome.defendersLeft = #battle.defenders
	return outcome
end

local function describe(o: Outcome): string
	return `{o.result} en {o.seconds} s ; restent {o.attackersLeft} attaquants, {o.defendersLeft} défenseurs`
		.. (if o.routed then ` ; repli {if o.routed == "attackers" then "de l'attaquant" else "du défenseur"}` else "")
end

local tests: { () -> Result } = {}

-- 1. Un soldat meurt en 2 à 4 s face à un soldat équivalent
table.insert(tests, function(): Result
	local o = fight(many(1, "Infanterie", ATTACK), many(1, "Infanterie", DEFEND))
	local t = o.firstDown or math.huge
	return {
		name = "1 infanterie contre 1 : un soldat meurt en 2 à 4 s",
		ok = t >= 2 and t <= 4,
		detail = `premier soldat tombé après {t} s ; {describe(o)}`,
	}
end)

-- 2. 10 contre 10 : 15 à 30 s, et quelqu'un gagne
table.insert(tests, function(): Result
	local o = fight(many(10, "Infanterie", ATTACK), many(10, "Infanterie", DEFEND))
	return {
		name = "10 contre 10 en plaine : 15 à 30 s, la bataille se termine",
		ok = o.result ~= "EnCours" and o.seconds >= 15 and o.seconds <= 30,
		detail = describe(o),
	}
end)

-- 3. Renforts de 2 régions : 20 contre 10, l'attaquant prend la région, vite
table.insert(tests, function(): Result
	local o = fight(many(20, "Infanterie", ATTACK), many(10, "Infanterie", DEFEND))
	return {
		name = "20 contre 10 (2 régions voisines) : la région est prise en moins de 20 s",
		ok = o.result == "Victoire" and o.seconds <= 20,
		detail = describe(o),
	}
end)

-- 4. Largeur de front : jamais plus de 20 soldats engagés par camp
table.insert(tests, function(): Result
	local o = fight(many(60, "Infanterie", ATTACK), many(45, "Infanterie", DEFEND))
	return {
		name = "60 contre 45 : au plus 20 soldats engagés en même temps, les autres en réserve",
		ok = o.maxLine == CombatConfig.frontWidth and o.result == "Victoire",
		detail = `au plus {o.maxLine} en ligne ; {describe(o)}`,
	}
end)

-- 5. Cibles en rotation : tous les soldats engagés tirent, répartis équitablement
table.insert(tests, function(): Result
	local battle = Combat.newBattle(many(12, "Infanterie", ATTACK), many(6, "Infanterie", DEFEND))
	local worstGap, idle = 0, 0
	for _ = 1, 40 do
		local nextBattle, report = Combat.resolveTick(battle)
		local load: { [string]: number } = {}
		local defenders = 0
		for _, d in nextBattle.defenders do
			if d.line and d.hp > 0 then
				load[d.id] = 0
				defenders += 1
			end
		end
		for _, a in nextBattle.attackers do
			-- une cible tombée pendant ce tick est remplacée au tick suivant
			if a.line and a.hp > 0 then
				if a.target and load[a.target] then
					load[a.target] += 1
				elseif not a.target and defenders > 0 then
					idle += 1
				end
			end
		end
		local low, high = math.huge, 0
		for _, n in load do
			low, high = math.min(low, n), math.max(high, n)
		end
		if defenders > 0 then
			worstGap = math.max(worstGap, high - low)
		end
		nextBattle.attackers = Combat.withoutDown(nextBattle.attackers)
		nextBattle.defenders = Combat.withoutDown(nextBattle.defenders)
		battle = nextBattle
		if report.result ~= "EnCours" then
			break
		end
	end
	return {
		name = "12 contre 6 : chaque soldat engagé a une cible, réparties à 1 près",
		ok = idle == 0 and worstGap <= 1,
		detail = `soldats engagés sans cible : {idle} ; écart de cibles au plus {worstGap}`,
	}
end)

-- 6. Défenseur +15 % : à nombre égal, il tient
table.insert(tests, function(): Result
	local o = fight(many(5, "Infanterie", ATTACK), many(5, "Infanterie", DEFEND))
	return {
		name = "5 contre 5 : le défenseur (+15 %) tient la région",
		ok = o.result == "Repli",
		detail = describe(o),
	}
end)

-- 7. L'artillerie à l'arrière n'est pas visée tant que la première ligne tient
table.insert(tests, function(): Result
	local defenders = join(many(4, "Infanterie", DEFEND), many(3, "Artillerie", DEFEND))
	local o = fight(many(6, "Infanterie", ATTACK), defenders)
	return {
		name = "Artillerie à l'arrière : épargnée tant que l'infanterie tient la ligne",
		ok = not o.rearHit and o.idle == 0,
		detail = `artillerie visée trop tôt : {o.rearHit} ; {describe(o)}`,
	}
end)

-- 8. Blindés contre infanterie : les blindés gagnent nettement
table.insert(tests, function(): Result
	local o = fight(many(4, "Blindee", ATTACK), many(8, "Infanterie", DEFEND))
	return {
		name = "4 blindés contre 8 infanteries : les blindés gagnent sans perte",
		ok = o.result == "Victoire" and o.attackersLeft == 4,
		detail = describe(o),
	}
end)

-- 9. Moral : un camp qui perd vite se replie avant le dernier soldat
table.insert(tests, function(): Result
	local o = fight(many(30, "Infanterie", ATTACK), many(10, "Infanterie", DEFEND))
	return {
		name = "30 contre 10 : le défenseur submergé se replie, la région tombe vite",
		ok = o.result == "Victoire" and o.seconds <= 15,
		detail = describe(o),
	}
end)

-- 10. Montagne, rivière et retranchement : l'attaque à nombre égal échoue
table.insert(tests, function(): Result
	local o = fight(
		many(6, "Infanterie", { attacking = true, terrain = "Montagne", river = "Riviere" }),
		many(6, "Infanterie", { attacking = false, terrain = "Montagne", entrenchment = 1 })
	)
	return {
		name = "Montagne, rivière, retranchement : l'attaque à nombre égal échoue",
		ok = o.result == "Repli" and o.defendersLeft >= 5,
		detail = describe(o),
	}
end)

-- 11. Recherche : des soldats améliorés gagnent à nombre égal
table.insert(tests, function(): Result
	local veterans = many(10, "Infanterie", { attacking = true, terrain = "Plaine", health = 0.4, damage = 0.3 })
	local o = fight(veterans, many(10, "Infanterie", DEFEND))
	return {
		name = "Recherche niveau 3 (+40 % PV, +30 % dégâts) : 10 contre 10, l'attaquant gagne",
		ok = o.result == "Victoire",
		detail = describe(o),
	}
end)

-- 12. Région vide : prise tout de suite
table.insert(tests, function(): Result
	local _, report = Combat.resolveTick(Combat.newBattle(many(3, "Infanterie", ATTACK), {}))
	return {
		name = "Région sans défenseur : prise au premier tick",
		ok = report.result == "Victoire",
		detail = report.result,
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
