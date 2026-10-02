--!strict
-- État client en lecture seule de la progression et point d'entrée des requêtes.
-- Le client ne peut jamais attribuer lui-même une récompense ou un achat.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Monetization = require(Config:WaitForChild("Monetization")) :: any

export type Bookmark = {
	x: number,
	z: number,
	distance: number,
}

local CommerceState = {}

local profileFolder: Folder? = nil
local actionRemote: RemoteFunction? = nil
local listeners: { () -> () } = {}
local attributeConnections: { [Instance]: RBXScriptConnection } = {}
local treeConnections: { RBXScriptConnection } = {}
local prices: { [string]: number } = {}
local startState: "idle" | "starting" | "ready" = "idle"
local notifyQueued = false

local function notify()
	if notifyQueued then
		return
	end
	notifyQueued = true
	task.defer(function()
		notifyQueued = false
		for _, listener in listeners do
			task.spawn(listener)
		end
	end)
end

local function watch(instance: Instance)
	if not attributeConnections[instance] then
		attributeConnections[instance] = instance.AttributeChanged:Connect(notify)
	end
end

local function unwatch(instance: Instance)
	local connection = attributeConnections[instance]
	if connection then
		connection:Disconnect()
		attributeConnections[instance] = nil
	end
end

local function watchTree(root: Instance)
	watch(root)
	for _, descendant in root:GetDescendants() do
		watch(descendant)
	end
	table.insert(treeConnections, root.DescendantAdded:Connect(function(descendant: Instance)
		watch(descendant)
		notify()
	end))
	table.insert(treeConnections, root.DescendantRemoving:Connect(function(descendant: Instance)
		unwatch(descendant)
		notify()
	end))
end

local function fetchPrice(cacheKey: string, id: number, infoType: Enum.InfoType)
	if id <= 0 then
		return
	end
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(id, infoType)
		end)
		if ok and typeof(info) == "table" and typeof(info.PriceInRobux) == "number" then
			prices[cacheKey] = math.max(0, math.floor(info.PriceInRobux))
			notify()
		end
	end)
end

function CommerceState.start(): boolean
	if startState == "ready" then
		return true
	elseif startState == "starting" then
		local deadline = os.clock() + 35
		while startState == "starting" and os.clock() < deadline do
			task.wait()
		end
		return startState == "ready"
	end
	startState = "starting"

	local world = ReplicatedStorage:WaitForChild("EtatMonde", 30)
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
	if not world or not remotes then
		warn("[Commerce] État du monde indisponible.")
		startState = "idle"
		return false
	end
	local commerce = world:WaitForChild("Monetisation", 30)
	local remote = remotes:WaitForChild("MonetisationAction", 30)
	if not commerce or not remote or not remote:IsA("RemoteFunction") then
		warn("[Commerce] Service de monétisation indisponible.")
		startState = "idle"
		return false
	end
	local profile = commerce:WaitForChild(tostring(player.UserId), 30)
	if not profile or not profile:IsA("Folder") then
		warn("[Commerce] Profil joueur indisponible.")
		startState = "idle"
		return false
	end

	profileFolder = profile
	actionRemote = remote
	watchTree(profile)
	startState = "ready"

	for key, offer in Monetization.gamePasses do
		fetchPrice("GamePass:" .. key, offer.id, Enum.InfoType.GamePass)
	end
	for key, offer in Monetization.products do
		fetchPrice("Product:" .. key, offer.id, Enum.InfoType.Product)
	end
	notify()
	return true
end

function CommerceState.onChanged(listener: () -> ()): () -> ()
	table.insert(listeners, listener)
	local connected = true
	return function()
		if not connected then
			return
		end
		connected = false
		local index = table.find(listeners, listener)
		if index then
			table.remove(listeners, index)
		end
	end
end

function CommerceState.folder(): Folder?
	return profileFolder
end

function CommerceState.attribute(name: string, fallback: any): any
	local folder = profileFolder
	if not folder then
		return fallback
	end
	local value = folder:GetAttribute(name)
	return if value == nil then fallback else value
end

function CommerceState.isClaimed(track: string, level: number): boolean
	local folder = profileFolder
	local claims = folder and folder:FindFirstChild(if track == "Premium" then "PremiumClaims" else "FreeClaims")
	return claims ~= nil and claims:GetAttribute("L" .. tostring(level)) == true
end

function CommerceState.hasUnlock(id: string): boolean
	local folder = profileFolder
	local unlocks = folder and folder:FindFirstChild("Unlocks")
	return unlocks ~= nil and unlocks:FindFirstChild(id) ~= nil
end

function CommerceState.ownsPass(key: string): boolean
	local folder = profileFolder
	local passes = folder and folder:FindFirstChild("Passes")
	return passes ~= nil and passes:GetAttribute(key) == true
end

function CommerceState.bookmarks(): { [number]: Bookmark }
	local result: { [number]: Bookmark } = {}
	local folder = profileFolder
	local entries = folder and folder:FindFirstChild("Bookmarks")
	if not entries then
		return result
	end
	for _, entry in entries:GetChildren() do
		local slot = tonumber(entry.Name)
		local x = entry:GetAttribute("X")
		local z = entry:GetAttribute("Z")
		local distance = entry:GetAttribute("Distance")
		if slot and typeof(x) == "number" and typeof(z) == "number" and typeof(distance) == "number" then
			result[slot] = { x = x, z = z, distance = distance }
		end
	end
	return result
end

function CommerceState.invoke(action: string, payload: any?): (boolean, string)
	local remote = actionRemote
	if not remote then
		return false, "Le service n'est pas encore prêt."
	end
	local callOk, accepted, message = pcall(function()
		return remote:InvokeServer(action, payload)
	end)
	if not callOk then
		return false, "Connexion au serveur interrompue."
	end
	return accepted == true, if typeof(message) == "string" then message else "Réponse invalide du serveur."
end

function CommerceState.priceText(kind: string, key: string, offer: any): string
	if offer.id <= 0 then
		return `Prévu : {offer.suggestedPrice} R$ • ID à configurer`
	end
	local price = prices[kind .. ":" .. key]
	return if price then `{price} R$` else "Prix Roblox…"
end

function CommerceState.promptGamePass(key: string): (boolean, string)
	local offer = Monetization.gamePasses[key]
	if not offer then
		return false, "Passe inconnu."
	end
	if offer.id <= 0 then
		return false, "Cet achat sera activé après configuration dans le Creator Dashboard."
	end
	local ok = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, offer.id)
	end)
	return ok, if ok then "Fenêtre d'achat ouverte." else "Impossible d'ouvrir l'achat."
end

function CommerceState.promptProduct(key: string): (boolean, string)
	local offer = Monetization.products[key]
	if not offer then
		return false, "Produit inconnu."
	end
	if offer.id <= 0 then
		return false, "Cet achat sera activé après configuration dans le Creator Dashboard."
	end
	local ok = pcall(function()
		MarketplaceService:PromptProductPurchase(player, offer.id)
	end)
	return ok, if ok then "Fenêtre d'achat ouverte." else "Impossible d'ouvrir l'achat."
end

return CommerceState
