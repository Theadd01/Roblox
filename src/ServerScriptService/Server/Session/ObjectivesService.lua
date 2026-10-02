--!strict
-- Objectifs nationaux (Config/Objectives) : chaque pays dirigé par un joueur suit une chaîne
-- d'objectifs tirée de sa géographie, avec une récompense à chaque étape.
-- Publiés dans ReplicatedStorage.EtatMonde.Pays.<code>.Objectifs.O<n> :
--   Ordre, Texte, Recompense (texte), Etat (« Fait » | « EnCours » | « AVenir »), Valeur, But
-- La chaîne reste attachée au pays : un joueur qui le reprend continue où le précédent s'est arrêté.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Objectives = require(Config:WaitForChild("Objectives")) :: any
local News = require(Config:WaitForChild("News")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local Market = require(Config:WaitForChild("Market")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Units = require(Config:WaitForChild("Units")) :: any
local CountryStats = require(Shared:WaitForChild("CountryStats")) :: any
local RegionResources = require(Shared:WaitForChild("RegionResources")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local Stocks = require(Server:WaitForChild("Economy"):WaitForChild("Stocks"))
local Divisions = require(Server:WaitForChild("Military"):WaitForChild("Divisions"))
local StatsService = require(script.Parent:WaitForChild("StatsService"))

local CURRENCY: string = Resources.currency.id

type Goal = {
	kind: string,
	target: number,
	text: string,
	reward: { [string]: number },
	resource: string?,
	region: string?,
}
type Chain = { goals: { Goal }, current: number, startedAt: number, baseline: number }

local ObjectivesService = {}

local chains: { [string]: Chain } = {}
local completedListeners: { (countryId: string) -> () } = {}

local function countryFolder(countryId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
end

-- Ressource principale d'un pays : sa production de plus grande valeur (la nourriture compte
-- pour moitié, pour préférer une ressource plus typique) ; et sa production par cycle
local function mainResource(countryId: string): (string, number)
	local production: { [string]: number } = {}
	for regionId, region in Regions do
		if region.startOwner == countryId then
			for resourceId, amount in RegionResources.production(regionId) do
				production[resourceId] = (production[resourceId] or 0) + amount
			end
		end
	end
	local best, bestValue = "Nourriture", -1
	for resourceId, amount in production do
		local value = amount * (Market.basePrices[resourceId] or 0) * (if resourceId == "Nourriture" then 0.5 else 1)
		if value > bestValue then
			best, bestValue = resourceId, value
		end
	end
	return best, production[best] or 0
end

-- Région voisine (par la terre) la moins défendue, pour l'objectif de conquête
local function conquestTarget(countryId: string): string?
	local best: string? = nil
	local bestDefense = math.huge
	for regionId, region in Regions do
		if region.startOwner == countryId then
			for _, link in region.neighbors do
				local owner = Regions[link.region] and Regions[link.region].startOwner
				if not link.bySea and owner ~= countryId then
					-- la moins défendue : celle qui a le moins de divisions
					local defense = #Divisions.inRegion(link.region)
					if defense < bestDefense then
						best, bestDefense = link.region, defense
					end
				end
			end
		end
	end
	return best
end

local function rewardText(reward: { [string]: number }): string
	local parts = {}
	if reward[CURRENCY] then
		table.insert(parts, `+{reward[CURRENCY]} {Resources.currency.icon}`)
	end
	for _, id in Resources.order do
		if reward[id] then
			table.insert(parts, `+{reward[id]} {Resources.list[id].icon}`)
		end
	end
	return table.concat(parts, ", ")
end

local function buildChain(countryId: string): Chain
	local resourceId, perCycle = mainResource(countryId)
	local r = Resources.list[resourceId]
	local region = conquestTarget(countryId)
	local small = CountryStats.area(countryId) < Objectives.smallArea
	local goals: { Goal } = {}
	for _, template in Objectives.chain do
		local goal = template
		if template.kind == "conquer" and (small or not region) then
			goal = Objectives.hold
		end
		local text = goal.text
			:gsub("{resource}", `{r.icon} {r.name}`)
			:gsub("{of}", News.resources[resourceId] or r.name)
		if goal.kind == "conquer" and region then
			text = text:gsub("{region}", FrenchNames.the(Regions[region].name))
		end
		-- première vente : environ une minute de production (Objectives.soldCycles)
		local target = if goal.kind == "sold" then math.clamp(perCycle * Objectives.soldCycles, Objectives.soldMin, goal.target) else goal.target
		text = text:gsub("{target}", tostring(target))
		table.insert(goals, {
			kind = goal.kind,
			target = target,
			text = text,
			reward = goal.reward,
			resource = resourceId,
			region = if goal.kind == "conquer" then region else nil,
		})
	end
	return { goals = goals, current = 1, startedAt = time(), baseline = 0 }
end

-- Valeur cumulée qui sert de point de départ (ventes, contrats) quand un objectif commence
local function cumulative(countryId: string, goal: Goal): number
	local stats = StatsService.get(countryId)
	if goal.kind == "sold" then
		return stats.sold[goal.resource :: string] or 0
	elseif goal.kind == "contracts" then
		return stats.contracts
	end
	return 0
end

-- Avancement d'un objectif : valeur actuelle et but
local function progress(countryId: string, chain: Chain, goal: Goal): (number, number)
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	if goal.kind == "sold" or goal.kind == "contracts" then
		return cumulative(countryId, goal) - chain.baseline, goal.target
	elseif goal.kind == "factories" or goal.kind == "factoryLevels" then
		local count, levels = 0, 0
		local usines = state and state:FindFirstChild("Usines")
		for _, factory in (if usines then usines:GetChildren() else {}) do
			-- bâtiments terminés, sans le camp militaire offert au départ
			if RegionService.getOwner(factory:GetAttribute("Region") :: string) == countryId and factory:GetAttribute("Statut") ~= "Construction"
				and factory:GetAttribute("Depart") ~= true then
				count += 1
				levels += (factory:GetAttribute("Niveau") :: number?) or 1
			end
		end
		return if goal.kind == "factories" then count else levels, goal.target
	elseif goal.kind == "troops" then
		local troops = 0
		local armees = state and state:FindFirstChild("Armees")
		for _, army in (if armees then armees:GetChildren() else {}) do
			if army:GetAttribute("Proprietaire") == countryId then
				for _, typeId in Units.kinds[Units.kindOf(army)].order do
					troops += (army:GetAttribute(typeId) :: number?) or 0
				end
			end
		end
		return troops, goal.target
	elseif goal.kind == "bloc" then
		return if DiplomacyState.blocOf(countryId) then 1 else 0, 1
	elseif goal.kind == "credits" then
		return Stocks.get(countryId, CURRENCY), goal.target
	elseif goal.kind == "conquer" then
		return if goal.region and RegionService.getOwner(goal.region) == countryId then 1 else 0, 1
	elseif goal.kind == "hold" then
		local since = math.max(chain.startedAt, StatsService.get(countryId).lastRegionLost)
		return math.floor(time() - since), goal.target
	elseif goal.kind == "exportRank" then
		local sold = StatsService.get(countryId).sold[goal.resource :: string] or 0
		local rank = StatsService.exportRank(countryId, goal.resource :: string)
		-- valeur affichée : 1 si le rang est atteint
		return if sold > 0 and rank <= goal.target then 1 else 0, 1
	end
	return 0, goal.target
end

-- Publie la chaîne d'un pays (dossier Objectifs)
local function publish(countryId: string, chain: Chain)
	local country = countryFolder(countryId)
	if not country then
		return
	end
	local folder = country:FindFirstChild("Objectifs")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Objectifs"
		folder.Parent = country
	end
	for i, goal in chain.goals do
		local item = folder:FindFirstChild("O" .. i) or Instance.new("Folder")
		item.Name = "O" .. i
		item:SetAttribute("Ordre", i)
		item:SetAttribute("Texte", goal.text)
		item:SetAttribute("Recompense", rewardText(goal.reward))
		local status = if i < chain.current then "Fait" elseif i == chain.current then "EnCours" else "AVenir"
		item:SetAttribute("Etat", status)
		if status == "EnCours" then
			local value, target = progress(countryId, chain, goal)
			item:SetAttribute("Valeur", math.clamp(value, 0, target))
			item:SetAttribute("But", target)
		elseif status == "Fait" then
			item:SetAttribute("Valeur", item:GetAttribute("But") or goal.target)
		end
		item.Parent = folder
	end
end

-- Chaîne d'un pays (créée à la première demande)
local function chainOf(countryId: string): Chain
	local chain = chains[countryId]
	if not chain then
		chain = buildChain(countryId)
		chain.baseline = cumulative(countryId, chain.goals[1])
		chains[countryId] = chain
	end
	return chain
end

-- Vérifie l'objectif en cours d'un pays ; récompense et passe au suivant s'il est atteint
local function check(countryId: string)
	local chain = chainOf(countryId)
	local goal = chain.goals[chain.current]
	while goal do
		local value, target = progress(countryId, chain, goal)
		if value < target then
			break
		end
		Stocks.addMany(countryId, goal.reward)
		for _, listener in completedListeners do
			task.spawn(listener, countryId)
		end
		chain.current += 1
		chain.startedAt = time()
		goal = chain.goals[chain.current]
		if goal then
			chain.baseline = cumulative(countryId, goal)
		end
	end
	publish(countryId, chain)
end

-- listener(pays) : un objectif national vient d'être atteint
function ObjectivesService.onCompleted(listener: (countryId: string) -> ())
	table.insert(completedListeners, listener)
end

-- Nouvelle partie : chaque pays repartira de son premier objectif
function ObjectivesService.reset()
	table.clear(chains)
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	for _, folder in (if pays then pays:GetChildren() else {}) do
		local list = folder:FindFirstChild("Objectifs")
		if list then
			list:Destroy()
		end
	end
end

-- À appeler au démarrage (après CountryAssignment.init et StatsService.start)
function ObjectivesService.start()
	task.spawn(function()
		while true do
			task.wait(Objectives.checkInterval)
			if not MatchState.isRunning() then
				continue
			end
			local state = ReplicatedStorage:FindFirstChild("EtatMonde")
			local pays = state and state:FindFirstChild("Pays")
			for _, folder in (if pays then pays:GetChildren() else {}) do
				if folder:GetAttribute("Joueur") ~= 0 then
					local ok, err = pcall(check, folder.Name)
					if not ok then
						warn(`[Objectifs] {folder.Name} : {err}`)
					end
				end
			end
		end
	end)
end

return ObjectivesService
