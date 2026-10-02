--!strict
-- Boutique, passe de combat et avantages de confort non pay-to-win.
-- Ce service observe les actions validées par les systèmes de jeu et attribue l'XP.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local BattlePass = require(Config:WaitForChild("BattlePass")) :: any
local Monetization = require(Config:WaitForChild("Monetization")) :: any
local MapGeometry = require(Config:WaitForChild("MapGeometry")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any

local Server = script.Parent.Parent
local ProfileStore = require(Server:WaitForChild("Data"):WaitForChild("ProfileStore"))
local BattlePassService = require(Server:WaitForChild("Progression"):WaitForChild("BattlePassService"))
local RateLimiter = require(Server:WaitForChild("Util"):WaitForChild("RateLimiter"))

type SessionStats = {
	playXp: number,
	factories: number,
	armies: number,
	victories: number,
	countryAwarded: boolean,
}

local MonetizationService = {}

local stateRoot: Folder
local ownedPasses: { [Player]: { [string]: boolean } } = {}
local sessionStats: { [Player]: SessionStats } = {}

local function finiteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function statsFor(player: Player): SessionStats
	local stats = sessionStats[player]
	if not stats then
		stats = {
			playXp = 0,
			factories = 0,
			armies = 0,
			victories = 0,
			countryAwarded = false,
		}
		sessionStats[player] = stats
	end
	return stats
end

local function hasPass(player: Player, key: string): boolean
	local passes = ownedPasses[player]
	return passes ~= nil and passes[key] == true
end

local function bookmarkSlots(player: Player): number
	return if hasPass(player, "CommandOffice") then 6 else Monetization.freeBookmarkSlots
end

local function playerFolder(player: Player): Folder
	local name = tostring(player.UserId)
	local existing = stateRoot:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = stateRoot
	return folder
end

local function childFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function syncBoolValues(folder: Folder, values: { [string]: boolean })
	for key, value in values do
		if value and not folder:FindFirstChild(key) then
			local marker = Instance.new("BoolValue")
			marker.Name = key
			marker.Value = true
			marker.Parent = folder
		end
	end
end

local function replicate(player: Player)
	local profile = ProfileStore.get(player)
	if not profile or not player.Parent then
		return
	end
	local folder = playerFolder(player)
	local level = BattlePass.levelForXp(profile.xp)
	folder:SetAttribute("SeasonId", BattlePass.season.id)
	folder:SetAttribute("SeasonName", BattlePass.season.name)
	folder:SetAttribute("SeasonSubtitle", BattlePass.season.subtitle)
	folder:SetAttribute("XP", profile.xp)
	folder:SetAttribute("Level", level)
	folder:SetAttribute("MaxLevel", BattlePass.season.maxLevel)
	folder:SetAttribute("LevelStartXP", BattlePass.startXpForLevel(level))
	folder:SetAttribute("NextLevelXP", BattlePass.nextLevelXp(level))
	folder:SetAttribute("Premium", profile.premium)
	folder:SetAttribute("Medals", profile.medals)
	folder:SetAttribute("SupportTotal", profile.supportTotal)
	folder:SetAttribute("BookmarkSlots", bookmarkSlots(player))
	folder:SetAttribute("AutoClaim", hasPass(player, "CommandOffice"))
	folder:SetAttribute("EquippedTitle", profile.equipped.Title or "")
	folder:SetAttribute("SaveMode", ProfileStore.mode(player) or "unavailable")

	local free = childFolder(folder, "FreeClaims")
	local premium = childFolder(folder, "PremiumClaims")
	for key, claimed in profile.claimedFree do
		if claimed then
			free:SetAttribute("L" .. key, true)
		end
	end
	for key, claimed in profile.claimedPremium do
		if claimed then
			premium:SetAttribute("L" .. key, true)
		end
	end

	syncBoolValues(childFolder(folder, "Unlocks"), profile.unlocks)

	local passes = childFolder(folder, "Passes")
	for key, offer in Monetization.gamePasses do
		passes:SetAttribute(key, hasPass(player, key))
		passes:SetAttribute(key .. "Configured", offer.id > 0)
	end
	for key, offer in Monetization.products do
		folder:SetAttribute(key .. "Configured", offer.id > 0)
	end

	local bookmarkFolder = childFolder(folder, "Bookmarks")
	bookmarkFolder:ClearAllChildren()
	for slot, bookmark in profile.bookmarks do
		local entry = Instance.new("Folder")
		entry.Name = slot
		entry:SetAttribute("X", bookmark.x)
		entry:SetAttribute("Z", bookmark.z)
		entry:SetAttribute("Distance", bookmark.distance)
		entry.Parent = bookmarkFolder
	end
end

local function playerOfCountry(countryId: string): Player?
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("Pays") == countryId then
			return player
		end
	end
	return nil
end

local function addXp(player: Player, amount: number, reason: string)
	if ProfileStore.get(player) then
		BattlePassService.addXp(player, amount, reason)
	end
end

local function applyPassBenefits(player: Player, key: string)
	if key == "Herald" then
		ProfileStore.mutate(player, function(profile: ProfileStore.Profile)
			profile.unlocks.TITLE_HERALD = true
			profile.unlocks.FRAME_HERALD = true
		end)
	elseif key == "Cartographer" then
		ProfileStore.mutate(player, function(profile: ProfileStore.Profile)
			profile.unlocks.THEME_CARTOGRAPHER = true
			profile.unlocks.MARKER_CARTOGRAPHER = true
		end)
	elseif key == "CommandOffice" then
		BattlePassService.claimAll(player)
	end
	ProfileStore.save(player)
	replicate(player)
end

local function checkPass(player: Player, key: string, offer: any)
	if offer.id <= 0 then
		return
	end
	for attempt = 1, 3 do
		local ok, result = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, offer.id)
		end)
		if ok then
			local passes = ownedPasses[player]
			if result == true and player.Parent and passes then
				passes[key] = true
				applyPassBenefits(player, key)
			end
			return
		end
		if not player.Parent then
			return
		end
		task.wait(attempt)
	end
	warn("[Monetisation] Vérification du passe impossible pour", player.UserId, key)
