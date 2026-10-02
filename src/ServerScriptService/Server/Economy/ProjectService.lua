--!strict
-- Course aux projets décisifs (Config/Projects) : un pays paie une étape de son projet, le chantier
-- dure Projects.stageTime secondes, puis l'étape compte. Le premier à finir toutes les étapes
-- remporte le projet (bonus au classement final ; effet lu avec shared/ProjectState).
-- Un pays en guerre avec le constructeur peut saboter son chantier ; prendre sa capitale lui fait
-- perdre une étape. Remotes : InvestirProjet(projet), SaboterProjet(projet, pays visé).
-- Publié dans ReplicatedStorage.EtatMonde.Projets.<projet> (voir shared/ProjectState).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Projects = require(Config:WaitForChild("Projects")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local ProjectState = require(Shared:WaitForChild("ProjectState")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local CountryAssignment = require(Server:WaitForChild("Session"):WaitForChild("CountryAssignment"))
local PlayStyle = require(Server:WaitForChild("Session"):WaitForChild("PlayStyle"))
local RateLimiter = require(Server:WaitForChild("Util"):WaitForChild("RateLimiter"))
local Stocks = require(script.Parent:WaitForChild("Stocks"))

-- événement : « Lancement », « Etape », « Termine », « Sabotage » (other = saboteur), « Capitale » (other = conquérant)
type Listener = (event: string, projectId: string, countryId: string, other: string?) -> ()

local ProjectService = {}

local folder: Folder? = nil
local generation = 0 -- change à chaque nouvelle partie : les chantiers en cours sont oubliés
local lastSabotage: { [string]: number } = {} -- « saboteur|cible » -> heure du dernier sabotage
local listeners: { Listener } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function nameOf(countryId: string): string
	return if Countries[countryId] then Countries[countryId].name else countryId
end

local function projectFolder(projectId: string): Instance?
	return if folder then folder:FindFirstChild(projectId) else nil
end

local function notify(event: string, projectId: string, countryId: string, other: string?)
	for _, listener in listeners do
		task.spawn(listener, event, projectId, countryId, other)
	end
end

-- « 500 💰 + 5 💾 + 10 🔩 »
function ProjectService.costText(costs: { [string]: number }): string
	local parts = {}
	if costs[Resources.currency.id] then
		table.insert(parts, `{costs[Resources.currency.id]} {Resources.currency.icon}`)
	end
	for _, id in Resources.order do
		if costs[id] then
			table.insert(parts, `{costs[id]} {Resources.list[id].icon}`)
		end
	end
	return table.concat(parts, " + ")
end

-- Recul d'un pays sur un projet : son chantier en cours est perdu, sinon une étape
local function setBack(projectId: string, countryId: string)
	local f = projectFolder(projectId)
	if not f then
		return
	end
	if f:GetAttribute("F_" .. countryId) then
		f:SetAttribute("F_" .. countryId, nil)
	else
		local stages = ProjectState.stages(projectId, countryId)
		f:SetAttribute("E_" .. countryId, if stages > 1 then stages - 1 else nil)
	end
end

-- Paie et lance l'étape suivante d'un projet
function ProjectService.invest(countryId: string, projectId: unknown): (boolean, string?)
	if not ProjectState.isOpen() then
		return false, "La course aux projets commence avec la phase « Course finale »."
	end
	if typeof(projectId) ~= "string" or not Projects.list[projectId] then
		return false, "Projet inconnu."
	end
	local f = projectFolder(projectId)
	if not f then
		return false, "Projet indisponible."
	end
	if ProjectState.winner(projectId) then
		return false, "Ce projet est déjà terminé."
	end
	local current = ProjectState.projectOf(countryId)
	if current and current ~= projectId then
		return false, `Tu mènes déjà le projet {Projects.list[current].name}.`
	end
	if ProjectState.buildingUntil(projectId, countryId) then
		return false, "Une étape est déjà en chantier."
	end
	local project = Projects.list[projectId]
	if not Stocks.spend(countryId, project.stageCost) then
		return false, `Il te faut {ProjectService.costText(project.stageCost)} pour cette étape.`
	end
	local first = ProjectState.stages(projectId, countryId) == 0
	local finish = now() + Projects.stageTime
	f:SetAttribute("F_" .. countryId, finish)
	if first then
		notify("Lancement", projectId, countryId)
	end
	local myGeneration = generation
	task.delay(Projects.stageTime, function()
		-- sabotage, capitale perdue ou nouvelle partie entre-temps : l'étape ne compte pas
		if generation ~= myGeneration or f:GetAttribute("F_" .. countryId) ~= finish then
			return
		end
		f:SetAttribute("F_" .. countryId, nil)
		if ProjectState.winner(projectId) then
			return -- un autre pays a fini avant
		end
		local done = ProjectState.stages(projectId, countryId) + 1
		f:SetAttribute("E_" .. countryId, done)
		notify("Etape", projectId, countryId)
		if done >= Projects.stages then
			f:SetAttribute("Vainqueur", countryId)
			f:SetAttribute("Termine", now())
			-- les chantiers des autres pays sur ce projet s'arrêtent
			for name in f:GetAttributes() do
				if name:sub(1, 2) == "F_" then
					f:SetAttribute(name, nil)
				end
			end
			notify("Termine", projectId, countryId)
		end
	end)
	return true, nil
end

-- Sabote le projet d'un pays avec qui on est en guerre
function ProjectService.sabotage(countryId: string, projectId: unknown, targetId: unknown): (boolean, string?)
	if not ProjectState.isOpen() then
		return false, "La course aux projets commence avec la phase « Course finale »."
	end
	if typeof(projectId) ~= "string" or not Projects.list[projectId] then
		return false, "Projet inconnu."
	end
	if typeof(targetId) ~= "string" or not Countries[targetId] or targetId == countryId then
		return false, "Pays inconnu."
	end
	if ProjectState.winner(projectId) then
		return false, "Ce projet est déjà terminé."
	end
	if not DiplomacyState.atWar(countryId, targetId) then
		return false, `Il faut être en guerre contre {FrenchNames.the(nameOf(targetId))} pour saboter son chantier.`
	end
	if ProjectState.stages(projectId, targetId) == 0 and not ProjectState.buildingUntil(projectId, targetId) then
		return false, `{FrenchNames.The(nameOf(targetId))} n'avance pas sur ce projet.`
	end
	local key = `{countryId}|{targetId}`
	local last = lastSabotage[key]
	if last and now() - last < Projects.sabotage.cooldown then
		return false, `Tes agents se cachent encore : réessaie dans {math.ceil(Projects.sabotage.cooldown - (now() - last))} s.`
	end
	if not Stocks.spend(countryId, Projects.sabotage.cost) then
		return false, `Il te faut {ProjectService.costText(Projects.sabotage.cost)} pour saboter.`
	end
	lastSabotage[key] = now()
	setBack(projectId, targetId)
	notify("Sabotage", projectId, targetId, countryId)
	return true, nil
end

-- listener(événement, projet, pays, autre pays) : voir le type Listener
function ProjectService.onEvent(listener: Listener)
	table.insert(listeners, listener)
end

-- Nouvelle partie : plus aucun projet, chantiers oubliés
function ProjectService.reset()
	generation += 1
	table.clear(lastSabotage)
	if folder then
		for _, f in folder:GetChildren() do
			for name in f:GetAttributes() do
				f:SetAttribute(name, nil)
			end
			f:SetAttribute("Vainqueur", "")
		end
	end
end

-- À appeler au démarrage (après Stocks.init)
function ProjectService.init()
	local projets = Instance.new("Folder")
	projets.Name = "Projets"
	for _, id in Projects.order do
		local f = Instance.new("Folder")
		f.Name = id
		f:SetAttribute("Vainqueur", "")
		f.Parent = projets
	end
	projets.Parent = ReplicatedStorage:WaitForChild("EtatMonde")
	folder = projets

	-- capitale prise : le projet de son pays recule d'une étape
	RegionService.onOwnerChanged(function(regionId: string, newOwner: string, oldOwner: string?)
		if oldOwner and regionId == oldOwner then
			local projectId = ProjectState.projectOf(oldOwner)
			if projectId then
				setBack(projectId, oldOwner)
				notify("Capitale", projectId, oldOwner, newOwner)
			end
		end
	end)

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local limiter = RateLimiter.new(0.5)
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
	remote("InvestirProjet", ProjectService.invest)
	remote("SaboterProjet", ProjectService.sabotage)
end

return ProjectService
