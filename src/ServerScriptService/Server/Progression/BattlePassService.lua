--!strict
-- Progression du passe. Le serveur est l'unique autorité pour l'XP et les récompenses.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local BattlePass = require(Config:WaitForChild("BattlePass")) :: any
local Monetization = require(Config:WaitForChild("Monetization")) :: any
local ProfileStore = require(script.Parent.Parent:WaitForChild("Data"):WaitForChild("ProfileStore"))

local BattlePassService = {}

local function finiteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local replicate: (Player) -> () = function() end
local ownsPass: (Player, string) -> boolean = function(_player: Player, _key: string): boolean
	return false
end

local function reward(track: string, level: number): any?
	local row = BattlePass.levels[level]
	if not row then
		return nil
	end
	return if track == "Premium" then row.premium elseif track == "Free" then row.free else nil
end

local function grantReward(profile: ProfileStore.Profile, item: any)
	if typeof(item.medals) == "number" then
		profile.medals += math.max(0, math.floor(item.medals))
	end
	if typeof(item.unlocks) == "table" then
		for _, id in item.unlocks do
			if typeof(id) == "string" then
				profile.unlocks[id] = true
			end
		end
	end
end

local function claimInProfile(profile: ProfileStore.Profile, track: string, level: number): boolean
	local item = reward(track, level)
	if not item then
		return false
	end
	local claims = if track == "Premium" then profile.claimedPremium else profile.claimedFree
	local key = tostring(level)
	if claims[key] then
		return false
	end
	claims[key] = true
	grantReward(profile, item)
	return true
end

local function autoClaim(player: Player, profile: ProfileStore.Profile)
	if not ownsPass(player, "CommandOffice") then
		return
	end
	local level = BattlePass.levelForXp(profile.xp)
	for index = 1, level do
		claimInProfile(profile, "Free", index)
		if profile.premium then
			claimInProfile(profile, "Premium", index)
		end
	end
end

function BattlePassService.init(options: {
	replicate: (Player) -> (),
	ownsPass: (Player, string) -> boolean,
})
	replicate = options.replicate
	ownsPass = options.ownsPass
end

function BattlePassService.addXp(player: Player, amount: number, _reason: string?): number
	if not finiteNumber(amount) or amount <= 0 then
		return 0
	end
	local before = 0
	local after = 0
	local maximum = BattlePass.startXpForLevel(BattlePass.season.maxLevel)
	local profile = ProfileStore.mutate(player, function(data: ProfileStore.Profile)
		before = data.xp
		data.xp = math.clamp(data.xp + math.floor(amount), 0, maximum)
		after = data.xp
		autoClaim(player, data)
	end)
	if profile then
		replicate(player)
	end
	return after - before
end

function BattlePassService.claim(player: Player, track: string, level: number): (boolean, string)
	if track ~= "Free" and track ~= "Premium" then
		return false, "Piste inconnue."
	end
	if not finiteNumber(level) then
		return false, "Palier invalide."
	end
	level = math.floor(level)
	if level < 1 or level > BattlePass.season.maxLevel then
		return false, "Palier inconnu."
	end
	local profile = ProfileStore.get(player)
	if not profile then
		return false, "Profil en cours de chargement."
	end
	if level > BattlePass.levelForXp(profile.xp) then
		return false, "Ce palier n'est pas encore atteint."
	end
	if track == "Premium" and not profile.premium then
		return false, "La piste Premium n'est pas débloquée."
	end

	local granted = false
	ProfileStore.mutate(player, function(data: ProfileStore.Profile)
		granted = claimInProfile(data, track, level)
	end)
	if not granted then
		return false, "Récompense déjà récupérée."
	end
	local saved = ProfileStore.save(player)
	replicate(player)
	if not saved then
		return false, "Récompense accordée pour cette session, mais la sauvegarde sera retentée."
	end
	return true, "Récompense récupérée."
end

function BattlePassService.claimAll(player: Player): (boolean, string)
	local profile = ProfileStore.get(player)
	if not profile then
		return false, "Profil en cours de chargement."
	end
	local count = 0
	ProfileStore.mutate(player, function(data: ProfileStore.Profile)
		local level = BattlePass.levelForXp(data.xp)
		for index = 1, level do
			if claimInProfile(data, "Free", index) then
				count += 1
			end
			if data.premium and claimInProfile(data, "Premium", index) then
				count += 1
			end
		end
	end)
	if count == 0 then
		return false, "Aucune récompense disponible."
	end
	local saved = ProfileStore.save(player)
	replicate(player)
	if not saved then
		return false, "Récompenses accordées pour cette session, mais la sauvegarde sera retentée."
	end
	return true, `{count} récompense{if count > 1 then "s" else ""} récupérée{if count > 1 then "s" else ""}.`
end

function BattlePassService.unlockPremium(player: Player)
	ProfileStore.mutate(player, function(profile: ProfileStore.Profile)
		profile.premium = true
		autoClaim(player, profile)
	end)
	replicate(player)
end

function BattlePassService.buyCosmetic(player: Player, cosmeticId: string): (boolean, string)
	local cosmetic = Monetization.cosmeticById(cosmeticId)
	if not cosmetic then
		return false, "Objet cosmétique inconnu."
	end
	local profile = ProfileStore.get(player)
	if not profile then
		return false, "Profil en cours de chargement."
	end
	if profile.unlocks[cosmeticId] then
		return false, "Objet déjà possédé."
	end
	if profile.medals < cosmetic.price then
		return false, "Pas assez de Médailles."
	end
	ProfileStore.mutate(player, function(data: ProfileStore.Profile)
		data.medals -= cosmetic.price
		data.unlocks[cosmeticId] = true
		if cosmetic.category == "Title" and not data.equipped.Title then
			data.equipped.Title = cosmeticId
		end
	end)
	local saved = ProfileStore.save(player)
	replicate(player)
	if not saved then
		return false, "Objet accordé pour cette session, mais la sauvegarde sera retentée."
	end
	return true, "Objet ajouté à ton inventaire."
end

function BattlePassService.equipTitle(player: Player, titleId: string): (boolean, string)
	local profile = ProfileStore.get(player)
	if not profile then
		return false, "Profil en cours de chargement."
	end
	if titleId ~= "" and (string.sub(titleId, 1, 6) ~= "TITLE_" or not profile.unlocks[titleId]) then
		return false, "Titre non possédé."
	end
	ProfileStore.mutate(player, function(data: ProfileStore.Profile)
		data.equipped.Title = titleId
	end)
	local saved = ProfileStore.save(player)
	replicate(player)
	if not saved then
		return false, "Titre changé pour cette session, mais la sauvegarde sera retentée."
	end
	return true, if titleId == "" then "Titre retiré." else "Titre équipé."
end

return BattlePassService
