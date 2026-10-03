--!strict
-- Conseil mondial et votes (cahier des charges v2, section 1 ; Config/Council).
-- SEUL UN JOUEUR propose un vote (Remotes.ProposerVote) : une résolution (sanctions, cessez-le-feu,
-- taxe sur le pétrole, reconnaissance d'une conquête, aide humanitaire), un événement mondial
-- (Config/WorldEvents, ceux marqués « proposable »), une trêve ou la paix avec un pays en guerre
-- contre lui. Les IA ne proposent jamais rien (ni ici, ni ailleurs) ; elles votent (CouncilAI).
-- Pays concernés : tous les pays encore sur la carte, ou les deux camps de la guerre pour une
-- trêve ou la paix ; celui qui propose vote « pour ». Les joueurs concernés votent dans la
-- fenêtre du Conseil (Remotes.VoterConseil) ; les pays IA votent seuls, selon leur affinité envers
-- celui qui propose, l'offre et leur guerre. Majorité simple ; sans vote à la fin : abstention.
-- Offre : des crédits par pays IA concerné, mis de côté au lancement, versés à ceux qui votent
-- « oui » ; le reste revient à celui qui propose. Un joueur peut aussi convaincre un pays IA
-- (Remotes.ConvaincreConseil).
-- État publié dans ReplicatedStorage.EtatMonde.Conseil :
--   Etat (« Attente » | « Vote » | « Resultat »), Fin (fin du vote), Type, Titre, Texte, Initiateur,
--   Cible, Region, Evenement, Offre (crédits par pays IA qui vote oui), Votants (« FRA,DEU,… »),
--   Pour, Contre, Abstention, Resultat (« Adoptee » | « Rejetee »), Sanction + SanctionFin,
--   CessezLeFeuFin (effets en cours) ;
--   Votes : un attribut par pays (« Pour », « Contre », « Abstention ») ; Chances : probabilité
--   de « oui » de chaque pays IA (0 à 1) ; Paiements : crédits reçus par chaque pays IA.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Council = require(Config:WaitForChild("Council")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local WorldEvents = require(Config:WaitForChild("WorldEvents")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local VoteRules = require(Shared:WaitForChild("VoteRules")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local CountryAssignment = require(Server:WaitForChild("Session"):WaitForChild("CountryAssignment"))
local PlayStyle = require(Server:WaitForChild("Session"):WaitForChild("PlayStyle"))
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
local EARLY_CLOSE = 2 -- secondes après le dernier vote attendu : le vote se termine plus tôt

type Resolution = { kind: string, target: string?, region: string?, event: string?, initiator: string? }
type Session = {
	resolution: Resolution,
	initiator: string,
	voters: { string }, -- pays concernés (sans celui qui propose)
	ai: { [string]: boolean }, -- pays IA parmi eux
	offer: number, -- crédits par pays IA qui vote « oui »
	escrow: number, -- crédits mis de côté
	generation: number,
	closing: boolean,
}

local CouncilService = {}

local folder: Folder? = nil
local votes: Folder? = nil
local chances: Folder? = nil
local payments: Folder? = nil
local current: Session? = nil
local lobbied: { [string]: boolean } = {} -- « lobbyiste|pays » déjà tenté pendant ce vote
local lastProposal: { [string]: number } = {} -- pays -> heure de sa dernière proposition
local resultListeners: { (title: string, adopted: boolean, yes: number, no: number) -> () } = {}
local openListeners: { (title: string) -> () } = {}
local eventHandler: ((eventId: string) -> boolean)? = nil
local rng = Random.new()
local generation = 0 -- change à chaque nouvelle partie : un vote en cours s'arrête sans effet

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

-- Pays encore sur la carte
local function aliveCountries(): { string }
	local seen: { [string]: boolean } = {}
	local list = {}
	for regionId in Regions do
		local owner = RegionService.getOwner(regionId)
		if owner and not seen[owner] then
			seen[owner] = true
			table.insert(list, owner)
		end
	end
	table.sort(list)
	return list
end

local function findEvent(id: unknown): any?
	if typeof(id) ~= "string" then
		return nil
	end
	for _, event in WorldEvents.list do
		if event.id == id and event.proposable then
			return event
		end
	end
	return nil
end

local function describe(resolution: Resolution): (string, string)
	local template = Council.resolutions[resolution.kind]
	local initiator = if resolution.initiator then FrenchNames.the(nameOf(resolution.initiator)) else ""
	local target = if resolution.target then FrenchNames.the(nameOf(resolution.target)) else ""
	local region = if resolution.region then FrenchNames.the(Regions[resolution.region].name) else ""
	local event = findEvent(resolution.event)
	local eventText = ""
	if event then
		eventText = string.gsub(string.gsub(event.text, "{countries}", function()
			return "de plusieurs pays"
		end), "{duration}", function()
			return `{event.duration or 0} s`
		end)
	end
	local values = {
		initiator = initiator,
		target = target,
		region = region,
		event = if event then `{event.icon} {event.title}` else "",
		eventText = eventText,
	}
	local function fill(text: string): string
		-- remplacement par fonction : un « % » dans un nom ne casse rien
		local result = string.gsub(text, "{(%a+)}", function(key: string): string
			return values[key] or "{" .. key .. "}"
		end)
		-- majuscule en début de phrase
		return (string.gsub(result, "^%l", string.upper))
	end
	return fill(template.title), fill(template.text)
end

local function count()
	local v = votes
	local f = folder
	if not v or not f then
		return
	end
	local list: { [string]: string } = {}
	for country, value in v:GetAttributes() do
		if typeof(value) == "string" then
			list[country] = value
		end
	end
	local yes, no, abstain = VoteRules.tally(list)
	f:SetAttribute("Pour", yes)
	f:SetAttribute("Contre", no)
	f:SetAttribute("Abstention", abstain)
end

local function setVote(countryId: string, vote: string)
	if votes then
		votes:SetAttribute(countryId, vote)
		count()
	end
end

local function clearAttributes(target: Instance?)
	if target then
		for name in target:GetAttributes() do
			target:SetAttribute(name, nil)
		end
	end
end

-- Applique l'effet d'une résolution adoptée (ou rejetée, pour la reconnaissance)
local function apply(resolution: Resolution, adopted: boolean)
	local f = folder
	if not f then
		return
	end
	local kind = resolution.kind
	if kind == "Treve" and adopted and resolution.initiator and resolution.target then
		if DiplomacyService.atWar(resolution.initiator, resolution.target) then
			DiplomacyService.makeTruce(resolution.initiator, resolution.target, Council.truceDuration)
		end
	elseif kind == "Paix" and adopted and resolution.initiator and resolution.target then
		if DiplomacyService.atWar(resolution.initiator, resolution.target) then
			DiplomacyService.makePeace(resolution.initiator, resolution.target)
		end
	elseif kind == "Sanctions" and adopted and resolution.target then
		f:SetAttribute("Sanction", resolution.target)
		f:SetAttribute("SanctionFin", now() + Council.sanctionDuration)
	elseif kind == "CessezLeFeu" and adopted then
		f:SetAttribute("CessezLeFeuFin", now() + Council.ceasefireDuration)
	elseif kind == "TaxePetrole" and adopted then
		MarketService.shock("Petrole", 1 + Council.oilTax)
	elseif kind == "Reconnaissance" and resolution.target then
		local delta = if adopted then Council.recognitionStability else -Council.recognitionStability
		Stability.change(resolution.target, delta, if adopted then "conquête reconnue" else "conquête condamnée")
	elseif kind == "AideHumanitaire" and adopted and resolution.target then
		Stocks.add(resolution.target, CURRENCY, Council.humanitarianAid)
	elseif kind == "Evenement" and adopted and resolution.event then
		local handler = eventHandler
		if handler then
			handler(resolution.event)
		end
	end
end

-- Fin du vote : décompte, effet, paiement des pays IA qui ont voté « oui », résultat affiché
local function close(session: Session)
	local f, v, p = folder, votes, payments
	if not f or not v or not p or current ~= session or session.closing then
		return
	end
	session.closing = true
	-- sans vote à la fin : abstention
	for _, countryId in session.voters do
		if v:GetAttribute(countryId) == nil then
			v:SetAttribute(countryId, "Abstention")
		end
	end
	count()
	local yes = (f:GetAttribute("Pour") :: number?) or 0
	local no = (f:GetAttribute("Contre") :: number?) or 0
	local adopted = yes > no
	-- l'offre : versée aux pays IA qui ont voté « oui », le reste revient à celui qui propose
	local spent = 0
	if session.offer > 0 then
		for countryId in session.ai do
			if v:GetAttribute(countryId) == "Pour" then
				Stocks.add(countryId, CURRENCY, session.offer)
				p:SetAttribute(countryId, session.offer)
				spent += session.offer
			end
		end
	end
	if session.escrow > spent then
		Stocks.add(session.initiator, CURRENCY, session.escrow - spent)
	end
	f:SetAttribute("Resultat", if adopted then "Adoptee" else "Rejetee")
	f:SetAttribute("Etat", "Resultat")
	apply(session.resolution, adopted)
	local title = tostring(f:GetAttribute("Titre"))
	for _, listener in resultListeners do
		task.spawn(listener, title, adopted, yes, no)
	end
	current = nil
	local myGeneration = session.generation
	task.delay(Council.resultDuration, function()
		if generation == myGeneration and current == nil and f:GetAttribute("Etat") == "Resultat" then
			f:SetAttribute("Etat", "Attente")
		end
	end)
end

-- Tous les pays concernés ont voté : le vote se termine un peu plus tôt
local function checkEarlyClose(session: Session)
	local v = votes
	if not v then
		return
	end
	for _, countryId in session.voters do
		if v:GetAttribute(countryId) == nil then
			return
		end
	end
	task.delay(EARLY_CLOSE, function()
		if current == session and generation == session.generation then
			close(session)
		end
	end)
end

-- Ce que peut proposer un joueur, vérifié : la résolution, ou la raison du refus
local function validate(initiator: string, data: { [any]: any }): (Resolution?, string?)
	local kind = data.type
	if typeof(kind) ~= "string" or not Council.resolutions[kind] then
		return nil, "Proposition inconnue."
	end
	local resolution: Resolution = { kind = kind, initiator = initiator }
	local definition = Council.resolutions[kind]
	if definition.target == "ennemi" then
		local target = data.cible
		if typeof(target) ~= "string" or not Countries[target] or not DiplomacyService.atWar(initiator, target) then
			return nil, "Choisis un pays avec lequel tu es en guerre."
		end
		resolution.target = target
	elseif definition.target == "pays" then
		local target = data.cible
		if typeof(target) ~= "string" or not Countries[target] or target == initiator or ownedRegions(target) == 0 then
			return nil, "Choisis un autre pays encore sur la carte."
		end
		resolution.target = target
	elseif definition.target == "conquete" then
		local regionId = data.region
		local region = if typeof(regionId) == "string" then Regions[regionId] else nil
		local owner = if typeof(regionId) == "string" then RegionService.getOwner(regionId) else nil
		if not region or not owner or owner == region.startOwner then
			return nil, "Choisis une région conquise."
		end
		resolution.region = regionId :: string
		resolution.target = owner
	elseif definition.target == "evenement" then
		local event = findEvent(data.evenement)
		if not event then
			return nil, "Événement inconnu."
		end
		resolution.event = event.id
	end
	return resolution, nil
end

-- Pays concernés par une résolution (sans celui qui propose)
local function votersOf(resolution: Resolution): { string }
	local initiator = resolution.initiator :: string
	local list = {}
	if Council.resolutions[resolution.kind].target == "ennemi" and resolution.target then
		local left, right = DiplomacyService.camps(initiator, resolution.target)
		for _, camp in { left, right } do
			for _, countryId in camp do
				if countryId ~= initiator and not table.find(list, countryId) then
					table.insert(list, countryId)
				end
			end
		end
	else
		for _, countryId in aliveCountries() do
			if countryId ~= initiator then
				table.insert(list, countryId)
			end
		end
	end
	table.sort(list)
	return list
end

-- Un joueur propose un vote. data : { type, cible?, region?, evenement?, offre? }
function CouncilService.propose(initiator: string, data: unknown): (boolean, string?)
	local f, v, c, p = folder, votes, chances, payments
	if not f or not v or not c or not p then
		return false, "Conseil indisponible."
	end
	if not MatchState.isRunning() then
		return false, "La partie est terminée."
	end
	-- seul un joueur lance une trêve, la paix ou un événement (jamais l'IA)
	if CountryAssignment.isAIControlled(initiator) then
		return false, "Seul un joueur peut proposer un vote."
	end
	if typeof(data) ~= "table" then
		return false, "Proposition incomplète."
	end
	if current then
		local finish = f:GetAttribute("Fin")
		return false, `Un vote est déjà en cours : encore {if typeof(finish) == "number" then math.max(1, math.ceil(finish - now())) else "?"} s.`
	end
	local last = lastProposal[initiator]
	if last and now() - last < Council.proposalCooldown then
		return false, `Tu as proposé un vote il y a peu : réessaie dans {math.ceil(Council.proposalCooldown - (now() - last))} s.`
	end
	local resolution, why = validate(initiator, data :: { [any]: any })
	if not resolution then
		return false, why
	end
	local voters = votersOf(resolution)
	if #voters == 0 then
		return false, "Aucun pays n'est concerné par ce vote."
	end
	local offer = (data :: any).offre
	local maxOffer = Council.paymentSteps[#Council.paymentSteps]
	offer = if typeof(offer) == "number" and offer == offer then math.clamp(math.floor(offer), 0, maxOffer) else 0
	local ai: { [string]: boolean } = {}
	local aiCount = 0
	for _, countryId in voters do
		if CountryAssignment.isAIControlled(countryId) then
			ai[countryId] = true
			aiCount += 1
		end
	end
	local escrow = offer * aiCount
	if escrow > 0 and not Stocks.spend(initiator, { [CURRENCY] = escrow }) then
		return false, `Ton offre demande {escrow} crédits de côté ({offer} pour chacun des {aiCount} pays IA).`
	end
	lastProposal[initiator] = now()
	generation += 1
	local session: Session = {
		resolution = resolution,
		initiator = initiator,
		voters = voters,
		ai = ai,
		offer = offer,
		escrow = escrow,
		generation = generation,
		closing = false,
	}
	current = session
	table.clear(lobbied)
	clearAttributes(v)
	clearAttributes(c)
	clearAttributes(p)
	local title, text = describe(resolution)
	f:SetAttribute("Type", resolution.kind)
	f:SetAttribute("Titre", title)
	f:SetAttribute("Texte", text)
	f:SetAttribute("Initiateur", initiator)
	f:SetAttribute("Cible", resolution.target or "")
	f:SetAttribute("Region", resolution.region or "")
	f:SetAttribute("Evenement", resolution.event or "")
	f:SetAttribute("Offre", offer)
	f:SetAttribute("Votants", table.concat(voters, ","))
	f:SetAttribute("Resultat", "")
	f:SetAttribute("Fin", now() + Council.voteDuration)
	f:SetAttribute("Etat", "Vote")
	setVote(initiator, "Pour")
	for _, listener in openListeners do
		task.spawn(listener, title)
	end

	-- les pays IA votent dans les premières secondes, selon leur probabilité de « oui »
	local leader = BalanceService.leader()
	local offerValue = VoteRules.paymentValue({ [CURRENCY] = offer }, CURRENCY, MarketService.price)
	for countryId in ai do
		task.delay(rng:NextNumber(Council.aiDelay.min, Council.aiDelay.max), function()
			if current ~= session or v:GetAttribute(countryId) ~= nil then
				return
			end
			local vote, chance = CouncilAI.vote(countryId, resolution, offerValue, leader)
			c:SetAttribute(countryId, chance)
			setVote(countryId, vote)
			checkEarlyClose(session)
		end)
	end
	task.delay(Council.voteDuration, function()
		if current == session and generation == session.generation then
			close(session)
		end
	end)
	return true, nil
end

-- listener(titre) : un vote commence
function CouncilService.onOpen(listener: (title: string) -> ())
	table.insert(openListeners, listener)
end

-- listener(titre, adoptée, pour, contre) : résultat d'un vote
function CouncilService.onResult(listener: (title: string, adopted: boolean, yes: number, no: number) -> ())
	table.insert(resultListeners, listener)
end

-- Effet d'un événement mondial adopté (WorldEventService, branché par Main)
function CouncilService.setEventHandler(handler: (eventId: string) -> boolean)
	eventHandler = handler
end

-- Un joueur concerné vote (il peut changer d'avis tant que le vote est ouvert)
function CouncilService.vote(countryId: string, vote: unknown): (boolean, string?)
	local session = current
	if not session then
		return false, "Aucun vote en cours."
	end
	if typeof(vote) ~= "string" or not VOTES[vote] then
		return false, "Vote invalide."
	end
	if countryId == session.initiator then
		return false, "Tu as proposé ce vote : tu votes « pour »."
	end
	if not table.find(session.voters, countryId) then
		return false, "Ton pays n'est pas concerné par ce vote."
	end
	setVote(countryId, vote)
	checkEarlyClose(session)
	return true, nil
end

-- Un joueur paie pour convaincre un pays IA de voter comme lui
function CouncilService.lobby(countryId: string, target: unknown): (boolean, string?)
	local session = current
	local v = votes
	if not session or not v then
		return false, "Aucun vote en cours."
	end
	if typeof(target) ~= "string" or not Countries[target] or target == countryId then
		return false, "Pays inconnu."
	end
	if not session.ai[target] then
		return false, "Ce pays n'est pas un pays IA concerné par ce vote."
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
	if not CouncilAI.acceptsLobby(target, countryId, mine :: string, session.resolution) then
		return false, `{nameOf(target)} refuse de changer son vote.`
	end
	Stocks.add(countryId, CURRENCY, -Council.lobbyCost)
	setVote(target, mine :: string)
	return true, nil
end

-- Nouvelle partie : vote annulé (l'offre est rendue), sanctions et cessez-le-feu levés
function CouncilService.reset()
	generation += 1
	local session = current
	if session and session.escrow > 0 then
		Stocks.add(session.initiator, CURRENCY, session.escrow)
	end
	current = nil
	table.clear(lobbied)
	table.clear(lastProposal)
	clearAttributes(votes)
	clearAttributes(chances)
	clearAttributes(payments)
	local f = folder
	if f then
		for _, name in { "Type", "Titre", "Texte", "Initiateur", "Cible", "Region", "Evenement", "Offre", "Votants", "Resultat", "Fin", "Pour", "Contre", "Abstention", "Sanction", "SanctionFin", "CessezLeFeuFin" } do
			f:SetAttribute(name, nil)
		end
		f:SetAttribute("Etat", "Attente")
	end
end

-- À appeler au démarrage (après DiplomacyService.init et MarketService.init)
function CouncilService.start()
	local conseil = Instance.new("Folder")
	conseil.Name = "Conseil"
	conseil:SetAttribute("Etat", "Attente")
	local created: { [string]: Folder } = {}
	for _, name in { "Votes", "Chances", "Paiements" } do
		local child = Instance.new("Folder")
		child.Name = name
		child.Parent = conseil
		created[name] = child
	end
	conseil.Parent = ReplicatedStorage:WaitForChild("EtatMonde")
	folder, votes, chances, payments = conseil, created.Votes, created.Chances, created.Paiements

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
			local accepted, reason = action(countryId, a)
			if accepted then
				PlayStyle.recordAction(countryId, name, if typeof(a) == "table" then (a :: any).type else a)
			end
			return accepted, reason
		end
		r.Parent = remotes
	end
	remote("ProposerVote", CouncilService.propose)
	remote("VoterConseil", CouncilService.vote)
	remote("ConvaincreConseil", CouncilService.lobby)
end

return CouncilService
