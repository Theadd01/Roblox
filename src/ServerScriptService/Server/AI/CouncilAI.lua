--!strict
-- IA des pays : votes au Conseil mondial. Chaque pays IA vote selon son intérêt (alliés,
-- ennemis, pétrole, personnalité), avec une part de hasard ; il peut se laisser convaincre
-- par un joueur (lobbying), sauf si cela va contre ses alliés ou si le joueur est son ennemi.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Council = require(Config:WaitForChild("Council")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local RegionResources = require(Shared:WaitForChild("RegionResources")) :: any
local MilitaryMath = require(Shared:WaitForChild("MilitaryMath")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local PersonalityService = require(script.Parent:WaitForChild("PersonalityService"))

export type Resolution = { kind: string, target: string?, region: string? }

local CouncilAI = {}

local rng = Random.new()

local function chance(p: number): boolean
	return rng:NextNumber() < p
end

local function lostRegions(countryId: string): number
	local lost = 0
	for regionId, region in Regions do
		if region.startOwner == countryId and RegionService.getOwner(regionId) ~= countryId then
			lost += 1
		end
	end
	return lost
end

local function oilUse(countryId: string): number
	local total = 0
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local armees = state and state:FindFirstChild("Armees")
	for _, army in (if armees then armees:GetChildren() else {}) do
		if army:GetAttribute("Proprietaire") == countryId then
			total += MilitaryMath.upkeep(army).Petrole or 0
		end
	end
	return total
end

-- Vote d'un pays IA : « Pour », « Contre » ou « Abstention »
function CouncilAI.vote(countryId: string, resolution: Resolution, leader: string?): string
	local personality = PersonalityService.get(countryId)
	local target = resolution.target
	local kind = resolution.kind
	if kind == "Sanctions" and target then
		if countryId == target or DiplomacyState.areAllies(countryId, target) then
			return "Contre"
		elseif DiplomacyState.atWar(countryId, target) then
			return "Pour"
		elseif target == leader and chance(0.7) then
			return "Pour" -- se méfier du plus fort
		elseif personality == "Commercant" then
			return if chance(0.6) then "Contre" else "Abstention" -- les sanctions gênent le commerce
		end
		return if chance(0.55) then "Pour" elseif chance(0.5) then "Contre" else "Abstention"
	elseif kind == "CessezLeFeu" then
		local atWar = #DiplomacyState.enemiesOf(countryId) > 0
		if atWar then
			return if lostRegions(countryId) > 0 then "Pour" else (if personality == "Agressif" then "Contre" else "Abstention")
		end
		if personality == "Agressif" or personality == "Opportuniste" then
			return if chance(0.6) then "Contre" else "Abstention"
		end
		return if chance(0.75) then "Pour" else "Abstention"
	elseif kind == "TaxePetrole" then
		local production = RegionResources.countryProduction(countryId, RegionService.getOwner)
		if (production.Petrole or 0) >= 3 then
			return "Pour" -- producteur : le prix monte
		elseif oilUse(countryId) > 0 then
			return "Contre" -- ses blindés roulent au pétrole
		end
		return if chance(0.5) then "Abstention" elseif chance(0.5) then "Pour" else "Contre"
	elseif kind == "Reconnaissance" and target and resolution.region then
		local home = Regions[resolution.region].startOwner
		if countryId == target or DiplomacyState.areAllies(countryId, target) then
			return "Pour"
		elseif countryId == home or DiplomacyState.areAllies(countryId, home) or DiplomacyState.atWar(countryId, target) then
			return "Contre"
		elseif personality == "Defensif" then
			return if chance(0.6) then "Contre" else "Abstention" -- les frontières ne se changent pas par la force
		end
		return if chance(0.4) then "Pour" elseif chance(0.5) then "Contre" else "Abstention"
	elseif kind == "AideHumanitaire" and target then
		if countryId == target then
			return "Pour"
		elseif DiplomacyState.atWar(countryId, target) then
			return "Contre"
		elseif personality == "Agressif" then
			return "Abstention"
		end
		return if chance(0.75) then "Pour" else "Abstention"
	end
	return "Abstention"
end

-- Le pays IA accepte-t-il de voter `wanted` à la demande de `lobbyist` ?
function CouncilAI.acceptsLobby(countryId: string, lobbyist: string, wanted: string, resolution: Resolution): boolean
	local target = resolution.target
	if countryId == target or DiplomacyState.atWar(countryId, lobbyist) then
		return false
	end
	if target and resolution.kind == "Sanctions" and wanted == "Pour" and DiplomacyState.areAllies(countryId, target) then
		return false -- ne sanctionne pas un allié
	end
	if DiplomacyState.areAllies(countryId, lobbyist) then
		return true -- un allié rend service
	end
	-- une bonne réputation aide à convaincre
	return chance(Council.lobbyChance * (0.5 + DiplomacyState.reputation(lobbyist) / 100))
end

return CouncilAI
