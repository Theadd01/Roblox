--!nocheck
-- Simulation des durées de combat (équilibrage de Config/CombatConfig) :
-- `lune run tools/lune/simulate_combat.luau`
local process = require("@lune/process")
local Harness = require("./harness")
local game = Harness.build(process.cwd)
local Combat = Harness.require(game:GetService("ServerScriptService").Server.Military.Combat)
local CombatConfig = Harness.require(game:GetService("ReplicatedStorage").Shared.Config.CombatConfig)
local Divisions = Harness.require(game:GetService("ReplicatedStorage").Shared.Config.Divisions)

local n = 0
local function many(count, typeId, ctx)
	local list = {}
	for _ = 1, count do
		n += 1
		local org = Divisions.types[typeId].org
		table.insert(list, Combat.makeUnit(typeId, { id = typeId .. n, org = org, orgMax = org, str = 100 }, ctx))
	end
	return list
end
local function run(label, attackers, defenders)
	local battle = Combat.newBattle(attackers, defenders)
	local firstDown, t = nil, 0
	local maxLine = 0
	for tick = 1, 1000 do
		local nextBattle, report = Combat.resolveTick(battle)
		t = tick * CombatConfig.tickSeconds
		local line = 0
		for _, u in nextBattle.attackers do if u.line then line += 1 end end
		maxLine = math.max(maxLine, line)
		if next(report.down) and not firstDown then firstDown = t end
		nextBattle.attackers = Combat.withoutDown(nextBattle.attackers)
		nextBattle.defenders = Combat.withoutDown(nextBattle.defenders)
		battle = nextBattle
		if report.result ~= "EnCours" then
			print(string.format("%-42s %-8s en %5.1f s (1er tombé %4.1f s) ; restent A=%d D=%d ; repli=%s ; max en ligne=%d", label, report.result, t, firstDown or -1, #battle.attackers, #battle.defenders, tostring(report.routed), maxLine))
			return
		end
	end
	print(label, "pas fini")
end
local A = { attacking = true, terrain = "Plaine" }
local D = { attacking = false, terrain = "Plaine" }
run("1 inf contre 1 inf", many(1, "Infanterie", A), many(1, "Infanterie", D))
run("5 inf contre 5 inf", many(5, "Infanterie", A), many(5, "Infanterie", D))
run("10 inf contre 10 inf", many(10, "Infanterie", A), many(10, "Infanterie", D))
run("20 inf contre 10 inf (2 régions)", many(20, "Infanterie", A), many(10, "Infanterie", D))
run("15 inf contre 10 inf", many(15, "Infanterie", A), many(10, "Infanterie", D))
run("30 inf contre 10 inf (général)", many(30, "Infanterie", A), many(10, "Infanterie", D))
run("40 inf contre 20 inf", many(40, "Infanterie", A), many(20, "Infanterie", D))
run("10 inf contre 10 inf retranchées", many(10, "Infanterie", A), many(10, "Infanterie", { attacking = false, terrain = "Plaine", entrenchment = 1 }))
run("10 inf contre 10 inf en montagne", many(10, "Infanterie", { attacking = true, terrain = "Montagne" }), many(10, "Infanterie", { attacking = false, terrain = "Montagne" }))
run("4 blindées contre 8 inf", many(4, "Blindee", A), many(8, "Infanterie", D))
run("6 inf + 4 art contre 10 inf", (function() local l = many(6, "Infanterie", A) for _, u in many(4, "Artillerie", A) do table.insert(l, u) end return l end)(), many(10, "Infanterie", D))
run("4 blindées contre 4 antichar", many(4, "Blindee", A), many(4, "AntiChar", D))
run("10 inf (+50% recherche) contre 10 inf", many(10, "Infanterie", { attacking = true, terrain = "Plaine", health = 0.4, damage = 0.3 }), many(10, "Infanterie", D))
run("3 inf contre région vide", many(3, "Infanterie", A), {})
