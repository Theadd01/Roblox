--!strict
-- Profil persistant du joueur : progression du passe, Médailles, cosmétiques et repères.
-- L'état militaire/économique d'une partie n'est volontairement jamais sauvegardé ici.

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local BattlePass = require(Config:WaitForChild("BattlePass")) :: any
local Monetization = require(Config:WaitForChild("Monetization")) :: any

export type Bookmark = {
	x: number,
	z: number,
	distance: number,
}

export type Profile = {
	version: number,
	seasonId: string,
	xp: number,
	premium: boolean,
	medals: number,
	claimedFree: { [string]: boolean },
	claimedPremium: { [string]: boolean },
	unlocks: { [string]: boolean },
	equipped: { [string]: string },
	bookmarks: { [string]: Bookmark },
	receipts: { [string]: boolean },
	supportTotal: number,
}

export type Mode = "persistent" | "studio" | "unavailable"

local ProfileStore = {}

-- GetDataStore lève une erreur dans une place locale non publiée. La connexion est
-- donc créée paresseusement, uniquement lorsqu'une expérience publiée peut persister.
local dataStore: any = nil
local dataStoreError: any = nil
local profiles: { [Player]: Profile } = {}
local modes: { [Player]: Mode } = {}
local loading: { [Player]: boolean } = {}
local revisions: { [Player]: number } = {}
local generations: { [Player]: number } = {}
local operationLocks: { [Player]: boolean } = {}

local function finiteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function persistentStore(): any?
	if dataStore then
		return dataStore
	end
	if game.GameId == 0 then
		return nil
	end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(Monetization.profileStoreName)
	end)
	if ok then
		dataStore = result
		dataStoreError = nil
		return dataStore
	end
	dataStoreError = result
	return nil
end

local function lockOperation(player: Player)
	while operationLocks[player] do
		task.wait()
	end
	operationLocks[player] = true
end

local function unlockOperation(player: Player)
	operationLocks[player] = nil
end

local function defaultProfile(): Profile
	return {
		version = 1,
		seasonId = BattlePass.season.id,
		xp = 0,
		premium = false,
		medals = 0,
		claimedFree = {},
		claimedPremium = {},
		unlocks = {},
		equipped = {},
		bookmarks = {},
		receipts = {},
		supportTotal = 0,
	}
end

local function boolDictionary(value: any): { [string]: boolean }
	local result: { [string]: boolean } = {}
	if typeof(value) == "table" then
		for key, owned in value do
			if typeof(key) == "string" and owned == true then
				result[key] = true
			end
		end
	end
	return result
end

local function stringDictionary(value: any): { [string]: string }
	local result: { [string]: string } = {}
	if typeof(value) == "table" then
		for key, selected in value do
			if typeof(key) == "string" and typeof(selected) == "string" then
				result[key] = selected
			end
		end
	end
	return result
end

local function bookmarks(value: any): { [string]: Bookmark }
	local result: { [string]: Bookmark } = {}
	if typeof(value) ~= "table" then
		return result
	end
	local count = 0
	for slot, entry in value do
		if typeof(entry) == "table"
			and typeof(slot) == "string"
			and finiteNumber(entry.x)
			and finiteNumber(entry.z)
			and finiteNumber(entry.distance)
		then
			result[slot] = {
				x = entry.x,
				z = entry.z,
				distance = entry.distance,
			}
			count += 1
		end
		if count >= 12 then
			break
		end
	end
	return result
end

local function normalize(raw: any): Profile
	local profile = defaultProfile()
	if typeof(raw) ~= "table" then
		return profile
	end
	profile.version = if finiteNumber(raw.version) then math.max(1, math.floor(raw.version)) else 1
	profile.medals = if finiteNumber(raw.medals) then math.max(0, math.floor(raw.medals)) else 0
	profile.unlocks = boolDictionary(raw.unlocks)
	profile.equipped = stringDictionary(raw.equipped)
	profile.bookmarks = bookmarks(raw.bookmarks)
	profile.receipts = boolDictionary(raw.receipts)
	profile.supportTotal = if finiteNumber(raw.supportTotal) then math.max(0, math.floor(raw.supportTotal)) else 0

	-- Une nouvelle saison conserve l'inventaire et les repères, mais recommence la piste.
	if raw.seasonId == BattlePass.season.id then
		profile.seasonId = raw.seasonId
		profile.xp = if finiteNumber(raw.xp)
			then math.clamp(math.floor(raw.xp), 0, BattlePass.startXpForLevel(BattlePass.season.maxLevel))
			else 0
		profile.premium = raw.premium == true
		profile.claimedFree = boolDictionary(raw.claimedFree)
		profile.claimedPremium = boolDictionary(raw.claimedPremium)
	end
	return profile
end

local function copyProfile(profile: Profile): Profile
	return normalize(profile)
end

local function keyFor(player: Player): string
	return "Player_" .. player.UserId
end