end

local function loadPlayer(player: Player)
	ProfileStore.load(player)
	if not player.Parent then
		return
	end
	ownedPasses[player] = {}
	statsFor(player)
	for key, offer in Monetization.gamePasses do
		task.spawn(checkPass, player, key, offer)
	end
	replicate(player)

	local function countryChanged()
		local countryId = player:GetAttribute("Pays")
		local stats = statsFor(player)
		if typeof(countryId) == "string" and countryId ~= "" and not stats.countryAwarded then
			stats.countryAwarded = true
			addXp(player, BattlePass.xp.countrySelected, "CountrySelected")
		end
	end
	player:GetAttributeChangedSignal("Pays"):Connect(countryChanged)
	countryChanged()
end

local function setupGameplayXp(state: Instance)
	local factories = state:WaitForChild("Usines")
	local armies = state:WaitForChild("Armees")
	local battles = state:WaitForChild("Batailles")

	factories.ChildAdded:Connect(function(factory: Instance)
		task.defer(function()
			local owner = factory:GetAttribute("Proprietaire")
			local player = if typeof(owner) == "string" then playerOfCountry(owner) else nil
			if player then
				local stats = statsFor(player)
				if stats.factories < BattlePass.xp.maxFactoriesPerSession then
					stats.factories += 1
					addXp(player, BattlePass.xp.factoryBuilt, "FactoryBuilt")
				end
			end
		end)
	end)

	armies.ChildAdded:Connect(function(army: Instance)
		task.defer(function()
			local owner = army:GetAttribute("Proprietaire")
			local player = if typeof(owner) == "string" then playerOfCountry(owner) else nil
			if player then
				local stats = statsFor(player)
				if stats.armies < BattlePass.xp.maxArmiesPerSession then
					stats.armies += 1
					addXp(player, BattlePass.xp.armyCreated, "ArmyCreated")
				end
			end
		end)
	end)

	battles.ChildAdded:Connect(function(battle: Instance)
		local handled = false
		local function changed()
			if handled or battle:GetAttribute("Etat") ~= "Victoire" then
				return
			end
			handled = true
			local attacker = battle:GetAttribute("Attaquant")
			local player = if typeof(attacker) == "string" then playerOfCountry(attacker) else nil
			if player then
				local stats = statsFor(player)
				if stats.victories < BattlePass.xp.maxVictoriesPerSession then
					stats.victories += 1
					addXp(player, BattlePass.xp.battleVictory, "BattleVictory")
				end
			end
		end
		battle:GetAttributeChangedSignal("Etat"):Connect(changed)
		changed()
	end)

	-- Seules les minutes jouées après le choix d'un pays comptent.
	task.spawn(function()
		while true do
			task.wait(60)
			for _, player in Players:GetPlayers() do
				local countryId = player:GetAttribute("Pays")
				if typeof(countryId) == "string" and countryId ~= "" then
					local stats = statsFor(player)
					if stats.playXp < BattlePass.xp.activeSessionCap then
						local amount = math.min(BattlePass.xp.activeMinute, BattlePass.xp.activeSessionCap - stats.playXp)
						stats.playXp += amount
						addXp(player, amount, "ActiveMinute")
					end
				end
			end
		end
	end)
end

