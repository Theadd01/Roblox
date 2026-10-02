--!strict
-- Généraux (cahier des charges v2, section 5) : un général est UNE armée.
--   1. On l'achète dans une de ses régions (« NommerGeneral » { region }).
--   2. On lui rattache des troupes par type et par nombre, depuis les régions où elles se trouvent
--      (« AbsorberTroupes » { general, troupes = { { region, type, nombre } } }) ou la sélection
--      (« AssignerDivisions » { general, ids }) : elles disparaissent de la carte et suivent le
--      général (attribut Armee de la division = identifiant du général). Le général apparaît comme
--      une seule unité avec un compteur.
--   3. Ses troupes n'occupent pas de place dans les régions : il ignore la limite de stationnement
--      et attaque avec tout son effectif (BattleManager, largeur de front comprise).
--   4. Il se déplace comme une seule armée, à la vitesse de sa troupe la plus lente
--      (« DeplacerGeneral » { general, region, continu } ; une région ennemie en guerre est
--      attaquée en arrivant à côté). Attaque continue : après une victoire, il attaque la région
--      ennemie voisine suivante tant qu'il a des troupes et du moral.
--   5. Il gagne de l'expérience en combattant (victoires, régions prises) ; chaque niveau donne
--      +10 troupes de capacité et un bonus au choix (« ChoisirBonusGeneral » { general, bonus }) ;
--      on peut aussi l'améliorer avec des crédits (« AmeliorerGeneral » { general }).
--   6. Ses troupes : les libérer vers la région la plus proche (« LibererTroupes » { general, type,
--      nombre }, « RetirerDivisions » { ids }) ou les dissoudre (« SupprimerTroupes ») ;
--      « RenommerGeneral » { general, nom } (texte filtré) ; « RenvoyerGeneral » { general }.
--   7. Toute son armée détruite : il est blessé (hors combat un moment) ou meurt, selon la
--      difficulté (Config/Match.difficulties) ; son quartier général pris : il recule avec son armée
--      vers la région amie la plus proche, ou il est vaincu s'il est encerclé.
-- État publié dans ReplicatedStorage.EtatMonde.Generaux.<id> : Nom, Proprietaire, Region,
-- Destination ("" à l'arrêt), Depart, Arrivee, Itineraire, Cible (région à attaquer en arrivant),
-- AttaqueContinue, Traits, Experience, Niveau, Capacite, Troupes (nombre), Composition
-- (« Infanterie=12,Blindee=3 »), ChoixBonus (bonus à choisir), Bonus_attack... (choix faits),
-- Desorganise et Blesse (heure de fin, absents sinon).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Military = require(Config:WaitForChild("Military")) :: any
local Generals = require(Config:WaitForChild("Generals")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Units = require(Config:WaitForChild("Units")) :: any
local DivisionConfig = require(Config:WaitForChild("Divisions")) :: any
local RegionTerrain = require(Config:WaitForChild("RegionTerrain")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any
local GeneralTraits = require(Shared:WaitForChild("GeneralTraits")) :: any
local CouncilState = require(Shared:WaitForChild("CouncilState")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local DiplomacyService = require(Server:WaitForChild("Politics"):WaitForChild("DiplomacyService"))
local Stocks = require(Server:WaitForChild("Economy"):WaitForChild("Stocks"))
local Divisions = require(script.Parent:WaitForChild("Divisions"))

type BattleHooks = {
	attack: (d: Instance, from: string, target: string) -> (boolean, string?),
	withdraw: (d: Instance) -> (),
	nextTarget: (countryId: string, from: string) -> string?,
	isFighting: (regionId: string) -> boolean,
}

local MAX_STEPS = 40 -- régions au plus dans un trajet

local Armies = {}

local folder: Folder? = nil
local nextId = 0
local nameIndex = 0
local rng = Random.new()
local hooks: BattleHooks? = nil
local checkQueued: { [Instance]: boolean } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function anchorOf(regionId: string): Vector3?
	local region = Regions[regionId]
	local city = region and region.city
	return if city then MapProjection.toVector3(city.lon, city.lat, MapSettings.regionTop) else nil
end

local function isHostile(countryId: string, owner: string?): boolean
	return owner ~= nil and owner ~= countryId and not DiplomacyService.areAllies(countryId, owner)
end

local function friendly(countryId: string, owner: string?): boolean
	return owner ~= nil and (owner == countryId or DiplomacyService.areAllies(countryId, owner))
end

local function landLink(from: string, to: string): boolean
	local region = Regions[from]
	for _, link in (if region then region.neighbors else {}) do
		if link.region == to and not link.bySea then
			return true
		end
	end
	return false
end

-- ---- Lecture ---------------------------------------------------------------------------------

function Armies.all(): { Instance }
	return if folder then folder:GetChildren() else {}
end

function Armies.get(id: unknown): Instance?
	return if typeof(id) == "string" and id ~= "" and folder then folder:FindFirstChild(id) else nil
end

function Armies.ofCountry(countryId: string): { Instance }
	local list = {}
	for _, g in Armies.all() do
		if g:GetAttribute("Proprietaire") == countryId then
			table.insert(list, g)
		end
	end
	return list
end

-- Un général dont le quartier général est (ou sera, s'il y va) dans cette région
function Armies.inRegion(regionId: string): Instance?
	for _, g in Armies.all() do
		if g:GetAttribute("Region") == regionId or g:GetAttribute("Destination") == regionId then
			return g
		end
	end
	return nil
end

-- Troupes de l'armée d'un général
function Armies.divisionsOf(general: Instance): { Instance }
	local list = {}
	for _, d in Divisions.all() do
		if d:GetAttribute("Armee") == general.Name then
			table.insert(list, d)
		end
	end
	return list
end

-- La division fait-elle partie de l'armée d'un général ? (elle n'est plus sur la carte)
function Armies.isAbsorbed(d: Instance): boolean
	return Armies.get(d:GetAttribute("Armee")) ~= nil
end

function Armies.levelOf(general: Instance): number
	return math.clamp((general:GetAttribute("Niveau") :: number?) or 1, 1, Military.generals.maxLevel)
end

-- Troupes au plus dans son armée (selon son niveau)
function Armies.capacityOf(general: Instance): number
	local capacity = Military.generals.capacity
	return capacity[math.clamp(Armies.levelOf(general), 1, #capacity)]
end

local function wounded(general: Instance): boolean
	local untilTime = general:GetAttribute("Blesse")
	return typeof(untilTime) == "number" and untilTime > now()
end

-- Bonus d'un effet pour les troupes d'un général : traits (Config/Generals), niveau et bonus
-- choisis (Config/Military.generals). Effets : attack, defense, speed, morale, recovery,
-- experience, upkeep, Blindes, Artillerie, rough, encirclement.
function Armies.generalBonus(general: Instance, effect: string): number
	local G = Military.generals
	local total = GeneralTraits.bonus(general, effect)
	local level = Armies.levelOf(general)
	local perLevel = G.levelBonus[effect]
	if perLevel then
		total += perLevel * (level - 1)
	end
	local choice = G.choices[effect]
	if choice then
		total += choice.value * ((general:GetAttribute("Bonus_" .. effect) :: number?) or 0)
	end
	return math.min(G.maxBonus, total)
end

-- Le général d'une division, s'il peut donner ses bonus (ni désorganisé, ni blessé)
function Armies.commanderOf(d: Instance): Instance?
	local general = Armies.get(d:GetAttribute("Armee"))
	if not general then
		return nil
	end
	local untilTime = general:GetAttribute("Desorganise")
	if (typeof(untilTime) == "number" and untilTime > now()) or wounded(general) then
		return nil
	end
	return general
end

-- Bonus d'un effet pour une division (0 sans général)
function Armies.bonus(d: Instance, effect: string): number
	local general = Armies.commanderOf(d)
	return if general then Armies.generalBonus(general, effect) else 0
end

-- Règle d'achat (pure, testée dans Tests/Generals.spec) : sa propre région, nombre de généraux
function Armies.buyRule(countryId: string, owner: string?, count: number): (boolean, string?)
	if owner ~= countryId then
		return false, "On achète un général dans une de ses propres régions."
	end
	if count >= Military.generals.maxPerCountry then
		return false, `Pas plus de {Military.generals.maxPerCountry} généraux.`
	end
	return true, nil
end

-- Niveau d'après l'expérience (pur)
function Armies.levelFor(xp: number): number
	local G = Military.generals
	return math.clamp(1 + math.floor(xp / G.xpPerLevel), 1, G.maxLevel)
end

-- Composition publiée : nombre de troupes, « Infanterie=12,Blindee=3 »
local function publishTroops(general: Instance)
	if not general.Parent then
		return
	end
	local counts: { [string]: number } = {}
	local total = 0
	for _, d in Armies.divisionsOf(general) do
		local typeId = d:GetAttribute("Type") :: string
		counts[typeId] = (counts[typeId] or 0) + 1
		total += 1
	end
	local parts = {}
	for _, typeId in DivisionConfig.order do
		if counts[typeId] then
			table.insert(parts, `{typeId}={counts[typeId]}`)
		end
	end
	if counts.Milice then
		table.insert(parts, `Milice={counts.Milice}`)
	end
	general:SetAttribute("Troupes", total)
	general:SetAttribute("Composition", table.concat(parts, ","))
	general:SetAttribute("Capacite", Armies.capacityOf(general))
end

-- Expérience d'un général ; nouveau niveau : un bonus à choisir, et un trait de plus aux paliers
function Armies.addExperience(general: Instance, amount: number)
	if not general.Parent or amount <= 0 then
		return
	end
	local G = Military.generals
	local before = Armies.levelOf(general)
	local xpMax = G.xpPerLevel * (G.maxLevel - 1) + G.xpPerLevel - 1
	local xp = math.min(xpMax, ((general:GetAttribute("Experience") :: number?) or 0) + amount * (1 + GeneralTraits.bonus(general, "experience")))
	general:SetAttribute("Experience", xp)
	local level = Armies.levelFor(xp)
	general:SetAttribute("Niveau", level)
	if level > before then
		general:SetAttribute("ChoixBonus", ((general:GetAttribute("ChoixBonus") :: number?) or 0) + (level - before))
		local traits = GeneralTraits.of(general)
		local wanted = if level >= Generals.thirdTraitLevel then 3 elseif level >= Generals.secondTraitLevel then 2 else 1
		while #traits < wanted do
			local extra = GeneralTraits.pick("Terre", traits, rng)
			if not extra then
				break
			end
			table.insert(traits, extra)
		end
		general:SetAttribute("Traits", table.concat(traits, ","))
		publishTroops(general)
	end
end

local function nextName(): string
	local names = Units.names
	nameIndex += 1
	local base = names[(nameIndex - 1) % #names + 1]
	local round = math.floor((nameIndex - 1) / #names)
	return "Général " .. base .. (if round > 0 then " " .. (round + 1) else "")
end

local function ownedGeneral(countryId: string, id: unknown): (Instance?, string?)
	local general = Armies.get(id)
	if not general or general:GetAttribute("Proprietaire") ~= countryId then
		return nil, "Ce général n'est pas à toi."
	end
	return general, nil
end

-- Achète un général dans une de ses régions ; renvoie aussi son identifiant
function Armies.buy(countryId: string, regionId: unknown): (boolean, string?, string?)
	if typeof(regionId) ~= "string" or not Regions[regionId] or not folder then
		return false, "Région inconnue.", nil
	end
	local ok, why = Armies.buyRule(countryId, RegionService.getOwner(regionId), #Armies.ofCountry(countryId))
	if not ok then
		return false, why, nil
	end
	if not Stocks.spend(countryId, Military.generals.cost) then
		return false, "Pas assez de crédits pour acheter un général.", nil
	end
	nextId += 1
	local g = Instance.new("Folder")
	g.Name = "G" .. nextId
	g:SetAttribute("Nom", nextName())
	g:SetAttribute("Proprietaire", countryId)
	g:SetAttribute("Region", regionId)
	g:SetAttribute("Destination", "")
	g:SetAttribute("Depart", 0)
	g:SetAttribute("Arrivee", 0)
	g:SetAttribute("Experience", 0)
	g:SetAttribute("Niveau", 1)
	g:SetAttribute("ChoixBonus", 0)
	g:SetAttribute("Traits", GeneralTraits.pick("Terre", {}, rng) or "") -- trait tiré au hasard
	g.Parent = folder
	publishTroops(g)
	return true, nil, g.Name
end

-- Une division peut-elle rejoindre une armée ? (à lui, prête, à l'arrêt, hors bataille)
local function canJoin(countryId: string, d: Instance): boolean
	return d.Parent ~= nil and d:GetAttribute("Proprietaire") == countryId and not Divisions.isTraining(d)
		and not Divisions.isMoving(d) and not Divisions.inBattle(d) and not Armies.isAbsorbed(d)
end

local function absorb(general: Instance, d: Instance)
	d:SetAttribute("Armee", general.Name)
	d:SetAttribute("Controle", "Manuel")
	d:SetAttribute("Itineraire", nil)
	d:SetAttribute("AttaqueContinue", nil)
	d:SetAttribute("Retranchement", 0)
	Divisions.setRegion(d, general:GetAttribute("Region") :: string)
end

-- Rattache des divisions précises (sélection sur la carte)
function Armies.assign(countryId: string, generalId: unknown, list: { Instance }): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	local room = Armies.capacityOf(general) - #Armies.divisionsOf(general)
	local added, refused = 0, 0
	for _, d in list do
		if d:GetAttribute("Armee") == general.Name then
			continue
		end
		if room <= 0 or not canJoin(countryId, d) then
			refused += 1
			continue
		end
		absorb(general, d)
		room -= 1
		added += 1
	end
	publishTroops(general)
	if added == 0 then
		return false, if room <= 0 then "Son armée est pleine : il faut monter de niveau." else "Ces divisions ne sont pas disponibles (entraînement, trajet ou bataille)."
	end
	if refused > 0 then
		return true, `{added} division{if added > 1 then "s" else ""} rattachée{if added > 1 then "s" else ""}, {refused} non (armée pleine ou divisions occupées).`
	end
	return true, nil
end

-- Rattache des troupes par type et par nombre, depuis les régions où elles se trouvent
-- picks : { { region = "FRA_2", type = "Infanterie", nombre = 4 }, ... }
function Armies.absorbTroops(countryId: string, generalId: unknown, picks: unknown): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	if typeof(picks) ~= "table" then
		return false, "Aucune troupe choisie."
	end
	local list: { Instance } = {}
	local seen: { [string]: boolean } = {}
	local count = 0
	for _, pick in picks :: { any } do
		if typeof(pick) ~= "table" then
			return false, "Choix invalide."
		end
		local regionId, typeId, wanted = pick.region, pick.type, pick.nombre
		if typeof(regionId) ~= "string" or not Regions[regionId] or typeof(typeId) ~= "string" or not DivisionConfig.types[typeId]
			or typeof(wanted) ~= "number" or wanted ~= wanted or wanted < 1 then
			return false, "Choix invalide."
		end
		local key = regionId .. "|" .. typeId
		if seen[key] then
			return false, "Choix invalide."
		end
		seen[key] = true
		count += 1
		if count > 60 then
			return false, "Trop de choix."
		end
		-- les plus valides d'abord
		local candidates = {}
		for _, d in Divisions.inRegion(regionId) do
			if d:GetAttribute("Type") == typeId and canJoin(countryId, d) then
				table.insert(candidates, d)
			end
		end
		table.sort(candidates, function(a: Instance, b: Instance): boolean
			return ((a:GetAttribute("Force") :: number?) or 0) > ((b:GetAttribute("Force") :: number?) or 0)
		end)
		for i = 1, math.min(math.floor(wanted), #candidates) do
			table.insert(list, candidates[i])
		end
	end
	if #list == 0 then
		return false, "Aucune de ces troupes n'est disponible."
	end
	return Armies.assign(countryId, generalId, list)
end

-- Région où libérer des troupes : celle du général si elle a de la place, sinon la plus proche
-- de ses régions (puis de ses alliés) qui en a ; nil si aucune
local function releaseTarget(general: Instance, needed: number): string?
	local countryId = general:GetAttribute("Proprietaire") :: string
	local from = general:GetAttribute("Region") :: string
	local seen = { [from] = true }
	local queue = { from }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		if RegionService.getOwner(current) == countryId and Divisions.capacityOf(current) - Divisions.occupancy(current) >= needed then
			return current
		end
		for _, link in Regions[current].neighbors do
			local nextId = link.region
			if not seen[nextId] and not link.bySea and Regions[nextId] and friendly(countryId, RegionService.getOwner(nextId)) then
				seen[nextId] = true
				table.insert(queue, nextId)
			end
		end
	end
	return nil
end

-- Libère des divisions de l'armée vers la région la plus proche qui a de la place
local function releaseList(general: Instance, list: { Instance }): (number, string?)
	local released = 0
	local lastRegion: string? = nil
	for _, d in list do
		local to = releaseTarget(general, 1)
		if not to then
			break
		end
		d:SetAttribute("Armee", "")
		d:SetAttribute("Destination", "")
		Divisions.setRegion(d, to)
		released += 1
		lastRegion = to
	end
	publishTroops(general)
	return released, lastRegion
end

local function pickTroops(general: Instance, typeId: unknown, count: unknown, weakestFirst: boolean): ({ Instance }?, string?)
	if typeof(typeId) ~= "string" or not DivisionConfig.types[typeId] then
		return nil, "Type de troupe inconnu."
	end
	if typeof(count) ~= "number" or count ~= count or count < 1 then
		return nil, "Nombre invalide."
	end
	local list = {}
	for _, d in Armies.divisionsOf(general) do
		if d:GetAttribute("Type") == typeId and not Divisions.inBattle(d) then
			table.insert(list, d)
		end
	end
	table.sort(list, function(a: Instance, b: Instance): boolean
		local fa, fb = (a:GetAttribute("Force") :: number?) or 0, (b:GetAttribute("Force") :: number?) or 0
		if weakestFirst then
			return fa < fb
		end
		return fa > fb
	end)
	local result = {}
	for i = 1, math.min(math.floor(count :: number), #list) do
		table.insert(result, list[i])
	end
	if #result == 0 then
		return nil, "Aucune troupe de ce type disponible (au combat ?)."
	end
	return result, nil
end

-- Libère `count` troupes d'un type vers la région la plus proche
function Armies.releaseTroops(countryId: string, generalId: unknown, typeId: unknown, count: unknown): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	local list, why = pickTroops(general, typeId, count, false)
	if not list then
		return false, why
	end
	local released, regionId = releaseList(general, list)
	if released == 0 then
		return false, "Aucune de tes régions proches n'a de place pour elles."
	end
	return true, `{released} division{if released > 1 then "s" else ""} libérée{if released > 1 then "s" else ""} en {Regions[regionId :: string].name}.`
end

-- Retire des divisions précises de l'armée (vers la région la plus proche)
function Armies.unassign(list: { Instance }): (boolean, string?)
	local byGeneral: { [Instance]: { Instance } } = {}
	for _, d in list do
		local general = Armies.get(d:GetAttribute("Armee"))
		if general and not Divisions.inBattle(d) then
			byGeneral[general] = byGeneral[general] or {}
			table.insert(byGeneral[general], d)
		end
	end
	local total = 0
	for general, divisions in byGeneral do
		total += (releaseList(general, divisions))
	end
	if total == 0 then
		return false, "Aucune place pour elles dans tes régions proches."
	end
	return true, nil
end

-- Dissout `count` troupes d'un type (les plus affaiblies d'abord)
function Armies.disbandTroops(countryId: string, generalId: unknown, typeId: unknown, count: unknown): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	local list, why = pickTroops(general, typeId, count, true)
	if not list then
		return false, why
	end
	for _, d in list do
		Divisions.destroy(d)
	end
	publishTroops(general)
	return true, nil
end

-- Améliore le général avec des crédits : niveau suivant
function Armies.upgrade(countryId: string, generalId: unknown): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	local G = Military.generals
	local level = Armies.levelOf(general)
	if level >= G.maxLevel then
		return false, "Ce général est déjà au niveau maximum."
	end
	local price = G.upgradeCost[level]
	if not Stocks.spend(countryId, { Credits = price }) then
		return false, `Il faut {price} crédits.`
	end
	local xp = (general:GetAttribute("Experience") :: number?) or 0
	local needed = level * G.xpPerLevel - xp
	-- l'achat n'est pas multiplié par le trait « Vétéran » : il donne juste le niveau suivant
	local factor = 1 + GeneralTraits.bonus(general, "experience")
	Armies.addExperience(general, needed / factor + 1e-6)
	return true, nil
end

-- Renomme le général (nom déjà filtré par le serveur : Commands)
function Armies.rename(countryId: string, generalId: unknown, name: unknown): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	if typeof(name) ~= "string" then
		return false, "Nom invalide."
	end
	local trimmed = name:gsub("^%s+", ""):gsub("%s+$", "")
	if #trimmed == 0 or utf8.len(trimmed) == nil or (utf8.len(trimmed) :: number) > Military.generals.nameMaxLength then
		return false, `Le nom doit faire de 1 à {Military.generals.nameMaxLength} caractères.`
	end
	general:SetAttribute("Nom", trimmed)
	return true, nil
end

-- Choisit le bonus d'un niveau gagné
function Armies.chooseBonus(countryId: string, generalId: unknown, bonus: unknown): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	if typeof(bonus) ~= "string" or not Military.generals.choices[bonus] then
		return false, "Bonus inconnu."
	end
	local pending = (general:GetAttribute("ChoixBonus") :: number?) or 0
	if pending <= 0 then
		return false, "Aucun bonus à choisir : il faut d'abord monter de niveau."
	end
	general:SetAttribute("ChoixBonus", pending - 1)
	local attribute = "Bonus_" .. bonus
	general:SetAttribute(attribute, ((general:GetAttribute(attribute) :: number?) or 0) + 1)
	return true, nil
end

-- ---- Déplacements et attaques ------------------------------------------------------------------

-- Durée d'une étape : celle de sa troupe la plus lente (sans troupe : un officier à pied)
function Armies.stepSeconds(general: Instance, from: string, to: string): number
	local a, b = anchorOf(from), anchorOf(to)
	local distance = if a and b then (b - a).Magnitude else 0
	local fuel = Stocks.get(general:GetAttribute("Proprietaire") :: string, "Petrole") > 0
	local slowest = 0
	local types: { [string]: boolean } = {}
	for _, d in Armies.divisionsOf(general) do
		types[d:GetAttribute("Type") :: string] = true
	end
	if next(types) == nil then
		types.Infanterie = true
	end
	for typeId in types do
		slowest = math.max(slowest, Divisions.stepSeconds(typeId, distance, RegionTerrain.terrain[to], fuel))
	end
	return slowest * math.max(0.2, 1 - Armies.generalBonus(general, "speed"))
end

-- Chemin par ses régions et celles de ses alliés (par la terre) jusqu'à `goal` (compris), le plus
-- court en nombre de régions ; nil : aucun
local function findPath(general: Instance, from: string, goal: string): { string }?
	local countryId = general:GetAttribute("Proprietaire") :: string
	local previous: { [string]: string } = {}
	local seen = { [from] = true }
	local queue = { from }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		if current == goal then
			break
		end
		for _, link in Regions[current].neighbors do
			local nextId = link.region
			if seen[nextId] or link.bySea or not Regions[nextId] then
				continue
			end
			if nextId ~= goal and not friendly(countryId, RegionService.getOwner(nextId)) then
				continue
			end
			seen[nextId] = true
			previous[nextId] = current
			table.insert(queue, nextId)
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

local function getItinerary(general: Instance): { string }
	local raw = general:GetAttribute("Itineraire")
	if typeof(raw) ~= "string" or raw == "" then
		return {}
	end
	return string.split(raw, ",")
end

local function setItinerary(general: Instance, steps: { string })
	general:SetAttribute("Itineraire", if #steps > 0 then table.concat(steps, ",") else nil)
end

local function startStep(general: Instance, to: string, factor: number?)
	local from = general:GetAttribute("Region") :: string
	local start = now()
	general:SetAttribute("Destination", to)
	general:SetAttribute("Depart", start)
	general:SetAttribute("Arrivee", start + Armies.stepSeconds(general, from, to) * (factor or 1))
	for _, d in Armies.divisionsOf(general) do
		d:SetAttribute("Retranchement", 0)
	end
end

-- L'armée attaque une région ennemie voisine de sa région, avec toutes ses troupes prêtes
local function launchAttack(general: Instance, target: string): (boolean, string?)
	local h = hooks
	if not h then
		return false, "Combat indisponible."
	end
	local countryId = general:GetAttribute("Proprietaire") :: string
	local here = general:GetAttribute("Region") :: string
	if wounded(general) then
		return false, "Ce général est blessé : il ne peut pas attaquer pour l'instant."
	end
	local owner = RegionService.getOwner(target)
	if not owner or not isHostile(countryId, owner) or not DiplomacyService.atWar(countryId, owner) then
		return false, "Pas en guerre avec ce pays : déclare-lui d'abord la guerre."
	end
	if CouncilState.ceasefireLeft() > 0 then
		return false, "Cessez-le-feu du Conseil mondial."
	end
	local sent = 0
	local lastError: string? = nil
	for _, d in Armies.divisionsOf(general) do
		if Divisions.inBattle(d) or Divisions.isTraining(d) then
			continue
		end
		local ok, why = h.attack(d, here, target)
		if ok then
			sent += 1
		else
			lastError = why
		end
	end
	if sent == 0 then
		return false, lastError or "Son armée n'a aucune troupe prête à attaquer."
	end
	general:SetAttribute("Cible", nil)
	return true, nil
end

-- Déplace l'armée vers une région : une de ses régions (ou d'un allié) par le chemin le plus
-- court ; une région ennemie en guerre : l'armée va dans la région voisine puis l'attaque.
-- continuous : après une victoire, elle enchaîne les régions ennemies voisines.
function Armies.move(countryId: string, generalId: unknown, regionId: unknown, continuous: unknown): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	if typeof(regionId) ~= "string" or not Regions[regionId] then
		return false, "Région inconnue."
	end
	for _, d in Armies.divisionsOf(general) do
		if Divisions.inBattle(d) then
			return false, "Son armée est au combat : attends la fin de la bataille."
		end
	end
	local from = general:GetAttribute(if general:GetAttribute("Destination") ~= "" then "Destination" else "Region") :: string
	local owner = RegionService.getOwner(regionId)
	general:SetAttribute("AttaqueContinue", if continuous == true then true else nil)
	if isHostile(countryId, owner) then
		if not DiplomacyService.atWar(countryId, owner :: string) then
			return false, "Pas en guerre avec ce pays : déclare-lui d'abord la guerre."
		end
		if wounded(general) then
			return false, "Ce général est blessé : il ne peut pas attaquer pour l'instant."
		end
		-- aller dans une de ses régions voisines de la cible, puis attaquer
		local best: { string }? = nil
		if landLink(from, regionId) then
			best = {}
		else
			for _, link in Regions[regionId].neighbors do
				if link.bySea or not friendly(countryId, RegionService.getOwner(link.region)) then
					continue
				end
				local path = findPath(general, from, link.region)
				if path and #path <= MAX_STEPS and (not best or #path < #best) then
					best = path
				end
			end
		end
		if not best then
			return false, "Aucun chemin par tes régions jusqu'à cette région."
		end
		general:SetAttribute("Cible", regionId)
		setItinerary(general, best)
		if general:GetAttribute("Destination") == "" then
			if #best == 0 then
				return launchAttack(general, regionId)
			end
			local steps = getItinerary(general)
			local first = table.remove(steps, 1) :: string
			setItinerary(general, steps)
			startStep(general, first)
		end
		return true, nil
	end
	general:SetAttribute("Cible", nil)
	if owner ~= countryId and not friendly(countryId, owner) then
		return false, "L'armée va dans une de tes régions, chez un allié, ou attaque un pays en guerre."
	end
	if from == regionId then
		setItinerary(general, {})
		return true, nil
	end
	local path = findPath(general, from, regionId)
	if not path or #path > MAX_STEPS then
		return false, "Aucun chemin par tes régions (ou celles de tes alliés) jusque-là."
	end
	setItinerary(general, path)
	if general:GetAttribute("Destination") == "" then
		local steps = getItinerary(general)
		local first = table.remove(steps, 1) :: string
		setItinerary(general, steps)
		startStep(general, first)
	end
	return true, nil
end

-- Après une victoire : l'armée entre dans la région prise (plus vite qu'un trajet normal)
function Armies.advance(general: Instance, regionId: string)
	if not general.Parent or general:GetAttribute("Destination") ~= "" then
		return
	end
	setItinerary(general, {})
	general:SetAttribute("Cible", nil)
	startStep(general, regionId, Military.generals.advanceFactor)
end

-- L'offensive du général s'arrête (attaque échouée, ordre du joueur)
function Armies.stopOffensive(general: Instance)
	if general.Parent then
		general:SetAttribute("AttaqueContinue", nil)
		general:SetAttribute("Cible", nil)
	end
end

-- Toute son armée est détruite : blessé (hors combat un moment) ou mort, selon la difficulté
local function defeated(general: Instance, fallback: string?)
	if not general.Parent then
		return
	end
	local _, difficulty = MatchState.difficulty()
	if difficulty.generalDefeat == "Mort" or not fallback then
		general:Destroy()
		return
	end
	general:SetAttribute("Region", fallback)
	general:SetAttribute("Destination", "")
	setItinerary(general, {})
	general:SetAttribute("Cible", nil)
	general:SetAttribute("AttaqueContinue", nil)
	general:SetAttribute("Blesse", now() + Military.generals.woundedSeconds)
	publishTroops(general)
end

-- Une de ses régions la plus proche (pour un général blessé) ; nil si le pays n'en a plus
local function nearestOwned(general: Instance, from: string): string?
	local countryId = general:GetAttribute("Proprietaire") :: string
	if RegionService.getOwner(from) == countryId then
		return from
	end
	local seen = { [from] = true }
	local queue = { from }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, link in Regions[current].neighbors do
			local nextId = link.region
			if seen[nextId] or not Regions[nextId] then
				continue
			end
			seen[nextId] = true
			if RegionService.getOwner(nextId) == countryId then
				return nextId
			end
			table.insert(queue, nextId)
		end
	end
	return nil
end

-- Une troupe de son armée est tombée au combat (BattleManager, avant de la détruire)
function Armies.casualty(d: Instance)
	local general = Armies.get(d:GetAttribute("Armee"))
	if not general or checkQueued[general] then
		return
	end
	checkQueued[general] = true
	task.defer(function()
		checkQueued[general] = nil
		if general.Parent then
			publishTroops(general)
			if #Armies.divisionsOf(general) == 0 then
				defeated(general, nearestOwned(general, general:GetAttribute("Region") :: string))
			end
		end
	end)
end

-- Renvoie un général : ses troupes sont libérées
function Armies.dismiss(countryId: string, generalId: unknown): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	local troops = Armies.divisionsOf(general)
	for _, d in troops do
		if Divisions.inBattle(d) then
			return false, "Son armée est au combat : attends la fin de la bataille."
		end
	end
	local released = releaseList(general, troops)
	if released < #troops then
		return false, "Pas assez de place dans tes régions proches pour toutes ses troupes."
	end
	general:Destroy()
	return true, nil
end

-- Région amie la plus proche (en nombre de régions) ; nil : encerclé
local function fallbackFor(general: Instance, from: string): string?
	local countryId = general:GetAttribute("Proprietaire") :: string
	local seen = { [from] = true }
	local queue = { from }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, link in Regions[current].neighbors do
			local nextId = link.region
			if seen[nextId] or link.bySea or not Regions[nextId] then
				continue
			end
			seen[nextId] = true
			if friendly(countryId, RegionService.getOwner(nextId)) then
				return nextId
			end
		end
	end
	return nil
end

-- Une région change de mains : les armées ennemies qui s'y trouvent reculent avec leur général
-- (désorganisé un moment), ou sont vaincues si elles sont encerclées
local function onOwnerChanged(regionId: string, newOwner: string)
	for _, general in Armies.all() do
		local owner = general:GetAttribute("Proprietaire") :: string
		local here = general:GetAttribute("Region") == regionId
		local going = general:GetAttribute("Destination") == regionId
		if not (here or going) or friendly(owner, newOwner) then
			continue
		end
		if going and not here then
			general:SetAttribute("Destination", "") -- il reste où il est
			setItinerary(general, {})
			continue
		end
		local troops = Armies.divisionsOf(general)
		local to = fallbackFor(general, regionId)
		if to then
			general:SetAttribute("Region", to)
			general:SetAttribute("Destination", "")
			setItinerary(general, {})
			general:SetAttribute("Cible", nil)
			general:SetAttribute("AttaqueContinue", nil)
			general:SetAttribute("Desorganise", now() + Military.generals.disorganizedSeconds)
			for _, d in troops do
				Divisions.setRegion(d, to)
			end
		else
			-- encerclé : son armée est détruite
			for _, d in troops do
				Divisions.destroy(d)
			end
			defeated(general, nearestOwned(general, regionId))
		end
	end
end

-- Arrivée au bout d'une étape : l'armée entre dans la région, puis continue sa route, attaque sa
-- cible, ou cherche la région suivante (attaque continue)
local function arrive(general: Instance)
	local countryId = general:GetAttribute("Proprietaire") :: string
	local to = general:GetAttribute("Destination") :: string
	general:SetAttribute("Destination", "")
	local owner = RegionService.getOwner(to)
	if isHostile(countryId, owner) then
		-- la région a été reprise pendant le trajet : l'armée reste où elle est
		setItinerary(general, {})
		return
	end
	general:SetAttribute("Region", to)
	general:SetAttribute("Arrivee", now())
	for _, d in Armies.divisionsOf(general) do
		Divisions.setRegion(d, to)
	end
	local steps = getItinerary(general)
	if #steps > 0 then
		local nextStep = table.remove(steps, 1) :: string
		setItinerary(general, steps)
		if friendly(countryId, RegionService.getOwner(nextStep)) then
			startStep(general, nextStep)
		else
			setItinerary(general, {})
		end
		return
	end
	local target = general:GetAttribute("Cible")
	if typeof(target) == "string" and target ~= "" then
		if not launchAttack(general, target) then
			general:SetAttribute("Cible", nil)
			general:SetAttribute("AttaqueContinue", nil)
		end
	end
end

-- Attaque continue : un général à l'arrêt, sans bataille, attaque la région ennemie voisine
-- suivante tant qu'il a des troupes et du moral
local function continueOffensive(general: Instance, t: number)
	local G = Military.generals
	local arrived = (general:GetAttribute("Arrivee") :: number?) or 0
	if t - arrived < G.continueDelay or CouncilState.ceasefireLeft() > 0 then
		return
	end
	local troops = Armies.divisionsOf(general)
	local org, orgMax = 0, 0
	for _, d in troops do
		if Divisions.inBattle(d) then
			return -- encore au combat
		end
		org += (d:GetAttribute("Org") :: number?) or 0
		orgMax += (d:GetAttribute("OrgMax") :: number?) or 1
	end
	local h = hooks
	local countryId = general:GetAttribute("Proprietaire") :: string
	local target = if h then h.nextTarget(countryId, general:GetAttribute("Region") :: string) else nil
	if not target or #troops == 0 or orgMax <= 0 or org / orgMax < G.continueMinOrganisation or wounded(general) then
		general:SetAttribute("AttaqueContinue", nil)
		return
	end
	if not launchAttack(general, target) then
		general:SetAttribute("AttaqueContinue", nil)
	end
end

local function update(_dt: number, t: number)
	for _, general in Armies.all() do
		local destination = general:GetAttribute("Destination")
		if typeof(destination) == "string" and destination ~= "" then
			if t >= ((general:GetAttribute("Arrivee") :: number?) or 0) then
				arrive(general)
			end
		elseif general:GetAttribute("AttaqueContinue") == true and not general:GetAttribute("Cible") then
			continueOffensive(general, t)
		end
		local untilTime = general:GetAttribute("Desorganise")
		if typeof(untilTime) == "number" and t >= untilTime then
			general:SetAttribute("Desorganise", nil)
		end
		local hurt = general:GetAttribute("Blesse")
		if typeof(hurt) == "number" and t >= hurt then
			general:SetAttribute("Blesse", nil)
		end
	end
end

-- BattleManager : engager une division, la retirer, choisir la région suivante
function Armies.setBattleHooks(battleHooks: BattleHooks)
	hooks = battleHooks
end

-- Nouvelle partie : plus aucun général
function Armies.reset()
	if folder then
		folder:ClearAllChildren()
	end
	nameIndex = 0
	table.clear(checkQueued)
end

function Armies.init(loop: any, commands: any)
	local generaux = Instance.new("Folder")
	generaux.Name = "Generaux"
	generaux.Parent = ReplicatedStorage:WaitForChild("EtatMonde")
	folder = generaux
	loop.every("generaux", 0.25, update)
	RegionService.onOwnerChanged(onOwnerChanged)
	-- un général renvoyé ou vaincu : ses troupes restantes reviennent sur la carte
	generaux.ChildRemoved:Connect(function(general: Instance)
		for _, d in Divisions.all() do
			if d:GetAttribute("Armee") == general.Name then
				d:SetAttribute("Armee", "")
			end
		end
	end)
	-- une division détruite (au combat, dissoute) : le compteur de son armée change
	Divisions.onRemoved(function(d: Instance)
		local general = Armies.get(d:GetAttribute("Armee"))
		if general then
			task.defer(publishTroops, general)
		end
	end)

	commands.register("NommerGeneral", function(countryId: string, data: { [any]: any }): (boolean, string?)
		local ok, message, id = Armies.buy(countryId, data.region)
		return ok, if ok then id else message
	end, "NommerGeneral")
	commands.register("AbsorberTroupes", function(countryId: string, data: { [any]: any }): (boolean, string?)
		return Armies.absorbTroops(countryId, data.general, data.troupes)
	end)
	commands.register("AssignerDivisions", function(countryId: string, data: { [any]: any }): (boolean, string?)
		local list, err = commands.ownedDivisions(countryId, data.ids)
		if not list then
			return false, err
		end
		return Armies.assign(countryId, data.general, list)
	end)
	commands.register("RetirerDivisions", function(countryId: string, data: { [any]: any }): (boolean, string?)
		local list, err = commands.ownedDivisions(countryId, data.ids)
		if not list then
			return false, err
		end
		return Armies.unassign(list)
	end)
	commands.register("LibererTroupes", function(countryId: string, data: { [any]: any }): (boolean, string?)
		return Armies.releaseTroops(countryId, data.general, data.type, data.nombre)
	end)
	commands.register("SupprimerTroupes", function(countryId: string, data: { [any]: any }): (boolean, string?)
		return Armies.disbandTroops(countryId, data.general, data.type, data.nombre)
	end)
	commands.register("DeplacerGeneral", function(countryId: string, data: { [any]: any }): (boolean, string?)
		return Armies.move(countryId, data.general, data.region, data.continu)
	end, "DeplacerArmee")
	commands.register("AttaqueContinueGeneral", function(countryId: string, data: { [any]: any }): (boolean, string?)
		local general, err = ownedGeneral(countryId, data.general)
		if not general then
			return false, err
		end
		general:SetAttribute("AttaqueContinue", if data.actif == true then true else nil)
		return true, nil
	end)
	commands.register("AmeliorerGeneral", function(countryId: string, data: { [any]: any }): (boolean, string?)
		return Armies.upgrade(countryId, data.general)
	end)
	commands.register("ChoisirBonusGeneral", function(countryId: string, data: { [any]: any }): (boolean, string?)
		return Armies.chooseBonus(countryId, data.general, data.bonus)
	end)
	commands.register("RenommerGeneral", function(countryId: string, data: { [any]: any }, player: Player): (boolean, string?)
		local filtered = commands.filterText(data.nom, player)
		if not filtered then
			return false, "Ce nom n'est pas accepté."
		end
		return Armies.rename(countryId, data.general, filtered)
	end)
	commands.register("RenvoyerGeneral", function(countryId: string, data: { [any]: any }): (boolean, string?)
		return Armies.dismiss(countryId, data.general)
	end)
end

return Armies
