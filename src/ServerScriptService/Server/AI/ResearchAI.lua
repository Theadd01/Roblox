--!strict
-- IA de la recherche (Config/Technologies) : un pays IA sans recherche en cours lance la première
-- technologie disponible de ses branches préférées (selon sa personnalité), s'il peut la payer en
-- gardant une réserve ; il achète au marché les matériaux qui lui manquent.
-- Mêmes fonctions que les joueurs (ResearchService, MarketService).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Technologies = require(Config:WaitForChild("Technologies")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local TechState = require(Shared:WaitForChild("TechState")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local Economy = script.Parent.Parent:WaitForChild("Economy")
local Stocks = require(Economy:WaitForChild("Stocks"))
local MarketService = require(Economy:WaitForChild("MarketService"))
local ResearchService = require(Economy:WaitForChild("ResearchService"))
local PersonalityService = require(script.Parent:WaitForChild("PersonalityService"))

local CURRENCY: string = Resources.currency.id
local PRICE_MARGIN = 1.2 -- le prix monte pendant l'achat : on prévoit 20 % de plus
local EXTRA_RESERVE = 300 -- crédits gardés en plus de la réserve habituelle

-- Branches préférées selon la personnalité
local PREFERENCES: { [string]: { string } } = {
	Agressif = { "Militaire", "Economie", "Renseignement" },
	Opportuniste = { "Militaire", "Renseignement", "Economie" },
	Industriel = { "Economie", "Militaire", "Renseignement" },
	Commercant = { "Economie", "Renseignement", "Militaire" },
	Defensif = { "Renseignement", "Militaire", "Economie" },
}
local DEFAULT = { "Economie", "Militaire", "Renseignement" }

export type Action = { kind: string, score: number, label: string, run: () -> boolean }

local ResearchAI = {}

-- Crédits nécessaires (coût en crédits + matériaux manquants au prix du marché) et achats à faire
local function budgetFor(countryId: string, cost: { [string]: number }): (number, { [string]: number })
	local credits = cost[CURRENCY] or 0
	local missing: { [string]: number } = {}
	for id, amount in cost do
		if id ~= CURRENCY then
			local lack = amount - Stocks.get(countryId, id)
			if lack > 0 then
				missing[id] = lack
				credits += lack * (MarketService.price(id) or math.huge) * PRICE_MARGIN
			end
		end
	end
	return credits, missing
end

local function choose(countryId: string): any?
	local order = PREFERENCES[PersonalityService.get(countryId) or ""] or DEFAULT
	for _, branch in order do
		for _, tech in Technologies.list do
			if tech.branch == branch and TechState.available(countryId, tech.id) then
				return tech
			end
		end
	end
	return nil
end

function ResearchAI.actions(countryId: string, P: any): { Action }
	local actions: { Action } = {}
	if not MatchState.isRunning() or TechState.research(countryId) then
		return actions
	end
	local tech = choose(countryId)
	if not tech then
		return actions
	end
	local need, missing = budgetFor(countryId, tech.cost)
	if Stocks.get(countryId, CURRENCY) - need < P.creditReserve + EXTRA_RESERVE then
		return actions
	end
	local techId = tech.id
	table.insert(actions, {
		kind = "Industrie",
		score = 0.38,
		label = `lance la recherche {tech.icon} {tech.name}`,
		run = function(): boolean
			for resourceId, amount in missing do
				if not MarketService.buy(countryId, resourceId, amount, nil) then
					return false
				end
			end
			return (ResearchService.research(countryId, techId))
		end,
	})
	return actions
end

return ResearchAI
