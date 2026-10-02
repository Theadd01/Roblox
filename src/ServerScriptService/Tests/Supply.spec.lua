--!strict
-- Scénarios de ravitaillement automatisés (SYSTEME_MILITAIRE.md, section 10, tests 6 et 7).
-- Lancés dans Studio par tests/LanceurTests.server.luau : fonctions pures de Supply, Combat et
-- Movement, sur la vraie carte, sans partie en cours.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Military = ServerScriptService:WaitForChild("Server"):WaitForChild("Military")
local Supply = require(Military:WaitForChild("Supply"))
local Combat = require(Military:WaitForChild("Combat"))
local Movement = require(Military:WaitForChild("Movement"))
local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local DivisionConfig = require(Config:WaitForChild("Divisions")) :: any

type Result = { name: string, ok: boolean, detail: string }

local function unit(typeId: string, id: string, ctx: Combat.Context): Combat.Unit
	local org = DivisionConfig.types[typeId].org
	return Combat.makeUnit(typeId, { id = id, org = org, orgMax = org, str = 100 }, ctx)
end

local function fight(battle: Combat.Battle): (string, number)
	local current = battle
	for tick = 1, 300 do
		local nextBattle, report = Combat.resolveTick(current)
		current = nextBattle
		if report.result ~= "EnCours" then
			return report.result, tick
		end
	end
	return "EnCours", 300
end

local tests: { () -> Result } = {}

-- 6. Division encerclée -> perd son ravitaillement, puis est détruite si elle perd la bataille
table.insert(tests, function(): Result
	-- la France de départ ; l'ennemi a pris la Bourgogne-Franche-Comté et l'Île-de-France :
	-- le Grand Est (FRA_5) n'est plus relié à Paris
	local lost = { FRA = false, FRA_3 = true }
	local function french(regionId: string): boolean
		return Regions[regionId] ~= nil and Regions[regionId].startOwner == "FRA" and not lost[regionId]
	end
	local before = Supply.network({ "FRA" }, function(regionId: string): boolean
		return Regions[regionId].startOwner == "FRA"
	end)
	-- capitale perdue elle aussi : il reste les ports (Supply.sourcesOf) ; ici, la capitale tombe
	lost.FRA = true
	local after = Supply.network({ "FRA_8" }, french) -- Marseille, un port encore français
	local cutOff = before.FRA_5 == true and after.FRA_5 ~= true
	-- au combat : la même division retranchée tient ravitaillée, et cède sans ravitaillement
	local supplied = fight({
		attackers = { unit("Infanterie", "A", { attacking = true, terrain = "Plaine" }) },
		defenders = { unit("Infanterie", "D", { attacking = false, terrain = "Plaine", entrenchment = 1 }) },
		width = Combat.width("Plaine", 1),
	})
	local cut = fight({
		attackers = { unit("Infanterie", "A", { attacking = true, terrain = "Plaine" }) },
		defenders = { unit("Infanterie", "D", { attacking = false, terrain = "Plaine", entrenchment = 1, supplied = false }) },
		width = Combat.width("Plaine", 1),
	})
	-- encerclée : aucune région voisine du réseau où reculer (BattleManager la détruit alors)
	local escape = false
	for _, link in Regions.FRA_5.neighbors do
		if not link.bySea and after[link.region] then
			escape = true
		end
	end
	return {
		name = "Division encerclée : plus de ravitaillement, défaite, pas de repli possible",
		ok = cutOff and supplied == "Repli" and cut == "Victoire" and not escape,
		detail = `Grand Est relié avant : {before.FRA_5 == true}, après : {after.FRA_5 == true} ; ravitaillée : {supplied}, coupée : {cut} ; repli possible : {escape}`,
	}
end)

-- 7. Blindés sans pétrole -> vitesse et attaque fortement réduites
table.insert(tests, function(): Result
	local withFuel = unit("Blindee", "B1", { attacking = true, terrain = "Plaine", fuel = true })
	local noFuel = unit("Blindee", "B2", { attacking = true, terrain = "Plaine", fuel = false })
	local fast = Movement.stepSeconds("Blindee", 140, "Plaine", true)
	local slow = Movement.stepSeconds("Blindee", 140, "Plaine", false)
	return {
		name = "Blindés sans pétrole : vitesse et attaque fortement réduites",
		ok = noFuel.attack <= withFuel.attack * 0.5 + 1e-6 and slow >= fast * 1.5,
		detail = `attaque {string.format("%.2f", withFuel.attack)} -> {string.format("%.2f", noFuel.attack)} ; étape de 140 studs : {math.floor(fast + 0.5)} s -> {math.floor(slow + 0.5)} s`,
	}
end)

return function(): { Result }
	local results = {}
	for i, test in tests do
		local ok, value = pcall(test)
		if ok then
			table.insert(results, value)
		else
			table.insert(results, { name = `Test {i + 5}`, ok = false, detail = "erreur : " .. tostring(value) })
		end
	end
	return results
end
