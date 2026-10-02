--!strict
-- Généraux et armées (SYSTEME_MILITAIRE.md, 4.1) : un général commande une armée de 1 à 24
-- divisions depuis son quartier général (une de ses régions, un seul général par région).
--   ordres (RemoteEvent CommandeMilitaire) : « NommerGeneral » { region }, « AssignerDivisions »
--   { general, ids }, « RetirerDivisions » { ids }, « DeplacerGeneral » { general, region },
--   « RenvoyerGeneral » { general } ;
--   traits : 1 à la nomination, 2e et 3e aux niveaux Config/Generals.secondTraitLevel et
--   thirdTraitLevel ; l'expérience vient des batailles de son armée (BattleManager) ;
--   quartier général pris : le général recule vers la région amie la plus proche et perd ses
--   bonus un moment ; sans issue (encerclé), il est capturé.
-- État publié dans ReplicatedStorage.EtatMonde.Generaux.<id> : Nom, Proprietaire, Region,
-- Destination ("" à l'arrêt), Depart, Arrivee, Traits, Experience, Niveau, Desorganise (heure de
-- fin, absent sinon). Les divisions d'une armée ont l'attribut Armee = identifiant du général.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Military = require(Config:WaitForChild("Military")) :: any
local Generals = require(Config:WaitForChild("Generals")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Units = require(Config:WaitForChild("Units")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any
local GeneralTraits = require(Shared:WaitForChild("GeneralTraits")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local DiplomacyService = require(Server:WaitForChild("Politics"):WaitForChild("DiplomacyService"))
local Stocks = require(Server:WaitForChild("Economy"):WaitForChild("Stocks"))
local Divisions = require(script.Parent:WaitForChild("Divisions"))

local Armies = {}

local folder: Folder? = nil
local nextId = 0
local nameIndex = 0
local rng = Random.new()

local function now(): number
	return workspace:GetServerTimeNow()
end

local function anchorOf(regionId: string): Vector3?
	local region = Regions[regionId]
	local city = region and region.city
	return if city then MapProjection.toVector3(city.lon, city.lat, MapSettings.regionTop) else nil
end

function Armies.all(): { Instance }
	return if folder then folder:GetChildren() else {}
end

function Armies.get(id: unknown): Instance?
	return if typeof(id) == "string" and folder then folder:FindFirstChild(id) else nil
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

-- Général dont le quartier général est (ou sera, s'il y va) dans cette région
function Armies.inRegion(regionId: string): Instance?
	for _, g in Armies.all() do
		if g:GetAttribute("Region") == regionId or g:GetAttribute("Destination") == regionId then
			return g
		end
	end
	return nil
end

-- Divisions de l'armée d'un général
function Armies.divisionsOf(general: Instance): { Instance }
	local list = {}
	for _, d in Divisions.all() do
		if d:GetAttribute("Armee") == general.Name then
			table.insert(list, d)
		end
	end
	return list
end

-- Règle de nomination (pure, testée dans tests/Generals.spec) : propriétaire de la région, général
-- déjà présent, nombre de généraux du pays
function Armies.nameRule(countryId: string, owner: string?, generalHere: boolean, count: number): (boolean, string?)
	if owner ~= countryId then
		return false, "On nomme un général dans une de ses propres régions."
	end
	if generalHere then
		return false, "Il y a déjà un général dans cette région (un seul par région)."
	end
	if count >= Military.generals.maxPerCountry then
		return false, `Pas plus de {Military.generals.maxPerCountry} généraux.`
	end
	return true, nil
end

local function levelFor(xp: number): number
	local G = Military.generals
	return math.clamp(1 + math.floor(xp / G.xpPerLevel), 1, G.maxLevel)
end

-- Expérience d'un général ; nouveau niveau : un trait de plus aux paliers (Config/Generals)
function Armies.addExperience(general: Instance, amount: number)
	if not general.Parent then
		return
	end
	local xp = math.min(100, ((general:GetAttribute("Experience") :: number?) or 0) + amount * (1 + GeneralTraits.bonus(general, "experience")))
	general:SetAttribute("Experience", xp)
	local level = levelFor(xp)
	general:SetAttribute("Niveau", level)
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
end

-- Le général d'une division, s'il peut donner ses bonus (pas désorganisé)
function Armies.commanderOf(d: Instance): Instance?
	local general = Armies.get(d:GetAttribute("Armee"))
	if not general then
		return nil
	end
	local untilTime = general:GetAttribute("Desorganise")
	if typeof(untilTime) == "number" and untilTime > now() then
		return nil
	end
	return general
end

-- Bonus d'un effet de trait pour une division (0 sans général)
function Armies.bonus(d: Instance, effect: string): number
	local general = Armies.commanderOf(d)
	return if general then GeneralTraits.bonus(general, effect) else 0
end

local function nextName(): string
	local names = Units.names
	nameIndex += 1
	local base = names[(nameIndex - 1) % #names + 1]
	local round = math.floor((nameIndex - 1) / #names)
	return "Général " .. base .. (if round > 0 then " " .. (round + 1) else "")
end

-- Nomme un général dans une de ses régions
function Armies.name(countryId: string, regionId: unknown): (boolean, string?)
	if typeof(regionId) ~= "string" or not Regions[regionId] or not folder then
		return false, "Région inconnue."
	end
	local ok, why = Armies.nameRule(countryId, RegionService.getOwner(regionId), Armies.inRegion(regionId) ~= nil, #Armies.ofCountry(countryId))
	if not ok then
		return false, why
	end
	if not Stocks.spend(countryId, Military.generals.cost) then
		return false, "Pas assez de crédits pour nommer un général."
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
	g:SetAttribute("Traits", GeneralTraits.pick("Terre", {}, rng) or "")
	g.Parent = folder
	return true, nil
end

local function ownedGeneral(countryId: string, id: unknown): (Instance?, string?)
	local general = Armies.get(id)
	if not general or general:GetAttribute("Proprietaire") ~= countryId then
		return nil, "Ce général n'est pas à toi."
	end
	return general, nil
end

-- Place les divisions sous les ordres d'un général (24 au plus)
function Armies.assign(countryId: string, generalId: unknown, list: { Instance }): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	local count = #Armies.divisionsOf(general)
	local added, full = 0, 0
	for _, d in list do
		if d:GetAttribute("Armee") == general.Name then
			continue
		end
		if count >= Military.maxDivisionsPerArmy then
			full += 1
			continue
		end
		d:SetAttribute("Armee", general.Name)
		d:SetAttribute("Controle", "Plan")
		count += 1
		added += 1
	end
	if full > 0 then
		return added > 0, `{added} division{if added > 1 then "s" else ""} ajoutée{if added > 1 then "s" else ""} ; l'armée est pleine ({Military.maxDivisionsPerArmy} divisions au plus).`
	end
	return true, nil
end

-- Sort des divisions de leur armée (contrôle manuel)
function Armies.unassign(list: { Instance })
	for _, d in list do
		d:SetAttribute("Armee", "")
		d:SetAttribute("Controle", "Manuel")
	end
end

-- Durée du trajet du quartier général
local function moveSeconds(general: Instance, from: string, to: string): number
	local a, b = anchorOf(from), anchorOf(to)
	local G = Military.generals
	local distance = if a and b then (b - a).Magnitude else 0
	return math.clamp(distance / G.moveSpeed, G.moveMin, G.moveMax) * (1 - GeneralTraits.bonus(general, "speed")) -- trait Stratège
end

local function startMove(general: Instance, to: string)
	local from = general:GetAttribute("Region") :: string
	local start = now()
	general:SetAttribute("Destination", to)
	general:SetAttribute("Depart", start)
	general:SetAttribute("Arrivee", start + moveSeconds(general, from, to))
end

-- Déplace le quartier général vers une autre de ses régions (ou d'un allié), libre de général
function Armies.move(countryId: string, generalId: unknown, regionId: unknown): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	if typeof(regionId) ~= "string" or not Regions[regionId] then
		return false, "Région inconnue."
	end
	local owner = RegionService.getOwner(regionId)
	if owner ~= countryId and not (owner and DiplomacyService.areAllies(countryId, owner)) then
		return false, "Le quartier général va dans une de tes régions ou chez un allié."
	end
	local other = Armies.inRegion(regionId)
	if other and other ~= general then
		return false, "Il y a déjà un général dans cette région (un seul par région)."
	end
	if general:GetAttribute("Region") == regionId then
		general:SetAttribute("Destination", "")
		return true, nil
	end
	startMove(general, regionId)
	return true, nil
end

-- Renvoie un général : ses divisions passent en contrôle manuel
function Armies.dismiss(countryId: string, generalId: unknown): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	Armies.unassign(Armies.divisionsOf(general))
	general:Destroy()
	return true, nil
end

-- Région amie la plus proche (en nombre de régions) sans autre général ; nil : encerclé
local function fallbackFor(general: Instance, from: string): string?
	local countryId = general:GetAttribute("Proprietaire") :: string
	local function friendly(regionId: string): boolean
		local owner = RegionService.getOwner(regionId)
		return owner == countryId or (owner ~= nil and DiplomacyService.areAllies(countryId, owner))
	end
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
			if friendly(nextId) then
				local other = Armies.inRegion(nextId)
				if not other or other == general then
					return nextId
				end
				table.insert(queue, nextId)
			end
		end
	end
	return nil
end

-- Une région change de mains : les généraux ennemis qui s'y trouvent reculent, ou sont capturés
local function onOwnerChanged(regionId: string, newOwner: string)
	for _, general in Armies.all() do
		local owner = general:GetAttribute("Proprietaire") :: string
		local here = general:GetAttribute("Region") == regionId
		local going = general:GetAttribute("Destination") == regionId
		if not (here or going) or owner == newOwner or DiplomacyService.areAllies(owner, newOwner) then
			continue
		end
		if going and not here then
			general:SetAttribute("Destination", "") -- il reste où il est
			continue
		end
		local to = fallbackFor(general, regionId)
		if to then
			general:SetAttribute("Region", to)
			general:SetAttribute("Destination", "")
			general:SetAttribute("Desorganise", now() + Military.generals.disorganizedSeconds)
		else
			-- encerclé : capturé, son armée passe en contrôle manuel
			Armies.unassign(Armies.divisionsOf(general))
			general:Destroy()
		end
	end
end

-- Arrivées des quartiers généraux, fin des désorganisations
local function update(_dt: number, t: number)
	for _, general in Armies.all() do
		local destination = general:GetAttribute("Destination")
		if typeof(destination) == "string" and destination ~= "" and t >= ((general:GetAttribute("Arrivee") :: number?) or 0) then
			general:SetAttribute("Region", destination)
			general:SetAttribute("Destination", "")
		end
		local untilTime = general:GetAttribute("Desorganise")
		if typeof(untilTime) == "number" and t >= untilTime then
			general:SetAttribute("Desorganise", nil)
		end
	end
end

-- Nouvelle partie : plus aucun général
function Armies.reset()
	if folder then
		folder:ClearAllChildren()
	end
	nameIndex = 0
end

function Armies.init(loop: any, commands: any)
	local generaux = Instance.new("Folder")
	generaux.Name = "Generaux"
	generaux.Parent = ReplicatedStorage:WaitForChild("EtatMonde")
	folder = generaux
	loop.every("generaux", 0.5, update)
	RegionService.onOwnerChanged(onOwnerChanged)
	-- une division détruite quitte son armée d'elle-même (l'attribut part avec elle)

	commands.register("NommerGeneral", function(countryId: string, data: { [any]: any }): (boolean, string?)
		return Armies.name(countryId, data.region)
	end, "NommerGeneral")
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
		Armies.unassign(list)
		return true, nil
	end)
	commands.register("DeplacerGeneral", function(countryId: string, data: { [any]: any }): (boolean, string?)
		return Armies.move(countryId, data.general, data.region)
	end)
	commands.register("RenvoyerGeneral", function(countryId: string, data: { [any]: any }): (boolean, string?)
		return Armies.dismiss(countryId, data.general)
	end)
end

return Armies
