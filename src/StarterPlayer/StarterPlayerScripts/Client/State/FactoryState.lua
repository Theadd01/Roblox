--!strict
-- Suit les usines publiées par le serveur (ReplicatedStorage.EtatMonde.Usines)
-- et prévient les abonnés à chaque changement (création, statut, niveau, suppression).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

type Listener = (factory: Instance, removed: boolean) -> ()

local FactoryState = {}

local folder: Instance? = nil
local listeners: { Listener } = {}

local function notify(factory: Instance, removed: boolean)
	for _, listener in listeners do
		task.spawn(listener, factory, removed)
	end
end

local function idNumber(factory: Instance): number
	return tonumber(factory.Name:match("%d+")) or 0
end

function FactoryState.start()
	local usines = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Usines")
	folder = usines
	local function hook(factory: Instance)
		factory.AttributeChanged:Connect(function()
			notify(factory, false)
		end)
		notify(factory, false)
	end
	for _, factory in usines:GetChildren() do
		hook(factory)
	end
	usines.ChildAdded:Connect(hook)
	usines.ChildRemoved:Connect(function(factory: Instance)
		notify(factory, true)
	end)
end

-- Toutes les usines, de la plus ancienne à la plus récente
function FactoryState.list(): { Instance }
	local list = if folder then folder:GetChildren() else {}
	table.sort(list, function(a: Instance, b: Instance): boolean
		return idNumber(a) < idNumber(b)
	end)
	return list
end

function FactoryState.inRegion(regionId: string): { Instance }
	local list = {}
	for _, factory in FactoryState.list() do
		if factory:GetAttribute("Region") == regionId then
			table.insert(list, factory)
		end
	end
	return list
end

function FactoryState.ownedBy(countryId: string): { Instance }
	local list = {}
	for _, factory in FactoryState.list() do
		if factory:GetAttribute("Proprietaire") == countryId then
			table.insert(list, factory)
		end
	end
	return list
end

-- Abonnement aux changements ; renvoie une fonction pour se désabonner
function FactoryState.onChanged(listener: Listener): () -> ()
	table.insert(listeners, listener)
	return function()
		local index = table.find(listeners, listener)
		if index then
			table.remove(listeners, index)
		end
	end
end

return FactoryState
