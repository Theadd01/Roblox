--!strict
-- Recherche technologique (Config/Technologies) : un pays paie une technologie disponible (ses
-- prérequis acquis), la recherche dure `time` secondes, puis la technologie s'ajoute aux siennes.
-- Une seule recherche à la fois. Publié dans les attributs de EtatMonde.Pays.<pays> (voir
-- shared/TechState). Remote : Rechercher(technologie).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Technologies = require(Shared:WaitForChild("Config"):WaitForChild("Technologies")) :: any
local Resources = require(Shared:WaitForChild("Config"):WaitForChild("Resources")) :: any
local TechState = require(Shared:WaitForChild("TechState")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local Server = script.Parent.Parent
local CountryAssignment = require(Server:WaitForChild("Session"):WaitForChild("CountryAssignment"))
local PlayStyle = require(Server:WaitForChild("Session"):WaitForChild("PlayStyle"))
local RateLimiter = require(Server:WaitForChild("Util"):WaitForChild("RateLimiter"))
local Stocks = require(script.Parent:WaitForChild("Stocks"))

local ResearchService = {}

local generation = 0 -- change à chaque nouvelle partie : les recherches en cours sont oubliées

local function countryFolder(countryId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
end

-- « 400 💰 + 3 💻 »
function ResearchService.costText(costs: { [string]: number }): string
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

-- Ajoute une technologie à un pays (fin de recherche, ou vol par espionnage)
function ResearchService.grant(countryId: string, techId: string): boolean
	local folder = countryFolder(countryId)
	if not folder or not Technologies.get(techId) or TechState.has(countryId, techId) then
		return false
	end
	local list = TechState.list(countryId)
	table.insert(list, techId)
	folder:SetAttribute("Technologies", table.concat(list, ","))
	return true
end

-- Lance une recherche
function ResearchService.research(countryId: string, techId: unknown): (boolean, string?)
	if not MatchState.isRunning() then
		return false, "La partie est terminée."
	end
	if typeof(techId) ~= "string" or not Technologies.get(techId) then
		return false, "Technologie inconnue."
	end
	local folder = countryFolder(countryId)
	if not folder then
		return false, "Pays inconnu."
	end
	if TechState.has(countryId, techId) then
		return false, "Tu as déjà cette technologie."
	end
	if not TechState.available(countryId, techId) then
		return false, "Il faut d'abord les technologies qui la précèdent."
	end
	if TechState.research(countryId) then
		return false, "Une recherche est déjà en cours."
	end
	local tech = Technologies.get(techId)
	if not Stocks.spend(countryId, tech.cost) then
		return false, `Il te faut {ResearchService.costText(tech.cost)}.`
	end
	local finish = workspace:GetServerTimeNow() + tech.time
	folder:SetAttribute("Recherche", techId)
	folder:SetAttribute("RechercheFin", finish)
	local myGeneration = generation
	task.delay(tech.time, function()
		if generation ~= myGeneration or folder:GetAttribute("RechercheFin") ~= finish then
			return -- nouvelle partie entre-temps
		end
		folder:SetAttribute("Recherche", "")
		folder:SetAttribute("RechercheFin", nil)
		ResearchService.grant(countryId, techId)
	end)
	return true, nil
end

-- Nouvelle partie : aucune technologie, aucune recherche
function ResearchService.reset()
	generation += 1
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	for _, folder in (if pays then pays:GetChildren() else {}) do
		folder:SetAttribute("Technologies", "")
		folder:SetAttribute("Recherche", "")
		folder:SetAttribute("RechercheFin", nil)
	end
end

-- À appeler au démarrage (après Stocks.init)
function ResearchService.init()
	ResearchService.reset()
	local remote = Instance.new("RemoteFunction")
	remote.Name = "Rechercher"
	local limiter = RateLimiter.new(0.5)
	remote.OnServerInvoke = function(player: Player, techId: unknown)
		if not limiter:allow(player) then
			return false, "Doucement, réessaie dans un instant."
		end
		local countryId = CountryAssignment.getCountryOf(player)
		if not countryId then
			return false, "Choisis d'abord un pays."
		end
		local ok, message = ResearchService.research(countryId, techId)
		if ok then
			PlayStyle.recordAction(countryId, "Rechercher", techId)
		end
		return ok, message
	end
	remote.Parent = ReplicatedStorage:WaitForChild("Remotes")
end

return ResearchService