function ProfileStore.load(player: Player): (Profile, Mode)
	if profiles[player] then
		return profiles[player], modes[player]
	end
	if loading[player] then
		while loading[player] and player.Parent do
			task.wait()
		end
		if profiles[player] then
			return profiles[player], modes[player]
		end
		return defaultProfile(), "unavailable"
	end
	local generation = (generations[player] or 0) + 1
	generations[player] = generation
	loading[player] = true
	local profile = defaultProfile()
	local mode: Mode = "studio"

	if game.GameId ~= 0 then
		local store = persistentStore()
		local ok, stored = pcall(function()
			if not store then
				error(dataStoreError or "DataStore indisponible")
			end
			return store:GetAsync(keyFor(player))
		end)
		if ok then
			profile = normalize(stored)
			mode = "persistent"
		elseif RunService:IsStudio() then
			warn("[ProfileStore] DataStore indisponible dans Studio, profil de session utilisé :", stored)
			mode = "studio"
		else
			warn("[ProfileStore] Chargement impossible pour", player.UserId, stored)
			mode = "unavailable"
		end
	end

	if generations[player] ~= generation or not player.Parent then
		if generations[player] == generation then
			loading[player] = nil
		end
		return profile, "unavailable"
	end
	profiles[player] = profile
	modes[player] = mode
	revisions[player] = 0
	loading[player] = nil
	return profile, mode
end

function ProfileStore.waitFor(player: Player, timeout: number?): Profile?
	if not profiles[player] and not loading[player] and player.Parent then
		ProfileStore.load(player)
	end
	local deadline = os.clock() + (timeout or 15)
	while loading[player] and os.clock() < deadline do
		task.wait()
	end
	return profiles[player]
end

function ProfileStore.get(player: Player): Profile?
	return profiles[player]
end

function ProfileStore.mode(player: Player): Mode?
	return modes[player]
end

function ProfileStore.mutate(player: Player, transform: (Profile) -> ()): Profile?
	local profile = profiles[player]
	if not profile then
		return nil
	end
	transform(profile)
	revisions[player] = (revisions[player] or 0) + 1
	return profile
end

function ProfileStore.save(player: Player): (boolean, string?)
	local profile = profiles[player]
	local mode = modes[player]
	if not profile then
		return false, "Profil non chargé."
	end
	if mode == "studio" then
		return true, nil
	elseif mode ~= "persistent" then
		return false, "Sauvegarde temporairement indisponible."
	end
	lockOperation(player)
	profile = profiles[player]
	mode = modes[player]
	if not profile or mode ~= "persistent" then
		unlockOperation(player)
		return false, "Profil non chargé."
	end
	local store = persistentStore()
	if not store then
		unlockOperation(player)
		return false, "Sauvegarde temporairement indisponible."
	end

	local snapshot = copyProfile(profile)
	local revision = revisions[player] or 0
	local ok, saved = pcall(function()
		return store:UpdateAsync(keyFor(player), function(old: any)
			local candidate = copyProfile(snapshot)
			local previous = normalize(old)
			-- Une ancienne session peut encore terminer un reçu pendant une téléportation.
			-- On ne supprime jamais ses marqueurs d'idempotence ni ses déblocages.
			for receipt in previous.receipts do
				candidate.receipts[receipt] = true
			end
			for unlock in previous.unlocks do
				candidate.unlocks[unlock] = true
			end
			candidate.premium = candidate.premium or previous.premium
			candidate.supportTotal = math.max(candidate.supportTotal, previous.supportTotal)
			return candidate
		end)
	end)
	if not ok then
		unlockOperation(player)
		warn("[ProfileStore] Sauvegarde impossible pour", player.UserId, saved)
		return false, "Sauvegarde temporairement indisponible."
	end
	if profiles[player] == profile and revisions[player] == revision then
		profiles[player] = normalize(saved)
	end
	unlockOperation(player)
	return true, nil
end

-- Le reçu et son attribution sont écrits dans la même UpdateAsync, afin qu'un reçu
-- rejoué sur deux serveurs ne puisse jamais être accordé deux fois.
function ProfileStore.processReceipt(
	player: Player,
	purchaseId: string,
	grant: (Profile) -> ()
): (boolean, Profile?)
	lockOperation(player)
	local profile = profiles[player]
	local mode = modes[player]
	if not profile then
		unlockOperation(player)
		return false, nil
	end

	if mode == "studio" then
		if not profile.receipts[purchaseId] then
			grant(profile)
			profile.receipts[purchaseId] = true
			revisions[player] = (revisions[player] or 0) + 1
		end
		unlockOperation(player)
		return true, profile
	elseif mode ~= "persistent" then
		unlockOperation(player)
		return false, nil
	end
	local store = persistentStore()
	if not store then
		unlockOperation(player)
		return false, nil
	end

	-- Le reçu est marqué et attribué dans une seule UpdateAsync. On ne sauvegarde pas
	-- un instantané juste avant : il pourrait effacer un reçu traité sur un autre serveur.
	local ok, updated = pcall(function()
		return store:UpdateAsync(keyFor(player), function(old: any)
			local data = normalize(old)
			if not data.receipts[purchaseId] then
				grant(data)
				data.receipts[purchaseId] = true
			end
			return data
		end)
	end)
	if not ok then
		unlockOperation(player)
		warn("[ProfileStore] Reçu non traité pour", player.UserId, updated)
		return false, nil
	end
	-- Conserve les progrès de la session qui ne sont pas encore autosauvegardés, tout
	-- en reflétant localement ce reçu une seule fois.
	if not profile.receipts[purchaseId] then
		grant(profile)
		profile.receipts[purchaseId] = true
		revisions[player] = (revisions[player] or 0) + 1
	end
	unlockOperation(player)
	return true, profile
end

function ProfileStore.release(player: Player)
	generations[player] = (generations[player] or 0) + 1
	while operationLocks[player] do
		task.wait()
	end
	profiles[player] = nil
	modes[player] = nil
	loading[player] = nil
	revisions[player] = nil
	generations[player] = nil
end

function ProfileStore.loadedPlayers(): { Player }
	local result = {}
	for player in profiles do
		table.insert(result, player)
	end
	return result
end

return ProfileStore
