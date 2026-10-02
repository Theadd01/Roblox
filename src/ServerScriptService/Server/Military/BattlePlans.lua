--!strict
-- Plans de bataille des généraux (SYSTEME_MILITAIRE.md, 4.2 et 4.3) :
--   « PlanFront » { general, region } : le front face au pays de cette région (ses régions à lui qui
--     touchent ce pays) ; le général y répartit ses divisions (GeneralAI) ;
--   « PlanObjectif » { general, region } : ajoute ou retire une région visée (ligne offensive ;
--     plusieurs régions = plusieurs flèches) ;
--   « PlanRepli » { general, region } : ajoute ou retire une de ses régions de la ligne de repli
--     (si le front casse, l'armée s'y retranche) ;
--   « PlanLancer » { general } : lance l'offensive (il faut être en guerre) ;
--   « PlanTenir » { general } : plus d'attaque, les divisions se retranchent sur place ;
--   « PlanAnnuler » { general } : plus aucun ordre.
-- Bonus de planification : tant que le plan n'est pas lancé, il monte jusqu'à
-- Config/Military.planning.max (en buildSeconds) ; il baisse à chaque tick de combat de l'armée
-- après le lancement. Seules les divisions sous contrôle du plan (Controle = "Plan") en profitent.
-- État publié sur le général (EtatMonde.Generaux.<id>) : FrontPays, Front, Objectifs, Repli
-- (listes de régions séparées par des virgules), Ordre ("" | "Front" | "Offensive" | "Tenir"),
-- Planification (0 à max).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Military = require(Config:WaitForChild("Military")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local CouncilState = require(Shared:WaitForChild("CouncilState")) :: any
local GeneralTraits = require(Shared:WaitForChild("GeneralTraits")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local DiplomacyService = require(Server:WaitForChild("Politics"):WaitForChild("DiplomacyService"))
local Armies = require(script.Parent:WaitForChild("Armies"))

local MAX_OBJECTIVES = 6
local MAX_FALLBACK = 12

local BattlePlans = {}

-- Liste de régions publiée en attribut (« A,B,C ») -> tableau
function BattlePlans.list(general: Instance, attribute: string): { string }
	local raw = general:GetAttribute(attribute)
	if typeof(raw) ~= "string" or raw == "" then
		return {}
	end
	return string.split(raw, ",")
end

local function setList(general: Instance, attribute: string, list: { string })
	general:SetAttribute(attribute, if #list > 0 then table.concat(list, ",") else nil)
end

local function friendly(countryId: string, owner: string?): boolean
	return owner ~= nil and (owner == countryId or DiplomacyService.areAllies(countryId, owner))
end

-- Front face à un pays : ses régions qui touchent (par la terre) une région de ce pays (pur : l'état
-- des propriétaires est passé en fonction). owned : ses régions, si on les connaît déjà (plus rapide)
function BattlePlans.frontRegions(countryId: string, enemy: string, ownerOf: (regionId: string) -> string?, owned: { string }?): { string }
	local list = {}
	local candidates: { string } = owned or {}
	if not owned then
		for regionId in Regions do
			table.insert(candidates, regionId)
		end
	end
	for _, regionId in candidates do
		local region = Regions[regionId]
		if not region or ownerOf(regionId) ~= countryId then
			continue
		end
		for _, link in region.neighbors do
			if not link.bySea and ownerOf(link.region) == enemy then
				table.insert(list, regionId)
				break
			end
		end
	end
	table.sort(list)
	return list
end

-- A-t-il un plan (front ou objectifs) ?
function BattlePlans.hasPlan(general: Instance): boolean
	local enemy = general:GetAttribute("FrontPays")
	return typeof(enemy) == "string" and enemy ~= ""
end

-- Bonus de planification d'une division (0 si elle n'est pas sous contrôle du plan)
function BattlePlans.bonus(d: Instance): number
	if d:GetAttribute("Controle") ~= "Plan" then
		return 0
	end
	local general = Armies.commanderOf(d)
	return if general then ((general:GetAttribute("Planification") :: number?) or 0) else 0
end

-- Maximum du bonus de planification d'un général (trait « Planificateur » : plus)
local function planningMax(general: Instance): number
	return Military.planning.max * (1 + GeneralTraits.bonus(general, "planning"))
end

-- Le plan a servi en combat (un tick) : le bonus diminue
function BattlePlans.spendPlanning(general: Instance)
	local value = (general:GetAttribute("Planification") :: number?) or 0
	if value > 0 then
		general:SetAttribute("Planification", math.max(0, value - Military.planning.lossPerTick))
	end
end

local function ownedGeneral(countryId: string, id: unknown): (Instance?, string?)
	local general = Armies.get(id)
	if not general or general:GetAttribute("Proprietaire") ~= countryId then
		return nil, "Ce général n'est pas à toi."
	end
	return general, nil
end

local function countryName(id: string): string
	local country = Countries[id]
	return if country then FrenchNames.the(country.name) else "ce pays"
end

-- Front face au pays de la région touchée
function BattlePlans.setFront(countryId: string, generalId: unknown, regionId: unknown): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	if typeof(regionId) ~= "string" or not Regions[regionId] then
		return false, "Région inconnue."
	end
	local enemy = RegionService.getOwner(regionId)
	if not enemy or friendly(countryId, enemy) then
		return false, "Touche une région d'un autre pays : le front sera face à lui."
	end
	local front = BattlePlans.frontRegions(countryId, enemy, RegionService.getOwner)
	if #front == 0 then
		return false, `Tu n'as pas de frontière avec {countryName(enemy)}.`
	end
	if general:GetAttribute("FrontPays") ~= enemy then
		setList(general, "Objectifs", {}) -- nouveau front : les anciens objectifs ne valent plus
		general:SetAttribute("Planification", 0)
	end
	general:SetAttribute("FrontPays", enemy)
	setList(general, "Front", front)
	if general:GetAttribute("Ordre") ~= "Offensive" then
		general:SetAttribute("Ordre", "Front")
	end
	return true, `Front face à {countryName(enemy)} : {#front} région{if #front > 1 then "s" else ""}.`
end

-- Ajoute (ou retire) une région de la ligne offensive
function BattlePlans.toggleObjective(countryId: string, generalId: unknown, regionId: unknown): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	if not BattlePlans.hasPlan(general) then
		return false, "Donne d'abord un front à ce général."
	end
	if typeof(regionId) ~= "string" or not Regions[regionId] then
		return false, "Région inconnue."
	end
	local list = BattlePlans.list(general, "Objectifs")
	local index = table.find(list, regionId)
	if index then
		table.remove(list, index)
		setList(general, "Objectifs", list)
		return true, nil
	end
	local owner = RegionService.getOwner(regionId)
	if owner ~= general:GetAttribute("FrontPays") then
		return false, `La ligne offensive va dans les régions {FrenchNames.of(Countries[general:GetAttribute("FrontPays") :: string].name)}.`
	end
	if #list >= MAX_OBJECTIVES then
		return false, `Pas plus de {MAX_OBJECTIVES} régions visées.`
	end
	table.insert(list, regionId)
	setList(general, "Objectifs", list)
	return true, nil
end

-- Ajoute (ou retire) une de ses régions de la ligne de repli
function BattlePlans.toggleFallback(countryId: string, generalId: unknown, regionId: unknown): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	if typeof(regionId) ~= "string" or not Regions[regionId] then
		return false, "Région inconnue."
	end
	local list = BattlePlans.list(general, "Repli")
	local index = table.find(list, regionId)
	if index then
		table.remove(list, index)
		setList(general, "Repli", list)
		return true, nil
	end
	if not friendly(countryId, RegionService.getOwner(regionId)) then
		return false, "La ligne de repli passe par tes régions (ou celles d'un allié)."
	end
	if #list >= MAX_FALLBACK then
		return false, `Pas plus de {MAX_FALLBACK} régions de repli.`
	end
	table.insert(list, regionId)
	setList(general, "Repli", list)
	return true, nil
end

function BattlePlans.launch(countryId: string, generalId: unknown): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	if #BattlePlans.list(general, "Objectifs") == 0 then
		return false, "Trace d'abord la ligne offensive (les régions visées)."
	end
	local enemy = general:GetAttribute("FrontPays") :: string
	if not DiplomacyService.atWar(countryId, enemy) then
		return false, `Pas en guerre avec {countryName(enemy)} : déclare la guerre dans l'onglet Diplomatie.`
	end
	if CouncilState.ceasefireLeft() > 0 then
		return false, `Cessez-le-feu du Conseil mondial : encore {math.ceil(CouncilState.ceasefireLeft())} s.`
	end
	general:SetAttribute("Ordre", "Offensive")
	return true, nil
end

function BattlePlans.hold(countryId: string, generalId: unknown): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	general:SetAttribute("Ordre", "Tenir")
	return true, nil
end

function BattlePlans.cancel(countryId: string, generalId: unknown): (boolean, string?)
	local general, err = ownedGeneral(countryId, generalId)
	if not general then
		return false, err
	end
	BattlePlans.clear(general)
	return true, nil
end

function BattlePlans.clear(general: Instance)
	for _, attribute in { "FrontPays", "Front", "Objectifs", "Repli" } do
		general:SetAttribute(attribute, nil)
	end
	general:SetAttribute("Ordre", "")
	general:SetAttribute("Planification", 0)
end

-- Chaque seconde : bonus de planification des plans pas encore lancés
local function update(dt: number, _now: number)
	for _, general in Armies.all() do
		if BattlePlans.hasPlan(general) and general:GetAttribute("Ordre") ~= "Offensive" then
			local value = (general:GetAttribute("Planification") :: number?) or 0
			local max = planningMax(general)
			if value < max then
				general:SetAttribute("Planification", math.min(max, value + max * dt / Military.planning.buildSeconds))
			end
		end
	end
end

function BattlePlans.init(loop: any, commands: any)
	loop.every("plans", 1, update)
	local function register(order: string, run: (string, unknown, unknown) -> (boolean, string?), styleName: string?)
		commands.register(order, function(countryId: string, data: { [any]: any }): (boolean, string?)
			return run(countryId, data.general, data.region)
		end, styleName)
	end
	register("PlanFront", BattlePlans.setFront)
	register("PlanObjectif", BattlePlans.toggleObjective)
	register("PlanRepli", BattlePlans.toggleFallback)
	register("PlanLancer", function(countryId: string, generalId: unknown): (boolean, string?)
		return BattlePlans.launch(countryId, generalId)
	end, "DeplacerArmee")
	register("PlanTenir", function(countryId: string, generalId: unknown): (boolean, string?)
		return BattlePlans.hold(countryId, generalId)
	end)
	register("PlanAnnuler", function(countryId: string, generalId: unknown): (boolean, string?)
		return BattlePlans.cancel(countryId, generalId)
	end)
end

return BattlePlans
