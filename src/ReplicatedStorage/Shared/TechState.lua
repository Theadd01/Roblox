--!strict
-- Lecture des technologies des pays (publiées par server/Economy/ResearchService), pour le serveur
-- comme pour le client. Attributs de EtatMonde.Pays.<pays> :
--   Technologies  identifiants séparés par des virgules
--   Recherche     technologie en cours de recherche (« » : aucune) ; RechercheFin : heure de fin
-- Et les effets cumulés (Config/Technologies) : TechState.bonus(pays, sorte, ...).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Technologies = require(script.Parent:WaitForChild("Config"):WaitForChild("Technologies")) :: any
local Military = require(script.Parent:WaitForChild("Config"):WaitForChild("Military")) :: any

local TechState = {}

local function countryFolder(countryId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
end

-- Technologies acquises d'un pays
function TechState.list(countryId: string): { string }
	local folder = countryFolder(countryId)
	local value = folder and folder:GetAttribute("Technologies")
	if typeof(value) ~= "string" or value == "" then
		return {}
	end
	return value:split(",")
end

function TechState.has(countryId: string, techId: string): boolean
	return table.find(TechState.list(countryId), techId) ~= nil
end

-- Recherche en cours : technologie et heure de fin (nil, nil : aucune)
function TechState.research(countryId: string): (string?, number?)
	local folder = countryFolder(countryId)
	local id = folder and folder:GetAttribute("Recherche")
	local finish = folder and folder:GetAttribute("RechercheFin")
	if typeof(id) == "string" and id ~= "" and typeof(finish) == "number" then
		return id, finish
	end
	return nil, nil
end

-- Le pays peut-il chercher cette technologie ? (pas encore acquise, prérequis acquis)
function TechState.available(countryId: string, techId: string): boolean
	local tech = Technologies.get(techId)
	if not tech or TechState.has(countryId, techId) then
		return false
	end
	for _, required in tech.requires do
		if not TechState.has(countryId, required) then
			return false
		end
	end
	return true
end

-- Somme des effets d'une sorte pour un pays ; filter(effet) choisit les effets concernés
local function sum(countryId: string, kind: string, filter: ((effect: any) -> boolean)?): number
	local total = 0
	for _, techId in TechState.list(countryId) do
		local tech = Technologies.get(techId)
		for _, effect in (if tech then tech.effects else {}) do
			if effect.kind == kind and (not filter or filter(effect)) then
				total += effect.value
			end
		end
	end
	return total
end

-- Multiplicateur d'attaque d'un type d'unité
function TechState.unitAttackFactor(countryId: string, typeId: string): number
	return 1 + sum(countryId, "unitAttack", function(effect: any): boolean
		return effect.types ~= nil and table.find(effect.types, typeId) ~= nil
	end)
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

-- Divisions qu'une région de ce pays peut accueillir (limite de stationnement)
function TechState.stationingCap(_countryId: string): number
	return Military.maxDivisionsPerRegion
end

-- PV et dégâts en plus d'un type de division (niveau de recherche de sa branche)
function TechState.divisionHealthBonus(_countryId: string, _typeId: string): number
	return 0
end

function TechState.divisionDamageBonus(_countryId: string, _typeId: string): number
	return 0
end

-- Multiplicateur du temps d'entraînement des divisions
function TechState.recruitTimeFactor(_countryId: string): number
	return 1
end

return TechState
