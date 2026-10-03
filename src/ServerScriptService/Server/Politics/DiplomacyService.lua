--!strict
-- Diplomatie : blocs d'alliance, guerres, trêves et propositions d'alliance. La paix et les trêves
-- se votent : seul un joueur les propose, au Conseil mondial (CouncilService, cahier des charges v2
-- section 1) ; ce module applique le résultat (makePeace, makeTruce).
-- Le serveur décide de tout. État publié dans ReplicatedStorage.EtatMonde.Diplomatie :
--   Blocs.<id>         Nom, Membres (« FRA,DEU ») ; et l'attribut « Bloc » de EtatMonde.Pays.<code>
--   Guerres.<A_B>      A, B, Depuis (heure serveur), Declarant (A et B dans l'ordre alphabétique)
--   Treves.<A_B>       A, B, Fin (heure serveur), Reprise (vrai : la guerre reprend à la fin)
--   Embargos.<A>B>     De, Contre : A refuse tout contrat avec B (voir ContractService)
--   Propositions.<id>  De, A, Type (« Alliance »), Expire,
--                      Reponse (« Acceptee » | « Refusee » | « Expiree ») une fois tranchée
-- Règles (Config/Diplomacy) :
--   - un bloc réunit au plus maxBlocSize pays ; ses membres partagent leurs guerres ;
--   - attaquer un pays en paix lui déclare la guerre (voir ArmyService) : les deux blocs entrent en guerre ;
--   - on n'attaque ni un allié, ni un pays avec qui on a une trêve ;
--   - la paix, votée, arrête la guerre entre les deux camps et ouvre une trêve ; une trêve votée
--     suspend la guerre un moment, puis elle reprend ;
--   - quitter son bloc pendant une guerre est une trahison (les IA s'en souviennent).
-- Remotes : ProposerAlliance(pays), DeclarerGuerre(pays) (aussi depuis la fiche d'une région),
--           RepondreProposition(id, accepte), QuitterBloc(), Embargo(pays, actif).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Diplomacy = require(Config:WaitForChild("Diplomacy")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local DiplomacyState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DiplomacyState")) :: any
local FrenchNames = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FrenchNames")) :: any
local Server = script.Parent.Parent
local CountryAssignment = require(Server:WaitForChild("Session"):WaitForChild("CountryAssignment"))
local PlayStyle = require(Server:WaitForChild("Session"):WaitForChild("PlayStyle"))
local RateLimiter = require(Server:WaitForChild("Util"):WaitForChild("RateLimiter"))

local DiplomacyService = {}

type Folders = { Blocs: Folder, Guerres: Folder, Treves: Folder, Propositions: Folder, Embargos: Folder }
local folders: Folders? = nil
local nextBlocId, nextProposalId = 0, 0
local lastProposal: { [string]: number } = {} -- « De|A|Type » -> heure de la dernière proposition
local proposalListeners: { (proposal: Instance) -> () } = {}
local warListeners: { (attacker: string, target: string) -> () } = {}
local peaceListeners: { (a: string, b: string) -> () } = {}
local betrayalListeners: { (traitor: string, victims: { string }) -> () } = {}
local allianceListeners: { (blocName: string, joined: { string }, founded: boolean) -> () } = {}
local dissolvedListeners: { (blocName: string, members: { string }, duration: number) -> () } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function countryFolder(countryId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
end

local function nameOf(countryId: string): string
	local country = Countries[countryId]
	return if country then country.name else countryId
end

local function notify(listeners: { any }, ...: any)
	for _, listener in listeners do
		task.spawn(listener, ...)
	end
end

-- ---- Lecture de l'état (partagée avec le client : shared/DiplomacyState) ----------------

DiplomacyService.blocOf = DiplomacyState.blocOf :: (countryId: string) -> string?
DiplomacyService.alliesOf = DiplomacyState.alliesOf :: (countryId: string) -> { string }
DiplomacyService.areAllies = DiplomacyState.areAllies :: (a: string, b: string) -> boolean
DiplomacyService.atWar = DiplomacyState.atWar :: (a: string, b: string) -> boolean
DiplomacyService.truceLeft = DiplomacyState.truceLeft :: (a: string, b: string) -> number
DiplomacyService.enemiesOf = DiplomacyState.enemiesOf :: (countryId: string) -> { string }
DiplomacyService.warSince = DiplomacyState.warSince :: (a: string, b: string) -> number?
DiplomacyService.blocName = DiplomacyState.blocName :: (countryId: string) -> string?
DiplomacyService.hasEmbargo = DiplomacyState.hasEmbargo :: (a: string, b: string) -> boolean
local members = DiplomacyState.members :: (blocId: string) -> { string }
local pairKey = DiplomacyState.pairKey :: (a: string, b: string) -> string

local function blocFolder(blocId: string): Instance?
	return if folders then folders.Blocs:FindFirstChild(blocId) else nil
end

local function setMembers(blocId: string, list: { string })
	local bloc = blocFolder(blocId)
	if bloc then
		table.sort(list)
		bloc:SetAttribute("Membres", table.concat(list, ","))
	end
end

-- Un pays et ses alliés
local function side(countryId: string): { string }
	local list = DiplomacyService.alliesOf(countryId)
	table.insert(list, countryId)
	return list
end

-- ---- Guerres et trêves ------------------------------------------------------------

-- declarer : pays qui a déclenché la guerre (publié pour les messages et le fil d'actualité)
local function setWar(a: string, b: string, declarer: string)
	local f = folders
	if not f or DiplomacyService.atWar(a, b) then
		return
	end
	local war = Instance.new("Folder")
	war.Name = pairKey(a, b)
	war:SetAttribute("A", if a < b then a else b)
	war:SetAttribute("B", if a < b then b else a)
	war:SetAttribute("Depuis", now())
	war:SetAttribute("Declarant", declarer)
	war.Parent = f.Guerres
end

-- Fin d'une guerre, suivie d'une trêve de `duration` secondes ; resume : à la fin de la trêve, la
-- guerre reprend (trêve votée), sinon c'est la paix
local function endWar(a: string, b: string, duration: number?, resume: boolean?)
	local f = folders
	if not f then
		return
	end
	local war = f.Guerres:FindFirstChild(pairKey(a, b))
	if war then
		local declarer = war:GetAttribute("Declarant")
		war:Destroy()
		local length = duration or Diplomacy.truceDuration
		local truce = f.Treves:FindFirstChild(pairKey(a, b)) or Instance.new("Folder")
		truce.Name = pairKey(a, b)
		truce:SetAttribute("A", if a < b then a else b)
		truce:SetAttribute("B", if a < b then b else a)
		truce:SetAttribute("Fin", now() + length)
		truce:SetAttribute("Reprise", if resume then true else nil)
		truce.Parent = f.Treves
		task.delay(length + 1, function()
			local finish = truce:GetAttribute("Fin")
			if truce.Parent and typeof(finish) == "number" and finish <= now() then
				local again = truce:GetAttribute("Reprise") == true
				truce:Destroy()
				-- trêve finie : la guerre reprend (sauf s'ils sont devenus alliés entre-temps)
				if again and not DiplomacyService.areAllies(a, b) then
					setWar(a, b, if typeof(declarer) == "string" then declarer else a)
				end
			end
		end)
	end
end

-- Peut-on attaquer ce pays ? (ni allié, ni sous trêve)
function DiplomacyService.canAttack(attacker: string, target: string): (boolean, string?)
	if attacker == target then
		return false, "C'est ton propre pays."
	end
	if DiplomacyService.areAllies(attacker, target) then
		return false, `{FrenchNames.The(nameOf(target))} fait partie de tes alliés.`
	end
	local truce = DiplomacyService.truceLeft(attacker, target)
	if truce > 0 then
		return false, `Trêve avec {FrenchNames.the(nameOf(target))} : encore {math.ceil(truce)} s.`
	end
	local protection = DiplomacyState.protectionLeft(target)
	if protection > 0 then
		return false, `Ce pays vient d'être choisi par un joueur : protégé encore {math.ceil(protection)} s.`
	end
	return true, nil
end

-- `attacker` déclare la guerre à `target` : les deux camps (blocs) entrent en guerre
function DiplomacyService.declareWar(attacker: string, target: string): (boolean, string?)
	if not Countries[target] then
		return false, "Pays inconnu."
	end
	local ok, reason = DiplomacyService.canAttack(attacker, target)
	if not ok then
		return false, reason
	end
	if DiplomacyService.atWar(attacker, target) then
		return true, nil
	end
	for _, x in side(attacker) do
		for _, y in side(target) do
			if x ~= y and not DiplomacyService.areAllies(x, y) and DiplomacyService.truceLeft(x, y) <= 0 then
				setWar(x, y, attacker)
			end
		end
	end
	notify(warListeners, attacker, target)
	return true, nil
end

-- Paix entre les camps de `a` et de `b` (toutes leurs guerres croisées), suivie d'une trêve
local function makePeace(a: string, b: string)
	for _, x in side(a) do
		for _, y in side(b) do
			endWar(x, y)
		end
	end
	notify(peaceListeners, a, b)
end
DiplomacyService.makePeace = makePeace

-- Trêve votée entre les camps de `a` et de `b` : plus d'attaque pendant `duration` secondes, puis
-- la guerre reprend
function DiplomacyService.makeTruce(a: string, b: string, duration: number)
	for _, x in side(a) do
		for _, y in side(b) do
			endWar(x, y, duration, true)
		end
	end
end

-- Les deux camps d'une guerre entre `a` et `b` : pays de chaque camp en guerre avec l'autre
function DiplomacyService.camps(a: string, b: string): ({ string }, { string })
	local left, right = {}, {}
	for _, x in side(a) do
		for _, y in side(b) do
			if DiplomacyService.atWar(x, y) then
				if not table.find(left, x) then
					table.insert(left, x)
				end
				if not table.find(right, y) then
					table.insert(right, y)
				end
			end
		end
	end
	return left, right
end

-- Les membres d'un bloc partagent leurs guerres
local function shareWars(blocId: string)
	local list = members(blocId)
	local enemies: { [string]: boolean } = {}
	for _, member in list do
		for _, enemy in DiplomacyService.enemiesOf(member) do
			enemies[enemy] = true
		end
	end
	for enemy in enemies do
		for _, member in list do
			if member ~= enemy and not DiplomacyService.areAllies(member, enemy) and DiplomacyService.truceLeft(member, enemy) <= 0 then
				setWar(member, enemy, enemy)
			end
		end
	end
end

-- Alliance acceptée : l'un rejoint le bloc de l'autre, ou un nouveau bloc est fondé
local function join(a: string, b: string): (boolean, string?)
	local f = folders
	if not f then
		return false, "Diplomatie indisponible."
	end
	local blocA, blocB = DiplomacyService.blocOf(a), DiplomacyService.blocOf(b)
	if blocA and blocB then
		return false, "Ces deux pays sont déjà dans des blocs différents."
	end
	local blocId = blocA or blocB
	if blocId then
		local list = members(blocId)
		if #list >= Diplomacy.maxBlocSize then
			return false, "Ce bloc est complet."
		end
		local newcomer = if blocA then b else a
		table.insert(list, newcomer)
		setMembers(blocId, list)
		local folder = countryFolder(newcomer)
		if folder then
			folder:SetAttribute("Bloc", blocId)
		end
		local bloc = blocFolder(blocId)
		notify(allianceListeners, if bloc then tostring(bloc:GetAttribute("Nom")) else "?", { newcomer }, false)
	else
		-- nouveau bloc, avec un nom fictif pas encore utilisé
		local used: { [string]: boolean } = {}
		for _, bloc in f.Blocs:GetChildren() do
			used[bloc:GetAttribute("Nom") :: string] = true
		end
		local name = Diplomacy.blocNames[1]
		for _, candidate in Diplomacy.blocNames do
			if not used[candidate] then
				name = candidate
				break
			end
		end
		nextBlocId += 1
		blocId = "L" .. nextBlocId
		local bloc = Instance.new("Folder")
		bloc.Name = blocId :: string
		bloc:SetAttribute("Nom", name)
		bloc:SetAttribute("Fondation", now()) -- pour « la plus longue alliance » (bilan de fin de partie)
		bloc.Parent = f.Blocs
		setMembers(blocId :: string, { a, b })
		for _, id in { a, b } do
			local folder = countryFolder(id)
			if folder then
				folder:SetAttribute("Bloc", blocId)
			end
		end
		notify(allianceListeners, name, { a, b }, true)
	end
	shareWars(blocId :: string)
	return true, nil
end

-- Quitter son bloc (trahison si une guerre est en cours)
function DiplomacyService.leaveBloc(countryId: string): (boolean, string?)
	local blocId = DiplomacyService.blocOf(countryId)
	if not blocId then
		return false, "Tu n'es dans aucun bloc."
	end
	local allies = DiplomacyService.alliesOf(countryId)
	local atWar = #DiplomacyService.enemiesOf(countryId) > 0
	for _, ally in allies do
		atWar = atWar or #DiplomacyService.enemiesOf(ally) > 0
	end
	local folder = countryFolder(countryId)
	if folder then
		folder:SetAttribute("Bloc", nil)
	end
	if #allies < 2 then
		-- il ne reste qu'un pays : le bloc est dissous
		for _, ally in allies do
			local allyFolder = countryFolder(ally)
			if allyFolder then
				allyFolder:SetAttribute("Bloc", nil)
			end
		end
		local bloc = blocFolder(blocId)
		if bloc then
			local founded = bloc:GetAttribute("Fondation")
			local everyone = table.clone(allies)
			table.insert(everyone, countryId)
			notify(dissolvedListeners, tostring(bloc:GetAttribute("Nom")), everyone, if typeof(founded) == "number" then now() - founded else 0)
			bloc:Destroy()
		end
	else
		setMembers(blocId, allies)
	end
	if atWar then
		notify(betrayalListeners, countryId, allies)
	end
	return true, nil
end

-- ---- Propositions -------------------------------------------------------------

local function pendingProposal(from: string, to: string, kind: string): Instance?
	if folders then
		for _, proposal in folders.Propositions:GetChildren() do
			if proposal:GetAttribute("De") == from and proposal:GetAttribute("A") == to and proposal:GetAttribute("Type") == kind
				and proposal:GetAttribute("Reponse") == nil then
				return proposal
			end
		end
	end
	return nil
end

local function close(proposal: Instance, answer: string)
	proposal:SetAttribute("Reponse", answer)
	task.delay(Diplomacy.resultDelay, function()
		if proposal.Parent then
			proposal:Destroy()
		end
	end)
end

-- `from` propose une alliance à `to` (la paix et les trêves se votent : CouncilService)
function DiplomacyService.propose(from: string, to: unknown, kind: unknown): (boolean, string?)
	local f = folders
	if not f then
		return false, "Diplomatie indisponible."
	end
	if typeof(to) ~= "string" or not Countries[to] or to == from then
		return false, "Pays inconnu."
	end
	if kind == "Paix" then
		return false, "La paix se vote : propose-la au Conseil mondial (onglet Diplomatie)."
	end
	if kind ~= "Alliance" then
		return false, "Proposition inconnue."
	end
	local key = `{from}|{to}|{kind}`
	if lastProposal[key] and now() - lastProposal[key] < Diplomacy.proposalCooldown then
		return false, "Tu as déjà fait cette proposition il y a peu."
	end
	if pendingProposal(from, to, kind) then
		return false, "Cette proposition attend déjà une réponse."
	end
	if kind == "Alliance" then
		if DiplomacyService.areAllies(from, to) then
			return false, "Vous êtes déjà alliés."
		end
		if DiplomacyService.atWar(from, to) then
			return false, "Vous êtes en guerre : proposez d'abord la paix."
		end
		local blocFrom, blocTo = DiplomacyService.blocOf(from), DiplomacyService.blocOf(to)
		if blocFrom and blocTo then
			return false, "Vous êtes déjà dans deux blocs différents."
		end
		local blocId = blocFrom or blocTo
		if blocId and #members(blocId) >= Diplomacy.maxBlocSize then
			return false, "Ce bloc est complet."
		end
	elseif not DiplomacyService.atWar(from, to) then
		return false, `Tu n'es pas en guerre contre {FrenchNames.the(nameOf(to))}.`
	end
	lastProposal[key] = now()
	nextProposalId += 1
	local proposal = Instance.new("Folder")
	proposal.Name = "P" .. nextProposalId
	proposal:SetAttribute("De", from)
	proposal:SetAttribute("A", to)
	proposal:SetAttribute("Type", kind)
	proposal:SetAttribute("Expire", now() + Diplomacy.proposalDuration)
	proposal.Parent = f.Propositions
	task.delay(Diplomacy.proposalDuration, function()
		if proposal.Parent and proposal:GetAttribute("Reponse") == nil then
			close(proposal, "Expiree")
		end
	end)
	notify(proposalListeners, proposal)
	return true, nil
end

-- `countryId` accepte ou refuse une proposition qui lui est faite
function DiplomacyService.respond(countryId: string, proposalId: unknown, accept: unknown): (boolean, string?)
	local proposal = if folders and typeof(proposalId) == "string" then folders.Propositions:FindFirstChild(proposalId) else nil
	if not proposal or proposal:GetAttribute("A") ~= countryId then
		return false, "Proposition introuvable."
	end
	if proposal:GetAttribute("Reponse") ~= nil then
		return false, "Cette proposition a déjà une réponse."
	end
	local from = proposal:GetAttribute("De") :: string
	if accept ~= true then
		close(proposal, "Refusee")
		return true, nil
	end
	if proposal:GetAttribute("Type") == "Alliance" then
		local ok, reason = join(from, countryId)
		if not ok then
			close(proposal, "Refusee")
			return false, reason
		end
	else
		if not DiplomacyService.atWar(from, countryId) then
			close(proposal, "Refusee")
			return false, "Vous n'êtes plus en guerre."
		end
		makePeace(from, countryId)
	end
	close(proposal, "Acceptee")
	return true, nil
end

-- ---- Embargos ------------------------------------------------------------------------

local embargoListeners: { (from: string, target: string, enabled: boolean) -> () } = {}

-- `from` met (ou lève) un embargo contre `target` : plus aucun contrat entre eux
function DiplomacyService.setEmbargo(from: string, target: unknown, enabled: unknown): (boolean, string?)
	local f = folders
	if not f then
		return false, "Diplomatie indisponible."
	end
	if typeof(target) ~= "string" or not Countries[target] or target == from then
		return false, "Pays inconnu."
	end
	local name = from .. ">" .. target
	local existing = f.Embargos:FindFirstChild(name)
	if enabled == true then
		if existing then
			return false, `Embargo déjà en place contre {FrenchNames.the(nameOf(target))}.`
		end
		local embargo = Instance.new("Folder")
		embargo.Name = name
		embargo:SetAttribute("De", from)
		embargo:SetAttribute("Contre", target)
		embargo.Parent = f.Embargos
	else
		if not existing then
			return false, "Pas d'embargo à lever."
		end
		existing:Destroy()
	end
	notify(embargoListeners, from, target, enabled == true)
	return true, nil
end

-- listener(pays, cible, actif) : un embargo vient d'être mis ou levé
function DiplomacyService.onEmbargo(listener: (from: string, target: string, enabled: boolean) -> ())
	table.insert(embargoListeners, listener)
end

-- ---- Abonnements (IA, fil d'actualité) ----------------------------------------------

-- listener(proposition) : une nouvelle proposition vient d'être faite
function DiplomacyService.onProposal(listener: (proposal: Instance) -> ())
	table.insert(proposalListeners, listener)
end

-- listener(attaquant, cible) : une guerre vient d'être déclarée
function DiplomacyService.onWar(listener: (attacker: string, target: string) -> ())
	table.insert(warListeners, listener)
end

-- listener(a, b) : la paix vient d'être signée entre les camps de a et de b
function DiplomacyService.onPeace(listener: (a: string, b: string) -> ())
	table.insert(peaceListeners, listener)
end

-- listener(nom du bloc, pays qui y entrent, vrai si le bloc vient d'être fondé)
function DiplomacyService.onAlliance(listener: (blocName: string, joined: { string }, founded: boolean) -> ())
	table.insert(allianceListeners, listener)
end

-- listener(traître, anciens alliés) : un pays a quitté son bloc pendant une guerre
function DiplomacyService.onBetrayal(listener: (traitor: string, victims: { string }) -> ())
	table.insert(betrayalListeners, listener)
end

-- À appeler après CountryAssignment.init() (qui crée EtatMonde et Remotes)
-- listener(nom du bloc, ses derniers membres, durée en secondes) : un bloc est dissous
function DiplomacyService.onBlocDissolved(listener: (blocName: string, members: { string }, duration: number) -> ())
	table.insert(dissolvedListeners, listener)
end

-- Nouvelle partie : ni blocs, ni guerres, ni trêves, ni propositions, ni embargos
function DiplomacyService.reset()
	local f = folders
	if f then
		f.Blocs:ClearAllChildren()
		f.Guerres:ClearAllChildren()
		f.Treves:ClearAllChildren()
		f.Propositions:ClearAllChildren()
		f.Embargos:ClearAllChildren()
	end
	table.clear(lastProposal)
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	for _, country in (if pays then pays:GetChildren() else {}) do
		country:SetAttribute("Bloc", nil)
	end
end

function DiplomacyService.init()
	local diplomatie = Instance.new("Folder")
	diplomatie.Name = "Diplomatie"
	local created: { [string]: Folder } = {}
	for _, name in { "Blocs", "Guerres", "Treves", "Propositions", "Embargos" } do
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = diplomatie
		created[name] = folder
	end
	folders = {
		Blocs = created.Blocs,
		Guerres = created.Guerres,
		Treves = created.Treves,
		Propositions = created.Propositions,
		Embargos = created.Embargos,
	}
	diplomatie.Parent = ReplicatedStorage:WaitForChild("EtatMonde")

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
	remote("ProposerAlliance", function(countryId: string, target: unknown)
		return DiplomacyService.propose(countryId, target, "Alliance")
	end)
	remote("DeclarerGuerre", function(countryId: string, target: unknown)
		if typeof(target) ~= "string" then
			return false, "Pays inconnu."
		end
		if DiplomacyService.atWar(countryId, target) then
			return false, `Tu es déjà en guerre contre {FrenchNames.the(nameOf(target))}.`
		end
		return DiplomacyService.declareWar(countryId, target)
	end)
	remote("RepondreProposition", function(countryId: string, proposalId: unknown, accept: unknown)
		return DiplomacyService.respond(countryId, proposalId, accept)
	end)
	remote("QuitterBloc", function(countryId: string)
		return DiplomacyService.leaveBloc(countryId)
	end)
	remote("Embargo", function(countryId: string, target: unknown, enabled: unknown)
		return DiplomacyService.setEmbargo(countryId, target, enabled)
	end)
end

return DiplomacyService
