--!strict
-- Envoi des ordres militaires au serveur (RemoteEvent Remotes.CommandeMilitaire) et attente de
-- sa réponse : send(ordre, données) -> (accepté, message). Le serveur décide de tout.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TIMEOUT = 6 -- secondes avant d'abandonner l'attente d'une réponse

local CommandSender = {}

local event: RemoteEvent? = nil
local nextRequest = 0
local pending: { [number]: thread } = {}

local function connect(): RemoteEvent
	if event then
		return event
	end
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CommandeMilitaire") :: RemoteEvent
	remote.OnClientEvent:Connect(function(kind: string, requestId: number, ok: boolean, message: string?)
		if kind ~= "Resultat" then
			return
		end
		local waiting = pending[requestId]
		if waiting then
			pending[requestId] = nil
			task.spawn(waiting, ok, message)
		end
	end)
	event = remote
	return remote
end

-- Envoie un ordre et attend la réponse du serveur (accepté, message de refus éventuel)
function CommandSender.send(order: string, data: { [string]: any }): (boolean, string?)
	local remote = connect()
	nextRequest += 1
	local requestId = nextRequest
	local thread = coroutine.running()
	pending[requestId] = thread
	task.delay(TIMEOUT, function()
		if pending[requestId] == thread then
			pending[requestId] = nil
			task.spawn(thread, false, "Le serveur ne répond pas.")
		end
	end)
	remote:FireServer(requestId, order, data)
	return coroutine.yield()
end

return CommandSender
