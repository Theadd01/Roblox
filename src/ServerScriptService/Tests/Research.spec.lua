--!strict
-- Scénarios automatisés de la recherche (cahier des charges v2, section 4) : l'arbre de
-- Config/Technologies est cohérent, les niveaux de l'infanterie suivent le tableau du cahier, les
-- effets sont globaux et cumulés (shared/TechState, fonctions pures), sans partie en cours.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Technologies = require(Shared:WaitForChild("Config"):WaitForChild("Technologies")) :: any
local Military = require(Shared:WaitForChild("Config"):WaitForChild("Military")) :: any
local TechState = require(Shared:WaitForChild("TechState")) :: any

type Result = { name: string, ok: boolean, detail: string }

local tests: { () -> Result } = {}

local function close(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end

-- 1. L'arbre est cohérent : prérequis existants, à gauche de la technologie, dans la même
-- catégorie, à un niveau qui existe ; une seule carte par case de la grille
table.insert(tests, function(): Result
	local problems = {}
	local branches: { [string]: boolean } = {}
	for _, branch in Technologies.branches do
		branches[branch.id] = true
	end
	local cells: { [string]: string } = {}
	for _, tech in Technologies.list do
		if not branches[tech.branch] then
			table.insert(problems, `{tech.id} : catégorie {tech.branch} inconnue`)
		end
		local cell = `{tech.branch}:{tech.column}:{tech.row}`
		if cells[cell] then
			table.insert(problems, `{tech.id} et {cells[cell]} sur la même case`)
		end
		cells[cell] = tech.id
		for _, requirement in tech.requires do
			local other = Technologies.get(requirement.id)
			if not other then
				table.insert(problems, `{tech.id} : prérequis {requirement.id} inconnu`)
			elseif requirement.level > Technologies.maxLevel(other) or other.column >= tech.column or other.branch ~= tech.branch then
				table.insert(problems, `{tech.id} : prérequis {requirement.id} niveau {requirement.level} mal placé`)
			end
		end
		for level, entry in tech.levels do
			if level > Technologies.startLevel(tech) and (entry.time <= 0 or next(entry.cost) == nil) then
				table.insert(problems, `{tech.id} niveau {level} : coût ou durée manquants`)
			end
		end
	end
	return {
		name = "Arbre cohérent (prérequis, catégories, grille, coûts)",
		ok = #problems == 0,
		detail = if #problems == 0 then `{#Technologies.list} technologies, {#Technologies.branches} catégories` else table.concat(problems, " ; "),
	}
end)

-- 2. Niveaux de l'infanterie : le tableau du cahier des charges
table.insert(tests, function(): Result
	local expected = { { 0, 0 }, { 0.2, 0.15 }, { 0.4, 0.3 }, { 0.65, 0.5 }, { 1, 0.75 } }
	local parts = {}
	local ok = true
	for level, values in expected do
		local levels = { EquipementInfanterie = level }
		local health = TechState.sumLevels(levels, "divisionHealth", TechState.forType("Infanterie"))
		local damage = TechState.sumLevels(levels, "divisionDamage", TechState.forType("Infanterie"))
		ok = ok and close(health, values[1]) and close(damage, values[2])
		table.insert(parts, `niv. {level} : +{math.floor(health * 100 + 0.5)} % PV, +{math.floor(damage * 100 + 0.5)} % dégâts`)
	end
	local tech = Technologies.get("EquipementInfanterie")
	ok = ok and tech ~= nil and tech.base == true and next(tech.levels[1].cost) == nil and Technologies.maxLevel(tech) == 5
	return {
		name = "Infanterie niveaux 1 à 5 : 100/120/140/165/200 % de PV, 100/115/130/150/175 % de dégâts (niveau 1 gratuit)",
		ok = ok,
		detail = table.concat(parts, " ; "),
	}
end)

-- 3. Effets : globaux, par type, et capacité de stationnement 10 -> 12 -> 15
table.insert(tests, function(): Result
	local armor = TechState.sumLevels({ BlindesModernes = 3 }, "divisionHealth", TechState.forType("Blindee"))
	local armorOnInfantry = TechState.sumLevels({ BlindesModernes = 3 }, "divisionHealth", TechState.forType("Infanterie"))
	local caps = {}
	for level = 0, 2 do
		table.insert(caps, Military.maxDivisionsPerRegion + TechState.sumLevels({ Garnisons = level }, "stationing"))
	end
	local slots = Technologies.slots + TechState.sumLevels({ CentresRecherche = 2 }, "researchSlots")
	local recruit = 1 + TechState.sumLevels({ Mobilisation = 3 }, "recruitTime")
	local income = 1 + TechState.sumLevels({ Fiscalite = 4 }, "income")
	return {
		name = "Effets : blindés seulement pour les blindés, stationnement 10/12/15, emplacements, recrutement, revenus",
		ok = close(armor, 0.4) and armorOnInfantry == 0 and caps[1] == 10 and caps[2] == 12 and caps[3] == 15 and slots == 5
			and close(recruit, 0.55) and close(income, 1.5),
		detail = `blindés +{armor * 100} % (infanterie +{armorOnInfantry * 100} %) ; stationnement {table.concat(caps, "/")} ; {slots} emplacements ; entraînement x{recruit} ; impôts x{income}`,
	}
end)

-- 4. Format publié : niveaux et file de recherche (aller-retour)
table.insert(tests, function(): Result
	local levels = TechState.parse(TechState.format({ Radars = 2, EquipementInfanterie = 4 }))
	local legacy = TechState.parse("Radars,Logistique")
	local queue = TechState.parseQueue(TechState.formatQueue({ { id = "Fiscalite", level = 2, start = 100.5, finish = 160.25 } }))
	return {
		name = "Niveaux et file publiés en attributs : relus à l'identique (ancien format compris)",
		ok = levels.Radars == 2 and levels.EquipementInfanterie == 4 and legacy.Radars == 1 and legacy.Logistique == 1
			and #queue == 1 and queue[1].id == "Fiscalite" and queue[1].level == 2 and close(queue[1].finish, 160.25),
		detail = `{TechState.format(levels)} ; file : {TechState.formatQueue(queue)}`,
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
