--!strict
-- Brouillard de guerre côté client (règles : shared/FogRules) : régions visibles du pays dirigé,
-- recalculées chaque seconde. Les régions hors de vue sont assombries sur la carte, et les modules
-- de la carte (armées, flèches, batailles) cachent ce qu'on ne voit pas.
-- Sans pays dirigé (écran titre, choix du pays), tout est visible.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FogRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FogRules")) :: any
local RegionView = require(script.Parent.Parent:WaitForChild("Map"):WaitForChild("RegionView"))

local UPDATE_INTERVAL = 1

type Listener = () -> ()

local Fog = {}

local country: string? = nil
local visible: { [string]: boolean } = {}
local friends: { [string]: boolean } = {}
local signature = ""
local listeners: { Listener } = {}

local function update(force: boolean?)
	if country then
		visible = FogRules.visibleRegions(country, RegionView.getOwner)
		friends = FogRules.friends(country)
	else
		visible, friends = {}, {}
	end
	local keys = {}
	for id in visible do
		table.insert(keys, id)
	end
	table.sort(keys)
	local friendKeys = {}
	for id in friends do
		table.insert(friendKeys, id)
	end
	table.sort(friendKeys)
	local sig = `{country or ""}|{table.concat(keys, ",")}|{table.concat(friendKeys, ",")}`
	if sig == signature and not force then
		return
	end
	signature = sig
	RegionView.setFog(if country then visible else nil)
	for _, listener in listeners do
		task.spawn(listener)
	end
end

-- Pays dirigé (nil : plus de brouillard, tout est visible)
function Fog.setCountry(countryId: string?)
	country = countryId
	update(true)
end

function Fog.isRegionVisible(regionId: string): boolean
	return country == nil or visible[regionId] == true
end

function Fog.isArmyVisible(army: Instance): boolean
	return country == nil or FogRules.armyVisible(army, visible, friends)
end

-- Appelé quand ce qui est visible change
function Fog.onChanged(listener: Listener)
	table.insert(listeners, listener)
end

function Fog.start()
	task.spawn(function()
		while true do
			task.wait(UPDATE_INTERVAL)
			update()
		end
	end)
end

return Fog
