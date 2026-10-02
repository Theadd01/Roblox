--!strict
-- Espionnage (Config/Espionage) : révéler une région (on y voit tout pendant quelques minutes),
-- saboter une usine étrangère visible (arrêtée un moment) et voler une technologie à un pays dont
-- une région est visible (Config/Technologies.steal). Les espions peuvent être démasqués : le pays
-- visé l'apprend et le pays espion perd de la réputation. Technologies : satellites espions
-- (révéler moins cher, plus longtemps), cyberdéfense (sabotages et vols contre soi moins efficaces).
-- Publié dans ReplicatedStorage.EtatMonde.Renseignements.<pays> : R_<région> = heure de fin.
-- Usine sabotée : attribut « SaboteeJusqua » (heure serveur), lu par FactoryService.
-- Remotes : RevelerRegion(région), SaboterUsine(usine), VolerTechnologie(pays).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Espionage = require(Config:WaitForChild("Espionage")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Technologies = require(Config:WaitForChild("Technologies")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local TechState = require(Shared:WaitForChild("TechState")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local FogRules = require(Shared:WaitForChild("FogRules")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local CountryAssignment = require(Server:WaitForChild("Session"):WaitForChild("CountryAssignment"))
local RateLimiter = require(Server:WaitForChild("Util"):WaitForChild("RateLimiter"))
local Stocks = require(Server:WaitForChild("Economy"):WaitForChild("Stocks"))
local ResearchService = require(Server:WaitForChild("Economy"):WaitForChild("ResearchService"))
local DilemmaService = require(script.Parent:WaitForChild("DilemmaService"))

-- événement : « Sabotage » (réussi), « Vol » (technologie volée), « Demasque » (espions pris) ;
-- spy = pays espion, target = pays visé
type Listener = (event: string, spy: string, target: string, regionId: string) -> ()

local EspionageService = {}

local folder: Folder? = nil
local rng = Random.new()
local lastSabotage: { [string]: number } = {} -- « espion|cible » -> heure
local lastTheft: { [string]: number } = {} -- « espion|cible » -> heure
local listeners: { Listener } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function costText(costs: { [string]: number }): string
	local parts = {}
	for id, amount in costs do
		local r = if id == Resources.currency.id then Resources.currency else Resources.list[id]
		table.insert(parts, `{amount} {if r then r.icon else id}`)
	end
	return table.concat(parts, " + ")
end

local function countryFolder(countryId: string): Folder?
	local f = folder
	if not f then
		return nil
	end
	local existing = f:FindFirstChild(countryId)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = countryId
	created.Parent = f
	return created
end

local function notify(event: string, spy: string, target: string, regionId: string)
	for _, listener in listeners do
		task.spawn(listener, event, spy, target, regionId)
	end
end

-- Coût et durée d'une révélation pour un pays (satellites espions : moins cher, plus long)
function EspionageService.revealTerms(countryId: string): ({ [string]: number }, number)
	local costFactor, durationFactor = TechState.revealFactors(countryId)
	local cost = {}
	for id, amount in Espionage.reveal.cost do
		cost[id] = math.max(1, math.floor(amount * costFactor + 0.5))
	end
	return cost, Espionage.reveal.duration * durationFactor
end

-- Révèle une région étrangère pendant Espionage.reveal.duration secondes
function EspionageService.reveal(countryId: string, regionId: unknown): (boolean, string?)
	if not MatchState.isRunning() then
		return false, "La partie est terminée."
	end
	if typeof(regionId) ~= "string" or not Regions[regionId] then
		return false, "Région inconnue."
	end
	local owner = RegionService.getOwner(regionId)
	if owner == countryId or (owner and DiplomacyState.areAllies(countryId, owner)) then
		return false, "Tu vois déjà cette région."
	end
	if FogRules.revealedUntil(countryId, regionId) then
		return false, "Tes espions surveillent déjà cette région."
	end
	local cost, duration = EspionageService.revealTerms(countryId)
	if not Stocks.spend(countryId, cost) then
		return false, `Il te faut {costText(cost)}.`
	end
	local mine = countryFolder(countryId)
	if mine then
		mine:SetAttribute("R_" .. regionId, now() + duration)
	end
	return true, nil
end

-- Sabote une usine étrangère d'une région visible
function EspionageService.sabotage(countryId: string, factoryId: unknown): (boolean, string?)
	if not MatchState.isRunning() then
		return false, "La partie est terminée."
	end
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local usines = state and state:FindFirstChild("Usines")
	local factory = if typeof(factoryId) == "string" and usines then usines:FindFirstChild(factoryId) else nil
	if not factory then
		return false, "Usine introuvable."
	end
	local regionId = factory:GetAttribute("Region") :: string
	local owner = RegionService.getOwner(regionId)
	if not owner or owner == countryId or DiplomacyState.areAllies(countryId, owner) then
		return false, "Tu ne peux pas saboter cette usine."
	end
	if not FogRules.visibleRegions(countryId, RegionService.getOwner)[regionId] then
		return false, "Cette région est dans le brouillard : révèle-la d'abord."
	end
	local S = Espionage.sabotage
	local key = `{countryId}|{owner}`
	local last = lastSabotage[key]
	if last and now() - last < S.cooldown then
		return false, `Tes agents se cachent encore : réessaie dans {math.ceil(S.cooldown - (now() - last))} s.`
	end
	if not Stocks.spend(countryId, S.cost) then
		return false, `Il te faut {costText(S.cost)}.`
	end
	lastSabotage[key] = now()
	local succeeded = rng:NextNumber() < S.success * TechState.sabotageFactor(owner) -- cyberdéfense de la cible
	if succeeded then
		factory:SetAttribute("SaboteeJusqua", now() + S.duration)
		notify("Sabotage", countryId, owner, regionId)
	end
	if rng:NextNumber() < S.caught then
		DilemmaService.changeReputation(countryId, S.caughtReputation)
		notify("Demasque", countryId, owner, regionId)
		return true, if succeeded then "Usine sabotée, mais tes espions ont été démasqués !" else "Échec : tes espions ont été démasqués !"
	end
	return true, if succeeded then nil else "Échec : tes espions n'ont pas pu approcher l'usine."
end

-- Vole une technologie à un pays (une de ses régions doit être visible)
function EspionageService.steal(countryId: string, targetId: unknown): (boolean, string?)
	if not MatchState.isRunning() then
		return false, "La partie est terminée."
	end
	if typeof(targetId) ~= "string" or not Countries[targetId] or targetId == countryId or DiplomacyState.areAllies(countryId, targetId) then
		return false, "Tu ne peux pas espionner ce pays."
	end
	local visible = FogRules.visibleRegions(countryId, RegionService.getOwner)
	local seen = false
	for regionId in Regions do
		if visible[regionId] and RegionService.getOwner(regionId) == targetId then
			seen = true
			break
		end
	end
	local targetName = Countries[targetId].name
	if not seen then
		return false, `Aucune région {FrenchNames.of(targetName)} n'est visible : révèle-en une d'abord.`
	end
	-- un niveau d'une technologie que la cible a et que le voleur pourrait chercher
	local candidates = TechState.stealable(countryId, targetId)
	if #candidates == 0 then
		return false, `{FrenchNames.The(targetName)} n'a aucune technologie à te voler pour l'instant.`
	end
	local T = Technologies.steal
	local key = `{countryId}|{targetId}`
	local last = lastTheft[key]
	if last and now() - last < T.cooldown then
		return false, `Tes agents se cachent encore : réessaie dans {math.ceil(T.cooldown - (now() - last))} s.`
	end
	if not Stocks.spend(countryId, T.cost) then
		return false, `Il te faut {costText(T.cost)}.`
	end
	lastTheft[key] = now()
	local techId = candidates[rng:NextInteger(1, #candidates)]
	local tech = Technologies.get(techId)
	local succeeded = rng:NextNumber() < T.success * TechState.sabotageFactor(targetId)
	if succeeded then
		ResearchService.grant(countryId, techId)
		notify("Vol", countryId, targetId, targetId)
	end
	local result = if succeeded then `Tes espions ont volé les plans : {tech.icon} {tech.name} niveau {TechState.level(countryId, techId)} !` else "Échec : tes espions n'ont rien trouvé."
	if rng:NextNumber() < T.caught then
		DilemmaService.changeReputation(countryId, Espionage.sabotage.caughtReputation)
		notify("Demasque", countryId, targetId, targetId)
		result ..= " Mais ils ont été démasqués !"
	end
	return true, result
end

-- listener(événement, espion, cible, région) : voir le type Listener
function EspionageService.onEvent(listener: Listener)
	table.insert(listeners, listener)
end

-- Nouvelle partie : plus aucun renseignement
function EspionageService.reset()
	if folder then
		folder:ClearAllChildren()
	end
	table.clear(lastSabotage)
	table.clear(lastTheft)
end

-- À appeler au démarrage (après Stocks.init et DilemmaService.start)
function EspionageService.init()
	local renseignements = Instance.new("Folder")
	renseignements.Name = "Renseignements"
	renseignements.Parent = ReplicatedStorage:WaitForChild("EtatMonde")
	folder = renseignements

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
	remote("RevelerRegion", EspionageService.reveal)
	remote("SaboterUsine", EspionageService.sabotage)
	remote("VolerTechnologie", EspionageService.steal)
end

return EspionageService
