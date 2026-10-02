--!strict
-- Déplacements des divisions de région en région (SYSTEME_MILITAIRE.md, 5.1 et 6.4) :
--   ordre « Deplacer » (ou « Attaquer ») vers une région : chemin le plus rapide de voisine en
--   voisine, par ses régions, celles de ses alliés et celles des pays en guerre avec lui ; la mer
--   seulement depuis une région où attend une de ses flottes ;
--   10 divisions au plus par région : une région pleine ne s'atteint pas et ne se traverse pas ;
--   entrer dans une région ennemie vide la prend ; une région ennemie défendue est attaquée depuis
--   la région voisine (bataille : BattleManager) et la division n'y entre qu'après la victoire ;
--   on n'attaque qu'un pays avec lequel on est en guerre (la guerre se déclare dans Diplomatie :
--   pas de guerre sur un clic droit raté) ;
--   « Arreter » : la division finit l'étape en cours puis s'arrête.
-- Durée d'une étape : distance entre les deux régions / vitesse de la division, ralentie par le
-- terrain d'arrivée (Config/Terrain) et le manque de pétrole (Config/Military), bornée.
-- Les arrivées sont traitées par la boucle centrale (MilitaryLoop).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Military = require(Config:WaitForChild("Military")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Units = require(Config:WaitForChild("Units")) :: any
local RegionTerrain = require(Config:WaitForChild("RegionTerrain")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any
local CouncilState = require(Shared:WaitForChild("CouncilState")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local DiplomacyService = require(Server:WaitForChild("Politics"):WaitForChild("DiplomacyService"))
local Stocks = require(Server:WaitForChild("Economy"):WaitForChild("Stocks"))
local ArmyService = require(script.Parent:WaitForChild("ArmyService"))
local Divisions = require(script.Parent:WaitForChild("Divisions"))
local Armies = require(script.Parent:WaitForChild("Armies"))

local HOSTILE_PENALTY = 15 -- secondes ajoutées au coût d'une région ennemie (on évite les détours par les combats)
local MAX_STEPS = 40 -- régions au plus dans un chemin

type AttackHandler = (d: Instance, from: string, target: string) -> (boolean, string?)
type BattleHooks = {
	attack: AttackHandler, -- engage la division contre une région défendue
	withdraw: (d: Instance) -> (), -- la retire de l'attaque qu'elle mène
	isAttacking: (d: Instance) -> boolean, -- mène-t-elle une attaque (et non une défense) ?
}

local Movement = {}

local moving: { [Instance]: boolean } = {}
local hooks: BattleHooks? = nil

local function now(): number
	return workspace:GetServerTimeNow()
end

local function anchorOf(regionId: string): Vector3?
	local region = Regions[regionId]
	local city = region and region.city
	return if city then MapProjection.toVector3(city.lon, city.lat, MapSettings.regionTop) else nil
end

local function link(from: string, to: string): any?
	local region = Regions[from]
	for _, l in (if region then region.neighbors else {}) do
		if l.region == to then
			return l
		end
	end
	return nil
end

-- Région d'un pays hostile (ni le sien, ni celle d'un allié) ?
local function isHostile(countryId: string, owner: string?): boolean
	return owner ~= nil and owner ~= countryId and not DiplomacyService.areAllies(countryId, owner)
end

-- Bataille en cours dans une région (attribut Bataille de EtatMonde.Regions.<id>)
local function battleIn(regionId: string): unknown
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local regions = state and state:FindFirstChild("Regions")
	local folder = regions and regions:FindFirstChild(regionId)
	return folder and folder:GetAttribute("Bataille")
end

-- Divisions ennemies (prêtes à combattre, et qui ne sont pas en train de partir) dans une région
function Movement.defenders(regionId: string, attacker: string): { Instance }
	local list = {}
	for _, d in Divisions.listIn(regionId) do
		local owner = d:GetAttribute("Proprietaire") :: string
		if isHostile(attacker, owner) and not Divisions.isTraining(d) and not Divisions.isMoving(d) then
			table.insert(list, d)
		end
	end
	return list
end

-- Durée d'une étape par la terre (fonction pure, testée dans Tests/Supply.spec : voir Divisions)
Movement.stepSeconds = Divisions.stepSeconds

-- Durée d'une étape (secondes) ; par la mer, à la vitesse des flottes
function Movement.travelTime(d: Instance, from: string, to: string, bySea: boolean?): number
	local a, b = anchorOf(from), anchorOf(to)
	local distance = if a and b then (b - a).Magnitude else 0
	if bySea then
		local k = Units.kinds.Mer
		return math.clamp(distance / k.speed, k.minTime, k.maxTime)
	end
	local fuel = Stocks.get(d:GetAttribute("Proprietaire") :: string, "Petrole") > 0
	-- général « Stratège » : trajets plus courts
	return Movement.stepSeconds(d:GetAttribute("Type") :: string, distance, RegionTerrain.terrain[to], fuel) * (1 - Armies.bonus(d, "speed"))
end

-- Chemin le plus rapide de `from` à `goal` (régions à traverser, `goal` compris) ; nil : aucun.
-- On ne passe que par ses régions, celles de ses alliés et celles des pays en guerre avec lui,
-- jamais par une région pleine ; la mer seulement depuis un port avec flotte.
local function findPath(d: Instance, from: string, goal: string): { string }?
	local countryId = d:GetAttribute("Proprietaire") :: string
	local function passable(regionId: string): boolean
		local owner = RegionService.getOwner(regionId)
		if regionId ~= goal and Divisions.occupancy(regionId) >= Divisions.capacityOf(regionId) then
			return false
		end
		if regionId == goal or owner == countryId then
			return true
		end
		return owner ~= nil and (DiplomacyService.areAllies(countryId, owner) or DiplomacyService.atWar(countryId, owner))
	end
	local cost: { [string]: number } = { [from] = 0 }
	local previous: { [string]: string } = {}
	local done: { [string]: boolean } = {}
	local open = { from }
	while #open > 0 do
		local bestIndex, best = 1, math.huge
		for i, id in open do
			if cost[id] < best then
				bestIndex, best = i, cost[id]
			end
		end
		local current = table.remove(open, bestIndex) :: string
		if current == goal then
			break
		end
		if done[current] then
			continue
		end
		done[current] = true
		local fleet: boolean? = nil
		for _, l in Regions[current].neighbors do
			local nextId = l.region
			if done[nextId] or not Regions[nextId] or not passable(nextId) then
				continue
			end
			if l.bySea then
				if fleet == nil then
					fleet = ArmyService.fleetInPort(countryId, current)
				end
				if not fleet then
					continue
				end
			end
			local step = Movement.travelTime(d, current, nextId, l.bySea)
			if isHostile(countryId, RegionService.getOwner(nextId)) then
				step += HOSTILE_PENALTY
			end
			if best + step < (cost[nextId] or math.huge) then
				cost[nextId] = best + step
				previous[nextId] = current
				table.insert(open, nextId)
			end
		end
	end
	if not previous[goal] then
		return nil
	end
	local path = {}
	local node = goal
	while node ~= from do
		table.insert(path, 1, node)
		node = previous[node]
	end
	return path
end

local function getItinerary(d: Instance): { string }
	local raw = d:GetAttribute("Itineraire")
	if typeof(raw) ~= "string" or raw == "" then
		return {}
	end
	return string.split(raw, ",")
end

local function setItinerary(d: Instance, steps: { string })
	d:SetAttribute("Itineraire", if #steps > 0 then table.concat(steps, ",") else nil)
end

-- Lance une étape (vérifications déjà faites)
local function startStep(d: Instance, from: string, to: string, bySea: boolean?, factor: number?)
	local duration = Movement.travelTime(d, from, to, bySea) * (factor or 1)
	local start = now()
	d:SetAttribute("Provenance", from)
	d:SetAttribute("ParMer", bySea or nil)
	d:SetAttribute("Destination", to)
	d:SetAttribute("Depart", start)
	d:SetAttribute("Arrivee", start + duration)
	d:SetAttribute("Retranchement", 0) -- le retranchement est perdu dès qu'elle bouge
	moving[d] = true
end

-- Prochaine étape de l'itinéraire (après une arrivée ou une victoire). Une région ennemie défendue
-- est attaquée depuis la région actuelle ; une route coupée (paix, région pleine, cessez-le-feu...)
-- arrête la division.
local function continueItinerary(d: Instance)
	if not d.Parent or Divisions.isMoving(d) or Divisions.inBattle(d) then
		return
	end
	local steps = getItinerary(d)
	if #steps == 0 then
		return
	end
	local countryId = d:GetAttribute("Proprietaire") :: string
	local from = d:GetAttribute("Region") :: string
	local nextId = steps[1]
	local l = link(from, nextId)
	local owner = RegionService.getOwner(nextId)
	local hostile = isHostile(countryId, owner)
	local ok = l ~= nil and (not l.bySea or ArmyService.fleetInPort(countryId, from))
	if ok and hostile then
		ok = DiplomacyService.atWar(countryId, owner :: string) and CouncilState.ceasefireLeft() <= 0
	end
	if not ok then
		setItinerary(d, {})
		return
	end
	if hostile and #Movement.defenders(nextId, countryId) > 0 then
		-- région défendue : on l'attaque depuis ici (la suite de la route attend la victoire)
		local h = hooks
		if not h or not h.attack(d, from, nextId) then
			setItinerary(d, {})
		end
		return
	end
	if Divisions.occupancy(nextId) >= Divisions.capacityOf(nextId) then
		setItinerary(d, {}) -- région pleine : la division s'arrête ici
		return
	end
	table.remove(steps, 1)
	setItinerary(d, steps)
	startStep(d, from, nextId, l.bySea)
end

-- Une région ennemie est prise : les divisions ennemies qui y restent (à l'entraînement, ou sans
-- organisation pour fuir) sont perdues ; celles qui battent en retraite continuent leur route ;
-- les armées des généraux reculent avec leur général (Armies, au changement de propriétaire)
local function capture(regionId: string, countryId: string)
	for _, other in Divisions.inRegion(regionId) do
		if isHostile(countryId, other:GetAttribute("Proprietaire") :: string) and not Divisions.isMoving(other) and not Divisions.isAbsorbed(other) then
			Divisions.destroy(other)
		end
	end
	RegionService.setOwner(regionId, countryId)
end

-- Retraite après une défaite : la division quitte sa région pour une région amie voisine
function Movement.retreat(d: Instance, to: string)
	if not d.Parent then
		return
	end
	setItinerary(d, {})
	local from = d:GetAttribute("Region") :: string
	local l = link(from, to)
	startStep(d, from, to, l and l.bySea)
end

-- Arrivée d'une division au bout d'une étape
local function arrive(d: Instance)
	moving[d] = nil
	local countryId = d:GetAttribute("Proprietaire") :: string
	local target = d:GetAttribute("Destination") :: string
	local from = d:GetAttribute("Provenance") :: string
	d:SetAttribute("Destination", "")
	d:SetAttribute("ParMer", nil)
	local owner = RegionService.getOwner(target)
	if isHostile(countryId, owner) then
		if not DiplomacyService.atWar(countryId, owner :: string) then
			-- la paix a été signée pendant le trajet : retour au point de départ
			setItinerary(d, {})
			return
		end
		if #Movement.defenders(target, countryId) > 0 then
			-- des défenseurs sont arrivés entre-temps : la division reste chez elle et attaque
			local h = hooks
			if not h or not h.attack(d, from, target) then
				setItinerary(d, {})
			end
			return
		end
		Divisions.setRegion(d, target)
		capture(target, countryId)
	else
		Divisions.setRegion(d, target)
	end
	continueItinerary(d)
end

-- Après une victoire : l'attaquant entre dans la région prise (plus vite qu'un trajet normal)
function Movement.advance(d: Instance, target: string)
	if not d.Parent or Divisions.isMoving(d) then
		return
	end
	local from = d:GetAttribute("Region") :: string
	if Divisions.occupancy(target) >= Divisions.capacityOf(target) then
		setItinerary(d, {})
		return
	end
	local steps = getItinerary(d)
	if steps[1] == target then
		table.remove(steps, 1)
		setItinerary(d, steps)
	end
	local l = link(from, target)
	startStep(d, from, target, l and l.bySea, Military.combat.advanceTravelFactor)
end

-- Ordre de déplacement (ou d'attaque) de plusieurs divisions vers une région (les troupes d'un
-- général ne bougent qu'avec lui : Armies)
function Movement.order(countryId: string, list: { Instance }, goal: unknown): (boolean, string?)
	if typeof(goal) ~= "string" or not Regions[goal] then
		return false, "Région inconnue."
	end
	local owner = RegionService.getOwner(goal)
	local hostile = isHostile(countryId, owner)
	if hostile then
		if not DiplomacyService.atWar(countryId, owner :: string) then
			local country = Countries[owner :: string]
			return false, `Pas en guerre avec {if country then FrenchNames.the(country.name) else "ce pays"} : déclare-lui la guerre (fiche de la région ou onglet Diplomatie).`
		end
		local ceasefire = CouncilState.ceasefireLeft()
		if ceasefire > 0 then
			return false, `Cessez-le-feu du Conseil mondial : encore {math.ceil(ceasefire)} s.`
		end
	end
	-- place restante dans la région visée (les divisions qui y restent ou y vont déjà comptent)
	local capacity = Divisions.capacityOf(goal)
	local room = capacity - Divisions.occupancy(goal)
	for _, d in list do
		if (d:GetAttribute("Region") == goal and not Divisions.isMoving(d)) or d:GetAttribute("Destination") == goal then
			room += 1
		end
	end
	local sent, full, blocked, busy = 0, 0, 0, 0
	local paths: { [Instance]: { string } } = {}
	local h = hooks
	for _, d in list do
		-- une division qui attaque peut être envoyée ailleurs (elle quitte la bataille) ; une
		-- division qui défend sa région ne la quitte pas en pleine bataille
		local attacking = h ~= nil and Divisions.inBattle(d) and h.isAttacking(d)
		if Divisions.isTraining(d) or Divisions.isAbsorbed(d) or (Divisions.inBattle(d) and not attacking) then
			busy += 1
			continue
		end
		local from = d:GetAttribute(if Divisions.isMoving(d) then "Destination" else "Region") :: string
		if from == goal then
			-- elle y est (ou y va) déjà : on annule la suite de sa route, et son attaque
			setItinerary(d, {})
			if attacking and h then
				h.withdraw(d)
			end
			sent += 1
			continue
		end
		if room <= 0 then
			full += 1
			continue
		end
		-- région voisine : on y va (ou on l'attaque) directement depuis sa région, sans détour (une
		-- attaque menée de plusieurs côtés garde ainsi toutes ses directions)
		local direct = link(from, goal)
		local path = if direct and (not direct.bySea or ArmyService.fleetInPort(countryId, from)) then { goal } else findPath(d, from, goal)
		if not path or #path > MAX_STEPS then
			blocked += 1
			continue
		end
		paths[d] = path
		room -= 1
		sent += 1
	end
	if next(paths) == nil and sent == 0 then
		if full > 0 then
			return false, `Région pleine : {capacity} divisions au maximum.`
		elseif blocked > 0 then
			return false, "Aucun chemin : il faut traverser un pays neutre, une région pleine, ou la mer sans flotte au port."
		end
		return false, "Ces divisions sont à l'entraînement, au combat, ou dans l'armée d'un général."
	end
	for d, path in paths do
		d:SetAttribute("AttaqueContinue", nil) -- un ordre direct arrête son offensive continue
		if h and Divisions.inBattle(d) then
			-- elle attaque déjà la région visée : elle continue
			if path[1] ~= nil and #path == 1 and d:GetAttribute("Bataille") == battleIn(path[1]) then
				continue
			end
			h.withdraw(d)
		end
		setItinerary(d, path)
		if not Divisions.isMoving(d) then
			continueItinerary(d)
		end
	end
	local refused = full + blocked + busy
	if refused > 0 then
		return true, `{sent} division{if sent > 1 then "s" else ""} en route, {refused} non : {if full > 0 then "région pleine" elseif blocked > 0 then "pas de chemin" else "occupées"}.`
	end
	return true, nil
end

-- Ordre « Arreter » : finir l'étape en cours, puis s'arrêter ; une division qui attaque cesse
-- l'attaque (elle reste dans sa région)
function Movement.stop(list: { Instance })
	local h = hooks
	for _, d in list do
		setItinerary(d, {})
		if h and Divisions.inBattle(d) and h.isAttacking(d) then
			h.withdraw(d)
		end
	end
end

-- BattleManager : engager une division contre une région défendue, l'en retirer
function Movement.setBattleHooks(battleHooks: BattleHooks)
	hooks = battleHooks
end

Movement.continueItinerary = continueItinerary
Movement.capture = capture

-- Arrivées des divisions en route (boucle centrale)
local function update(_dt: number, t: number)
	for d in moving do
		if not d.Parent then
			moving[d] = nil
		elseif t >= ((d:GetAttribute("Arrivee") :: number?) or 0) then
			arrive(d)
		end
	end
end

-- Nouvelle partie : plus aucun trajet
function Movement.reset()
	table.clear(moving)
end

function Movement.init(loop: any, commands: any)
	loop.every("mouvements", 0.1, update)
	commands.register("Deplacer", function(countryId: string, data: { [any]: any }): (boolean, string?)
		local list, err = commands.ownedDivisions(countryId, data.ids)
		if not list then
			return false, err
		end
		return Movement.order(countryId, list, data.region)
	end, "DeplacerArmee")
	commands.register("Arreter", function(countryId: string, data: { [any]: any }): (boolean, string?)
		local list, err = commands.ownedDivisions(countryId, data.ids)
		if not list then
			return false, err
		end
		Movement.stop(list)
		return true, nil
	end)
end

return Movement
