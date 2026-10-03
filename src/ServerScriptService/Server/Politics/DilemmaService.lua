--!strict
-- Dilemmes de dirigeant (Config/Dilemmas) : régulièrement, chaque joueur reçoit une carte de
-- décision avec deux choix et leurs conséquences, tirée selon sa situation (usines, guerre,
-- réserves...). Sans réponse à temps, le choix par défaut s'applique.
-- Carte publiée dans ReplicatedStorage.EtatMonde.Pays.<code>.Dilemme :
--   Id, Titre, Texte, ChoixA, ChoixB, EffetsA, EffetsB (résumés), Defaut (1 ou 2), Fin (heure serveur)
-- Réputation (0 à 100) : attribut « Reputation » de chaque pays ; elle rend les IA plus ou moins
-- disposées à s'allier avec lui ou à se laisser convaincre au Conseil mondial.
-- Remote : ChoisirDilemme(1 | 2).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Dilemmas = require(Config:WaitForChild("Dilemmas")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local Market = require(Config:WaitForChild("Market")) :: any
local Units = require(Config:WaitForChild("Units")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local RegionResources = require(Shared:WaitForChild("RegionResources")) :: any
local MilitaryMath = require(Shared:WaitForChild("MilitaryMath")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local CountryAssignment = require(Server:WaitForChild("Session"):WaitForChild("CountryAssignment"))
local RateLimiter = require(Server:WaitForChild("Util"):WaitForChild("RateLimiter"))
local Stocks = require(Server:WaitForChild("Economy"):WaitForChild("Stocks"))
local Stability = require(script.Parent:WaitForChild("Stability"))
local CouncilService = require(script.Parent:WaitForChild("CouncilService"))

local CURRENCY: string = Resources.currency.id
local CHECK_INTERVAL = 5
local HISTORY = 4 -- un même dilemme ne revient pas avant 4 autres

local DilemmaService = {}

local nextAt: { [string]: number } = {}
local recent: { [string]: { string } } = {}
local rng = Random.new()

local function countryFolder(countryId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
end

local function forces(countryId: string): { Instance }
	local list = {}
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local armees = state and state:FindFirstChild("Armees")
	for _, army in (if armees then armees:GetChildren() else {}) do
		if army:GetAttribute("Proprietaire") == countryId then
			table.insert(list, army)
		end
	end
	return list
end

-- Ressource principale (plus grande valeur produite, la nourriture comptant pour moitié)
local function mainResource(countryId: string): string
	local production = RegionResources.countryProduction(countryId, RegionService.getOwner)
	local best, bestValue = "Nourriture", -1
	for resourceId, amount in production do
		local value = amount * (Market.basePrices[resourceId] or 0) * (if resourceId == "Nourriture" then 0.5 else 1)
		if value > bestValue then
			best, bestValue = resourceId, value
		end
	end
	return best
end

-- Situations qui rendent un dilemme possible
local conditions: { [string]: (string) -> boolean } = {
	always = function(): boolean
		return true
	end,
	hasFactory = function(countryId: string): boolean
		local state = ReplicatedStorage:FindFirstChild("EtatMonde")
		local usines = state and state:FindFirstChild("Usines")
		for _, factory in (if usines then usines:GetChildren() else {}) do
			if RegionService.getOwner(factory:GetAttribute("Region") :: string) == countryId then
				return true
			end
		end
		return false
	end,
	foodStock = function(countryId: string): boolean
		return Stocks.get(countryId, "Nourriture") >= 80
	end,
	hasArmy = function(countryId: string): boolean
		for _, army in forces(countryId) do
			for _, typeId in Units.kinds[Units.kindOf(army)].order do
				if ((army:GetAttribute(typeId) :: number?) or 0) > 0 then
					return true
				end
			end
		end
		return false
	end,
	oilLow = function(countryId: string): boolean
		if Stocks.get(countryId, "Petrole") >= 20 then
			return false
		end
		for _, army in forces(countryId) do
			if (MilitaryMath.upkeep(army).Petrole or 0) > 0 then
				return true
			end
		end
		return false
	end,
	atWar = function(countryId: string): boolean
		return #DiplomacyState.enemiesOf(countryId) > 0
	end,
	hasEnemy = function(countryId: string): boolean
		return #DiplomacyState.enemiesOf(countryId) > 0
	end,
	farmer = function(countryId: string): boolean
		local production = RegionResources.countryProduction(countryId, RegionService.getOwner)
		return (production.Nourriture or 0) >= 8
	end,
}

function DilemmaService.reputation(countryId: string): number
	local folder = countryFolder(countryId)
	local value = folder and folder:GetAttribute("Reputation")
	return if typeof(value) == "number" then value else Dilemmas.startReputation
end

function DilemmaService.changeReputation(countryId: string, delta: number)
	local folder = countryFolder(countryId)
	if folder then
		folder:SetAttribute("Reputation", math.clamp(DilemmaService.reputation(countryId) + delta, 0, 100))
	end
end

-- Résumé des effets d'un choix : « −300 💰, +3 stabilité »
local function summary(countryId: string, effects: { [string]: any }): string
	local parts = {}
	local function signed(n: number): string
		return if n >= 0 then `+{n}` else `−{-n}`
	end
	if effects.credits then
		table.insert(parts, `{signed(effects.credits)} {Resources.currency.icon}`)
	end
	if effects.food then
		table.insert(parts, `{signed(effects.food)} {Resources.list.Nourriture.icon}`)
	end
	if effects.oil then
		table.insert(parts, `{signed(effects.oil)} {Resources.list.Petrole.icon}`)
	end
	if effects.mainResource then
		table.insert(parts, `{signed(effects.mainResource)} {Resources.list[mainResource(countryId)].icon}`)
	end
	if effects.stability then
		table.insert(parts, `{signed(effects.stability)} stabilité`)
	end
	if effects.reputation then
		table.insert(parts, `{signed(effects.reputation)} réputation`)
	end
	if effects.morale then
		table.insert(parts, `{signed(effects.morale)} moral des armées`)
	end
	if effects.peace then
		table.insert(parts, "propose la paix à ton ennemi (vote)")
	end
	return table.concat(parts, ", ")
end

local function applyEffects(countryId: string, title: string, effects: { [string]: any })
	local function give(stockId: string, amount: number)
		if amount < 0 then
			amount = -math.min(-amount, Stocks.get(countryId, stockId))
		end
		Stocks.add(countryId, stockId, amount)
	end
	if effects.credits then
		give(CURRENCY, effects.credits)
	end
	if effects.food then
		give("Nourriture", effects.food)
	end
	if effects.oil then
		give("Petrole", effects.oil)
	end
	if effects.mainResource then
		give(mainResource(countryId), effects.mainResource)
	end
	if effects.stability then
		Stability.change(countryId, effects.stability, `décision : {string.lower(title)}`)
	end
	if effects.reputation then
		DilemmaService.changeReputation(countryId, effects.reputation)
	end
	if effects.morale then
		for _, army in forces(countryId) do
			army:SetAttribute("Moral", math.clamp(MilitaryMath.morale(army) + effects.morale, 0, 100))
		end
	end
	if effects.peace then
		-- la paix se vote (cahier des charges v2, section 1) : un vote au Conseil avec le premier ennemi
		local enemy = DiplomacyState.enemiesOf(countryId)[1]
		if enemy then
			CouncilService.propose(countryId, { type = "Paix", cible = enemy, offre = 0 })
		end
	end
end

local function findDilemma(id: string): any
	for _, dilemma in Dilemmas.list do
		if dilemma.id == id then
			return dilemma
		end
	end
	return nil
end

-- Applique un choix (1 ou 2) à la carte en cours d'un pays
local function resolve(countryId: string, choice: number)
	local folder = countryFolder(countryId)
	local card = folder and folder:FindFirstChild("Dilemme")
	if not card then
		return
	end
	local dilemma = findDilemma(card:GetAttribute("Id") :: string)
	card:Destroy()
	nextAt[countryId] = time() + rng:NextNumber(Dilemmas.interval.min, Dilemmas.interval.max)
	if dilemma then
		applyEffects(countryId, dilemma.title, dilemma.choices[choice].effects)
	end
end

-- Pose une carte à un pays
local function deal(countryId: string)
	local folder = countryFolder(countryId)
	if not folder or folder:FindFirstChild("Dilemme") then
		return
	end
	local history = recent[countryId] or {}
	recent[countryId] = history
	local possible = {}
	for _, dilemma in Dilemmas.list do
		local condition = conditions[dilemma.condition]
		if condition and condition(countryId) and not table.find(history, dilemma.id) then
			table.insert(possible, dilemma)
		end
	end
	if #possible == 0 then
		table.clear(history)
		return
	end
	local dilemma = possible[rng:NextInteger(1, #possible)]
	table.insert(history, dilemma.id)
	if #history > HISTORY then
		table.remove(history, 1)
	end
	local card = Instance.new("Folder")
	card.Name = "Dilemme"
	card:SetAttribute("Id", dilemma.id)
	card:SetAttribute("Titre", dilemma.title)
	card:SetAttribute("Texte", dilemma.text)
	card:SetAttribute("ChoixA", dilemma.choices[1].label)
	card:SetAttribute("ChoixB", dilemma.choices[2].label)
	card:SetAttribute("EffetsA", summary(countryId, dilemma.choices[1].effects))
	card:SetAttribute("EffetsB", summary(countryId, dilemma.choices[2].effects))
	card:SetAttribute("Defaut", dilemma.default)
	card:SetAttribute("Fin", workspace:GetServerTimeNow() + Dilemmas.answerTime)
	card.Parent = folder
	task.delay(Dilemmas.answerTime, function()
		if card.Parent then
			resolve(countryId, dilemma.default)
		end
	end)
end

-- Le joueur choisit
function DilemmaService.choose(countryId: string, choice: unknown): (boolean, string?)
	if choice ~= 1 and choice ~= 2 then
		return false, "Choix invalide."
	end
	local folder = countryFolder(countryId)
	if not folder or not folder:FindFirstChild("Dilemme") then
		return false, "Aucune décision en attente."
	end
	resolve(countryId, choice :: number)
	return true, nil
end

-- Nouvelle partie : plus de carte en cours, réputation de départ pour tous
function DilemmaService.reset()
	table.clear(nextAt)
	table.clear(recent)
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	for _, folder in (if pays then pays:GetChildren() else {}) do
		local card = folder:FindFirstChild("Dilemme")
		if card then
			card:Destroy()
		end
		folder:SetAttribute("Reputation", Dilemmas.startReputation)
	end
end

-- À appeler au démarrage (après Stability.init et DiplomacyService.init)
function DilemmaService.start()
	local pays = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Pays")
	for _, folder in pays:GetChildren() do
		folder:SetAttribute("Reputation", Dilemmas.startReputation)
	end
	CountryAssignment.onAssigned(function(_player: Player, countryId: string)
		-- première carte pas avant Dilemmas.firstDelay secondes de partie
		nextAt[countryId] = time() + math.max(Dilemmas.firstDelay - MatchState.elapsed(), Dilemmas.interval.min / 2)
	end)

	local remote = Instance.new("RemoteFunction")
	remote.Name = "ChoisirDilemme"
	local limiter = RateLimiter.new(0.5)
	remote.OnServerInvoke = function(player: Player, choice: unknown)
		if not limiter:allow(player) then
			return false, "Doucement, réessaie dans un instant."
		end
		local countryId = CountryAssignment.getCountryOf(player)
		if not countryId then
			return false, "Choisis d'abord un pays."
		end
		return DilemmaService.choose(countryId, choice)
	end
	remote.Parent = ReplicatedStorage:WaitForChild("Remotes")

	task.spawn(function()
		while true do
			task.wait(CHECK_INTERVAL)
			if not MatchState.isRunning() then
				continue
			end
			for _, folder in pays:GetChildren() do
				local id = folder.Name
				if folder:GetAttribute("Joueur") ~= 0 and folder:GetAttribute("Absent") ~= true and nextAt[id] and time() >= nextAt[id] then
					nextAt[id] = time() + Dilemmas.interval.min -- évite de reposer une carte à chaque passage
					local ok, err = pcall(deal, id)
					if not ok then
						warn(`[Dilemmes] {id} : {err}`)
					end
				end
			end
		end
	end)
end

return DilemmaService
