--!strict
-- Forces militaires (armées, escadrilles, flottes). Le serveur décide de tout : nomination du chef,
-- recrutement, déplacement ; il ne publie que la position logique, les clients animent.
-- État publié dans ReplicatedStorage.EtatMonde.Armees.<id> (un dossier par force) :
--   Genre ("Terre" | "Air" | "Mer"), Nom, Proprietaire, Region, Niveau,
--   un attribut par type de troupe, Destination ("" à l'arrêt), Depart, Arrivee,
--   ParMer (armée de terre transportée par une flotte), EnCombat (bataille en cours),
--   Moral, Experience, Ravitaillee, Penurie, Posture ("Normal" | "Defendre" | "Tenir"),
--   Provenance (région quittée au dernier déplacement : c'est là qu'on se replie),
--   Traits (traits du chef, Config/Generals : un à la nomination, un second au niveau 3),
--   Itineraire (armée de terre : régions qui restent à traverser après Destination, séparées par
--   des virgules ; absent s'il n'y en a pas).
-- Déplacements :
--   Terre : région voisine par la terre, ou voisine par la mer si une flotte du pays est au port ;
--           vers une région lointaine, le serveur calcule le chemin le plus rapide et l'armée va de
--           région en région (elle livre bataille en route et repart après chaque victoire)
--   Air   : toute région à portée de vol
--   Mer   : toute région côtière (avec port) à portée
-- Entrer dans la région d'un pays étranger lui déclare la guerre (s'il n'est ni allié, ni sous trêve)
-- et engage une bataille (BattleService) ; chez un allié, la force stationne sans combattre.
-- Remotes : NommerGeneral(région, genre), Recruter(force, type), DeplacerArmee(force, région),
--           OrdreArmee(force, ordre) avec ordre = "Normal" | "Defendre" | "Tenir" | "Replier" | "Arreter".

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Units = require(Config:WaitForChild("Units")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local CountryAssignment = require(Server:WaitForChild("Session"):WaitForChild("CountryAssignment"))
local PlayStyle = require(Server:WaitForChild("Session"):WaitForChild("PlayStyle"))
local RateLimiter = require(Server:WaitForChild("Util"):WaitForChild("RateLimiter"))
local Stocks = require(Server:WaitForChild("Economy"):WaitForChild("Stocks"))
local BattleService = require(script.Parent:WaitForChild("BattleService"))
local Stability = require(Server:WaitForChild("Politics"):WaitForChild("Stability"))
local StabilityRules = require(Shared:WaitForChild("StabilityRules")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local DiplomacyService = require(Server:WaitForChild("Politics"):WaitForChild("DiplomacyService"))
local Combat = require(Config:WaitForChild("Combat")) :: any
local MilitaryMath = require(Shared:WaitForChild("MilitaryMath")) :: any
local GeneralTraits = require(Shared:WaitForChild("GeneralTraits")) :: any
local CouncilState = require(Shared:WaitForChild("CouncilState")) :: any

local ArmyService = {}

local startTravel: (army: Instance, from: string, destination: string, bySea: boolean?) -> ()

local MAX_STEPS = 40 -- régions au plus dans un itinéraire
local HOSTILE_PENALTY = 20 -- secondes ajoutées au coût d'une région ennemie (on évite les détours par les combats)
local PAUSE_AFTER_VICTORY = 1.5 -- secondes avant de repartir après une victoire

local folder: Folder? = nil -- EtatMonde.Armees
local nextId = 0
local nameIndex = 0
local rng = Random.new()

local function now(): number
	return workspace:GetServerTimeNow()
end

local function forcesOf(countryId: string, kind: string?): { Instance }
	local list = {}
	if folder then
		for _, army in folder:GetChildren() do
			if army:GetAttribute("Proprietaire") == countryId and (kind == nil or Units.kindOf(army) == kind) then
				table.insert(list, army)
			end
		end
	end
	return list
end

-- Nombre total de troupes d'une force
function ArmyService.size(army: Instance): number
	local total = 0
	for _, typeId in Units.kinds[Units.kindOf(army)].order do
		total += (army:GetAttribute(typeId) :: number?) or 0
	end
	return total
end

local function capacity(army: Instance): number
	local caps = Units.kinds[Units.kindOf(army)].capacity
	local level = (army:GetAttribute("Niveau") :: number?) or 1
	return caps[math.clamp(level, 1, #caps)]
end

local function point(lonLat: any): Vector3?
	return if lonLat then MapProjection.toVector3(lonLat.lon, lonLat.lat, MapSettings.regionTop) else nil
end

-- Point de référence d'une région pour une sorte de force (la mer utilise le port)
local function anchorOf(regionId: string, kind: string): Vector3?
	local region = Regions[regionId]
	if not region then
		return nil
	end
	return point(if kind == "Mer" then region.port else region.city)
end

local function distance(from: string, to: string, kind: string): number
	local a, b = anchorOf(from, kind), anchorOf(to, kind)
	return if a and b then (b - a).Magnitude else math.huge
end

-- Durée d'un trajet (secondes) ; une armée transportée par la mer va à la vitesse des flottes
function ArmyService.travelTime(from: string, to: string, kind: string, bySea: boolean?): number
	local k = Units.kinds[if bySea then "Mer" else kind]
	local d = distance(from, to, if kind == "Mer" then "Mer" else "Terre")
	if d == math.huge then
		d = 0
	end
	return math.clamp(d / k.speed, k.minTime, k.maxTime)
end

local function link(from: string, to: string): any?
	local region = Regions[from]
	if region then
		for _, l in region.neighbors do
			if l.region == to then
				return l
			end
		end
	end
	return nil
end

-- Une flotte du pays est-elle au port dans cette région (à l'arrêt, hors bataille) ?
local function fleetInPort(countryId: string, regionId: string): boolean
	for _, fleet in forcesOf(countryId, "Mer") do
		if fleet:GetAttribute("Region") == regionId and fleet:GetAttribute("Destination") == "" and not fleet:GetAttribute("EnCombat") then
			return true
		end
	end
	return false
end

-- Une flotte du pays est-elle au port dans cette région ? (traversée de la mer par les divisions)
function ArmyService.fleetInPort(countryId: string, regionId: string): boolean
	return fleetInPort(countryId, regionId)
end

-- Itinéraire : régions qui restent à traverser après la destination en cours
local function getItinerary(army: Instance): { string }
	local raw = army:GetAttribute("Itineraire")
	if typeof(raw) ~= "string" or raw == "" then
		return {}
	end
	return string.split(raw, ",")
end

local function setItinerary(army: Instance, steps: { string })
	army:SetAttribute("Itineraire", if #steps > 0 then table.concat(steps, ",") else nil)
end

-- Région d'un pays hostile (ni le sien, ni celle d'un allié) ?
local function isHostile(countryId: string, owner: string?): boolean
	return owner ~= nil and owner ~= countryId and not DiplomacyService.areAllies(countryId, owner)
end

-- Chemin le plus rapide d'une armée de terre de `from` à `goal` (régions à traverser, `goal` compris),
-- de voisine en voisine. On ne passe que par ses régions, celles de ses alliés, celles des pays avec
-- qui on est en guerre et celles du pays visé (jamais chez un pays neutre) ; la mer seulement depuis
-- une région où une de ses flottes attend au port. nil : aucun chemin.
local function findPath(countryId: string, from: string, goal: string): { string }?
	local target = RegionService.getOwner(goal)
	local function passable(regionId: string): boolean
		local owner = RegionService.getOwner(regionId)
		if regionId == goal or owner == countryId or owner == target then
			return true
		end
		return owner ~= nil and (DiplomacyService.areAllies(countryId, owner) or DiplomacyService.atWar(countryId, owner))
	end
	-- Dijkstra : moins de 700 régions, une recherche simple suffit
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
					fleet = fleetInPort(countryId, current)
				end
				if not fleet then
					continue
				end
			end
			local step = ArmyService.travelTime(current, nextId, "Terre", l.bySea)
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

local function findArmy(countryId: string, armyId: unknown): (Instance?, string?)
	local army = if typeof(armyId) == "string" and folder then folder:FindFirstChild(armyId) else nil
	if not army then
		return nil, "Force introuvable."
	end
	if army:GetAttribute("Proprietaire") ~= countryId then
		return nil, "Cette force ne t'appartient pas."
	end
	return army, nil
end

local function nextName(kind: string): string
	local names = Units.names
	nameIndex += 1
	local base = names[(nameIndex - 1) % #names + 1]
	local round = math.floor((nameIndex - 1) / #names)
	return Units.kinds[kind].leaderTitle .. " " .. base .. (if round > 0 then " " .. (round + 1) else "")
end

-- Nomme un chef (nouvelle force vide) dans une région du pays
function ArmyService.nameCommander(countryId: string, regionId: unknown, kindId: unknown): (boolean, string?)
	local kind = if kindId == nil then "Terre" else kindId
	if typeof(kind) ~= "string" or not Units.kinds[kind] then
		return false, "Sorte de force inconnue."
	end
	if kind == "Terre" then
		-- refonte militaire : sur terre, on recrute des divisions (Config/Divisions)
		return false, "Sur terre, recrute des divisions (onglet Armée)."
	end
	local k = Units.kinds[kind]
	if typeof(regionId) ~= "string" or not Regions[regionId] then
		return false, "Région inconnue."
	end
	if RegionService.getOwner(regionId) ~= countryId then
		return false, "Il faut le faire dans une de tes régions."
	end
	if k.coastal and not Regions[regionId].port then
		return false, "Une flotte a besoin d'une région avec un port (côtière)."
	end
	if #forcesOf(countryId, kind) >= k.maxPerCountry then
		return false, `Pas plus de {k.maxPerCountry} : {string.lower(k.name)}s.`
	end
	if not Stocks.spend(countryId, k.cost) then
		return false, "Pas assez de ressources."
	end
	nextId += 1
	local army = Instance.new("Folder")
	army.Name = "A" .. nextId
	army:SetAttribute("Genre", kind)
	army:SetAttribute("Nom", nextName(kind))
	army:SetAttribute("Proprietaire", countryId)
	army:SetAttribute("Region", regionId)
	army:SetAttribute("Niveau", 1)
	for _, typeId in k.order do
		army:SetAttribute(typeId, 0)
	end
	army:SetAttribute("Destination", "")
	army:SetAttribute("Depart", 0)
	army:SetAttribute("Arrivee", 0)
	army:SetAttribute("Moral", Combat.morale.start)
	army:SetAttribute("Experience", 0)
	army:SetAttribute("Ravitaillee", true)
	army:SetAttribute("Penurie", "")
	army:SetAttribute("Posture", "Normal")
	army:SetAttribute("Provenance", regionId)
	army:SetAttribute("Traits", GeneralTraits.pick(kind, {}, rng) or "")
	army.Parent = folder
	return true, nil
end

-- Recrute une troupe dans une force (sur le territoire du pays, à l'arrêt, hors bataille)
function ArmyService.recruit(countryId: string, armyId: unknown, unitType: unknown): (boolean, string?)
	local army, err = findArmy(countryId, armyId)
	if not army then
		return false, err
	end
	local kind = Units.kindOf(army)
	if typeof(unitType) ~= "string" or not Units.types[unitType] or Units.types[unitType].kind ~= kind then
		return false, "Ce type de troupe ne va pas dans cette force."
	end
	if army:GetAttribute("Destination") ~= "" then
		return false, "Impossible de recruter pendant un déplacement."
	end
	if army:GetAttribute("EnCombat") then
		return false, "Impossible de recruter pendant une bataille."
	end
	if RegionService.getOwner(army:GetAttribute("Region") :: string) ~= countryId then
		return false, "On ne recrute que sur son propre territoire."
	end
	if ArmyService.size(army) >= capacity(army) then
		return false, `Cette force compte déjà {capacity(army)} unités (maximum).`
	end
	-- un pays instable paie ses recrues plus cher (opinion publique)
	local cost = StabilityRules.recruitCost(Units.types[unitType].cost, Stability.get(countryId), Resources.currency.id)
	if not Stocks.spend(countryId, cost) then
		return false, "Pas assez de ressources pour recruter."
	end
	army:SetAttribute(unitType, ((army:GetAttribute(unitType) :: number?) or 0) + 1)
	return true, nil
end

-- Vérifie qu'un déplacement est possible ; renvoie s'il se fait par la mer (transport)
local function checkRoute(countryId: string, army: Instance, from: string, to: string): (boolean, string?, boolean)
	local kind = Units.kindOf(army)
	if not Regions[to] or to == from then
		return false, "Destination impossible.", false
	end
	if kind == "Terre" then
		local l = link(from, to)
		if not l then
			return false, "Destination impossible : choisis une région voisine.", false
		end
		if l.bySea and not fleetInPort(countryId, from) then
			return false, "Pour traverser la mer, il faut une de tes flottes au port de cette région.", false
		end
		return true, nil, l.bySea
	end
	local k = Units.kinds[kind]
	if kind == "Mer" and not Regions[to].port then
		return false, "Une flotte ne va que dans les régions côtières.", false
	end
	if distance(from, to, kind) > (k.range :: number) then
		return false, "Destination hors de portée.", false
	end
	return true, nil, false
end

-- Étape suivante de l'itinéraire, après une arrivée en terrain ami ou une victoire. Si la route est
-- coupée (paix signée, flotte partie, bataille déjà en cours, cessez-le-feu...), la force s'arrête.
local function continueItinerary(army: Instance)
	if not army.Parent or army:GetAttribute("EnCombat") or army:GetAttribute("Destination") ~= "" then
		return
	end
	local steps = getItinerary(army)
	if #steps == 0 then
		return
	end
	local countryId = army:GetAttribute("Proprietaire") :: string
	local from = army:GetAttribute("Region") :: string
	local nextId = table.remove(steps, 1) :: string
	local ok, _, bySea = checkRoute(countryId, army, from, nextId)
	local owner = RegionService.getOwner(nextId)
	if ok and isHostile(countryId, owner) then
		ok = DiplomacyService.atWar(countryId, owner :: string) and ArmyService.size(army) > 0
			and not BattleService.isFighting(nextId) and CouncilState.ceasefireLeft() <= 0
	end
	if not ok then
		setItinerary(army, {})
		return
	end
	setItinerary(army, steps)
	startTravel(army, from, nextId, bySea)
end

-- Lance le trajet (sans vérification : déjà faite par l'appelant)
function startTravel(army: Instance, from: string, destination: string, bySea: boolean?)
	local countryId = army:GetAttribute("Proprietaire") :: string
	local kind = Units.kindOf(army)
	local duration = ArmyService.travelTime(from, destination, kind, bySea) * MilitaryMath.travelFactor(army)
	local start = now()
	army:SetAttribute("Provenance", from)
	army:SetAttribute("ParMer", bySea or nil)
	army:SetAttribute("Destination", destination)
	army:SetAttribute("Depart", start)
	army:SetAttribute("Arrivee", start + duration)
	task.delay(duration, function()
		-- on vérifie que c'est bien toujours ce trajet-là
		if army.Parent and army:GetAttribute("Destination") == destination and army:GetAttribute("Depart") == start then
			army:SetAttribute("Region", destination)
			army:SetAttribute("Destination", "")
			army:SetAttribute("ParMer", nil)
			-- région d'un pays en guerre avec lui : la bataille (ou le raid) s'engage, sauf si une autre
			-- y a déjà lieu ; chez un allié : il stationne ; paix signée pendant le trajet : il rentre.
			-- En terrain ami, l'armée suit son itinéraire ; après une victoire aussi (voir init).
			local owner = RegionService.getOwner(destination)
			if owner and owner ~= countryId and not DiplomacyService.areAllies(countryId, owner) then
				if not DiplomacyService.atWar(countryId, owner) then
					ArmyService.retreat(army)
				elseif not BattleService.isFighting(destination) then
					BattleService.start(army, destination)
				else
					setItinerary(army, {}) -- une autre bataille a lieu ici : la force attend sur place
				end
			else
				continueItinerary(army)
			end
		end
	end)
end

-- Repli vers une région amie : celle d'où la force vient, sinon la plus proche possible.
-- Sans issue (encerclée), la force est perdue.
function ArmyService.retreat(army: Instance)
	if not army.Parent then
		return
	end
	setItinerary(army, {}) -- un repli annule la suite de la route
	local countryId = army:GetAttribute("Proprietaire") :: string
	local kind = Units.kindOf(army)
	local here = army:GetAttribute("Region") :: string
	local target: string? = nil
	local provenance = army:GetAttribute("Provenance")
	if typeof(provenance) == "string" and provenance ~= here and RegionService.getOwner(provenance) == countryId then
		target = provenance
	end
	if not target then
		local best = math.huge
		local candidates = {}
		if kind == "Terre" then
			for _, l in Regions[here].neighbors do
				table.insert(candidates, l.region)
			end
		else
			for id in Regions do
				table.insert(candidates, id)
			end
		end
		for _, id in candidates do
			if id ~= here and RegionService.getOwner(id) == countryId and (kind ~= "Mer" or Regions[id].port) then
				local d = distance(here, id, if kind == "Mer" then "Mer" else "Terre")
				if d < best and (kind == "Terre" or d <= (Units.kinds[kind].range :: number) * 1.5) then
					best = d
					target = id
				end
			end
		end
	end
	if not target then
		army:Destroy() -- encerclée : plus aucune région amie à portée
		return
	end
	local l = link(here, target)
	startTravel(army, here, target, kind == "Terre" and l ~= nil and l.bySea)
end

-- Ordres donnés par le joueur à une force
function ArmyService.order(countryId: string, armyId: unknown, order: unknown): (boolean, string?)
	local army, err = findArmy(countryId, armyId)
	if not army then
		return false, err
	end
	if order == "Normal" or order == "Defendre" or order == "Tenir" then
		army:SetAttribute("Posture", order)
		return true, nil
	end
	if order == "Arreter" then
		-- la force finit le trajet en cours, puis s'arrête
		setItinerary(army, {})
		return true, nil
	end
	if order ~= "Replier" then
		return false, "Ordre inconnu."
	end
	if army:GetAttribute("EnCombat") then
		BattleService.orderRetreat(army)
		return true, nil
	end
	if army:GetAttribute("Destination") ~= "" then
		return false, "Cette force est déjà en route."
	end
	if RegionService.getOwner(army:GetAttribute("Region") :: string) == countryId then
		return false, "Cette force est déjà en territoire ami."
	end
	ArmyService.retreat(army)
	return true, nil
end

-- Envoie une force vers une autre région. Armée de terre : une région lointaine est atteinte de
-- voisine en voisine (itinéraire calculé ici). Une armée déjà en route finit son trajet en cours,
-- puis suit le nouvel itinéraire.
function ArmyService.move(countryId: string, armyId: unknown, destination: unknown): (boolean, string?)
	local army, err = findArmy(countryId, armyId)
	if not army then
		return false, err
	end
	local kind = Units.kindOf(army)
	local moving = army:GetAttribute("Destination") ~= ""
	if moving and kind ~= "Terre" then
		return false, "Cette force est déjà en route."
	end
	if army:GetAttribute("EnCombat") then
		return false, "Cette force est en pleine bataille."
	end
	if typeof(destination) ~= "string" or not Regions[destination] then
		return false, "Destination impossible."
	end
	-- point de départ du nouvel ordre : là où la force sera à la fin de son trajet en cours
	local from = army:GetAttribute(if moving then "Destination" else "Region") :: string
	if destination == from then
		if moving then
			setItinerary(army, {}) -- elle y va déjà : on annule seulement la suite
			return true, nil
		end
		return false, "Cette force y est déjà."
	end
	local steps = { destination }
	if kind == "Terre" and not link(from, destination) then
		local path = findPath(countryId, from, destination)
		if not path then
			return false, "Aucun chemin : il faut traverser un pays neutre, ou la mer sans flotte au port."
		end
		if #path > MAX_STEPS then
			return false, "Destination trop lointaine : choisis une étape plus proche."
		end
		steps = path
	end
	local first = steps[1]
	local ok, reason, bySea = checkRoute(countryId, army, from, first)
	if not ok then
		return false, reason
	end
	local firstOwner = RegionService.getOwner(first)
	if isHostile(countryId, firstOwner) and BattleService.isFighting(first) then
		return false, "Une bataille a déjà lieu dans cette région."
	end
	local owner = RegionService.getOwner(destination)
	if isHostile(countryId, owner) or isHostile(countryId, firstOwner) then
		if ArmyService.size(army) == 0 then
			return false, "Une force sans troupes ne peut pas attaquer."
		end
		local ceasefire = CouncilState.ceasefireLeft()
		if ceasefire > 0 then
			return false, `Cessez-le-feu du Conseil mondial : encore {math.ceil(ceasefire)} s.`
		end
		-- attaquer un pays en paix lui déclare la guerre (impossible avec un allié, pendant une trêve
		-- ou pendant la protection de départ d'un pays qu'un joueur vient de prendre). Les autres
		-- pays traversés sont déjà en guerre avec lui (voir findPath).
		if isHostile(countryId, owner) then
			local target = owner :: string
			local allowed, why = DiplomacyService.canAttack(countryId, target)
			if allowed then
				allowed, why = DiplomacyService.declareWar(countryId, target)
			end
			if not allowed then
				return false, why
			end
		end
	end
	if moving then
		setItinerary(army, steps) -- après le trajet en cours
	else
		table.remove(steps, 1)
		setItinerary(army, steps)
		startTravel(army, from, first, bySea)
	end
	return true, nil
end

-- À appeler après Stocks.init() et BattleService.init()
-- Nouvelle partie : toutes les forces disparaissent (leurs trajets en cours sont ignorés)
function ArmyService.reset()
	if folder then
		folder:ClearAllChildren()
	end
end

function ArmyService.init()
	local armees = Instance.new("Folder")
	armees.Name = "Armees"
	armees.Parent = ReplicatedStorage:WaitForChild("EtatMonde")
	folder = armees

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local limiter = RateLimiter.new(0.25)
	local function remote(name: string, action: (string, unknown, unknown) -> (boolean, string?))
		local r = Instance.new("RemoteFunction")
		r.Name = name
		r.OnServerInvoke = function(player: Player, a: unknown, b: unknown)
			if not limiter:allow(player) then
				return false, "Doucement, réessaie dans un instant."
			end
			local countryId = CountryAssignment.getCountryOf(player)
			if not countryId then
				return false, "Choisis d'abord un pays."
			end
			local ok, message = action(countryId, a, b)
			if ok then
				PlayStyle.recordAction(countryId, name, a, b)
			end
			return ok, message
		end
		r.Parent = remotes
	end
	remote("NommerGeneral", ArmyService.nameCommander)
	remote("Recruter", ArmyService.recruit)
	remote("DeplacerArmee", ArmyService.move)
	remote("OrdreArmee", ArmyService.order)
	BattleService.setRetreatHandler(ArmyService.retreat)
	-- après une victoire, l'armée reprend son itinéraire (une fois la région prise)
	BattleService.onResult(function(result: string, _attacker: string, _defender: string, _regionId: string, army: Instance?)
		if not army then
			return -- bataille terrestre (divisions, voir BattleManager)
		end
		if result == "Victoire" and Units.kindOf(army) == "Terre" then
			task.delay(PAUSE_AFTER_VICTORY, continueItinerary, army)
		elseif army.Parent then
			setItinerary(army, {})
		end
	end)
end

return ArmyService
