--!strict
-- Lecture de l'état du Conseil mondial (ReplicatedStorage.EtatMonde.Conseil), côté serveur et
-- client : effets en cours des résolutions adoptées (sanctions, cessez-le-feu).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CouncilState = {}

local function council(): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	return state and state:FindFirstChild("Conseil")
end

local function timeLeft(attribute: string): number
	local c = council()
	local finish = c and c:GetAttribute(attribute)
	return if typeof(finish) == "number" then math.max(0, finish - workspace:GetServerTimeNow()) else 0
end

-- Le pays est-il sous sanctions du Conseil ? (frais sur le marché, aucun contrat)
function CouncilState.sanctioned(countryId: string): boolean
	local c = council()
	return c ~= nil and c:GetAttribute("Sanction") == countryId and timeLeft("SanctionFin") > 0
end

-- Pays sous sanctions et secondes restantes (nil s'il n'y en a pas)
function CouncilState.sanction(): (string?, number)
	local c = council()
	local target = c and c:GetAttribute("Sanction")
	local left = timeLeft("SanctionFin")
	return if typeof(target) == "string" and target ~= "" and left > 0 then target else nil, left
end

-- Secondes de cessez-le-feu mondial restantes (0 : pas de cessez-le-feu)
function CouncilState.ceasefireLeft(): number
	return timeLeft("CessezLeFeuFin")
end

return CouncilState
