--!strict
-- IA des pays sans joueur : chaque pays qui n'a pas de joueur et possède au moins une région
-- joue un tour toutes les AI.turnInterval secondes (voir CountryBrain).
-- Les pays jouent l'un après l'autre, dans un ordre mélangé : les décisions sont réparties
-- sur tout l'intervalle, jamais toutes en même temps.
-- Un joueur qui prend un pays arrête son IA ; s'il part ou s'absente, l'IA reprend au passage suivant.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local AI = require(Config:WaitForChild("AI")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local CountryAssignment = require(Server:WaitForChild("Session"):WaitForChild("CountryAssignment"))
local CountryBrain = require(script.Parent:WaitForChild("CountryBrain"))
local PersonalityService = require(script.Parent:WaitForChild("PersonalityService"))
local DiplomacyAI = require(script.Parent:WaitForChild("DiplomacyAI"))
local TradeAI = require(script.Parent:WaitForChild("TradeAI"))
local MilitaryAI = require(script.Parent:WaitForChild("MilitaryAI"))
local MatchState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MatchState")) :: any

local AIService = {}

local rng = Random.new()

-- Vrai si le pays est géré par l'IA en ce moment (pas de joueur, ou joueur absent)
function AIService.isAIControlled(countryId: string): boolean
	return CountryAssignment.isAIControlled(countryId)
end

-- Pays à faire jouer : sans joueur et avec au moins une région, dans un ordre mélangé
local function aiCountries(): { string }
	local list = {}
	local seen: { [string]: boolean } = {}
	for regionId in Regions do
		local owner = RegionService.getOwner(regionId)
		if owner and not seen[owner] and AIService.isAIControlled(owner) then
			seen[owner] = true
			table.insert(list, owner)
		end
	end
	for i = #list, 2, -1 do
		local j = rng:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

-- Nouvelle partie : nouvelles personnalités, mémoire de l'IA effacée
function AIService.reset()
	PersonalityService.assign()
	DiplomacyAI.reset()
	TradeAI.reset()
	MilitaryAI.reset()
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	for _, folder in (if pays then pays:GetChildren() else {}) do
		folder:SetAttribute("DecisionIA", nil)
	end
end

-- À appeler au démarrage du serveur, après les services de l'économie
function AIService.start()
	-- chaque pays reçoit sa personnalité dès le début (visible dans la fiche région)
	PersonalityService.assign()
	DiplomacyAI.start() -- l'IA répond aux propositions d'alliance et de paix
	TradeAI.start() -- ... et aux contrats commerciaux
	task.spawn(function()
		task.wait(AI.startDelay)
		while true do
			local list = if MatchState.isRunning() then aiCountries() else {}
			if #list == 0 then
				task.wait(AI.turnInterval)
				continue
			end
			local pause = AI.turnInterval / #list
			for _, countryId in list do
				-- un joueur a pu prendre le pays depuis le début du passage (ou la partie finir)
				if AIService.isAIControlled(countryId) and MatchState.isRunning() then
					local begin = os.clock()
					local ok, err = pcall(CountryBrain.turn, countryId)
					if not ok then
						warn(`[IA] tour de {countryId} : {err}`)
					end
					-- dans Studio : le tour le plus long (ms), dans ServerStorage.PerfMilitaire
					if RunService:IsStudio() then
						local perf = game:GetService("ServerStorage"):FindFirstChild("PerfMilitaire")
						local ms = (os.clock() - begin) * 1000
						if perf and ms > ((perf:GetAttribute("ia_tour") :: number?) or 0) then
							perf:SetAttribute("ia_tour", math.floor(ms * 10 + 0.5) / 10)
							perf:SetAttribute("ia_tour_pays", countryId)
						end
					end
				end
				task.wait(pause)
			end
		end
	end)
end

return AIService
