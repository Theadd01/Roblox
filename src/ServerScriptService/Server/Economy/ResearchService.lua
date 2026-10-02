--!strict
-- Recherche technologique à niveaux (cahier des charges v2, section 4 ; Config/Technologies) : un
-- pays paie le niveau suivant d'une technologie disponible (prérequis atteints), la recherche dure
-- `time` secondes (divisé par sa vitesse de recherche), puis le pays passe à ce niveau. Plusieurs
-- recherches en parallèle : Technologies.slots emplacements, plus avec « Centres de recherche ».
-- Les pays dirigés par l'IA cherchent plus lentement selon la difficulté
-- (Config/Match.difficulties.researchSpeed). Publié dans les attributs de EtatMonde.Pays.<pays>
-- (voir shared/TechState). Remotes : Rechercher(technologie), AnnulerRecherche(technologie).

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

local UPDATE_SECONDS = 0.5 -- fins de recherche vérifiées deux fois par seconde

type Research = { id: string, level: number, start: number, finish: number }

local ResearchService = {}

local queues: { [string]: { Research } } = {} -- pays -> recherches en cours
local listeners: { (countryId: string, techId: string, level: number) -> () } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

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

local function publishQueue(countryId: string)
	local folder = countryFolder(countryId)
	if folder then
		folder:SetAttribute("Recherches", TechState.formatQueue(queues[countryId] or {}))
	end
end

-- Fixe le niveau d'une technologie
local function setLevel(countryId: string, techId: string, level: number)
	local folder = countryFolder(countryId)
	if not folder then
		return
	end
	local levels = table.clone(TechState.levels(countryId))
	levels[techId] = level
	folder:SetAttribute("Technologies", TechState.format(levels))
	for _, listener in listeners do
		task.spawn(listener, countryId, techId, level)
	end
end

-- Vitesse de recherche d'un pays (Centres de recherche ; IA : selon la difficulté)
function ResearchService.speedOf(countryId: string): number
	local speed = TechState.researchSpeed(countryId)
	if CountryAssignment.isAIControlled(countryId) then
		local _, difficulty = MatchState.difficulty()
		speed *= difficulty.researchSpeed
	end
	return math.max(0.05, speed)
end

-- Ajoute un niveau à une technologie (vol par espionnage) ; vrai si le pays progresse
function ResearchService.grant(countryId: string, techId: string): boolean
	local tech = Technologies.get(techId)
	if not tech or not countryFolder(countryId) then
		return false
	end
	local level = TechState.level(countryId, techId) + 1
	if level > Technologies.maxLevel(tech) then
		return false
	end
	-- ce niveau était en cours de recherche : il n'est plus à chercher (sans remboursement)
	local queue = queues[countryId]
	if queue then
		for i, r in queue do
			if r.id == techId then
				table.remove(queue, i)
				publishQueue(countryId)
				break
			end
		end
	end
	setLevel(countryId, techId, level)
	return true
end

-- Lance la recherche du niveau suivant d'une technologie
function ResearchService.research(countryId: string, techId: unknown): (boolean, string?)
	if not MatchState.isRunning() then
		return false, "La partie est terminée."
	end
	if typeof(techId) ~= "string" or not Technologies.get(techId) then
		return false, "Technologie inconnue."
	end
	if not countryFolder(countryId) then
		return false, "Pays inconnu."
	end
	local ok, why = TechState.canResearch(countryId, techId)
	if not ok then
		return false, why
	end
	local tech = Technologies.get(techId)
	local level = TechState.level(countryId, techId) + 1
	local entry = tech.levels[level]
	if not Stocks.spend(countryId, entry.cost) then
		return false, `Il te faut {ResearchService.costText(entry.cost)}.`
	end
	local start = now()
	queues[countryId] = queues[countryId] or {}
	table.insert(queues[countryId], { id = techId, level = level, start = start, finish = start + entry.time / ResearchService.speedOf(countryId) })
	publishQueue(countryId)
	return true, nil
end

-- Annule une recherche en cours : la moitié du coût est rendue
function ResearchService.cancel(countryId: string, techId: unknown): (boolean, string?)
	local queue = queues[countryId]
	if typeof(techId) ~= "string" or not queue then
		return false, "Aucune recherche à annuler."
	end
	for i, r in queue do
		if r.id == techId then
			table.remove(queue, i)
			local tech = Technologies.get(techId)
			for resourceId, amount in tech.levels[r.level].cost do
				local refund = math.floor(amount * Technologies.cancelRefund)
				if refund > 0 then
					Stocks.add(countryId, resourceId, refund)
				end
			end
			publishQueue(countryId)
			return true, nil
		end
	end
	return false, "Aucune recherche à annuler."
end

-- listener(pays, technologie, niveau) : un pays vient d'atteindre un niveau
function ResearchService.onLevel(listener: (countryId: string, techId: string, level: number) -> ())
	table.insert(listeners, listener)
end

-- Fins de recherche
local function update()
	local t = now()
	for countryId, queue in queues do
		local finished = false
		for i = #queue, 1, -1 do
			local r = queue[i]
			if t >= r.finish then
				table.remove(queue, i)
				finished = true
				if TechState.level(countryId, r.id) < r.level then
					setLevel(countryId, r.id, r.level)
				end
			end
		end
		if finished then
			publishQueue(countryId)
		end
	end
end

-- Nouvelle partie : aucune technologie au-dessus du niveau de départ, aucune recherche
function ResearchService.reset()
	table.clear(queues)
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	for _, folder in (if pays then pays:GetChildren() else {}) do
		folder:SetAttribute("Technologies", "")
		folder:SetAttribute("Recherches", "")
	end
end

-- À appeler au démarrage (après Stocks.init)
function ResearchService.init()
	ResearchService.reset()
	local limiter = RateLimiter.new(0.3)
	local function remote(name: string, action: (string, unknown) -> (boolean, string?))
		local r = Instance.new("RemoteFunction")
		r.Name = name
		r.OnServerInvoke = function(player: Player, techId: unknown)
			if not limiter:allow(player) then
				return false, "Doucement, réessaie dans un instant."
			end
			local countryId = CountryAssignment.getCountryOf(player)
			if not countryId then
				return false, "Choisis d'abord un pays."
			end
			local ok, message = action(countryId, techId)
			if ok and name == "Rechercher" then
				PlayStyle.recordAction(countryId, "Rechercher", techId)
			end
			return ok, message
		end
		r.Parent = ReplicatedStorage:WaitForChild("Remotes")
	end
	remote("Rechercher", ResearchService.research)
	remote("AnnulerRecherche", ResearchService.cancel)
	task.spawn(function()
		while true do
			task.wait(UPDATE_SECONDS)
			local ok, err = pcall(update)
			if not ok then
				warn(`[Recherche] {err}`)
			end
		end
	end)
end

return ResearchService
