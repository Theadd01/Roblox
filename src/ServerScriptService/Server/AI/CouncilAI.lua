--!strict
-- IA des pays : votes sur les propositions des joueurs (Conseil mondial : résolutions, événements,
-- trêves, paix ; cahier des charges v2, section 1). L'IA ne propose jamais rien : elle vote.
-- Probabilité de « oui » (shared/VoteRules, Config/Council) : affinité envers celui qui propose,
-- paiement offert, malus si elle gagne sa guerre, et son intérêt pour la résolution (alliés,
-- ennemis, pétrole, personnalité). Certains votes sont imposés (on ne vote pas des sanctions contre
-- soi-même). Elle peut se laisser convaincre par un joueur (lobbying).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Council = require(Config:WaitForChild("Council")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local RegionResources = require(Shared:WaitForChild("RegionResources")) :: any
local MilitaryMath = require(Shared:WaitForChild("MilitaryMath")) :: any
local VoteRules = require(Shared:WaitForChild("VoteRules")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local Stability = require(Server:WaitForChild("Politics"):WaitForChild("Stability"))
local PersonalityService = require(script.Parent:WaitForChild("PersonalityService"))

export type Resolution = { kind: string, target: string?, region: string?, event: string?, initiator: string? }

local CouncilAI = {}

local rng = Random.new()

local function chance(p: number): boolean
	return rng:NextNumber() < p
end

-- Régions gagnées sur ses ennemis moins régions de départ perdues (positif : il gagne sa guerre).
-- against : seulement contre ces pays (le camp de celui qui propose une trêve ou la paix)
function CouncilAI.winning(countryId: string, against: { [string]: boolean }?): number
	local enemies: { [string]: boolean } = against or {}
	if not against then
		for _, enemy in DiplomacyState.enemiesOf(countryId) do
			enemies[enemy] = true
		end
	end
	local won, lost = 0, 0
	for regionId, region in Regions do
		local owner = RegionService.getOwner(regionId)
		if owner == countryId and enemies[region.startOwner] then
			won += 1
		elseif region.startOwner == countryId and owner ~= countryId and owner ~= nil and (not against or enemies[owner]) then
			lost += 1
		end
	end
	return won - lost
end

local function oilUse(countryId: string): number
	local total = 0
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local armees = state and state:FindFirstChild("Armees")
	if armees then
		for _, army in armees:GetChildren() do
			if army:GetAttribute("Proprietaire") == countryId then
				total += MilitaryMath.upkeep(army).Petrole or 0
			end
		end
	end
	return total
end

local function oilProducer(countryId: string): boolean
	local production = RegionResources.countryProduction(countryId, RegionService.getOwner)
	return (production.Petrole or 0) >= 3
end

local function commonEnemy(a: string, b: string): boolean
	local mine: { [string]: boolean } = {}
	for _, enemy in DiplomacyState.enemiesOf(a) do
		mine[enemy] = true
	end
	for _, enemy in DiplomacyState.enemiesOf(b) do
		if mine[enemy] then
			return true
		end
	end
	return false
end

-- Intérêt d'un pays IA pour une proposition (-1 à 1), ou son vote imposé
function CouncilAI.interest(countryId: string, resolution: Resolution, leader: string?): (number, string?)
	local personality = PersonalityService.get(countryId)
	local P = PersonalityService.settings(countryId)
	local target = resolution.target
	local kind = resolution.kind
	if kind == "Sanctions" and target then
		if countryId == target or DiplomacyState.areAllies(countryId, target) then
			return 0, "Contre"
		end
		local value = 0
		if DiplomacyState.atWar(countryId, target) then
			value += 0.3
		end
		if target == leader then
			value += 0.15 -- se méfier du plus fort
		end
		if personality == "Commercant" then
			value -= 0.15 -- les sanctions gênent le commerce
		end
		return value, nil
	elseif kind == "AideHumanitaire" and target then
		if countryId == target then
			return 0, "Pour"
		end
		local value = if DiplomacyState.atWar(countryId, target) then -0.4 else 0.1
		if personality == "Agressif" then
			value -= 0.1
		end
		return value, nil
	elseif kind == "Reconnaissance" and target and resolution.region then
		local home = Regions[resolution.region].startOwner
		if countryId == target or DiplomacyState.areAllies(countryId, target) then
			return 0, "Pour"
		elseif countryId == home or DiplomacyState.areAllies(countryId, home) then
			return 0, "Contre"
		end
		local value = if DiplomacyState.atWar(countryId, target) then -0.3 else 0
		if personality == "Defensif" then
			value -= 0.15 -- les frontières ne se changent pas par la force
		end
		return value, nil
	elseif kind == "TaxePetrole" then
		if oilProducer(countryId) then
			return 0.3, nil -- producteur : le prix monte
		elseif oilUse(countryId) > 0 then
			return -0.3, nil -- ses armées roulent au pétrole
		end
		return 0, nil
	elseif kind == "CessezLeFeu" then
		local value = 0
		if #DiplomacyState.enemiesOf(countryId) > 0 and CouncilAI.winning(countryId) < 0 then
			value += 0.2 -- la guerre tourne mal
		end
		if personality == "Agressif" or personality == "Opportuniste" then
			value -= 0.15
		elseif personality == "Defensif" then
			value += 0.1
		end
		return value, nil
	elseif kind == "Treve" or kind == "Paix" then
		local value = (P.peaceWillingness or 0.45) - 0.45
		if Stability.get(countryId) < (P.lowStabilityPeace or 40) then
			value += 0.2 -- la population ne veut plus de cette guerre
		end
		return value, nil
	elseif kind == "Evenement" then
		local event = resolution.event
		if event == "CriseEnergetique" then
			return if oilProducer(countryId) then 0.25 elseif oilUse(countryId) > 0 then -0.2 else 0, nil
		elseif event == "Cyberattaque" or event == "Greve" then
			return -0.1, nil -- ses usines pourraient être touchées
		end
		return 0, nil
	end
	return 0, nil
end

-- Probabilité de « oui » d'un pays IA (et vote imposé éventuel)
function CouncilAI.chance(countryId: string, resolution: Resolution, offerValue: number, leader: string?): (number, string?)
	local interest, forced = CouncilAI.interest(countryId, resolution, leader)
	if forced then
		return if forced == "Pour" then 1 else 0, forced
	end
	local initiator = resolution.initiator
	local definition = Council.resolutions[resolution.kind]
	local war = definition ~= nil and definition.war == true
	local affinity = 0
	if initiator then
		affinity = VoteRules.affinity({
			relation = DiplomacyState.relation(countryId, initiator),
			reputation = DiplomacyState.reputation(initiator),
			commonEnemy = commonEnemy(countryId, initiator),
		})
	end
	-- trêve, paix : « il gagne sa guerre » contre le camp de celui qui propose
	local against: { [string]: boolean }? = nil
	if (resolution.kind == "Treve" or resolution.kind == "Paix") and initiator then
		local camp: { [string]: boolean } = { [initiator] = true }
		for _, ally in DiplomacyState.alliesOf(initiator) do
			camp[ally] = true
		end
		if camp[countryId] and resolution.target then
			-- un allié de celui qui propose : sa guerre, c'est contre le camp de la cible
			camp = { [resolution.target] = true }
			for _, ally in DiplomacyState.alliesOf(resolution.target) do
				camp[ally] = true
			end
		end
		against = camp
	end
	local p = VoteRules.chance({
		affinity = affinity,
		payment = offerValue,
		winning = CouncilAI.winning(countryId, against),
		war = war,
		interest = interest,
	})
	return p, nil
end

-- Vote d'un pays IA : « Pour » ou « Contre », et sa probabilité de « oui »
function CouncilAI.vote(countryId: string, resolution: Resolution, offerValue: number, leader: string?): (string, number)
	local p, forced = CouncilAI.chance(countryId, resolution, offerValue, leader)
	if forced then
		return forced, p
	end
	return if chance(p) then "Pour" else "Contre", p
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
