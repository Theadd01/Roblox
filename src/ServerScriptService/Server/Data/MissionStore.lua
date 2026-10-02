--!strict
-- Sauvegarde des missions quotidiennes de chaque joueur (DataStore « MissionsQuotidiennes ») :
-- { day = numéro du jour UTC, progress = { [mission] = valeur }, done = { [mission] = vrai } }.
-- Lecture et écriture avec nouvelles tentatives ; dans une place non publiée (Studio), les
-- données restent en mémoire pour la session.

local DataStoreService = game:GetService("DataStoreService")

export type Record = {
	day: number,
	progress: { [string]: number },
	done: { [string]: boolean },
}

local RETRIES = 3
local RETRY_DELAY = 2

local MissionStore = {}

local store: any = nil
local unavailable = false

local function getStore(): any?
	if store or unavailable then
		return store
	end
	if game.GameId == 0 then
		unavailable = true -- place locale non publiée : pas de DataStore
		return nil
	end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore("MissionsQuotidiennes")
	end)
	if ok then
		store = result
	else
		unavailable = true
		warn(`[Missions] DataStore indisponible : {result}`)
	end
	return store
end

local function keyFor(userId: number): string
	return "Joueur_" .. userId
end

-- Nombre entier de jours UTC depuis 1970 (change à minuit UTC)
function MissionStore.today(): number
	return os.time() // 86400
end

local function fresh(day: number): Record
	return { day = day, progress = {}, done = {} }
end

-- Valeurs reçues du DataStore, vérifiées (types, nombres finis)
local function normalize(raw: any, day: number): Record
	if typeof(raw) ~= "table" or raw.day ~= day then
		return fresh(day)
	end
	local record = fresh(day)
	if typeof(raw.progress) == "table" then
		for id, value in raw.progress do
			if typeof(id) == "string" and typeof(value) == "number" and value == value and value >= 0 and value < 1e9 then
				record.progress[id] = value
			end
		end
	end
	if typeof(raw.done) == "table" then
		for id, value in raw.done do
			if typeof(id) == "string" and value == true then
				record.done[id] = true
			end
		end
	end
	return record
end

-- Charge les missions du jour d'un joueur (nouvelles si le jour a changé)
function MissionStore.load(userId: number): Record
	local day = MissionStore.today()
	local s = getStore()
	if not s then
		return fresh(day)
	end
	for attempt = 1, RETRIES do
		local ok, result = pcall(function()
			return s:GetAsync(keyFor(userId))
		end)
		if ok then
			return normalize(result, day)
		end
		warn(`[Missions] lecture {userId}, essai {attempt} : {result}`)
		task.wait(RETRY_DELAY * attempt)
	end
	return fresh(day)
end

-- Enregistre (renvoie vrai si c'est fait, ou s'il n'y a pas de DataStore)
function MissionStore.save(userId: number, record: Record): boolean
	local s = getStore()
	if not s then
		return true
	end
	for attempt = 1, RETRIES do
		local ok, err = pcall(function()
			s:SetAsync(keyFor(userId), { day = record.day, progress = record.progress, done = record.done }, { userId })
		end)
		if ok then
			return true
		end
		warn(`[Missions] sauvegarde {userId}, essai {attempt} : {err}`)
		task.wait(RETRY_DELAY * attempt)
	end
	return false
end

return MissionStore
