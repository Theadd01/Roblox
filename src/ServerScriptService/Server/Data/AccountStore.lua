--!strict
-- Sauvegarde du compte de chaque joueur (DataStore « ComptesJoueurs ») : succès débloqués, titre
-- affiché, parties jouées et gagnées, podiums, meilleur rang, réglages (volumes, messages, taille
-- de l'interface). Lecture et écriture avec nouvelles tentatives ; dans une place non publiée
-- (Studio), les données restent en mémoire pour la session.

local DataStoreService = game:GetService("DataStoreService")

export type Account = {
	achievements: { [string]: boolean },
	title: string, -- identifiant du succès dont le titre est affiché (« » : aucun)
	games: number,
	wins: number,
	podiums: number,
	bestRank: number, -- 0 : aucune partie finie
	settings: { [string]: any },
}

local RETRIES = 3
local RETRY_DELAY = 2

local AccountStore = {}

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
		return DataStoreService:GetDataStore("ComptesJoueurs")
	end)
	if ok then
		store = result
	else
		unavailable = true
		warn(`[Compte] DataStore indisponible : {result}`)
	end
	return store
end

local function keyFor(userId: number): string
	return "Joueur_" .. userId
end

function AccountStore.fresh(): Account
	return { achievements = {}, title = "", games = 0, wins = 0, podiums = 0, bestRank = 0, settings = {} }
end

local function count(value: any): number
	return if typeof(value) == "number" and value == value and value >= 0 and value < 1e7 then math.floor(value) else 0
end

-- Valeurs reçues du DataStore, vérifiées une à une
local function normalize(raw: any): Account
	local account = AccountStore.fresh()
	if typeof(raw) ~= "table" then
		return account
	end
	if typeof(raw.achievements) == "table" then
		for id, value in raw.achievements do
			if typeof(id) == "string" and value == true then
				account.achievements[id] = true
			end
		end
	end
	account.title = if typeof(raw.title) == "string" then raw.title else ""
	account.games = count(raw.games)
	account.wins = count(raw.wins)
	account.podiums = count(raw.podiums)
	account.bestRank = count(raw.bestRank)
	if typeof(raw.settings) == "table" then
		for key, value in raw.settings do
			if typeof(key) == "string" and (typeof(value) == "number" or typeof(value) == "boolean" or typeof(value) == "string") then
				account.settings[key] = value
			end
		end
	end
	return account
end

function AccountStore.load(userId: number): Account
	local s = getStore()
	if not s then
		return AccountStore.fresh()
	end
	for attempt = 1, RETRIES do
		local ok, result = pcall(function()
			return s:GetAsync(keyFor(userId))
		end)
		if ok then
			return normalize(result)
		end
		warn(`[Compte] lecture {userId}, essai {attempt} : {result}`)
		task.wait(RETRY_DELAY * attempt)
	end
	return AccountStore.fresh()
end

function AccountStore.save(userId: number, account: Account): boolean
	local s = getStore()
	if not s then
		return true
	end
	for attempt = 1, RETRIES do
		local ok, err = pcall(function()
			s:SetAsync(keyFor(userId), account, { userId })
		end)
		if ok then
			return true
		end
		warn(`[Compte] sauvegarde {userId}, essai {attempt} : {err}`)
		task.wait(RETRY_DELAY * attempt)
	end
	return false
end

return AccountStore
