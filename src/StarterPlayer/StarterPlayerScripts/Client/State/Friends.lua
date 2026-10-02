--!strict
-- Amis Roblox présents sur le serveur (vérifiés une fois par joueur, en arrière-plan) et pays
-- qu'ils dirigent. Sert au choix du pays (jouer près de ses amis) et au panneau social.

local Players = game:GetService("Players")

type Listener = () -> ()

local Friends = {}

local known: { [number]: boolean } = {} -- userId -> ami ?
local listeners: { Listener } = {}

local function notify()
	for _, listener in listeners do
		task.spawn(listener)
	end
end

local function check(player: Player)
	if player == Players.LocalPlayer or known[player.UserId] ~= nil then
		return
	end
	local ok, result = pcall(function()
		return Players.LocalPlayer:IsFriendsWith(player.UserId)
	end)
	known[player.UserId] = ok and result == true
	notify()
end

-- Le joueur est-il un ami Roblox du joueur local ?
function Friends.isFriend(userId: number): boolean
	return known[userId] == true
end

-- Autres joueurs du serveur : les amis d'abord
function Friends.others(): { Player }
	local list = {}
	for _, player in Players:GetPlayers() do
		if player ~= Players.LocalPlayer then
			table.insert(list, player)
		end
	end
	table.sort(list, function(a, b)
		local fa, fb = Friends.isFriend(a.UserId), Friends.isFriend(b.UserId)
		if fa ~= fb then
			return fa
		end
		return a.DisplayName < b.DisplayName
	end)
	return list
end

-- Pays dirigés par des amis : pays -> pseudo de l'ami
function Friends.countries(): { [string]: string }
	local map = {}
	for _, player in Players:GetPlayers() do
		local countryId = player:GetAttribute("Pays")
		if player ~= Players.LocalPlayer and Friends.isFriend(player.UserId) and typeof(countryId) == "string" and countryId ~= "" then
			map[countryId] = player.DisplayName
		end
	end
	return map
end

-- Appelé quand la liste change (arrivée, départ, ami reconnu, pays choisi)
function Friends.onChanged(listener: Listener)
	table.insert(listeners, listener)
end

function Friends.start()
	local function watch(player: Player)
		task.spawn(check, player)
		player:GetAttributeChangedSignal("Pays"):Connect(notify)
	end
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(player: Player)
		known[player.UserId] = nil
		notify()
	end)
end

return Friends
