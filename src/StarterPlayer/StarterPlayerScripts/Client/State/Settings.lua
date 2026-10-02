--!strict
-- Réglages du joueur pour la session : volume de la musique, volume des effets, messages
-- d'information à l'écran, taille de l'interface.
-- Les modules concernés s'abonnent avec Settings.onChanged.
-- Ils sont sauvegardés avec le compte (server/Session/AccountService) : Settings.attach les
-- recharge à l'arrivée du joueur, puis renvoie au serveur chaque changement.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Audio = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Audio")) :: any

type Listener = (key: string, value: any) -> ()

local Settings = {}

local values: { [string]: any } = {
	musicVolume = Audio.defaultMusicVolume, -- 0 à 1
	effectsVolume = Audio.defaultEffectsVolume, -- 0 à 1
	infoMessages = true, -- faux : seuls les messages importants (succès, alertes) s'affichent
	uiSize = "Normale", -- "Petite" | "Normale" | "Grande" (voir UI/UIScaler)
}
local listeners: { Listener } = {}

function Settings.get(key: string): any
	return values[key]
end

function Settings.set(key: string, value: any)
	if values[key] == value then
		return
	end
	values[key] = value
	for _, listener in listeners do
		task.spawn(listener, key, value)
	end
end

-- Appelé à chaque changement de réglage
function Settings.onChanged(listener: Listener)
	table.insert(listeners, listener)
end

-- Recharge les réglages sauvegardés du joueur, puis enregistre ses changements (regroupés)
function Settings.attach()
	local account = Players.LocalPlayer:WaitForChild("Compte", 60)
	if account then
		local ok, saved = pcall(function()
			return HttpService:JSONDecode(tostring(account:GetAttribute("Reglages") or "{}"))
		end)
		if ok and typeof(saved) == "table" then
			for key, value in saved do
				if values[key] ~= nil and typeof(value) == typeof(values[key]) then
					Settings.set(key, value)
				end
			end
		end
	end
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("EnregistrerReglages") :: RemoteEvent
	local pending = false
	Settings.onChanged(function()
		if pending then
			return
		end
		pending = true
		task.delay(1.5, function()
			pending = false
			remote:FireServer(values)
		end)
	end)
end

return Settings
