--!strict
-- Présence du joueur : signale au serveur qu'il est actif (souris, clavier, écran tactile),
-- au plus toutes les Session.pingInterval secondes, et tout de suite s'il était absent.
-- Sans signal pendant Session.afkTimeout secondes, l'IA prend le relais (server/Session/PlayerRelay).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Session = require(Config:WaitForChild("Session")) :: any

local ABSENT_RETRY = 1 -- secondes entre deux signaux quand le joueur est marqué absent

local Presence = {}

local lastPing = -math.huge
local remote: RemoteEvent? = nil

-- Le pays du joueur est-il dirigé par l'IA parce qu'il était inactif ?
function Presence.isAbsent(): boolean
	local countryId = Players.LocalPlayer:GetAttribute("Pays")
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	local folder = if typeof(countryId) == "string" and pays then pays:FindFirstChild(countryId) else nil
	return folder ~= nil and folder:GetAttribute("Absent") == true
end

local function ping()
	local now = os.clock()
	local wait = if Presence.isAbsent() then ABSENT_RETRY else Session.pingInterval
	if not remote or now - lastPing < wait then
		return
	end
	lastPing = now
	remote:FireServer()
end

function Presence.start()
	remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Activite") :: RemoteEvent
	UserInputService.InputBegan:Connect(ping)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.MouseWheel or t == Enum.UserInputType.Touch then
			ping()
		end
	end)
end

return Presence