local function setupActions(remotes: Instance)
	local limiter = RateLimiter.new(0.15)
	local remote = Instance.new("RemoteFunction")
	remote.Name = "MonetisationAction"
	remote.OnServerInvoke = function(player: Player, action: unknown, payload: unknown): (boolean, string)
		if not limiter:allow(player) then
			return false, "Doucement, réessaie dans un instant."
		end
		if typeof(action) ~= "string" or not ProfileStore.get(player) then
			return false, "Profil en cours de chargement."
		end
		if ProfileStore.mode(player) == "unavailable" then
			return false, "Sauvegarde indisponible : action bloquée pour protéger ta progression."
		end
		if action == "Claim" and typeof(payload) == "table" then
			local track = payload.track
			local level = payload.level
			if typeof(track) == "string" and typeof(level) == "number" then
				return BattlePassService.claim(player, track, level)
			end
		elseif action == "ClaimAll" then
			return BattlePassService.claimAll(player)
		elseif action == "BuyCosmetic" and typeof(payload) == "string" then
			return BattlePassService.buyCosmetic(player, payload)
		elseif action == "EquipTitle" and typeof(payload) == "string" then
			return BattlePassService.equipTitle(player, payload)
		elseif action == "SaveBookmark" and typeof(payload) == "table" then
			local slot, x, z, distance = payload.slot, payload.x, payload.z, payload.distance
			local bounds = MapGeometry.bounds
			if not finiteNumber(slot) or slot % 1 ~= 0 or slot < 1 or slot > bookmarkSlots(player) then
				return false, "Emplacement de repère indisponible."
			end
			if not finiteNumber(x) or not finiteNumber(z) or not finiteNumber(distance) then
				return false, "Position de caméra invalide."
			end
			if x < bounds.minX or x > bounds.maxX or z < bounds.minZ or z > bounds.maxZ
				or distance < MapSettings.camera.minDistance or distance > MapSettings.camera.maxDistance
			then
				return false, "Position hors de la carte."
			end
			ProfileStore.mutate(player, function(profile: ProfileStore.Profile)
				profile.bookmarks[tostring(slot)] = { x = x, z = z, distance = distance }
			end)
			local saved = ProfileStore.save(player)
			replicate(player)
			if not saved then
				return false, "Repère gardé pour cette session, sauvegarde en attente."
			end
			return true, `Repère {slot} enregistré.`
		elseif action == "DeleteBookmark" and finiteNumber(payload) then
			local slot = math.floor(payload)
			if slot < 1 or slot > bookmarkSlots(player) then
				return false, "Emplacement inconnu."
			end
			ProfileStore.mutate(player, function(profile: ProfileStore.Profile)
				profile.bookmarks[tostring(slot)] = nil
			end)
			local saved = ProfileStore.save(player)
			replicate(player)
			if not saved then
				return false, "Repère supprimé pour cette session, sauvegarde en attente."
			end
			return true, "Repère supprimé."
		end
		return false, "Action inconnue."
	end
	remote.Parent = remotes
end

local function setupPurchases()
	MarketplaceService.ProcessReceipt = function(receiptInfo: any): Enum.ProductPurchaseDecision
		local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
		if not player then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		if not ProfileStore.waitFor(player, 15) then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		local _key, offer = Monetization.productById(receiptInfo.ProductId)
		if not offer then
			warn("[Monetisation] Produit inconnu :", receiptInfo.ProductId)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		local success = ProfileStore.processReceipt(player, tostring(receiptInfo.PurchaseId), function(profile: ProfileStore.Profile)
			if offer.kind == "PremiumSeason" then
				profile.premium = true
			elseif offer.kind == "Support" then
				profile.medals += offer.medals or 0
				profile.supportTotal += math.max(0, math.floor(receiptInfo.CurrencySpent or offer.suggestedPrice))
				for _, unlock in offer.unlocks or {} do
					profile.unlocks[unlock] = true
				end
			end
		end)
		if not success then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		replicate(player)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, gamePassId: number, wasPurchased: boolean)
		if not wasPurchased then
			return
		end
		local key, offer = Monetization.gamePassById(gamePassId)
		if not key or not offer then
			return
		end
		task.spawn(checkPass, player, key, offer)
	end)
end

function MonetizationService.init()
	local worldState = ReplicatedStorage:WaitForChild("EtatMonde")
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local root = Instance.new("Folder")
	root.Name = "Monetisation"
	root:SetAttribute("Version", 1)
	root.Parent = worldState
	stateRoot = root

	BattlePassService.init({
		replicate = replicate,
		ownsPass = hasPass,
	})
	setupActions(remotes)

	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(loadPlayer, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(loadPlayer, player)
	end
	setupPurchases()
	task.spawn(setupGameplayXp, worldState)

	Players.PlayerRemoving:Connect(function(player: Player)
		ProfileStore.save(player)
		local folder = stateRoot:FindFirstChild(tostring(player.UserId))
		if folder then
			folder:Destroy()
		end
		ProfileStore.release(player)
		ownedPasses[player] = nil
		sessionStats[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(Monetization.autosaveSeconds)
			for _, player in ProfileStore.loadedPlayers() do
				ProfileStore.save(player)
			end
		end
	end)

	game:BindToClose(function()
		local pending = 0
		for _, player in ProfileStore.loadedPlayers() do
			pending += 1
			task.spawn(function()
				ProfileStore.save(player)
				pending -= 1
			end)
		end
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return MonetizationService
