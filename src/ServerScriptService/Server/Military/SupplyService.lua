--!strict
-- Ravitaillement et moral des forces, à chaque cycle de production :
--   1. entretien : chaque unité consomme des ressources (Units.types[...].upkeep) dans les stocks
--      de son pays ; si une ressource manque, les forces qui en ont besoin sont en pénurie ;
--   2. ravitaillement : une armée de terre est ravitaillée en territoire ami ou allié, ou juste à côté
--      (région voisine par la terre d'une telle région), et s'il n'y a pas de pénurie ;
--      l'aviation et la marine se ravitaillent à leurs bases (seule la pénurie compte) ;
--   3. moral : il remonte au repos si la force est ravitaillée, il baisse sinon ;
--   4. repli automatique : une force démoralisée en territoire étranger recule d'elle-même
--      (sauf ordre « Tenir la position »).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Combat = require(Config:WaitForChild("Combat")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local Units = require(Config:WaitForChild("Units")) :: any
local MilitaryMath = require(Shared:WaitForChild("MilitaryMath")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local Stocks = require(Server:WaitForChild("Economy"):WaitForChild("Stocks"))
local ArmyService = require(script.Parent:WaitForChild("ArmyService"))
local DiplomacyService = require(Server:WaitForChild("Politics"):WaitForChild("DiplomacyService"))

local SupplyService = {}

local function forces(): { Instance }
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local armees = state and state:FindFirstChild("Armees")
	return if armees then armees:GetChildren() else {}
end

-- Région du pays ou d'un de ses alliés
local function friendly(regionId: string, countryId: string): boolean
	local owner = RegionService.getOwner(regionId)
	return owner == countryId or (owner ~= nil and DiplomacyService.areAllies(owner, countryId))
end

-- Territoire ami ou allié, ou région voisine (par la terre) d'une telle région
local function inSupplyRange(regionId: string, countryId: string): boolean
	if friendly(regionId, countryId) then
		return true
	end
	local region = Regions[regionId]
	if region then
		for _, link in region.neighbors do
			if not link.bySea and friendly(link.region, countryId) then
				return true
			end
		end
	end
	return false
end

function SupplyService.tick()
	local all = forces()

	-- 1. entretien, payé pays par pays
	local needs: { [string]: { [string]: number } } = {}
	for _, army in all do
		local countryId = army:GetAttribute("Proprietaire") :: string
		local need = needs[countryId] or {}
		needs[countryId] = need
		for resourceId, amount in MilitaryMath.upkeep(army) do
			need[resourceId] = (need[resourceId] or 0) + amount
		end
	end
	local shortages: { [string]: { [string]: boolean } } = {}
	for countryId, need in needs do
		shortages[countryId] = {}
		for resourceId, amount in need do
			local have = Stocks.get(countryId, resourceId)
			if have >= amount then
				Stocks.add(countryId, resourceId, -amount)
			else
				Stocks.add(countryId, resourceId, -have)
				shortages[countryId][resourceId] = true
			end
		end
	end

	-- 2 à 4. ravitaillement, moral et repli de chaque force
	local M = Combat.morale
	for _, army in all do
		if not army.Parent then
			continue
		end
		local countryId = army:GetAttribute("Proprietaire") :: string
		local here = army:GetAttribute("Region") :: string
		local kind = Units.kindOf(army)
		local inRange = kind ~= "Terre" or inSupplyRange(here, countryId)
		local lacking = {}
		for resourceId in MilitaryMath.upkeep(army) do
			if shortages[countryId] and shortages[countryId][resourceId] then
				table.insert(lacking, Resources.list[resourceId].name)
			end
		end
		table.sort(lacking)
		local supplied = inRange and #lacking == 0
		army:SetAttribute("Ravitaillee", supplied)
		army:SetAttribute("HorsDePortee", not inRange)
		army:SetAttribute("Penurie", table.concat(lacking, ", "))

		local fighting = army:GetAttribute("EnCombat") ~= nil
		local moving = army:GetAttribute("Destination") ~= ""
		local home = RegionService.getOwner(here) == countryId
		if not fighting then
			local delta = if not supplied then -M.unsupplied elseif moving then 0 elseif home then M.restHome else M.restAway
			army:SetAttribute("Moral", math.clamp(MilitaryMath.morale(army) + delta, 0, 100))
		end

		-- repli automatique d'une force démoralisée hors de chez elle
		if not fighting and not moving and not home and MilitaryMath.morale(army) < M.retreatBelow
			and army:GetAttribute("Posture") ~= "Tenir" then
			ArmyService.retreat(army)
		end
	end
end

return SupplyService
