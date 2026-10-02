--!strict
-- Discussions privées entre dirigeants (pour négocier) : un canal du chat Roblox (TextChatService)
-- par paire de joueurs, créé à la demande (Remotes.OuvrirDiscussion(userId) -> vrai, nom du canal).
-- Les messages passent par le chat de Roblox, donc par son filtre (obligatoire), et respectent
-- les réglages de chat de chaque joueur. Les canaux d'un joueur disparaissent quand il part.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local RateLimiter = require(script.Parent.Parent:WaitForChild("Util"):WaitForChild("RateLimiter"))

local PREFIX = "Prive_"

local PrivateChat = {}

local function channelName(a: number, b: number): string
	return `{PREFIX}{math.min(a, b)}_{math.max(a, b)}`
end

local function isMember(channel: TextChannel, userId: number): boolean
	for _, child in channel:GetChildren() do
		if child:IsA("TextSource") and child.UserId == userId then
			return true
		end
	end
	return false
end

-- Ouvre (ou retrouve) la discussion privée entre `player` et le joueur `otherUserId`
function PrivateChat.open(player: Player, otherUserId: unknown): (boolean, string?)
	if typeof(otherUserId) ~= "number" then
		return false, "Joueur inconnu."
	end
	local other = Players:GetPlayerByUserId(otherUserId)
	if not other or other == player then
		return false, "Ce joueur n'est plus dans la partie."
	end
	local channels = TextChatService:FindFirstChild("TextChannels")
	if not channels then
		return false, "Le chat n'est pas disponible."
	end
	local name = channelName(player.UserId, other.UserId)
	local channel = channels:FindFirstChild(name) :: TextChannel?
	if not channel then
		local created = Instance.new("TextChannel")
		created.Name = name
		created.Parent = channels
		channel = created
	end
	local c = channel :: TextChannel
	for _, p in { player, other } do
		if not isMember(c, p.UserId) then
			local ok, _source, success = pcall(function()
				return c:AddUserAsync(p.UserId)
			end)
			if not ok or success == false then
				return false, if p == player then "Ton compte ne peut pas utiliser le chat." else `{other.DisplayName} ne peut pas recevoir de messages privés.`
			end
		end
	end
	return true, name
end

-- À appeler au démarrage
function PrivateChat.init()
	local remote = Instance.new("RemoteFunction")
	remote.Name = "OuvrirDiscussion"
	local limiter = RateLimiter.new(1)
	remote.OnServerInvoke = function(player: Player, otherUserId: unknown)
		if not limiter:allow(player) then
			return false, "Doucement, réessaie dans un instant."
		end
		return PrivateChat.open(player, otherUserId)
	end
	remote.Parent = ReplicatedStorage:WaitForChild("Remotes")

	Players.PlayerRemoving:Connect(function(player: Player)
		local channels = TextChatService:FindFirstChild("TextChannels")
		for _, channel in (if channels then channels:GetChildren() else {}) do
			if channel.Name:sub(1, #PREFIX) == PREFIX and table.find(channel.Name:sub(#PREFIX + 1):split("_"), tostring(player.UserId)) then
				channel:Destroy()
			end
		end
	end)
end

return PrivateChat
