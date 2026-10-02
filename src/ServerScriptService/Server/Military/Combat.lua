--!strict
-- Résolution du combat terrestre (SYSTEME_MILITAIRE.md, 5.2 à 5.4) : fonctions PURES, sans instance,
-- sans horloge et sans hasard, pour être testées seules (tests/Combat.spec.luau).
--   Combat.makeUnit : une division prête au combat (statistiques de son type x modificateurs) ;
--   Combat.width : largeur de bataille (terrain + directions d'attaque) ;
--   Combat.deploy : qui est en ligne, qui reste en réserve ;
--   Combat.resolveTick : un tick de combat -> nouvel état (l'ancien n'est pas modifié) ;
--   Combat.estimate : qui gagnerait si rien ne change (affichage, IA).
-- Un tick : chaque division en ligne tire (attaque douce contre ce qui n'est pas blindé, dure
-- contre ce qui l'est) sur toute la ligne ennemie ; chaque cible absorbe une partie des coups avec
-- sa défense (en défendant) ou sa percée (en attaquant) ; les coups non absorbés font 4 fois plus
-- de dégâts. Les dégâts retirent surtout de l'organisation, un peu de force.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local DivisionConfig = require(Config:WaitForChild("Divisions")) :: any
local Terrain = require(Config:WaitForChild("Terrain")) :: any
local Military = require(Config:WaitForChild("Military")) :: any

export type Unit = {
	id: string,
	org: number,
	orgMax: number,
	str: number, -- force (0 à 100)
	soft: number,
	hard: number,
	defense: number,
	breakthrough: number,
	armor: number,
	piercing: number,
	hardness: number,
	width: number,
	attack: number, -- multiplicateur de l'attaque (terrain, rivière, expérience, ravitaillement...)
	defend: number, -- multiplicateur de la défense ou de la percée (retranchement, fortification...)
	orgLoss: number, -- multiplicateur de l'organisation perdue (général « Meneur d'hommes » : moins)
	line: boolean, -- en première ligne (sinon en réserve)
}

export type Battle = {
	attackers: { Unit },
	defenders: { Unit },
	width: number,
}

export type Report = {
	result: string, -- "EnCours", "Victoire" (le défenseur cède) ou "Repli" (l'attaque échoue)
	orgLostAttackers: number,
	orgLostDefenders: number,
	strLost: { [string]: number }, -- force perdue par division (id)
}

-- Ce qui modifie une division au combat (tout est facultatif)
export type Context = {
	attacking: boolean, -- vrai pour l'attaquant
	terrain: string?, -- terrain de la région disputée
	river: string?, -- rivière franchie par l'attaquant ("Riviere" ou "Fleuve")
	entrenchment: number?, -- retranchement du défenseur (0 à 1 : part du maximum)
	fortification: number?, -- niveau de fortification de la région (défenseur)
	experience: number?, -- 0 à 100
	supplied: boolean?, -- faux : réserve de ravitaillement épuisée
	fuel: boolean?, -- faux : plus de pétrole (blindés et motorisés)
	attackBonus: number?, -- bonus d'attaque en plus (général, planification, projets...)
	defenseBonus: number?, -- bonus de défense en plus
	factor: number?, -- multiplicateur global (ex. milice d'un pays affaibli)
	resilience: number?, -- part de l'organisation perdue évitée (général « Meneur d'hommes »)
}

export type UnitState = {
	id: string,
	org: number,
	orgMax: number,
	str: number,
}

local Combat = {}

local function experienceBonus(xp: number): number
	for _, level in Military.experience.levels do
		if xp >= level.min then
			return level.bonus
		end
	end
	return 0
end

-- Une division prête au combat : statistiques de son type, état actuel et modificateurs
function Combat.makeUnit(typeId: string, state: UnitState, ctx: Context): Unit
	local t = DivisionConfig.types[typeId] or DivisionConfig.types.Infanterie
	local C = Military.combat
	local terrainId = ctx.terrain or Terrain.default
	local terrain = Terrain.types[terrainId] or Terrain.types[Terrain.default]
	local typeBonus = if t.terrainBonus then (t.terrainBonus[terrainId] or 0) else 0
	local xp = experienceBonus(ctx.experience or 0)
	local attack = 1 + typeBonus + xp + (ctx.attackBonus or 0)
	local defend = 1 + typeBonus + xp + (ctx.defenseBonus or 0)
	if ctx.attacking then
		-- l'attaquant subit le terrain et la rivière (une partie ignorée par les troupes de montagne)
		attack += terrain.attack
		local river = ctx.river and Terrain.rivers[ctx.river]
		if river then
			attack += river.attack * (1 - (t.riverBonus or 0))
		end
	else
		defend += (ctx.entrenchment or 0) * Military.entrenchMax
		defend += (ctx.fortification or 0) * Military.fortification.defensePerLevel
	end
	local factor = ctx.factor or 1
	if ctx.supplied == false then
		factor *= C.outOfSupply
	end
	local attackFactor = factor
	if t.fuel and ctx.fuel == false then
		attackFactor *= C.noFuel
	end
	return {
		id = state.id,
		org = state.org,
		orgMax = state.orgMax,
		str = state.str,
		soft = t.soft,
		hard = t.hard,
		defense = t.defense,
		breakthrough = t.breakthrough,
		armor = t.armor,
		piercing = t.piercing,
		hardness = t.hardness,
		width = t.width,
		attack = math.max(0.1, attack) * attackFactor,
		defend = math.max(0.1, defend) * factor,
		orgLoss = 1 - math.clamp(ctx.resilience or 0, 0, 0.9),
		line = false,
	}
end

-- Largeur de bataille : celle du terrain, plus un peu par direction d'attaque supplémentaire
function Combat.width(terrainId: string?, directions: number): number
	local terrain = Terrain.types[terrainId or Terrain.default] or Terrain.types[Terrain.default]
	return terrain.width + terrain.widthPerDirection * math.max(0, directions - 1)
end

local function copy(unit: Unit): Unit
	return table.clone(unit)
end

-- Ligne et réserve : les divisions déjà en ligne y restent tant qu'elles ont de l'organisation,
-- puis les autres (les plus organisées d'abord) jusqu'à remplir la largeur. Une division à 0
-- d'organisation ne combat plus. Renvoie des copies.
function Combat.deploy(units: { Unit }, width: number): { Unit }
	local result = {}
	for _, u in units do
		table.insert(result, copy(u))
	end
	local order = table.clone(result)
	table.sort(order, function(a: Unit, b: Unit): boolean
		if a.line ~= b.line then
			return a.line
		end
		local ra, rb = a.org / math.max(a.orgMax, 0.01), b.org / math.max(b.orgMax, 0.01)
		if ra ~= rb then
			return ra > rb
		end
		return a.id < b.id
	end)
	local used = 0
	for _, u in order do
		u.line = false
		if u.org > 0 and (used + u.width <= width or used == 0) then
			u.line = true
			used += u.width
		end
	end
	return result
end

-- Les divisions encore capables de se battre (organisation au-dessus de 0)
local function standing(units: { Unit }): number
	local n = 0
	for _, u in units do
		if u.org > 0 then
			n += 1
		end
	end
	return n
end

local function strength(u: Unit): number
	return 0.5 + 0.5 * math.clamp(u.str / 100, 0, 1) -- une division affaiblie se bat moins bien
end

-- Coups reçus par chaque division en ligne de `targets`, tirés par la ligne de `shooters`
local function incoming(shooters: { Unit }, targets: { Unit }, C: any): ({ [Unit]: number }, { [Unit]: number })
	local hits: { [Unit]: number } = {}
	local weighted: { [Unit]: number } = {}
	local lineWidth = 0
	for _, t in targets do
		if t.line then
			lineWidth += t.width
		end
	end
	if lineWidth <= 0 then
		return hits, weighted
	end
	for _, s in shooters do
		if not s.line then
			continue
		end
		local power = C.hitsPerAttack * s.attack * strength(s)
		for _, t in targets do
			if not t.line then
				continue
			end
			local share = t.width / lineWidth
			local h = share * power * (s.soft * (1 - t.hardness) + s.hard * t.hardness)
			-- blindage : plus épais que la perforation du tireur, il protège ; et un tireur dont le
			-- blindage dépasse la perforation de sa cible lui fait plus mal
			local armor = 1
			if t.armor > s.piercing then
				armor *= C.armorDamageTaken
			end
			if s.armor > t.piercing then
				armor *= C.armorDamageDealt
			end
			hits[t] = (hits[t] or 0) + h
			weighted[t] = (weighted[t] or 0) + h * armor
		end
	end
	return hits, weighted
end

-- Dégâts d'un tick sur une division : absorbés par la défense (ou la percée), puis x4
local function damageOf(t: Unit, hits: number, weighted: number, defending: boolean, C: any): number
	if hits <= 0 then
		return 0
	end
	local capacity = (if defending then t.defense else t.breakthrough) * C.absorbPerPoint * t.defend * strength(t)
	local absorbed = math.min(1, capacity / hits)
	return weighted * (absorbed + (1 - absorbed) * C.undefendedMultiplier)
end

-- Un tick de combat. Renvoie le nouvel état (les entrées ne sont pas modifiées) et le bilan.
function Combat.resolveTick(battle: Battle, config: any?): (Battle, Report)
	local C = config or Military.combat
	local attackers = Combat.deploy(battle.attackers, battle.width)
	local defenders = Combat.deploy(battle.defenders, battle.width)
	local report: Report = { result = "EnCours", orgLostAttackers = 0, orgLostDefenders = 0, strLost = {} }
	-- plus personne pour tenir la région : elle cède sans combat
	if standing(defenders) == 0 then
		report.result = "Victoire"
		return { attackers = attackers, defenders = defenders, width = battle.width }, report
	end
	if standing(attackers) == 0 then
		report.result = "Repli"
		return { attackers = attackers, defenders = defenders, width = battle.width }, report
	end
	-- les deux camps tirent en même temps
	local hitsOnDefenders, weightedOnDefenders = incoming(attackers, defenders, C)
	local hitsOnAttackers, weightedOnAttackers = incoming(defenders, attackers, C)
	local function apply(list: { Unit }, hits: { [Unit]: number }, weighted: { [Unit]: number }, defending: boolean): number
		local orgLost = 0
		for _, u in list do
			local damage = damageOf(u, hits[u] or 0, weighted[u] or 0, defending, C)
			if damage > 0 then
				local org = math.min(u.org, damage * C.orgPerHit * u.orgLoss)
				local str = math.min(u.str, damage * C.strPerHit)
				u.org -= org
				u.str -= str
				orgLost += org
				report.strLost[u.id] = str
			end
		end
		return orgLost
	end
	report.orgLostDefenders = apply(defenders, hitsOnDefenders, weightedOnDefenders, true)
	report.orgLostAttackers = apply(attackers, hitsOnAttackers, weightedOnAttackers, false)
	-- fin de bataille : le défenseur cède s'il n'a plus d'organisation (et que l'attaquant en a
	-- encore) ; sinon l'attaque échoue quand l'attaquant n'en a plus
	if standing(defenders) == 0 and standing(attackers) > 0 then
		report.result = "Victoire"
	elseif standing(attackers) == 0 then
		report.result = "Repli"
	end
	return { attackers = attackers, defenders = defenders, width = battle.width }, report
end

-- Organisation restante d'un camp (0 à 1)
function Combat.orgRatio(units: { Unit }): number
	local org, orgMax = 0, 0
	for _, u in units do
		org += u.org
		orgMax += u.orgMax
	end
	return if orgMax > 0 then org / orgMax else 0
end

-- Qui gagnerait si rien ne change ? Simule au plus `maxTicks` ticks.
-- Renvoie le résultat ("Victoire", "Repli" ou "EnCours" si rien n'est joué) et le nombre de ticks.
function Combat.estimate(battle: Battle, maxTicks: number, config: any?): (string, number)
	local current = battle
	for tick = 1, maxTicks do
		local nextBattle, report = Combat.resolveTick(current, config)
		if report.result ~= "EnCours" then
			return report.result, tick
		end
		current = nextBattle
	end
	return "EnCours", maxTicks
end

return Combat
