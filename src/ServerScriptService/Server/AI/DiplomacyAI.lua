--!strict
-- IA des pays : diplomatie (voir DiplomacyService).
--   - répond aux propositions faites à un pays qu'elle dirige (alliance, paix), selon sa
--     personnalité (allianceWillingness, peaceWillingness), sa situation et sa mémoire ;
--   - propose des alliances (ennemi commun, menace à la frontière) et la paix (guerre qui
--     tourne mal ou qui dure) : actions de la famille « Diplomatie » pour CountryBrain ;
--   - se souvient des trahisons : un pays qui a quitté son bloc en pleine guerre n'est plus
--     digne de confiance.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Diplomacy = require(Config:WaitForChild("Diplomacy")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local CountryAssignment = require(Server:WaitForChild("Session"):WaitForChild("CountryAssignment"))
local DiplomacyService = require(Server:WaitForChild("Politics"):WaitForChild("DiplomacyService"))
local DiplomacyState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DiplomacyState")) :: any
local PersonalityService = require(script.Parent:WaitForChild("PersonalityService"))
local MilitaryAI = require(script.Parent:WaitForChild("MilitaryAI"))
local Stability = require(Server:WaitForChild("Politics"):WaitForChild("Stability"))
local BalanceService = require(Server:WaitForChild("Politics"):WaitForChild("BalanceService"))
local Politics = require(Config:WaitForChild("Politics")) :: any

export type Action = { kind: string, score: number, label: string, run: () -> boolean }

local DiplomacyAI = {}

local distrust: { [string]: { [string]: boolean } } = {} -- pays IA -> pays qui l'ont trahi
local lastProposalOf: { [string]: number } = {} -- dernière proposition d'alliance de chaque pays IA
local lastProposalTo: { [string]: number } = {} -- « De|A » -> heure de la proposition
local rng = Random.new()

local function set(list: { string }): { [string]: boolean }
	local result = {}
	for _, id in list do
		result[id] = true
	end
	return result
end

local function nameOf(countryId: string): string
	return if Countries[countryId] then Countries[countryId].name else countryId
end

-- Régions de départ de `countryId` qu'il a perdues, et régions prises à ses ennemis
local function warBalance(countryId: string, enemies: { [string]: boolean }): (number, number)
	local lost, won = 0, 0
	for regionId, region in Regions do
		local owner = RegionService.getOwner(regionId)
		if region.startOwner == countryId and owner ~= countryId then
			lost += 1
		elseif owner == countryId and enemies[region.startOwner] then
			won += 1
		end
	end
	return lost, won
end

-- Guerres qu'une alliance avec `other` ferait entrer : ennemis de son camp qu'on ne combat pas
local function newWars(countryId: string, other: string): number
	local mine = set(DiplomacyService.enemiesOf(countryId))
	local count = 0
	local theirs: { [string]: boolean } = {}
	for _, id in DiplomacyService.alliesOf(other) do
		for _, enemy in DiplomacyService.enemiesOf(id) do
			theirs[enemy] = true
		end
	end
	for _, enemy in DiplomacyService.enemiesOf(other) do
		theirs[enemy] = true
	end
	for enemy in theirs do
		if not mine[enemy] and enemy ~= countryId then
			count += 1
		end
	end
	return count
end

-- Pays exposé au leader : en guerre contre lui, ou voisin d'une de ses régions
local function exposedTo(countryId: string, leader: string): boolean
	if DiplomacyService.atWar(countryId, leader) then
		return true
	end
	for regionId, region in Regions do
		if RegionService.getOwner(regionId) == countryId then
			for _, link in region.neighbors do
				if RegionService.getOwner(link.region) == leader then
					return true
				end
			end
		end
	end
	return false
end

-- Envie de s'allier avec `other` (0 à 1 environ ; accepté au-dessus de 0,5)
local function allianceScore(countryId: string, other: string, P: any): number
	if distrust[countryId] and distrust[countryId][other] then
		return 0 -- il nous a trahis
	end
	local score = P.allianceWillingness
	local mine = set(DiplomacyService.enemiesOf(countryId))
	for _, enemy in DiplomacyService.enemiesOf(other) do
		if mine[enemy] then
			score += 0.35 -- ennemi commun
			break
		end
	end
	if MilitaryAI.worstDanger(countryId, P) > 1 then
		score += 0.2 -- menacé : il cherche des alliés
	end
	score -= 0.25 * newWars(countryId, other)
	-- réputation : on s'allie plus volontiers avec un pays qui tient parole
	score += (DiplomacyState.reputation(other) - 50) / 100 * 0.3
	-- coalition contre le leader de la partie
	local leader = BalanceService.leader()
	if leader and other == leader then
		score -= 0.2 -- personne ne veut renforcer le plus fort
	elseif leader and leader ~= countryId and exposedTo(countryId, leader) and exposedTo(other, leader) then
		score += Politics.balance.coalitionBonus
	end
	return score
end

-- Envie de faire la paix avec `enemy` (acceptée au-dessus de 0,5)
local function peaceScore(countryId: string, enemy: string, P: any): number
	local score = P.peaceWillingness
	local enemies = set(DiplomacyService.enemiesOf(countryId))
	local lost, won = warBalance(countryId, enemies)
	if lost > 0 then
		score += 0.25 -- la guerre tourne mal
	end
	if won > 0 then
		score -= 0.3 -- elle tourne bien : on continue
	end
	local since = DiplomacyService.warSince(countryId, enemy)
	if since and workspace:GetServerTimeNow() - since > P.longWar then
		score += 0.15
	end
	-- une guerre toute jeune : on laisse aux généraux le temps de préparer et lancer leurs offensives
	if since and workspace:GetServerTimeNow() - since < P.minWarDuration then
		score -= 0.35
	end
	if MilitaryAI.worstDanger(countryId, P) > 1 then
		score += 0.2
	end
	if Stability.get(countryId) < P.lowStabilityPeace then
		score += 0.3 -- la population ne veut plus de cette guerre
	end
	return score
end

-- Réponse de l'IA à une proposition faite à un pays qu'elle dirige
local function answer(proposal: Instance)
	local to = proposal:GetAttribute("A") :: string
	local from = proposal:GetAttribute("De") :: string
	if not CountryAssignment.isAIControlled(to) then
		return -- un joueur répondra lui-même
	end
	task.wait(rng:NextNumber(Diplomacy.answerDelay.min, Diplomacy.answerDelay.max))
	if not proposal.Parent or proposal:GetAttribute("Reponse") ~= nil or not CountryAssignment.isAIControlled(to) then
		return
	end
	local P = PersonalityService.settings(to)
	local score = if proposal:GetAttribute("Type") == "Alliance" then allianceScore(to, from, P) else peaceScore(to, from, P)
	DiplomacyService.respond(to, proposal.Name, score >= 0.5)
end

-- Actions diplomatiques possibles pour un pays IA (famille « Diplomatie »)
function DiplomacyAI.actions(countryId: string, P: any): { Action }
	local actions: { Action } = {}
	local now = time()

	-- la paix avec un ennemi, si la guerre tourne mal ou dure trop
	for _, enemy in DiplomacyService.enemiesOf(countryId) do
		local score = peaceScore(countryId, enemy, P)
		local key = `{countryId}|{enemy}`
		if score >= 0.6 and now - (lastProposalTo[key] or -math.huge) >= P.proposalRepeat then
			table.insert(actions, {
				kind = "Diplomatie",
				score = 0.4 + (score - 0.5),
				label = `propose la paix à {nameOf(enemy)}`,
				run = function(): boolean
					lastProposalTo[key] = time()
					return (DiplomacyService.propose(countryId, enemy, "Paix"))
				end,
			})
			break
		end
	end

	-- une alliance : avec un pays qui a le même ennemi, ou un voisin quand il est menacé
	if now - (lastProposalOf[countryId] or -math.huge) < P.proposalInterval then
		return actions
	end
	local myBloc = DiplomacyService.blocOf(countryId)
	if myBloc and #DiplomacyService.alliesOf(countryId) + 1 >= Diplomacy.maxBlocSize then
		return actions
	end
	local candidates: { [string]: boolean } = {}
	for regionId, region in Regions do
		if RegionService.getOwner(regionId) == countryId then
			for _, link in region.neighbors do
				local owner = RegionService.getOwner(link.region)
				if owner and owner ~= countryId then
					candidates[owner] = true
				end
			end
		end
	end
	for _, enemy in DiplomacyService.enemiesOf(countryId) do
		for _, other in DiplomacyService.enemiesOf(enemy) do
			if other ~= countryId then
				candidates[other] = true -- l'ennemi de mon ennemi
			end
		end
	end
	-- coalition : les autres voisins du leader, s'il nous menace aussi
	local leader = BalanceService.leader()
	if leader and leader ~= countryId and exposedTo(countryId, leader) then
		for regionId, region in Regions do
			if RegionService.getOwner(regionId) == leader then
				for _, link in region.neighbors do
					local owner = RegionService.getOwner(link.region)
					if owner and owner ~= countryId and owner ~= leader then
						candidates[owner] = true
					end
				end
			end
		end
	end
	local best: string? = nil
	local bestScore = 0.5
	for other in candidates do
		local otherBloc = DiplomacyService.blocOf(other)
		if DiplomacyService.areAllies(countryId, other) or DiplomacyService.atWar(countryId, other)
			or (myBloc and otherBloc) or now - (lastProposalTo[`{countryId}|{other}`] or -math.huge) < P.proposalRepeat then
			continue
		end
		local score = allianceScore(countryId, other, P)
		if score > bestScore then
			best, bestScore = other, score
		end
	end
	if best then
		local target = best :: string
		table.insert(actions, {
			kind = "Diplomatie",
			score = bestScore,
			label = `propose une alliance à {nameOf(target)}`,
			run = function(): boolean
				lastProposalOf[countryId] = time()
				lastProposalTo[`{countryId}|{target}`] = time()
				return (DiplomacyService.propose(countryId, target, "Alliance"))
			end,
		})
	end
	return actions
end

-- Nouvelle partie : l'IA oublie les trahisons et ses propositions
function DiplomacyAI.reset()
	table.clear(distrust)
	table.clear(lastProposalOf)
	table.clear(lastProposalTo)
end

-- À appeler au démarrage (après DiplomacyService.init)
function DiplomacyAI.start()
	DiplomacyService.onProposal(answer)
	DiplomacyService.onBetrayal(function(traitor: string, victims: { string })
		for _, victim in victims do
			distrust[victim] = distrust[victim] or {}
			distrust[victim][traitor] = true
		end
	end)
end

return DiplomacyAI
