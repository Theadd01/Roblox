--!strict
-- Conseil mondial (Config/Council) : toutes les 15 minutes, tous les pays votent une résolution
-- tirée de la situation du monde (sanctions contre le leader ou un agresseur, cessez-le-feu,
-- taxe sur le pétrole, reconnaissance d'une conquête, aide humanitaire). Un pays = une voix.
-- Les pays IA votent selon leur intérêt (CouncilAI) ; les joueurs votent et peuvent convaincre
-- des pays IA en payant (lobbying). La résolution adoptée a un effet réel.
-- État publié dans ReplicatedStorage.EtatMonde.Conseil :
--   Etat (« Attente » | « Vote » | « Resultat »), Prochaine (heure du prochain vote), Fin (fin du vote),
--   Type, Titre, Texte, Cible, Region, Pour, Contre, Abstention, Resultat (« Adoptee » | « Rejetee »),
--   Sanction + SanctionFin, CessezLeFeuFin (effets en cours) ; Votes : un attribut par pays
-- Remotes : VoterConseil(vote), ConvaincreConseil(pays).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Council = require(Config:WaitForChild("Council")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local CountryAssignment = require(Server:WaitForChild("Session"):WaitForChild("CountryAssignment"))
local RateLimiter = require(Server:WaitForChild("Util"):WaitForChild("RateLimiter"))
local Economy = Server:WaitForChild("Economy")
local Stocks = require(Economy:WaitForChild("Stocks"))
local MarketService = require(Economy:WaitForChild("MarketService"))
local DiplomacyService = require(script.Parent:WaitForChild("DiplomacyService"))
local Stability = require(script.Parent:WaitForChild("Stability"))
local BalanceService = require(script.Parent:WaitForChild("BalanceService"))
local CouncilAI = require(Server:WaitForChild("AI"):WaitForChild("CouncilAI"))

local CURRENCY: string = Resources.currency.id
local VOTES = { Pour = true, Contre = true, Abstention = true }

type Resolution = { kind: string, target: string?, region: string? }

local CouncilService = {}

local folder: Folder? = nil
local votes: Folder? = nil
local current: Resolution? = nil
local lastAggressor: string? = nil
local lobbied: { [string]: boolean } = {} -- « lobbyiste|pays » déjà tenté pendant ce vote
local resultListeners: { (title: string, adopted: boolean, yes: number, no: number) -> () } = {}
local openListeners: { (title: string) -> () } = {}
local rng = Random.new()
local generation = 0 -- change à chaque nouvelle partie : une séance en cours s'arrête sans effet

local function now(): number
	return workspace:GetServerTimeNow()
end

local function nameOf(countryId: string): string
	return if Countries[countryId] then Countries[countryId].name else countryId
end

local function ownedRegions(countryId: string): number
	local count = 0
	for regionId in Regions do
		if RegionService.getOwner(regionId) == countryId then
			count += 1
		end
	end
	return count
end

-- Résolutions qui ont du sens en ce moment, avec leur poids pour le tirage
local function candidates(): { { resolution: Resolution, weight: number } }
	local list = {}
	local leader = BalanceService.leader()
	local sanctionTarget = leader or lastAggressor
	if sanctionTarget and ownedRegions(sanctionTarget) > 0 then
		table.insert(list, { resolution = { kind = "Sanctions", target = sanctionTarget }, weight = 3 })
	end
	local wars = 0
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local diplomatie = state and state:FindFirstChild("Diplomatie")
	local guerres = diplomatie and diplomatie:FindFirstChild("Guerres")
	wars = if guerres then #guerres:GetChildren() else 0
	if wars >= 2 then
		table.insert(list, { resolution = { kind = "CessezLeFeu" }, weight = 2 })
	end
	table.insert(list, { resolution = { kind = "TaxePetrole" }, weight = 1 })
	local conquered = {}
	local weakest, weakestLost = nil :: string?, 0
	local lostBy: { [string]: number } = {}
	for regionId, region in Regions do
		local owner = RegionService.getOwner(regionId)
		if owner and owner ~= region.startOwner then
			table.insert(conquered, regionId)
			lostBy[region.startOwner] = (lostBy[region.startOwner] or 0) + 1
		end
	end
	if #conquered > 0 then
		local regionId = conquered[rng:NextInteger(1, #conquered)]
		table.insert(list, { resolution = { kind = "Reconnaissance", target = RegionService.getOwner(regionId), region = regionId }, weight = 2 })
	end
	for countryId, lost in lostBy do
		if lost > weakestLost and ownedRegions(countryId) > 0 then
			weakest, weakestLost = countryId, lost
		end
	end
	if weakest then
		table.insert(list, { resolution = { kind = "AideHumanitaire", target = weakest }, weight = 2 })
	end
	return list
end

local function describe(resolution: Resolution): (string, string)
	local template = Council.resolutions[resolution.kind]
	local target = if resolution.target then FrenchNames.the(nameOf(resolution.target)) else ""
	local region = if resolution.region then FrenchNames.the(Regions[resolution.region].name) else ""
	local function fill(text: string): string
		local result = text:gsub("{target}", target):gsub("{region}", region)
		-- majuscule en début de phrase
		return (result:gsub("^%l", string.upper))
	end
	return fill(template.title), fill(template.text)
end

local function count()
	local v = votes
	local f = folder
	if not v or not f then
		return
	end
	local tally = { Pour = 0, Contre = 0, Abstention = 0 }
	for _, value in v:GetAttributes() do
		if tally[value] then
			tally[value] += 1
		end
	end
	f:SetAttribute("Pour", tally.Pour)
	f:SetAttribute("Contre", tally.Contre)
	f:SetAttribute("Abstention", tally.Abstention)
end

local function setVote(countryId: string, vote: string)
	if votes then
		votes:SetAttribute(countryId, vote)
		count()
	end
end

-- Applique l'effet d'une résolution adoptée (ou rejetée, pour la reconnaissance)
local function apply(resolution: Resolution, adopted: boolean)
	local f = folder
	if not f then
		return
	end
	if resolution.kind == "Sanctions" and adopted and resolution.target then
		f:SetAttribute("Sanction", resolution.target)
		f:SetAttribute("SanctionFin", now() + Council.sanctionDuration)
	elseif resolution.kind == "CessezLeFeu" and adopted then
		f:SetAttribute("CessezLeFeuFin", now() + Council.ceasefireDuration)
	elseif resolution.kind == "TaxePetrole" and adopted then
		MarketService.shock("Petrole", 1 + Council.oilTax)
	elseif resolution.kind == "Reconnaissance" and resolution.target then
		local delta = if adopted then Council.recognitionStability else -Council.recognitionStability
		Stability.change(resolution.target, delta, if adopted then "conquête reconnue" else "conquête condamnée")
	elseif resolution.kind == "AideHumanitaire" and adopted and resolution.target then
		Stocks.add(resolution.target, CURRENCY, Council.humanitarianAid)
	end
end

local function session()
	local f, v = folder, votes
	if not f or not v then
		return
	end
	local myGeneration = generation
	local list = candidates()
	local total = 0
	for _, c in list do
		total += c.weight
	end
	local roll = rng:NextNumber(0, total)
	local chosen = list[#list].resolution
	for _, c in list do
		roll -= c.weight
		if roll <= 0 then
			chosen = c.resolution
			break
		end
	end
	current = chosen
	table.clear(lobbied)
	for name in v:GetAttributes() do
		v:SetAttribute(name, nil)
	end
	local title, text = describe(chosen)
	f:SetAttribute("Type", chosen.kind)
	f:SetAttribute("Titre", title)
	f:SetAttribute("Texte", text)
	f:SetAttribute("Cible", chosen.target or "")
	f:SetAttribute("Region", chosen.region or "")
	f:SetAttribute("Resultat", "")
	f:SetAttribute("Fin", now() + Council.voteDuration)
	f:SetAttribute("Etat", "Vote")
	count()
	for _, listener in openListeners do
		task.spawn(listener, title)
	end

	-- les pays IA votent dans les premières secondes
	local leader = BalanceService.leader()
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	for _, country in (if pays then pays:GetChildren() else {}) do
		local id = country.Name
		if CountryAssignment.isAIControlled(id) then -- même en exil, un pays garde sa voix
			task.delay(rng:NextNumber(1, Council.voteDuration * 0.4), function()
				if current == chosen and v:GetAttribute(id) == nil then
					setVote(id, CouncilAI.vote(id, chosen, leader))
				end
			end)
		end
	end

	task.wait(Council.voteDuration)
	if generation ~= myGeneration then
		return -- nouvelle partie pendant le vote
	end
	local yes = (f:GetAttribute("Pour") :: number?) or 0
	local no = (f:GetAttribute("Contre") :: number?) or 0
	local adopted = yes > no
	f:SetAttribute("Resultat", if adopted then "Adoptee" else "Rejetee")
	f:SetAttribute("Etat", "Resultat")
	apply(chosen, adopted)
	for _, listener in resultListeners do
		task.spawn(listener, title, adopted, yes, no)
	end
	current = nil
	task.wait(Council.resultDuration)
	if generation == myGeneration then
		f:SetAttribute("Etat", "Attente")
	end
end

-- listener(titre) : un vote commence
function CouncilService.onOpen(listener: (title: string) -> ())
	table.insert(openListeners, listener)
end

-- listener(titre, adoptée, pour, contre) : résultat d'un vote
function CouncilService.onResult(listener: (title: string, adopted: boolean, yes: number, no: number) -> ())
	table.insert(resultListeners, listener)
end

-- Un joueur vote (il peut changer d'avis tant que le vote est ouvert)
function CouncilService.vote(countryId: string, vote: unknown): (boolean, string?)
	if not current then
		return false, "Aucun vote en cours au Conseil mondial."
	end
	if typeof(vote) ~= "string" or not VOTES[vote] then
		return false, "Vote invalide."
	end
	setVote(countryId, vote)
	return true, nil
end

-- Un joueur paie pour convaincre un pays IA de voter comme lui
function CouncilService.lobby(countryId: string, target: unknown): (boolean, string?)
	local resolution = current
	local v = votes
	if not resolution or not v then
		return false, "Aucun vote en cours au Conseil mondial."
	end
	if typeof(target) ~= "string" or not Countries[target] or target == countryId then
		return false, "Pays inconnu."
	end
	if not CountryAssignment.isAIControlled(target) then
		return false, "Ce pays est dirigé par un joueur : négocie avec lui directement."
	end
	local mine = v:GetAttribute(countryId)
	if mine ~= "Pour" and mine ~= "Contre" then
		return false, "Vote d'abord « pour » ou « contre »."
	end
	if v:GetAttribute(target) == mine then
		return false, `{nameOf(target)} vote déjà comme toi.`
	end
	local key = `{countryId}|{target}`
	if lobbied[key] then
		return false, `{nameOf(target)} t'a déjà répondu.`
	end
	lobbied[key] = true
	if Stocks.get(countryId, CURRENCY) < Council.lobbyCost then
		return false, "Pas assez de crédits."
	end
	if not CouncilAI.acceptsLobby(target, countryId, mine :: string, resolution) then
		return false, `{nameOf(target)} refuse de changer son vote.`
	end
	Stocks.add(countryId, CURRENCY, -Council.lobbyCost)
	setVote(target, mine :: string)
	return true, nil
end

-- Nouvelle partie : séance annulée, sanctions et cessez-le-feu levés, première séance dans
-- Council.firstSession secondes
function CouncilService.reset()
	generation += 1
	current = nil
	lastAggressor = nil
	table.clear(lobbied)
	local f, v = folder, votes
	if v then
		for name in v:GetAttributes() do
			v:SetAttribute(name, nil)
		end
	end
	if f then
		for _, name in { "Type", "Titre", "Texte", "Cible", "Region", "Resultat", "Fin", "Pour", "Contre", "Abstention", "Sanction", "SanctionFin", "CessezLeFeuFin" } do
			f:SetAttribute(name, nil)
		end
		f:SetAttribute("Etat", "Attente")
		f:SetAttribute("Prochaine", now() + Council.firstSession)
	end
end

-- À appeler au démarrage (après DiplomacyService.init et MarketService.init)
function CouncilService.start()
	local conseil = Instance.new("Folder")
	conseil.Name = "Conseil"
	conseil:SetAttribute("Etat", "Attente")
	conseil:SetAttribute("Prochaine", now() + Council.firstSession)
	local v = Instance.new("Folder")
	v.Name = "Votes"
	v.Parent = conseil
	conseil.Parent = ReplicatedStorage:WaitForChild("EtatMonde")
	folder, votes = conseil, v

	DiplomacyService.onWar(function(attacker: string)
		lastAggressor = attacker
	end)

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local limiter = RateLimiter.new(0.5)
	local function remote(name: string, action: (string, unknown) -> (boolean, string?))
		local r = Instance.new("RemoteFunction")
		r.Name = name
		r.OnServerInvoke = function(player: Player, a: unknown)
			if not limiter:allow(player) then
				return false, "Doucement, réessaie dans un instant."
			end
			local countryId = CountryAssignment.getCountryOf(player)
			if not countryId then
				return false, "Choisis d'abord un pays."
			end
			return action(countryId, a)
		end
		r.Parent = remotes
	end
	remote("VoterConseil", CouncilService.vote)
	remote("ConvaincreConseil", CouncilService.lobby)

	-- une séance dès que l'heure publiée (« Prochaine ») est passée, pendant la partie
	task.spawn(function()
		while true do
			task.wait(1)
			local nextSession = conseil:GetAttribute("Prochaine")
			if MatchState.isRunning() and conseil:GetAttribute("Etat") == "Attente" and typeof(nextSession) == "number" and now() >= nextSession then
				local myGeneration = generation
				local ok, err = pcall(session)
				if not ok then
					warn(`[Conseil] {err}`)
				end
				if generation == myGeneration then
					conseil:SetAttribute("Prochaine", now() + Council.interval - Council.voteDuration - Council.resultDuration)
				end
			end
		end
	end)
end

return CouncilService
