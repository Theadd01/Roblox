--!strict
-- Compte de chaque joueur (sauvegardé par server/Data/AccountStore) : chargé à son arrivée, publié
-- pour les clients, sauvegardé quand il change (au plus toutes les SAVE_INTERVAL secondes), à son
-- départ et à l'arrêt du serveur.
-- Publié dans Player.Compte : Parties, Victoires, Podiums, MeilleurRang, Reglages (JSON) ;
-- sous-dossier Succes (un attribut vrai par succès débloqué). L'attribut « Titre » du joueur
-- (titre affiché, visible par tous) vient du succès qu'il a choisi.
-- Remotes : ChoisirTitre(succès, « » pour aucun), EnregistrerReglages(réglages).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Achievements = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Achievements")) :: any
local Server = script.Parent.Parent
local AccountStore = require(Server:WaitForChild("Data"):WaitForChild("AccountStore"))
local RateLimiter = require(Server:WaitForChild("Util"):WaitForChild("RateLimiter"))

local SAVE_INTERVAL = 30
local UI_SIZES = { Petite = true, Normale = true, Grande = true }

type State = { account: AccountStore.Account, dirty: boolean, folder: Folder }

local AccountService = {}

local states: { [Player]: State } = {}
local unlockListeners: { (player: Player, id: string) -> () } = {}

local function titleText(id: string): string
	local achievement = Achievements.get(id)
	return if achievement then achievement.title else ""
end

local function publish(player: Player, state: State)
	local account = state.account
	local folder = state.folder
	folder:SetAttribute("Parties", account.games)
	folder:SetAttribute("Victoires", account.wins)
	folder:SetAttribute("Podiums", account.podiums)
	folder:SetAttribute("MeilleurRang", account.bestRank)
	folder:SetAttribute("TitreChoisi", account.title)
	folder:SetAttribute("Reglages", HttpService:JSONEncode(account.settings))
	local unlocked = folder:FindFirstChild("Succes") or Instance.new("Folder")
	unlocked.Name = "Succes"
	for id in account.achievements do
		unlocked:SetAttribute(id, true)
	end
	unlocked.Parent = folder
	player:SetAttribute("Titre", titleText(account.title))
end

-- Compte d'un joueur (nil s'il n'est pas encore chargé)
function AccountService.get(player: Player): AccountStore.Account?
	local state = states[player]
	return if state then state.account else nil
end

-- Débloque un succès (une seule fois) ; le premier titre obtenu est affiché tout de suite
function AccountService.unlock(player: Player, id: string): boolean
	local state = states[player]
	if not state or not Achievements.get(id) or state.account.achievements[id] then
		return false
	end
	state.account.achievements[id] = true
	if state.account.title == "" then
		state.account.title = id
	end
	state.dirty = true
	publish(player, state)
	for _, listener in unlockListeners do
		task.spawn(listener, player, id)
	end
	return true
end

-- Une partie finie, au rang `rank`
function AccountService.recordGame(player: Player, rank: number)
	local state = states[player]
	if not state then
		return
	end
	local account = state.account
	account.games += 1
	if rank == 1 then
		account.wins += 1
	end
	if rank <= 3 then
		account.podiums += 1
	end
	account.bestRank = if account.bestRank == 0 then rank else math.min(account.bestRank, rank)
	state.dirty = true
	publish(player, state)
end

-- listener(joueur, succès) : un succès vient d'être débloqué
function AccountService.onUnlock(listener: (player: Player, id: string) -> ())
	table.insert(unlockListeners, listener)
end

-- Le joueur choisit le titre affiché (un succès débloqué, ou « » pour aucun)
local function chooseTitle(player: Player, id: unknown): (boolean, string?)
	local state = states[player]
	if not state then
		return false, "Ton compte se charge encore."
	end
	if id ~= "" and (typeof(id) ~= "string" or not state.account.achievements[id]) then
		return false, "Ce titre n'est pas encore débloqué."
	end
	state.account.title = id :: string
	state.dirty = true
	publish(player, state)
	return true, nil
end

-- Réglages envoyés par le client : seules les valeurs prévues sont gardées
local function saveSettings(player: Player, values: unknown)
	local state = states[player]
	if not state or typeof(values) ~= "table" then
		return
	end
	local settings = state.account.settings
	local v = values :: any
	for _, key in { "musicVolume", "effectsVolume" } do
		local value = v[key]
		if typeof(value) == "number" and value == value then
			settings[key] = math.clamp(value, 0, 1)
		end
	end
	if typeof(v.infoMessages) == "boolean" then
		settings.infoMessages = v.infoMessages
	end
	if typeof(v.uiSize) == "string" and UI_SIZES[v.uiSize] then
		settings.uiSize = v.uiSize
	end
	state.dirty = true
	state.folder:SetAttribute("Reglages", HttpService:JSONEncode(settings))
end

local function save(player: Player)
	local state = states[player]
	if state and state.dirty then
		state.dirty = false
		if not AccountStore.save(player.UserId, state.account) then
			state.dirty = true -- on réessaiera
		end
	end
end

local function onPlayerAdded(player: Player)
	local account = AccountStore.load(player.UserId)
	if not player.Parent then
		return -- parti pendant le chargement
	end
	local folder = Instance.new("Folder")
	folder.Name = "Compte"
	local state: State = { account = account, dirty = false, folder = folder }
	states[player] = state
	publish(player, state)
	folder.Parent = player
end

function AccountService.start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local limiter = RateLimiter.new(0.5)
	local title = Instance.new("RemoteFunction")
	title.Name = "ChoisirTitre"
	title.OnServerInvoke = function(player: Player, id: unknown)
		if not limiter:allow(player) then
			return false, "Doucement, réessaie dans un instant."
		end
		return chooseTitle(player, id)
	end
	title.Parent = remotes
	local settingsLimiter = RateLimiter.new(1)
	local settings = Instance.new("RemoteEvent")
	settings.Name = "EnregistrerReglages"
	settings.OnServerEvent:Connect(function(player: Player, values: unknown)
		if settingsLimiter:allow(player) then
			saveSettings(player, values)
		end
	end)
	settings.Parent = remotes

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		save(player)
		states[player] = nil
	end)
	game:BindToClose(function()
		for player in states do
			save(player)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(SAVE_INTERVAL)
			for player in states do
				task.spawn(save, player)
			end
		end
	end)
end

return AccountService
