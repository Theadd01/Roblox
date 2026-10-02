--!strict
-- Détection des succès (Config/Achievements) : écoute la partie (contrats, conquêtes, usines,
-- batailles, crédits, blocs, projets décisifs, soulèvements, classement final) et débloque le succès
-- du joueur qui dirige le pays concerné (AccountService.unlock). Enregistre aussi chaque partie
-- finie dans son compte (AccountService.recordGame).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Achievements = require(Config:WaitForChild("Achievements")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local BattleService = require(Server:WaitForChild("Military"):WaitForChild("BattleService"))
local ProjectService = require(Server:WaitForChild("Economy"):WaitForChild("ProjectService"))
local Stocks = require(Server:WaitForChild("Economy"):WaitForChild("Stocks"))
local CountryAssignment = require(script.Parent:WaitForChild("CountryAssignment"))
local StatsService = require(script.Parent:WaitForChild("StatsService"))
local PlayStyle = require(script.Parent:WaitForChild("PlayStyle"))
local MatchService = require(script.Parent:WaitForChild("MatchService"))
local AccountService = require(script.Parent:WaitForChild("AccountService"))

local CHECK_INTERVAL = 10 -- secondes entre deux vérifications (crédits, taille du bloc)

local AchievementsService = {}

-- compteurs de la partie en cours, par joueur (remis à zéro à chaque nouvelle partie)
local counters: { [Player]: { factories: number, battles: number } } = {}
local counterGame = 0

local function playerOf(countryId: string?): Player?
	if not countryId then
		return nil
	end
	for _, player in Players:GetPlayers() do
		if CountryAssignment.getCountryOf(player) == countryId then
			return player
		end
	end
	return nil
end

local function countersOf(player: Player): { factories: number, battles: number }
	if counterGame ~= MatchState.number() then
		counterGame = MatchState.number()
		table.clear(counters)
	end
	local c = counters[player]
	if not c then
		c = { factories = 0, battles = 0 }
		counters[player] = c
	end
	return c
end

local function unlockFor(countryId: string?, id: string)
	local player = playerOf(countryId)
	if player then
		AccountService.unlock(player, id)
	end
end

function AchievementsService.start()
	StatsService.onEvent(function(kind: string, countryId: string)
		if kind == "contrat" then
			unlockFor(countryId, "PremierContrat")
		end
	end)
	RegionService.onOwnerChanged(function(_regionId: string, newOwner: string, oldOwner: string?, reason: string)
		if oldOwner and reason == "Conquete" then
			unlockFor(newOwner, "PremiereConquete")
		elseif reason == "Soulevement" then
			unlockFor(newOwner, "Liberateur")
		end
	end)
	PlayStyle.onAction(function(countryId: string, action: string)
		local player = if action == "ConstruireUsine" then playerOf(countryId) else nil
		if player then
			local c = countersOf(player)
			c.factories += 1
			if c.factories >= Achievements.factories then
				AccountService.unlock(player, "Batisseur")
			end
		end
	end)
	BattleService.onResult(function(result: string, attacker: string, defender: string)
		local player = playerOf(if result == "Victoire" then attacker else defender)
		if player then
			local c = countersOf(player)
			c.battles += 1
			if c.battles >= Achievements.battles then
				AccountService.unlock(player, "ChefDeGuerre")
			end
		end
	end)
	ProjectService.onEvent(function(event: string, _projectId: string, countryId: string)
		if event == "Termine" then
			unlockFor(countryId, "Visionnaire")
		end
	end)
	MatchService.onFinished(function(ranking: { any })
		for _, entry in ranking do
			local player = playerOf(entry.country)
			if player then
				AccountService.recordGame(player, entry.rank)
				if entry.rank <= 3 then
					AccountService.unlock(player, "Podium")
				end
				if entry.rank == 1 then
					AccountService.unlock(player, "Vainqueur")
					if StatsService.get(entry.country).regionsLost == 0 then
						AccountService.unlock(player, "SansPerte")
					end
				end
				local account = AccountService.get(player)
				if account and account.games >= Achievements.games then
					AccountService.unlock(player, "Fidele")
				end
			end
		end
	end)
	-- crédits et taille du bloc, vérifiés régulièrement
	task.spawn(function()
		while true do
			task.wait(CHECK_INTERVAL)
			for _, player in Players:GetPlayers() do
				local countryId = CountryAssignment.getCountryOf(player)
				if countryId then
					if Stocks.get(countryId, Resources.currency.id) >= Achievements.credits then
						AccountService.unlock(player, "Magnat")
					end
					local bloc = DiplomacyState.blocOf(countryId)
					if bloc and #DiplomacyState.members(bloc) >= Achievements.blocSize then
						AccountService.unlock(player, "Diplomate")
					end
				end
			end
		end
	end)
end

return AchievementsService
