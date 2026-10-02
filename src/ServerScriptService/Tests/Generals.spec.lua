--!strict
-- Scénarios automatisés des généraux (cahier des charges v2, section 5) : règles pures de
-- server/Military/Armies (achat, niveaux, capacité, bonus) et combat d'une armée de général
-- (server/Military/Combat), sans partie en cours.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Military = ServerScriptService:WaitForChild("Server"):WaitForChild("Military")
local Armies = require(Military:WaitForChild("Armies"))
local Combat = require(Military:WaitForChild("Combat"))
local Divisions = require(Military:WaitForChild("Divisions"))
local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local MilitaryConfig = require(Config:WaitForChild("Military")) :: any
local DivisionConfig = require(Config:WaitForChild("Divisions")) :: any

type Result = { name: string, ok: boolean, detail: string }

local tests: { () -> Result } = {}

-- 1. Achat : dans une de ses régions, 5 généraux au plus ; plusieurs dans une même région
table.insert(tests, function(): Result
	local own = Armies.buyRule("FRA", "FRA", 0)
	local foreign = Armies.buyRule("FRA", "DEU", 0)
	local tooMany, why = Armies.buyRule("FRA", "FRA", MilitaryConfig.generals.maxPerCountry)
	return {
		name = "Achat d'un général : sa région oui, une région étrangère non, 5 au plus",
		ok = own and not foreign and not tooMany,
		detail = `sa région : {own} ; étrangère : {foreign} ; 6e : {tostring(why)}`,
	}
end)

-- 2. Niveaux et capacité : niveau 1 = 20 troupes, +10 par niveau (niveau 5 : 60)
table.insert(tests, function(): Result
	local levels = { Armies.levelFor(0), Armies.levelFor(24), Armies.levelFor(25), Armies.levelFor(60), Armies.levelFor(500) }
	local capacity = MilitaryConfig.generals.capacity
	return {
		name = "Niveaux (expérience) et capacité : 20 au niveau 1, +10 par niveau, 60 au niveau 5",
		ok = levels[1] == 1 and levels[2] == 1 and levels[3] == 2 and levels[4] == 3 and levels[5] == 5
			and capacity[1] == 20 and capacity[2] == 30 and capacity[5] == 60,
		detail = `niveaux pour 0/24/25/60/500 xp : {table.concat(levels, "/")} ; capacité : {table.concat(capacity, "/")}`,
	}
end)

-- 3. Bonus de ses troupes : niveau, bonus choisis
table.insert(tests, function(): Result
	local general = Instance.new("Folder")
	general:SetAttribute("Niveau", 3)
	general:SetAttribute("Traits", "")
	general:SetAttribute("Bonus_attack", 1)
	local attack = Armies.generalBonus(general, "attack")
	local defense = Armies.generalBonus(general, "defense")
	local speed = Armies.generalBonus(general, "speed")
	general:Destroy()
	local function close(a: number, b: number): boolean
		return math.abs(a - b) < 1e-6
	end
	return {
		name = "Bonus d'un général niveau 3 avec « Attaque » choisi : +20 % d'attaque, +10 % de défense",
		ok = close(attack, 0.2) and close(defense, 0.1) and close(speed, 0),
		detail = `attaque {attack}, défense {defense}, vitesse {speed}`,
	}
end)

-- 4. Une armée de général ignore la limite de 10 : 30 troupes (+20 %) contre une région de 10
table.insert(tests, function(): Result
	local n = 0
	local function many(count: number, ctx: Combat.Context): { Combat.Unit }
		local list = {}
		for _ = 1, count do
			n += 1
			local org = DivisionConfig.types.Infanterie.org
			table.insert(list, Combat.makeUnit("Infanterie", { id = string.format("G%03d", n), org = org, orgMax = org, str = 100 }, ctx))
		end
		return list
	end
	local battle = Combat.newBattle(many(30, { attacking = true, terrain = "Plaine", attackBonus = 0.2 }), many(MilitaryConfig.maxDivisionsPerRegion, { attacking = false, terrain = "Plaine" }))
	local result, seconds = "EnCours", 0
	for tick = 1, 400 do
		local nextBattle, report = Combat.resolveTick(battle)
		nextBattle.attackers = Combat.withoutDown(nextBattle.attackers)
		nextBattle.defenders = Combat.withoutDown(nextBattle.defenders)
		battle = nextBattle
		if report.result ~= "EnCours" then
			result, seconds = report.result, tick * 0.5
			break
		end
	end
	return {
		name = "Armée de 30 troupes d'un général contre une région pleine (10) : prise en moins de 15 s",
		ok = result == "Victoire" and seconds <= 15,
		detail = `{result} en {seconds} s`,
	}
end)

-- 5. Vitesse : un général va à la vitesse de sa troupe la plus lente (artillerie < blindés)
table.insert(tests, function(): Result
	local tanks = Divisions.stepSeconds("Blindee", 140, "Plaine", true)
	local guns = Divisions.stepSeconds("Artillerie", 140, "Plaine", true)
	return {
		name = "Vitesse : l'artillerie est plus lente que les blindés (l'armée suit la plus lente)",
		ok = guns > tanks,
		detail = `étape de 140 studs : blindés {math.floor(tanks + 0.5)} s, artillerie {math.floor(guns + 0.5)} s`,
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
