--!strict
-- Suit les forces publiées par le serveur (ReplicatedStorage.EtatMonde.Armees) : armées de terre,
-- escadrilles et flottes. Prévient les abonnés à chaque changement (création, troupes, déplacement...).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Units = require(Config:WaitForChild("Units")) :: any

type Listener = (army: Instance, removed: boolean) -> ()

local ArmyState = {}

local folder: Instance? = nil
local listeners: { Listener } = {}

local function notify(army: Instance, removed: boolean)
	for _, listener in listeners do
		task.spawn(listener, army, removed)
	end
end

local function idNumber(army: Instance): number
	return tonumber(army.Name:match("%d+")) or 0
end

function ArmyState.start()
	local armees = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Armees")
	folder = armees
	local function hook(army: Instance)
		army.AttributeChanged:Connect(function()
			notify(army, false)
		end)
		notify(army, false)
	end
	for _, army in armees:GetChildren() do
		hook(army)
	end
	armees.ChildAdded:Connect(hook)
	armees.ChildRemoved:Connect(function(army: Instance)
		notify(army, true)
	end)
end

function ArmyState.get(armyId: string): Instance?
	return if folder then folder:FindFirstChild(armyId) else nil
end

-- Toutes les armées, de la plus ancienne à la plus récente
function ArmyState.list(): { Instance }
	local list = if folder then folder:GetChildren() else {}
	table.sort(list, function(a: Instance, b: Instance): boolean
		return idNumber(a) < idNumber(b)
	end)
	return list
end

function ArmyState.ownedBy(countryId: string): { Instance }
	local list = {}
	for _, army in ArmyState.list() do
		if army:GetAttribute("Proprietaire") == countryId then
			table.insert(list, army)
		end
	end
	return list
end

-- Armées à l'arrêt dans une région
function ArmyState.restingIn(regionId: string): { Instance }
	local list = {}
	for _, army in ArmyState.list() do
		if army:GetAttribute("Region") == regionId and army:GetAttribute("Destination") == "" then
			table.insert(list, army)
		end
	end
	return list
end

function ArmyState.isMoving(army: Instance): boolean
	local destination = army:GetAttribute("Destination")
	return typeof(destination) == "string" and destination ~= ""
end

-- Régions qui restent à traverser après la destination en cours (armée de terre envoyée loin)
function ArmyState.itinerary(army: Instance): { string }
	local raw = army:GetAttribute("Itineraire")
	if typeof(raw) ~= "string" or raw == "" then
		return {}
	end
	return string.split(raw, ",")
end

-- Sorte de force : "Terre" | "Air" | "Mer"
function ArmyState.kind(army: Instance): string
	return Units.kindOf(army)
end

-- Nombre de troupes par type et total
function ArmyState.troops(army: Instance): ({ [string]: number }, number)
	local counts, total = {}, 0
	for _, typeId in Units.kinds[Units.kindOf(army)].order do
		local n = (army:GetAttribute(typeId) :: number?) or 0
		counts[typeId] = n
		total += n
	end
	return counts, total
end

function ArmyState.capacity(army: Instance): number
	local caps = Units.kinds[Units.kindOf(army)].capacity
	local level = (army:GetAttribute("Niveau") :: number?) or 1
	return caps[math.clamp(level, 1, #caps)]
end

-- « ⚔️ 3  🛡️ 2  💥 1 » (types présents seulement)
function ArmyState.troopText(army: Instance): string
	local counts = ArmyState.troops(army)
	local parts = {}
	for _, typeId in Units.kinds[Units.kindOf(army)].order do
		if counts[typeId] > 0 then
			table.insert(parts, `{Units.types[typeId].icon} {counts[typeId]}`)
		end
	end
	return if #parts > 0 then table.concat(parts, "  ") else "aucune troupe"
end

-- Abonnement aux changements ; renvoie une fonction pour se désabonner
function ArmyState.onChanged(listener: Listener): () -> ()
	table.insert(listeners, listener)
	return function()
		local index = table.find(listeners, listener)
		if index then
			table.remove(listeners, index)
		end
	end
end

return ArmyState
