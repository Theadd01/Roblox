--!strict
-- Relais joueur ↔ IA (voir CLAUDE.md, « Passage de relais joueur ↔ IA ») :
--   - arrivée : un joueur prend un pays libre, jusque-là dirigé par l'IA, dans son état actuel
--     (CountryAssignment) ; on oublie le style de jeu du dirigeant précédent ;
--   - absence : sans activité pendant Session.afkTimeout secondes, l'IA dirige son pays
--     (attribut « Absent » de EtatMonde.Pays.<code>) ; le pays lui reste réservé et il reprend
--     la main dès qu'il revient ;
--   - départ : son pays redevient libre et l'IA le reprend (CountryAssignment).
-- Quand l'IA prend le relais, elle adopte la personnalité la plus proche du style du joueur (PlayStyle).
-- Le client signale son activité avec Remotes.Activite (RemoteEvent, sans argument).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Session = require(Config:WaitForChild("Session")) :: any
local Server = script.Parent.Parent
local CountryAssignment = require(script.Parent:WaitForChild("CountryAssignment"))
local PlayStyle = require(script.Parent:WaitForChild("PlayStyle"))
local PersonalityService = require(Server:WaitForChild("AI"):WaitForChild("PersonalityService"))

local PING_COOLDOWN = 2 -- secondes minimum entre deux signaux d'activité pris en compte

local PlayerRelay = {}

local lastActive: { [Player]: number } = {}

local function countryFolder(countryId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
end

-- L'IA prend le relais : elle adopte la personnalité qui ressemble le plus au joueur
local function adoptPlayerStyle(countryId: string)
	local style = PlayStyle.closest(countryId)
	if style then
		PersonalityService.set(countryId, style)
	end
end

local function setAbsent(player: Player, absent: boolean)
	local countryId = CountryAssignment.getCountryOf(player)
	local folder = countryId and countryFolder(countryId)
	if not folder or folder:GetAttribute("Joueur") ~= player.UserId then
		return
	end
	if absent and folder:GetAttribute("Absent") ~= true then
		adoptPlayerStyle(countryId :: string)
		folder:SetAttribute("Absent", true)
	elseif not absent and folder:GetAttribute("Absent") == true then
		folder:SetAttribute("Absent", nil)
	end
end

-- Temps (en secondes) depuis la dernière activité du joueur
function PlayerRelay.idleTime(player: Player): number
	return time() - (lastActive[player] or time())
end

-- Nouvelle partie : plus de protection de départ ni d'absence (chacun rechoisit son pays)
function PlayerRelay.reset()
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	for _, folder in (if pays then pays:GetChildren() else {}) do
		folder:SetAttribute("Protection", nil)
		folder:SetAttribute("Absent", nil)
	end
	for player in lastActive do
		lastActive[player] = time()
	end
end

-- À appeler au démarrage, après CountryAssignment.init()
function PlayerRelay.init()
	local remote = Instance.new("RemoteEvent")
	remote.Name = "Activite"
	remote.OnServerEvent:Connect(function(player: Player)
		local now = time()
		if lastActive[player] and now - lastActive[player] < PING_COOLDOWN then
			return
		end
		lastActive[player] = now
		setAbsent(player, false) -- il est revenu : il reprend la main
	end)
	remote.Parent = ReplicatedStorage:WaitForChild("Remotes")

	Players.PlayerAdded:Connect(function(player: Player)
		lastActive[player] = time()
	end)
	for _, player in Players:GetPlayers() do
		lastActive[player] = time()
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		lastActive[player] = nil
	end)

	CountryAssignment.onAssigned(function(player: Player, countryId: string)
		PlayStyle.reset(countryId) -- nouveau dirigeant
		lastActive[player] = time()
		-- protection de départ : personne ne peut l'attaquer pendant quelques minutes
		local folder = countryFolder(countryId)
		if folder then
			folder:SetAttribute("Protection", workspace:GetServerTimeNow() + Session.protectionDuration)
		end
	end)
	CountryAssignment.onReleased(function(_player: Player, countryId: string)
		adoptPlayerStyle(countryId)
	end)

	-- absences : l'IA prend le relais des joueurs inactifs
	task.spawn(function()
		while true do
			task.wait(Session.checkInterval)
			for _, player in Players:GetPlayers() do
				if CountryAssignment.getCountryOf(player) and PlayerRelay.idleTime(player) >= Session.afkTimeout then
					setAbsent(player, true)
				end
			end
		end
	end)
end

return PlayerRelay
