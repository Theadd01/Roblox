--!strict
-- Suit l'état militaire publié par le serveur (ReplicatedStorage.EtatMonde.Divisions) : divisions
-- par région, par pays ; prévient les abonnés à chaque changement.
--   onChanged(division, retirée) : un attribut a changé (organisation, déplacement...)
--   onRegionChanged(région) : une division est arrivée, partie, née ou détruite dans cette région
--     (ou se met en route vers elle) : sa disposition sur la carte est à refaire

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local DivisionConfig = require(Config:WaitForChild("Divisions")) :: any

type Listener = (division: Instance, removed: boolean) -> ()
type RegionListener = (regionId: string) -> ()

local MilitaryState = {}

local folder: Instance? = nil
local listeners: { Listener } = {}
local regionListeners: { RegionListener } = {}
local byRegion: { [string]: { [Instance]: boolean } } = {}
local lastRegion: { [Instance]: string } = {}

local function idNumber(d: Instance): number
	return tonumber(d.Name:match("%d+")) or 0
end

local function notifyRegion(regionId: unknown)
	if typeof(regionId) ~= "string" or regionId == "" then
		return
	end
	for _, listener in regionListeners do
		task.spawn(listener, regionId)
	end
end

local function notify(d: Instance, removed: boolean)
	for _, listener in listeners do
		task.spawn(listener, d, removed)
	end
end

local function place(d: Instance)
	local regionId = d:GetAttribute("Region")
	local previous = lastRegion[d]
	if previous == regionId then
		return
	end
	if previous and byRegion[previous] then
		byRegion[previous][d] = nil
		notifyRegion(previous)
	end
	if typeof(regionId) == "string" then
		byRegion[regionId] = byRegion[regionId] or {}
		byRegion[regionId][d] = true
		lastRegion[d] = regionId
		notifyRegion(regionId)
	end
end

function MilitaryState.start()
	local divisions = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Divisions")
	folder = divisions
	local function hook(d: Instance)
		place(d)
		d.AttributeChanged:Connect(function(name: string)
			if name == "Region" then
				place(d)
			elseif name == "Destination" or name == "Entrainement" or name == "Bataille" then
				notifyRegion(d:GetAttribute("Region"))
				notifyRegion(d:GetAttribute("Destination"))
			end
			notify(d, false)
		end)
		notify(d, false)
	end
	for _, d in divisions:GetChildren() do
		hook(d)
	end
	divisions.ChildAdded:Connect(hook)
	divisions.ChildRemoved:Connect(function(d: Instance)
		local regionId = lastRegion[d]
		if regionId and byRegion[regionId] then
			byRegion[regionId][d] = nil
		end
		lastRegion[d] = nil
		notifyRegion(regionId)
		notify(d, true)
	end)
end

function MilitaryState.get(id: string): Instance?
	return if folder then folder:FindFirstChild(id) else nil
end

function MilitaryState.list(): { Instance }
	return if folder then folder:GetChildren() else {}
end

-- Divisions d'une région (dans l'ordre de création)
function MilitaryState.inRegion(regionId: string): { Instance }
	local list = {}
	for d in byRegion[regionId] or {} do
		if d.Parent then
			table.insert(list, d)
		end
	end
	table.sort(list, function(a: Instance, b: Instance): boolean
		return idNumber(a) < idNumber(b)
	end)
	return list
end

-- Régions où se trouve au moins une division
function MilitaryState.regions(): { string }
	local list = {}
	for regionId, set in byRegion do
		if next(set) then
			table.insert(list, regionId)
		end
	end
	return list
end

function MilitaryState.ofCountry(countryId: string): { Instance }
	local list = {}
	for _, d in MilitaryState.list() do
		if d:GetAttribute("Proprietaire") == countryId then
			table.insert(list, d)
		end
	end
	return list
end

function MilitaryState.typeOf(d: Instance): any
	return DivisionConfig.types[d:GetAttribute("Type") :: string] or DivisionConfig.types.Infanterie
end

function MilitaryState.isMoving(d: Instance): boolean
	local destination = d:GetAttribute("Destination")
	return typeof(destination) == "string" and destination ~= ""
end

function MilitaryState.isTraining(d: Instance): boolean
	return d:GetAttribute("Entrainement") ~= nil
end

-- Abonnements ; renvoient une fonction pour se désabonner
function MilitaryState.onChanged(listener: Listener): () -> ()
	table.insert(listeners, listener)
	return function()
		local i = table.find(listeners, listener)
		if i then
			table.remove(listeners, i)
		end
	end
end

function MilitaryState.onRegionChanged(listener: RegionListener): () -> ()
	table.insert(regionListeners, listener)
	return function()
		local i = table.find(regionListeners, listener)
		if i then
			table.remove(regionListeners, i)
		end
	end
end

return MilitaryState
