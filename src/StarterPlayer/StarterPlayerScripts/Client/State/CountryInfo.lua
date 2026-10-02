--!strict
-- Portrait d'un pays d'après l'état publié par le serveur : forces (miliciens, armées, usines),
-- territoire (régions conquises ou perdues), guerres en cours, points forts et points faibles.
-- Utilisé par la fiche du menu de choix du pays.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local Units = require(Config:WaitForChild("Units")) :: any
local CountrySelection = require(Config:WaitForChild("CountrySelection")) :: any
local CountryStats = require(Shared:WaitForChild("CountryStats")) :: any
local RegionResources = require(Shared:WaitForChild("RegionResources")) :: any
local RegionView = require(script.Parent.Parent:WaitForChild("Map"):WaitForChild("RegionView"))
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any

export type Forces = {
	divisions: number, -- divisions terrestres (SYSTEME_MILITAIRE.md)
	armies: { [string]: number }, -- forces par sorte (Terre, Air, Mer)
	troops: number,
	factories: number,
}

local CountryInfo = {}

local function children(name: string): { Instance }
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local folder = state and state:FindFirstChild(name)
	return if folder then folder:GetChildren() else {}
end

local function regionState(regionId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local regions = state and state:FindFirstChild("Regions")
	return regions and regions:FindFirstChild(regionId)
end

function CountryInfo.forces(countryId: string): Forces
	local divisions = 0
	for _, d in children("Divisions") do
		if d:GetAttribute("Proprietaire") == countryId then
			divisions += 1
		end
	end
	local armies: { [string]: number } = {}
	local troops = 0
	for _, army in children("Armees") do
		if army:GetAttribute("Proprietaire") == countryId then
			local kind = Units.kindOf(army)
			armies[kind] = (armies[kind] or 0) + 1
			for _, typeId in Units.kinds[kind].order do
				troops += (army:GetAttribute(typeId) :: number?) or 0
			end
		end
	end
	local factories = 0
	for _, factory in children("Usines") do
		if RegionView.getOwner(factory:GetAttribute("Region") :: string) == countryId then
			factories += 1
		end
	end
	return { divisions = divisions, armies = armies, troops = troops, factories = factories }
end

-- Nombre de régions, dont conquises, et régions de départ perdues
function CountryInfo.territory(countryId: string): (number, number, number)
	local owned, conquered, lost = 0, 0, 0
	for regionId, region in Regions do
		local owner = RegionView.getOwner(regionId)
		if owner == countryId then
			owned += 1
			if region.startOwner ~= countryId then
				conquered += 1
			end
		elseif region.startOwner == countryId then
			lost += 1
		end
	end
	return owned, conquered, lost
end

-- Pays avec qui il se bat : guerres déclarées, batailles en cours et forces en marche
function CountryInfo.wars(countryId: string): { string }
	local enemies: { [string]: boolean } = {}
	for _, enemy in DiplomacyState.enemiesOf(countryId) do
		enemies[enemy] = true
	end
	for _, battle in children("Batailles") do
		if battle:GetAttribute("Etat") == "EnCours" then
			local attacker, defender = battle:GetAttribute("Attaquant"), battle:GetAttribute("Defenseur")
			if attacker == countryId and typeof(defender) == "string" then
				enemies[defender] = true
			elseif defender == countryId and typeof(attacker) == "string" then
				enemies[attacker] = true
			end
		end
	end
	for _, army in children("Armees") do
		local owner = army:GetAttribute("Proprietaire")
		local destination = army:GetAttribute("Destination")
		if typeof(owner) == "string" and typeof(destination) == "string" and destination ~= "" then
			local target = RegionView.getOwner(destination)
			if owner == countryId and target and target ~= countryId then
				enemies[target] = true
			elseif target == countryId and owner ~= countryId then
				enemies[owner] = true
			end
		end
	end
	local list = {}
	for id in enemies do
		table.insert(list, id)
	end
	table.sort(list)
	return list
end

-- Points forts et points faibles (production, taille, accès à la mer)
function CountryInfo.traits(countryId: string): ({ string }, { string })
	local T = CountrySelection.traits
	local production = RegionResources.countryProduction(countryId, RegionView.getOwner)
	local strengths, weaknesses = {}, {}
	for _, rule in T.strengths do
		if (production[rule.resource] or 0) >= rule.min then
			table.insert(strengths, rule.text)
		end
	end
	local iron, coal = production.MineraiFer or 0, production.Charbon or 0
	if iron > 0 and coal > 0 then
		table.insert(strengths, T.steel)
	elseif iron == 0 and coal == 0 then
		table.insert(weaknesses, T.noSteel)
	end
	for _, rule in T.weaknesses do
		if (production[rule.resource] or 0) <= rule.max then
			table.insert(weaknesses, rule.text)
		end
	end
	local area = CountryStats.area(countryId)
	if area >= CountrySelection.easyArea then
		table.insert(strengths, T.large)
	elseif area < CountrySelection.mediumArea then
		table.insert(weaknesses, T.small)
	end
	local port = false
	for regionId, region in Regions do
		if region.port and RegionView.getOwner(regionId) == countryId then
			port = true
			break
		end
	end
	if not port then
		table.insert(weaknesses, T.noPort)
	end
	return strengths, weaknesses
end

return CountryInfo
