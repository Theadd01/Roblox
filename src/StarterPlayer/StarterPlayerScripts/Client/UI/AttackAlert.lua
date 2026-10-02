--!strict
-- Alerte « attaque en approche » : quand une force étrangère se met en route vers une région
-- du joueur, un message le prévient, avec le temps qu'il lui reste pour renforcer sa défense.
-- Une armée qui avance de région en région ne prévient qu'une fois par REPEAT_AFTER secondes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Units = require(Config:WaitForChild("Units")) :: any
local Client = script.Parent.Parent
local ArmyState = require(Client:WaitForChild("State"):WaitForChild("ArmyState"))
local RegionView = require(Client:WaitForChild("Map"):WaitForChild("RegionView"))
local Toast = require(script.Parent:WaitForChild("Toast"))

local VERBS = { Terre = "marche sur", Air = "vole vers", Mer = "fait route vers" }

local AttackAlert = {}

local REPEAT_AFTER = 45

local alerted: { [Instance]: number } = {} -- force -> heure de départ du trajet déjà signalé
local lastAlert: { [Instance]: number } = {} -- force -> moment du dernier message

local function check(army: Instance, removed: boolean)
	if removed then
		alerted[army] = nil
		lastAlert[army] = nil
		return
	end
	local me = Players.LocalPlayer:GetAttribute("Pays")
	local destination = army:GetAttribute("Destination")
	local departure = army:GetAttribute("Depart")
	if typeof(me) ~= "string" or me == "" or typeof(destination) ~= "string" or destination == "" or typeof(departure) ~= "number" then
		return
	end
	local owner = army:GetAttribute("Proprietaire")
	if owner == me or RegionView.getOwner(destination) ~= me or alerted[army] == departure then
		return
	end
	alerted[army] = departure
	if os.clock() - (lastAlert[army] or -math.huge) < REPEAT_AFTER then
		return -- étape suivante de la même offensive : déjà signalée
	end
	lastAlert[army] = os.clock()
	local kind = Units.kindOf(army)
	local country = Countries[owner]
	local arrival = army:GetAttribute("Arrivee")
	local seconds = if typeof(arrival) == "number" then math.max(0, math.ceil(arrival - workspace:GetServerTimeNow())) else 0
	Toast.show(
		`🚨 {Units.kinds[kind].icon} {army:GetAttribute("Nom")} ({if country then country.name else "?"}) {VERBS[kind]} <b>{Regions[destination].name}</b> : arrivée dans {seconds} s !`,
		"danger"
	)
end

function AttackAlert.start()
	ArmyState.onChanged(check)
end

return AttackAlert
