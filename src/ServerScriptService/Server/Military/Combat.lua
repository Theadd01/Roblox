--!strict
-- Résolution du combat terrestre (cahier des charges v2, section 2) : fonctions PURES, sans
-- instance, sans horloge et sans hasard, pour être testées seules (Tests/Combat.spec).
--   Combat.makeUnit : une division prête au combat (PV, DPS et défense de son type, modifiés par
--     la recherche, le général, le terrain, l'expérience, le ravitaillement...) ;
--   Combat.resolveTick : un tick de combat (Config/CombatConfig.tickSeconds) -> nouvel état
--     (l'ancien n'est pas modifié) et bilan ;
--   Combat.estimate : qui gagnerait si rien ne change (affichage, IA).
-- Un tick : déploiement progressif (largeur de front), cibles attribuées en rotation, dégâts
-- simultanés, soldats tombés (0 PV), moral des camps (repli d'un camp à bout). Tous les chiffres
-- sont dans Config/CombatConfig.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local CombatConfig = require(Config:WaitForChild("CombatConfig")) :: any
local DivisionConfig = require(Config:WaitForChild("Divisions")) :: any
local Terrain = require(Config:WaitForChild("Terrain")) :: any
local Military = require(Config:WaitForChild("Military")) :: any

export type Unit = {
	id: string,
	typeId: string,
	hp: number, -- PV restants
	hpMax: number,
	str: number, -- PV restants en % (attribut Force de la division)
	dps: number, -- dégâts par seconde, tous bonus compris
	defense: number, -- les dégâts reçus sont divisés par ce nombre
	armored: boolean,
	rear: boolean, -- à l'arrière : visé seulement quand plus personne ne tient la première ligne
	vsArmor: number,
	vsSoft: number,
	value: number, -- poids dans les effectifs (avantage du nombre)
	org: number, -- moral (organisation)
	orgMax: number,
	orgLoss: number, -- multiplicateur du moral perdu (général « Meneur d'hommes » : moins)
	width: number, -- place en ligne : chaque soldat compte pour un
	line: boolean, -- engagé (sinon en réserve)
	target: string?, -- soldat ennemi visé
}

export type SideState = {
	credit: number, -- soldats qui peuvent encore être engagés (déploiement progressif)
	committed: number, -- soldats engagés par ce camp depuis le début (renforts compris)
	rotation: number, -- position dans la rotation des cibles
	seen: { [string]: boolean },
}

export type Battle = {
	attackers: { Unit },
	defenders: { Unit },
	width: number, -- largeur du front (soldats engagés en même temps par camp)
	elapsed: number?, -- secondes de combat déjà jouées
	sides: { attackers: SideState, defenders: SideState }?,
}

export type Report = {
	result: string, -- "EnCours", "Victoire" (le défenseur cède) ou "Repli" (l'attaque échoue)
	down: { [string]: boolean }, -- soldats tombés à 0 PV pendant ce tick
	routed: string?, -- "attackers" ou "defenders" : ce camp se replie, à bout de moral
	shots: { [string]: string }, -- tireur -> cible pendant ce tick
	orgLostAttackers: number,
	orgLostDefenders: number,
	strLost: { [string]: number }, -- PV perdus (en %) par division
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
	health: number?, -- PV en plus (recherche : 0,2 = +20 %)
	damage: number?, -- dégâts en plus (recherche : 0,15 = +15 %)
	attackBonus: number?, -- bonus de dégâts en plus (général, projets, soutien aérien...)
	defenseBonus: number?, -- bonus de défense en plus
	factor: number?, -- multiplicateur global (ex. milice d'un pays affaibli)
	resilience: number?, -- part du moral perdu évitée (général « Meneur d'hommes »)
}

export type UnitState = {
	id: string,
	org: number,
	orgMax: number,
	str: number, -- PV en % (0 à 100)
}

local Combat = {}

local BASE = CombatConfig.stats(nil)
local BASE_VALUE = math.sqrt(BASE.health * BASE.dps)

local function experienceBonus(xp: number): number
	for _, level in Military.experience.levels do
		if xp >= level.min then
			return level.bonus
		end
	end
	return 0
end

-- Une division prête au combat : statistiques de son type (Config/CombatConfig), état actuel
-- (PV en %, moral) et modificateurs
function Combat.makeUnit(typeId: string, state: UnitState, ctx: Context): Unit
	local stats = CombatConfig.stats(typeId)
	local t = DivisionConfig.types[typeId] or DivisionConfig.types.Infanterie
	local C = Military.combat
	local terrainId = ctx.terrain or Terrain.default
	local terrain = Terrain.types[terrainId] or Terrain.types[Terrain.default]
	local typeBonus = if t.terrainBonus then (t.terrainBonus[terrainId] or 0) else 0
	local xp = experienceBonus(ctx.experience or 0)
	-- dégâts : (1 + recherche + général + expérience...) x facteur terrain
	local bonus = 1 + (ctx.damage or 0) + (ctx.attackBonus or 0) + xp
	local terrainFactor = 1 + typeBonus
	if ctx.attacking then
		-- l'attaquant subit le terrain et la rivière (une partie ignorée par les troupes de montagne)
		terrainFactor += terrain.attack
		local river = ctx.river and Terrain.rivers[ctx.river]
		if river then
			terrainFactor += river.attack * (1 - (t.riverBonus or 0))
		end
	end
	local factor = ctx.factor or 1
	if ctx.supplied == false then
		factor *= C.outOfSupply
	end
	local attackFactor = factor
	if t.fuel and ctx.fuel == false then
		attackFactor *= C.noFuel
	end
	-- défense : le défenseur connaît le terrain, il s'est retranché, la région est fortifiée
	local defense = 1 + (ctx.defenseBonus or 0) + xp + typeBonus
	if not ctx.attacking then
		defense += CombatConfig.defenderBonus
		defense += (ctx.entrenchment or 0) * Military.entrenchMax
		defense += (ctx.fortification or 0) * Military.fortification.defensePerLevel
	end
	local hpMax = stats.health * math.max(0.1, 1 + (ctx.health or 0))
	local str = math.clamp(state.str, 0, 100)
	return {
		id = state.id,
		typeId = typeId,
		hp = hpMax * str / 100,
		hpMax = hpMax,
		str = str,
		dps = stats.dps * math.max(0.1, bonus) * math.max(0.1, terrainFactor) * attackFactor,
		defense = math.max(0.2, defense * factor),
		armored = stats.armored == true,
		rear = stats.rear == true,
		vsArmor = stats.vsArmor or 1,
		vsSoft = stats.vsSoft or 1,
		value = math.sqrt(stats.health * stats.dps) / BASE_VALUE,
		org = state.org,
		orgMax = state.orgMax,
		orgLoss = 1 - math.clamp(ctx.resilience or 0, 0, 0.9),
		width = 1,
		line = false,
		target = nil,
	}
end

-- Largeur du front : nombre de soldats engagés en même temps par camp (le terrain ralentit et
-- affaiblit l'attaquant, il ne bloque plus des soldats en réserve)
function Combat.width(_terrainId: string?, _directions: number?): number
	return CombatConfig.frontWidth
end

local function newSide(): SideState
	return { credit = 0, committed = 0, rotation = 0, seen = {} }
end

-- Une nouvelle bataille
function Combat.newBattle(attackers: { Unit }, defenders: { Unit }): Battle
	return {
		attackers = attackers,
		defenders = defenders,
		width = CombatConfig.frontWidth,
		elapsed = 0,
		sides = { attackers = newSide(), defenders = newSide() },
	}
end

local function copySide(side: SideState?): SideState
	if not side then
		return newSide()
	end
	return { credit = side.credit, committed = side.committed, rotation = side.rotation, seen = table.clone(side.seen) }
end

local function alive(u: Unit): boolean
	return u.hp > 0
end

-- Les soldats encore debout d'un camp
local function standing(units: { Unit }): number
	local n = 0
	for _, u in units do
		if alive(u) then
			n += 1
		end
	end
	return n
end

-- Nouveaux soldats (début de bataille ou renforts) : le déploiement en tient compte
local function register(units: { Unit }, side: SideState)
	for _, u in units do
		if alive(u) and not side.seen[u.id] then
			side.seen[u.id] = true
			side.committed += 1
		end
	end
end

-- Déploiement progressif : les soldats arrivent au front peu à peu, au plus `width` en ligne ;
-- d'abord la première ligne, puis l'arrière ; les plus valides d'abord
local function deploy(units: { Unit }, side: SideState, elapsed: number, dt: number, width: number, C: any)
	local D = C.deployment
	local active = 0
	local reserve = {}
	for _, u in units do
		if alive(u) then
			if u.line then
				active += 1
			else
				table.insert(reserve, u)
			end
		else
			u.line = false
			u.target = nil
		end
	end
	if elapsed <= 0 then
		side.credit = D.initial
	else
		side.credit += math.max(D.minRate, side.committed / D.window) * dt
	end
	side.credit = math.min(side.credit, width)
	table.sort(reserve, function(a: Unit, b: Unit): boolean
		if a.rear ~= b.rear then
			return not a.rear
		end
		local ra, rb = a.hp / a.hpMax, b.hp / b.hpMax
		if ra ~= rb then
			return ra > rb
		end
		return a.id < b.id
	end)
	for _, u in reserve do
		if active >= width then
			break
		end
		if side.credit >= 1 then
			side.credit -= 1
		elseif active > 0 then
			break
		end
		-- plus personne en ligne : un soldat de la réserve y va tout de suite
		u.line = true
		active += 1
	end
end

-- Cibles en rotation : chaque soldat engagé sans cible valable reçoit le soldat ennemi le moins
-- visé (à égalité, le suivant dans la rotation). L'arrière n'est visé qu'en dernier.
local function assign(shooters: { Unit }, enemies: { Unit }, side: SideState)
	local front, all = {}, {}
	for _, e in enemies do
		if alive(e) and e.line then
			table.insert(all, e)
			if not e.rear then
				table.insert(front, e)
			end
		end
	end
	local targets: { Unit } = if #front > 0 then front else all
	local valid: { [string]: boolean } = {}
	local load: { [string]: number } = {}
	for _, e in targets do
		valid[e.id] = true
		load[e.id] = 0
	end
	for _, s in shooters do
		if alive(s) and s.line and s.target and valid[s.target] then
			load[s.target] += 1
		else
			s.target = nil
		end
	end
	if #targets == 0 then
		return
	end
	for _, s in shooters do
		if alive(s) and s.line and not s.target then
			local best: Unit? = nil
			local bestLoad = math.huge
			for k = 0, #targets - 1 do
				local e = targets[(side.rotation + k) % #targets + 1]
				if load[e.id] < bestLoad then
					best, bestLoad = e, load[e.id]
				end
			end
			local chosen = best :: Unit
			s.target = chosen.id
			load[chosen.id] += 1
			side.rotation = (side.rotation + 1) % #targets
		end
	end
end

-- Effectifs d'un camp : chaque soldat debout compte selon sa valeur et ses PV restants
local function headcount(units: { Unit }): number
	local total = 0
	for _, u in units do
		if alive(u) then
			total += u.value * (0.5 + 0.5 * u.hp / u.hpMax)
		end
	end
	return total
end

-- Multiplicateur de dégâts du camp `mine` face à `theirs` (avantage du nombre)
local function numbersFactor(mine: number, theirs: number, C: any): number
	if theirs <= 0 then
		return C.numbers.max
	end
	if mine <= 0 then
		return 1 / C.numbers.max
	end
	return math.clamp((mine / theirs) ^ C.numbers.exponent, 1 / C.numbers.max, C.numbers.max)
end

local function copyUnits(units: { Unit }): { Unit }
	local list = table.create(#units)
	for _, u in units do
		table.insert(list, table.clone(u))
	end
	return list
end

-- Moral : chaque soldat tombé en retire à tout son camp, le combat aussi un peu chaque seconde.
-- Renvoie le moral perdu et vrai si le camp se replie (moyenne sous routBelow)
local function morale(units: { Unit }, casualties: number, side: SideState, dt: number, C: any): (number, boolean)
	local M = C.morale
	local lost = 0
	local org, orgMax = 0, 0
	local share = casualties * M.perCasualty / math.max(side.committed, 1)
	for _, u in units do
		if not alive(u) then
			continue
		end
		local loss = math.min(u.org, u.orgMax * (share + M.perSecond * dt) * u.orgLoss)
		u.org -= loss
		lost += loss
		org += u.org
		orgMax += u.orgMax
	end
	return lost, orgMax > 0 and org / orgMax <= M.routBelow
end

-- Un tick de combat. Renvoie le nouvel état (les entrées ne sont pas modifiées) et le bilan.
function Combat.resolveTick(battle: Battle, config: any?): (Battle, Report)
	local C = config or CombatConfig
	local dt = C.tickSeconds
	local width = battle.width or C.frontWidth
	local elapsed = battle.elapsed or 0
	local attackers = copyUnits(battle.attackers)
	local defenders = copyUnits(battle.defenders)
	local previous = battle.sides
	local sides = {
		attackers = copySide(previous and previous.attackers),
		defenders = copySide(previous and previous.defenders),
	}
	local report: Report = { result = "EnCours", down = {}, routed = nil, shots = {}, orgLostAttackers = 0, orgLostDefenders = 0, strLost = {} }
	local function state(): Battle
		return { attackers = attackers, defenders = defenders, width = width, elapsed = elapsed + dt, sides = sides }
	end
	register(attackers, sides.attackers)
	register(defenders, sides.defenders)
	-- plus personne pour tenir la région : elle cède sans combat
	if standing(defenders) == 0 then
		report.result = if standing(attackers) > 0 then "Victoire" else "Repli"
		return state(), report
	end
	if standing(attackers) == 0 then
		report.result = "Repli"
		return state(), report
	end

	deploy(attackers, sides.attackers, elapsed, dt, width, C)
	deploy(defenders, sides.defenders, elapsed, dt, width, C)
	assign(attackers, defenders, sides.attackers)
	assign(defenders, attackers, sides.defenders)

	-- les deux camps tirent en même temps
	local attackerCount, defenderCount = headcount(attackers), headcount(defenders)
	local byId: { [string]: Unit } = {}
	for _, u in attackers do
		byId[u.id] = u
	end
	for _, u in defenders do
		byId[u.id] = u
	end
	local damage: { [string]: number } = {}
	local function fire(shooters: { Unit }, numbers: number)
		for _, s in shooters do
			if not (alive(s) and s.line and s.target) then
				continue
			end
			local t = byId[s.target :: string]
			local efficiency = if t.armored then s.vsArmor else s.vsSoft
			damage[t.id] = (damage[t.id] or 0) + s.dps * dt * efficiency * numbers / t.defense
			report.shots[s.id] = t.id
		end
	end
	fire(attackers, numbersFactor(attackerCount, defenderCount, C))
	fire(defenders, numbersFactor(defenderCount, attackerCount, C))

	local function apply(list: { Unit }): number
		local casualties = 0
		for _, u in list do
			local d = damage[u.id]
			if d and d > 0 and alive(u) then
				local before = u.str
				u.hp = math.max(0, u.hp - d)
				u.str = 100 * u.hp / u.hpMax
				report.strLost[u.id] = before - u.str
				if u.hp <= 0 then
					u.line = false
					u.target = nil
					report.down[u.id] = true
					casualties += 1
				end
			end
		end
		return casualties
	end
	local attackerLosses = apply(attackers)
	local defenderLosses = apply(defenders)
	local attackersRout, defendersRout
	report.orgLostAttackers, attackersRout = morale(attackers, attackerLosses, sides.attackers, dt, C)
	report.orgLostDefenders, defendersRout = morale(defenders, defenderLosses, sides.defenders, dt, C)

	-- fin de bataille : la région cède quand il n'y a plus de défenseur debout (ou qu'ils se
	-- replient) ; l'attaque échoue quand il n'y a plus d'attaquant (ou qu'ils se replient)
	local attackersLeft, defendersLeft = standing(attackers), standing(defenders)
	if attackersLeft == 0 or attackersRout then
		report.result = "Repli"
		report.routed = if attackersLeft > 0 then "attackers" else nil
	elseif defendersLeft == 0 or defendersRout then
		report.result = "Victoire"
		report.routed = if defendersLeft > 0 then "defenders" else nil
	elseif elapsed + dt >= C.maxSeconds then
		report.result = "Repli"
	end
	return state(), report
end

-- Organisation restante d'un camp (0 à 1)
function Combat.orgRatio(units: { Unit }): number
	local org, orgMax = 0, 0
	for _, u in units do
		if alive(u) then
			org += u.org
			orgMax += u.orgMax
		end
	end
	return if orgMax > 0 then org / orgMax else 0
end

-- PV restants d'un camp (0 à 1 : part des PV de départ des soldats encore debout)
function Combat.healthRatio(units: { Unit }): number
	local hp, hpMax = 0, 0
	for _, u in units do
		hp += math.max(0, u.hp)
		hpMax += u.hpMax
	end
	return if hpMax > 0 then hp / hpMax else 0
end

-- Retire les soldats tombés (ils se replient ou meurent : c'est le serveur qui décide)
function Combat.withoutDown(units: { Unit }): { Unit }
	local list = {}
	for _, u in units do
		if alive(u) then
			table.insert(list, u)
		end
	end
	return list
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
		nextBattle.attackers = Combat.withoutDown(nextBattle.attackers)
		nextBattle.defenders = Combat.withoutDown(nextBattle.defenders)
		current = nextBattle
	end
	return "EnCours", maxTicks
end

return Combat
