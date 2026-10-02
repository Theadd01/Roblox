--!strict
-- Un tour de l'IA pour un pays : rassemble les actions possibles (économie, armées, diplomatie,
-- commerce, projets décisifs, recherche),
-- pondère leur score selon la personnalité du pays, les classe et exécute les meilleures
-- (actionsPerTurn au plus, et maxPerKind par famille : le commerce ne prend pas toute la place).
-- La décision est publiée dans l'attribut « DecisionIA » de EtatMonde.Pays.<code>.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyAI = require(script.Parent:WaitForChild("EconomyAI"))
local MilitaryAI = require(script.Parent:WaitForChild("MilitaryAI"))
local PersonalityService = require(script.Parent:WaitForChild("PersonalityService"))
local DiplomacyAI = require(script.Parent:WaitForChild("DiplomacyAI"))
local TradeAI = require(script.Parent:WaitForChild("TradeAI"))
local ProjectAI = require(script.Parent:WaitForChild("ProjectAI"))
local ResearchAI = require(script.Parent:WaitForChild("ResearchAI"))

local CountryBrain = {}

type Profile = { sellFloor: number, buyCeiling: number, reserveCeiling: number }

local rng = Random.new()

-- Prix acceptés à ce tour, tirés au hasard entre les bornes des réglages du pays : chaque pays
-- vend ou achète tantôt plus, tantôt moins cher, et tous ont leur chance sur le marché
local function drawProfile(P: any): Profile
	return {
		sellFloor = rng:NextNumber(P.sellFloor.min, P.sellFloor.max),
		buyCeiling = rng:NextNumber(P.buyCeiling.min, P.buyCeiling.max),
		reserveCeiling = rng:NextNumber(P.reserveCeiling.min, P.reserveCeiling.max),
	}
end

local function publish(countryId: string, text: string)
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	local folder = pays and pays:FindFirstChild(countryId)
	if folder then
		folder:SetAttribute("DecisionIA", text)
	end
end

-- Joue un tour pour `countryId` ; renvoie les décisions prises
function CountryBrain.turn(countryId: string): { string }
	local P = PersonalityService.settings(countryId)
	local weights = PersonalityService.weights(countryId)
	MilitaryAI.housekeeping(countryId)
	local actions = EconomyAI.actions(countryId, drawProfile(P), P)
	for _, action in MilitaryAI.actions(countryId, P) do
		table.insert(actions, action)
	end
	for _, action in DiplomacyAI.actions(countryId, P) do
		table.insert(actions, action)
	end
	for _, action in TradeAI.actions(countryId, P) do
		table.insert(actions, action)
	end
	for _, action in ProjectAI.actions(countryId, P) do -- course aux projets décisifs (fin de partie)
		table.insert(actions, action)
	end
	for _, action in ResearchAI.actions(countryId, P) do -- arbre technologique
		table.insert(actions, action)
	end
	for _, action in actions do
		action.score *= weights[action.kind] or 1
	end
	table.sort(actions, function(a, b)
		return a.score > b.score
	end)
	local done = {}
	local perKind: { [string]: number } = {}
	for _, action in actions do
		if #done >= P.actionsPerTurn or action.score < P.minScore then
			break
		end
		if (perKind[action.kind] or 0) < (P.maxPerKind[action.kind] or P.actionsPerTurn) and action.run() then
			perKind[action.kind] = (perKind[action.kind] or 0) + 1
			table.insert(done, action.label)
		end
	end
	if #done > 0 then
		publish(countryId, table.concat(done, ", "))
	end
	return done
end

return CountryBrain
