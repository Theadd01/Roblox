--!strict
-- IA de la course aux projets décisifs (Config/Projects) : pendant la phase finale, un pays IA
-- assez riche investit dans un projet (celui qu'il mène déjà, sinon le moins disputé), en achetant
-- au marché les matériaux qui lui manquent ; en guerre contre un pays qui mène un projet, il peut
-- saboter son chantier. Mêmes fonctions que les joueurs (ProjectService, MarketService).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Projects = require(Config:WaitForChild("Projects")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local ProjectState = require(Shared:WaitForChild("ProjectState")) :: any
local Economy = script.Parent.Parent:WaitForChild("Economy")
local Stocks = require(Economy:WaitForChild("Stocks"))
local MarketService = require(Economy:WaitForChild("MarketService"))
local ProjectService = require(Economy:WaitForChild("ProjectService"))

local CURRENCY: string = Resources.currency.id
local PRICE_MARGIN = 1.2 -- le prix monte pendant l'achat : on prévoit 20 % de plus

export type Action = { kind: string, score: number, label: string, run: () -> boolean }

local ProjectAI = {}

local function nameOf(countryId: string): string
	return if Countries[countryId] then Countries[countryId].name else countryId
end

-- Crédits nécessaires pour une étape (son coût en crédits + les matériaux qui manquent, au
-- prix du marché) et matériaux à acheter
local function stageBudget(countryId: string, cost: { [string]: number }): (number, { [string]: number })
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

-- Projet à faire avancer : celui qu'il mène, sinon le moins disputé encore ouvert
local function chooseProject(countryId: string): string?
	local current = ProjectState.projectOf(countryId)
	if current then
		return current
	end
	local best: string? = nil
	local fewest = math.huge
	for _, id in Projects.order do
		if not ProjectState.winner(id) then
			local racers = #ProjectState.racers(id)
			if racers < fewest then
				best, fewest = id, racers
			end
		end
	end
	return best
end

function ProjectAI.actions(countryId: string, P: any): { Action }
	local actions: { Action } = {}
	if not ProjectState.isOpen() then
		return actions
	end
	-- investir dans l'étape suivante
	local projectId = chooseProject(countryId)
	if projectId and not ProjectState.buildingUntil(projectId, countryId) then
		local project = Projects.list[projectId]
		local need, missing = stageBudget(countryId, project.stageCost)
		if Stocks.get(countryId, CURRENCY) - need >= Projects.aiReserve then
			local id = projectId
			local stages = ProjectState.stages(id, countryId)
			table.insert(actions, {
				kind = "Industrie",
				score = 0.5 + 0.1 * stages,
				label = `investit dans le projet {project.name} (étape {stages + 1}/{Projects.stages})`,
				run = function(): boolean
					for resourceId, amount in missing do
						if not MarketService.buy(countryId, resourceId, amount, nil) then
							return false
						end
					end
					return (ProjectService.invest(countryId, id))
				end,
			})
		end
	end
	-- saboter un ennemi qui mène un projet
	local reserve = P.creditReserve + (Projects.sabotage.cost[CURRENCY] or 0)
	if Stocks.get(countryId, CURRENCY) >= reserve then
		for _, enemy in DiplomacyState.enemiesOf(countryId) do
			local target = ProjectState.projectOf(enemy)
			if target then
				local stages = ProjectState.stages(target, enemy)
				table.insert(actions, {
					kind = "Attaque",
					score = 0.35 + 0.1 * stages,
					label = `sabote le projet {Projects.list[target].name} {FrenchNames.of(nameOf(enemy))}`,
					run = function(): boolean
						return (ProjectService.sabotage(countryId, target, enemy))
					end,
				})
				break -- un sabotage envisagé par tour suffit
			end
		end
	end
	return actions
end

return ProjectAI
