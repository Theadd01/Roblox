--!strict
-- Missions quotidiennes (Config/Missions) : les mêmes pour tous chaque jour UTC. Elles comptent les
-- actions du joueur dans le pays qu'il dirige (ventes, batailles, conquêtes, contrats, usines,
-- recrues, votes, objectifs, temps de jeu, classement, projets), d'une partie à l'autre.
-- Une mission finie donne de l'expérience de compte : celle du passe de saison
-- (server/Progression/BattlePassService, s'il est présent).
-- Publié pour le client dans Player.MissionsDuJour (attribut FinJour : heure UTC du changement) :
--   M1, M2... : Ordre, Texte, Valeur, But, XP, Faite. Sauvegarde : server/Data/MissionStore.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Missions = require(Shared:WaitForChild("Config"):WaitForChild("Missions")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local Server = script.Parent.Parent
local MissionStore = require(Server:WaitForChild("Data"):WaitForChild("MissionStore"))
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local BattleService = require(Server:WaitForChild("Military"):WaitForChild("BattleService"))
local ProjectService = require(Server:WaitForChild("Economy"):WaitForChild("ProjectService"))
local CountryAssignment = require(script.Parent:WaitForChild("CountryAssignment"))
local StatsService = require(script.Parent:WaitForChild("StatsService"))
local PlayStyle = require(script.Parent:WaitForChild("PlayStyle"))
local ObjectivesService = require(script.Parent:WaitForChild("ObjectivesService"))
local MatchService = require(script.Parent:WaitForChild("MatchService"))

type State = { record: MissionStore.Record, dirty: boolean, folder: Folder }

local DailyMissions = {}

local states: { [Player]: State } = {}
local battlePass: any = nil -- passe de saison (expérience de compte), s'il existe dans le jeu

-- Missions du jour : tirage fixé par le numéro du jour (le même pour tout le monde)
local function missionsOf(day: number): { any }
	local rng = Random.new(day)
	local pool = table.clone(Missions.pool)
	local chosen = {}
	for _ = 1, math.min(Missions.perDay, #pool) do
		table.insert(chosen, table.remove(pool, rng:NextInteger(1, #pool)))
	end
	return chosen
end

local function playerOf(countryId: string): Player?
	for _, player in Players:GetPlayers() do
		if CountryAssignment.getCountryOf(player) == countryId then
			return player
		end
	end
	return nil
end

-- Met à jour le dossier MissionsDuJour du joueur
local function publish(state: State)
	local folder = state.folder
	local record = state.record
	folder:SetAttribute("Jour", record.day)
	folder:SetAttribute("FinJour", (record.day + 1) * 86400)
	for i, mission in missionsOf(record.day) do
		local item = folder:FindFirstChild("M" .. i) or Instance.new("Folder")
		item.Name = "M" .. i
		item:SetAttribute("Ordre", i)
		item:SetAttribute("Id", mission.id)
		item:SetAttribute("Texte", (mission.text:gsub("{target}", tostring(mission.target))))
		item:SetAttribute("Valeur", math.min(record.progress[mission.id] or 0, mission.target))
		item:SetAttribute("But", mission.target)
		item:SetAttribute("XP", mission.xp)
		item:SetAttribute("Faite", record.done[mission.id] == true)
		item.Parent = folder
	end
end

local function grantXp(player: Player, amount: number)
	if not battlePass then
		return
	end
	local ok, err = pcall(battlePass.addXp, player, amount, "MissionDuJour")
	if not ok then
		warn(`[Missions] expérience non donnée à {player.Name} : {err}`)
	end
end

-- Ajoute `amount` au compteur `counter` d'un joueur ; une mission atteinte est terminée
local function add(player: Player, counter: string, amount: number)
	local state = states[player]
	if not state or amount <= 0 then
		return
	end
	local today = MissionStore.today()
	if state.record.day ~= today then
		-- minuit UTC pendant la session : nouvelles missions
		state.record = { day = today, progress = {}, done = {} }
		state.folder:ClearAllChildren()
	end
	local changed = false
	for _, mission in missionsOf(state.record.day) do
		if mission.counter == counter and not state.record.done[mission.id] then
			local value = math.min(mission.target, (state.record.progress[mission.id] or 0) + amount)
			state.record.progress[mission.id] = value
			changed = true
			if value >= mission.target then
				state.record.done[mission.id] = true
				grantXp(player, mission.xp)
			end
		end
	end
	if changed then
		state.dirty = true
		publish(state)
	end
end

local function addForCountry(countryId: string?, counter: string, amount: number)
	local player = if countryId then playerOf(countryId) else nil
	if player then
		add(player, counter, amount)
	end
end

local function save(player: Player)
	local state = states[player]
	if state and state.dirty then
		state.dirty = false
		if not MissionStore.save(player.UserId, state.record) then
			state.dirty = true -- on réessaiera
		end
	end
end

local function onPlayerAdded(player: Player)
	local folder = Instance.new("Folder")
	folder.Name = "MissionsDuJour"
	local record = MissionStore.load(player.UserId)
	if not player.Parent then
		return -- parti pendant le chargement
	end
	local state: State = { record = record, dirty = false, folder = folder }
	states[player] = state
	publish(state)
	folder.Parent = player
end

-- À appeler au démarrage (après MatchService.start et ProjectService.init)
function DailyMissions.start()
	-- passe de saison (ajouté au jeu à part) : l'expérience des missions s'y ajoute
	local progression = Server:FindFirstChild("Progression")
	local module = progression and progression:FindFirstChild("BattlePassService")
	if module then
		local ok, result = pcall(require, module)
		battlePass = if ok then result else nil
	end

	StatsService.onEvent(function(kind: string, countryId: string, a: number, b: number)
		if kind == "vente" then
			addForCountry(countryId, "sold", a)
			addForCountry(countryId, "saleCredits", b)
		elseif kind == "contrat" then
			addForCountry(countryId, "contracts", 1)
		end
	end)
	BattleService.onResult(function(result: string, attacker: string, defender: string)
		addForCountry(if result == "Victoire" then attacker else defender, "battlesWon", 1)
	end)
	RegionService.onOwnerChanged(function(_regionId: string, newOwner: string, oldOwner: string?, reason: string)
		if oldOwner and reason == "Conquete" then
			addForCountry(newOwner, "conquests", 1)
		end
	end)
	PlayStyle.onAction(function(countryId: string, action: string)
		if action == "ConstruireUsine" then
			addForCountry(countryId, "factories", 1)
		elseif action == "Recruter" then
			addForCountry(countryId, "recruits", 1)
		end
	end)
	ObjectivesService.onCompleted(function(countryId: string)
		addForCountry(countryId, "objectives", 1)
	end)
	ProjectService.onEvent(function(event: string, _projectId: string, countryId: string)
		if event == "Etape" then
			addForCountry(countryId, "projectStages", 1)
		end
	end)
	MatchService.onFinished(function(ranking: { any })
		for _, entry in ranking do
			if entry.rank <= 10 then
				addForCountry(entry.country, "top10", 1)
			end
		end
	end)
	-- votes au Conseil mondial : le premier vote de chaque séance compte
	local conseil = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Conseil")
	local votes = conseil:WaitForChild("Votes")
	local counted: { [string]: unknown } = {} -- pays -> séance déjà comptée (heure de fin du vote)
	votes.AttributeChanged:Connect(function(countryId: string)
		local session = conseil:GetAttribute("Fin")
		if votes:GetAttribute(countryId) ~= nil and counted[countryId] ~= session then
			counted[countryId] = session
			addForCountry(countryId, "votes", 1)
		end
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		save(player)
		states[player] = nil
	end)
	game:BindToClose(function()
		for player in states do
			save(player)
		end
	end)

	-- temps de jeu (une minute à la fois) et sauvegardes régulières
	task.spawn(function()
		local elapsed = 0
		while true do
			task.wait(60)
			elapsed += 60
			if MatchState.isRunning() then
				for _, player in Players:GetPlayers() do
					if CountryAssignment.getCountryOf(player) then
						add(player, "minutes", 1)
					end
				end
			end
			if elapsed >= Missions.saveInterval then
				elapsed = 0
				for player in states do
					task.spawn(save, player)
				end
			end
		end
	end)
end

return DailyMissions
