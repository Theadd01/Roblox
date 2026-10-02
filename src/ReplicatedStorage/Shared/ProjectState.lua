--!strict
-- Lecture de la course aux projets décisifs (publiée par server/Politics/ProjectService), pour le
-- serveur comme pour le client. ReplicatedStorage.EtatMonde.Projets.<projet> :
--   Vainqueur  pays qui l'a terminé le premier (« » tant que personne)
--   E_<pays>   étapes terminées par ce pays
--   F_<pays>   heure serveur de fin du chantier en cours de ce pays (absent : pas de chantier)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = script.Parent
local Projects = require(Shared:WaitForChild("Config"):WaitForChild("Projects")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any

local ProjectState = {}

local function folder(projectId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local projets = state and state:FindFirstChild("Projets")
	return projets and projets:FindFirstChild(projectId)
end

-- La course est-elle ouverte ? (phase « Course finale », partie en cours)
function ProjectState.isOpen(): boolean
	return MatchState.isRunning() and MatchState.phaseIndex() >= Projects.unlockPhase
end

-- Pays qui a terminé ce projet le premier (nil si personne)
function ProjectState.winner(projectId: string): string?
	local f = folder(projectId)
	local value = f and f:GetAttribute("Vainqueur")
	return if typeof(value) == "string" and value ~= "" then value else nil
end

-- Étapes terminées par un pays
function ProjectState.stages(projectId: string, countryId: string): number
	local f = folder(projectId)
	local value = f and f:GetAttribute("E_" .. countryId)
	return if typeof(value) == "number" then value else 0
end

-- Fin du chantier en cours d'un pays (nil s'il n'en a pas)
function ProjectState.buildingUntil(projectId: string, countryId: string): number?
	local f = folder(projectId)
	local value = f and f:GetAttribute("F_" .. countryId)
	return if typeof(value) == "number" then value else nil
end

-- Projet que mène un pays (nil s'il n'en mène aucun) : le seul non remporté où il a avancé
function ProjectState.projectOf(countryId: string): string?
	for _, id in Projects.order do
		if not ProjectState.winner(id) and (ProjectState.stages(id, countryId) > 0 or ProjectState.buildingUntil(id, countryId)) then
			return id
		end
	end
	return nil
end

-- Pays en course pour un projet, du plus avancé au moins avancé : { { country, stages, until } }
function ProjectState.racers(projectId: string): { { country: string, stages: number, buildingUntil: number? } }
	local f = folder(projectId)
	local list = {}
	if f then
		for name, value in f:GetAttributes() do
			local country = name:match("^E_(.+)$")
			if country and typeof(value) == "number" and value > 0 then
				table.insert(list, { country = country, stages = value, buildingUntil = ProjectState.buildingUntil(projectId, country) })
			end
		end
		for name, value in f:GetAttributes() do
			local country = name:match("^F_(.+)$")
			if country and typeof(value) == "number" and ProjectState.stages(projectId, country) == 0 then
				table.insert(list, { country = country, stages = 0, buildingUntil = value })
			end
		end
	end
	table.sort(list, function(a, b)
		if a.stages ~= b.stages then
			return a.stages > b.stages
		end
		return a.country < b.country
	end)
	return list
end

-- Bonus d'un pays pour un type d'effet (« production », « attack », « defense ») : 1 sans projet
function ProjectState.factor(countryId: string, kind: string): number
	local factor = 1
	for _, id in Projects.order do
		local project = Projects.list[id]
		if project.effect.kind == kind and ProjectState.winner(id) == countryId then
			factor += project.effect.value
		end
	end
	return factor
end

return ProjectState
