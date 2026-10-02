--!strict
-- Lecture des technologies des pays (publiées par server/Economy/ResearchService), pour le serveur
-- comme pour le client (cahier des charges v2, section 4). Attributs de EtatMonde.Pays.<pays> :
--   Technologies  niveaux atteints : « Radars=2,Logistique=1,EquipementInfanterie=3 » (les lignes
--                 d'équipement sont au niveau 1 sans être écrites)
--   Recherches    file en cours, en parallèle : « id:niveau:début:fin;... » (heures serveur)
-- Et les effets cumulés (Config/Technologies) : un niveau donne ses effets à tout le pays, tout de
-- suite, unités existantes comprises.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = script.Parent:WaitForChild("Config")
local Technologies = require(Config:WaitForChild("Technologies")) :: any
local Military = require(Config:WaitForChild("Military")) :: any

export type Research = { id: string, level: number, start: number, finish: number }

local TechState = {}

local function countryFolder(countryId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
end

-- Niveaux publiés (lus une fois par changement d'attribut : le combat les lit à chaque tick)
local cache: { [string]: { raw: string, levels: { [string]: number } } } = {}

function TechState.parse(raw: string): { [string]: number }
	local levels: { [string]: number } = {}
	for _, part in string.split(raw, ",") do
		local id, level = string.match(part, "^([%w_]+)=(%d+)$")
		if id and level then
			levels[id] = tonumber(level) :: number
		elseif part ~= "" and Technologies.get(part) then
			levels[part] = 1 -- ancien format : une technologie sans niveau
		end
	end
	return levels
end

function TechState.format(levels: { [string]: number }): string
	local parts = {}
	for id, level in levels do
		table.insert(parts, `{id}={level}`)
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

-- Niveaux atteints par un pays (au-dessus du niveau de départ), technologie -> niveau
function TechState.levels(countryId: string): { [string]: number }
	local folder = countryFolder(countryId)
	local raw = folder and folder:GetAttribute("Technologies")
	if typeof(raw) ~= "string" or raw == "" then
		return {}
	end
	local cached = cache[countryId]
	if cached and cached.raw == raw then
		return cached.levels
	end
	local levels = TechState.parse(raw)
	cache[countryId] = { raw = raw, levels = levels }
	return levels
end

-- Niveau d'une technologie (lignes d'équipement : 1 au moins ; 0 : pas encore cherchée)
function TechState.level(countryId: string, techId: string): number
	local tech = Technologies.get(techId)
	if not tech then
		return 0
	end
	return math.max(Technologies.startLevel(tech), TechState.levels(countryId)[techId] or 0)
end

function TechState.has(countryId: string, techId: string): boolean
	return TechState.level(countryId, techId) >= 1
end

-- Technologies cherchées par un pays (au-dessus du niveau de départ)
function TechState.list(countryId: string): { string }
	local list = {}
	for id, level in TechState.levels(countryId) do
		local tech = Technologies.get(id)
		if tech and level > Technologies.startLevel(tech) then
			table.insert(list, id)
		end
	end
	table.sort(list)
	return list
end

-- File de recherche (dans l'ordre de lancement)
function TechState.parseQueue(raw: unknown): { Research }
	local list: { Research } = {}
	if typeof(raw) ~= "string" or raw == "" then
		return list
	end
	for _, part in string.split(raw, ";") do
		local id, level, start, finish = string.match(part, "^([%w_]+):(%d+):([%d%.%-]+):([%d%.%-]+)$")
		if id and level and start and finish then
			table.insert(list, { id = id, level = tonumber(level) :: number, start = tonumber(start) :: number, finish = tonumber(finish) :: number })
		end
	end
	return list
end

function TechState.formatQueue(list: { Research }): string
	local parts = {}
	for _, r in list do
		table.insert(parts, string.format("%s:%d:%.2f:%.2f", r.id, r.level, r.start, r.finish))
	end
	return table.concat(parts, ";")
end

function TechState.queue(countryId: string): { Research }
	local folder = countryFolder(countryId)
	return TechState.parseQueue(folder and folder:GetAttribute("Recherches"))
end

-- Première recherche en cours : technologie et heure de fin (nil, nil : aucune)
function TechState.research(countryId: string): (string?, number?)
	local first = TechState.queue(countryId)[1]
	if first then
		return first.id, first.finish
	end
	return nil, nil
end

-- Niveau en cours de recherche pour une technologie (nil : aucun)
function TechState.queuedLevel(countryId: string, techId: string): number?
	for _, r in TechState.queue(countryId) do
		if r.id == techId then
			return r.level
		end
	end
	return nil
end

-- Somme des effets d'une sorte pour des niveaux donnés (fonction pure, testée dans
-- Tests/Research.spec) ; filter(effet) choisit les effets concernés
function TechState.sumLevels(levels: { [string]: number }, kind: string, filter: ((effect: any) -> boolean)?): number
	local total = 0
	for _, tech in Technologies.list do
		local level = math.max(Technologies.startLevel(tech), levels[tech.id] or 0)
		local entry = if level >= 1 then tech.levels[math.min(level, #tech.levels)] else nil
		for _, effect in (if entry then entry.effects else {}) do
			if effect.kind == kind and (not filter or filter(effect)) then
				total += effect.value
			end
		end
	end
	return total
end

-- Somme des effets d'une sorte pour un pays
local function sum(countryId: string, kind: string, filter: ((effect: any) -> boolean)?): number
	return TechState.sumLevels(TechState.levels(countryId), kind, filter)
end

local function forType(typeId: string): (effect: any) -> boolean
	return function(effect: any): boolean
		return effect.types ~= nil and table.find(effect.types, typeId) ~= nil
	end
end
TechState.forType = forType

-- Emplacements de recherche (recherches en parallèle)
function TechState.slots(countryId: string): number
	return Technologies.slots + math.floor(sum(countryId, "researchSlots"))
end

-- Multiplicateur de vitesse de recherche (Centres de recherche)
function TechState.researchSpeed(countryId: string): number
	return 1 + sum(countryId, "researchSpeed")
end

-- Les prérequis du prochain niveau sont-ils atteints ?
function TechState.requirementsMet(countryId: string, techId: string): boolean
	local tech = Technologies.get(techId)
	if not tech then
		return false
	end
	for _, requirement in tech.requires do
		if TechState.level(countryId, requirement.id) < requirement.level then
			return false
		end
	end
	return true
end

-- Le pays peut-il chercher le niveau suivant de cette technologie ? (pas au maximum, pas déjà en
-- cours, prérequis atteints ; les emplacements libres sont vérifiés à part : canResearch)
function TechState.available(countryId: string, techId: string): boolean
	local tech = Technologies.get(techId)
	if not tech or TechState.queuedLevel(countryId, techId) then
		return false
	end
	return TechState.level(countryId, techId) < Technologies.maxLevel(tech) and TechState.requirementsMet(countryId, techId)
end

-- Peut-il lancer la recherche maintenant ? (raison sinon ; le coût est vérifié à part)
function TechState.canResearch(countryId: string, techId: string): (boolean, string?)
	local tech = Technologies.get(techId)
	if not tech then
		return false, "Technologie inconnue."
	end
	if TechState.queuedLevel(countryId, techId) then
		return false, "Déjà en cours de recherche."
	end
	if TechState.level(countryId, techId) >= Technologies.maxLevel(tech) then
		return false, "Niveau maximum atteint."
	end
	if not TechState.requirementsMet(countryId, techId) then
		local missing = {}
		for _, requirement in tech.requires do
			if TechState.level(countryId, requirement.id) < requirement.level then
				local other = Technologies.get(requirement.id)
				table.insert(missing, `{if other then other.name else requirement.id} niveau {requirement.level}`)
			end
		end
		return false, `Il faut d'abord : {table.concat(missing, ", ")}.`
	end
	if #TechState.queue(countryId) >= TechState.slots(countryId) then
		return false, `Tous tes emplacements de recherche sont occupés ({TechState.slots(countryId)}).`
	end
	return true, nil
end

-- Technologies qu'un espion peut voler : la cible a un niveau de plus, et le voleur pourrait le chercher
function TechState.stealable(thief: string, victim: string): { string }
	local list = {}
	for _, tech in Technologies.list do
		if TechState.level(victim, tech.id) > TechState.level(thief, tech.id) and TechState.available(thief, tech.id) then
			table.insert(list, tech.id)
		end
	end
	return list
end

-- ---- Effets ---------------------------------------------------------------------------------

-- PV, dégâts et moral (perte en moins) en plus pour un type de division
function TechState.divisionHealthBonus(countryId: string, typeId: string): number
	return sum(countryId, "divisionHealth", forType(typeId))
end

function TechState.divisionDamageBonus(countryId: string, typeId: string): number
	return sum(countryId, "divisionDamage", forType(typeId))
end

function TechState.divisionMoraleBonus(countryId: string, typeId: string): number
	return sum(countryId, "divisionMorale", forType(typeId))
end

-- Multiplicateur d'attaque d'un type d'unité aérienne ou navale
function TechState.unitAttackFactor(countryId: string, typeId: string): number
	return 1 + sum(countryId, "unitAttack", forType(typeId))
end

-- Multiplicateur des PV d'un type d'unité aérienne ou navale
function TechState.unitHealthFactor(countryId: string, typeId: string): number
	return 1 + sum(countryId, "unitHealth", forType(typeId))
end

-- Multiplicateur de l'entretien des forces
function TechState.upkeepFactor(countryId: string): number
	return math.max(0, 1 + sum(countryId, "upkeep"))
end

-- Multiplicateur de production d'une ressource
function TechState.productionFactor(countryId: string, resourceId: string): number
	return 1 + sum(countryId, "production", function(effect: any): boolean
		return effect.resource == nil or effect.resource == resourceId
	end)
end

-- Multiplicateur des impôts (revenus)
function TechState.incomeFactor(countryId: string): number
	return 1 + sum(countryId, "income")
end

-- Lots de plus fabriqués par chaque usine
function TechState.extraBatches(countryId: string): number
	return sum(countryId, "factoryBatches")
end

-- Rangées de régions vues en plus autour du territoire (radars)
function TechState.visionRings(countryId: string): number
	return sum(countryId, "vision")
end

-- Révélation d'une région : multiplicateurs du coût et de la durée
function TechState.revealFactors(countryId: string): (number, number)
	return math.max(0, 1 + sum(countryId, "revealCost")), 1 + sum(countryId, "revealDuration")
end

-- Multiplicateur de réussite des sabotages et vols contre ce pays (cyberdéfense)
function TechState.sabotageFactor(countryId: string): number
	return math.max(0, 1 + sum(countryId, "sabotageDefense"))
end

-- Divisions qu'une région de ce pays peut accueillir (limite de stationnement : 10, 12, 15)
function TechState.stationingCap(countryId: string): number
	return Military.maxDivisionsPerRegion + math.floor(sum(countryId, "stationing"))
end

-- Multiplicateur du temps d'entraînement des divisions (Mobilisation)
function TechState.recruitTimeFactor(countryId: string): number
	return math.max(0.2, 1 + sum(countryId, "recruitTime"))
end

return TechState
