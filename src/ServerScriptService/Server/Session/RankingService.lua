--!strict
-- Classement de fin de partie : chaque pays est noté de 0 à 100 dans quatre domaines
-- (100 = le meilleur pays du domaine), puis un score total pondéré (Config/Match.scoreWeights) :
--   Territoire : régions possédées. Chaque pays de départ vaut autant qu'une région quand la carte
--                comptait une région par pays (garnison complète d'après sa taille), partagé entre
--                ses régions selon leur surface : découper un pays ne le rend pas plus précieux
--   Économie   : crédits + stocks au prix du marché + usines (coût de construction et d'amélioration)
--   Militaire  : forces encore en vie (attaque × vie de chaque unité)
--   Commerce   : ventes de la partie (marché et contrats) + contrats signés
-- Chaque projet décisif remporté ajoute Projects.scoreBonus points au score total.
-- Publié dans ReplicatedStorage.EtatMonde.Classement (voir RankingService.publish).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Match = require(Config:WaitForChild("Match")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local Factories = require(Config:WaitForChild("Factories")) :: any
local Combat = require(Config:WaitForChild("Combat")) :: any
local Units = require(Config:WaitForChild("Units")) :: any
local DivisionConfig = require(Config:WaitForChild("Divisions")) :: any
local Projects = require(Config:WaitForChild("Projects")) :: any
local ProjectState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ProjectState")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local Stocks = require(Server:WaitForChild("Economy"):WaitForChild("Stocks"))
local MarketService = require(Server:WaitForChild("Economy"):WaitForChild("MarketService"))
local MapGeometry = require(Config:WaitForChild("MapGeometry")) :: any
local CountryStats = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CountryStats")) :: any
local StatsService = require(script.Parent:WaitForChild("StatsService"))

local CURRENCY: string = Resources.currency.id
local DIVISION_WEIGHT = 15 -- poids d'une division (somme de ses statistiques de combat) dans la puissance militaire

export type Entry = {
	country: string,
	score: number,
	domains: { [string]: number }, -- note de 0 à 100 par domaine
	projects: string, -- icônes des projets décisifs remportés (bonus compris dans le score)
	rank: number,
}

local RankingService = {}

-- Valeur de territoire d'une région : part (selon la surface) de la valeur de son pays de départ
local function territoryValue(regionId: string): number
	local region = Regions[regionId]
	local shape = region and MapGeometry.countries[region.geometry]
	local total = if region then CountryStats.area(region.startOwner) else 0
	if not shape or total <= 0 then
		return 0
	end
	local countryValue = math.clamp(3 + math.floor(math.sqrt(total) / 20), 3, 12)
	return countryValue * shape.area / total
end

local function state(): Instance?
	return ReplicatedStorage:FindFirstChild("EtatMonde")
end

-- Valeur des crédits dépensés pour une usine (construction + améliorations jusqu'à son niveau)
local function factoryValue(factory: Instance): number
	local kind = Factories.types[factory:GetAttribute("Type") :: string]
	if not kind then
		return 0
	end
	local value = kind.buildCost[CURRENCY] or 0
	local level = (factory:GetAttribute("Niveau") :: number?) or 1
	for l = 2, level do
		local cost = kind.upgradeCosts[l]
		value += if cost then cost[CURRENCY] or 0 else 0
	end
	return value
end

-- Valeurs brutes de chaque domaine, pays par pays
local function rawValues(): { [string]: { [string]: number } }
	local raw: { [string]: { [string]: number } } = {}
	for countryId in Countries do
		raw[countryId] = { Territoire = 0, Economie = 0, Militaire = 0, Commerce = 0 }
	end
	-- territoire
	for regionId in Regions do
		local owner = RegionService.getOwner(regionId)
		if owner and raw[owner] then
			raw[owner].Territoire += territoryValue(regionId)
		end
	end
	-- économie : crédits et stocks au prix du marché
	for countryId, values in raw do
		local wealth = Stocks.get(countryId, CURRENCY)
		for _, resourceId in Resources.order do
			wealth += Stocks.get(countryId, resourceId) * (MarketService.price(resourceId) or 0)
		end
		values.Economie = wealth
	end
	local s = state()
	local usines = s and s:FindFirstChild("Usines")
	for _, factory in (if usines then usines:GetChildren() else {}) do
		local owner = factory:GetAttribute("Proprietaire")
		if typeof(owner) == "string" and raw[owner] then
			raw[owner].Economie += factoryValue(factory)
		end
	end
	-- puissance militaire : les forces encore en vie
	local armees = s and s:FindFirstChild("Armees")
	for _, army in (if armees then armees:GetChildren() else {}) do
		local owner = army:GetAttribute("Proprietaire")
		if typeof(owner) == "string" and raw[owner] then
			local kind = Units.kinds[Units.kindOf(army)]
			for _, typeId in kind.order do
				local count = (army:GetAttribute(typeId) :: number?) or 0
				local unit = Combat.units[typeId]
				if unit and count > 0 then
					raw[owner].Militaire += count * unit.attack * unit.health
				end
			end
		end
	end
	-- divisions terrestres : leurs statistiques de combat, selon leur force restante
	local divisions = s and s:FindFirstChild("Divisions")
	for _, d in (if divisions then divisions:GetChildren() else {}) do
		local owner = d:GetAttribute("Proprietaire")
		local t = DivisionConfig.types[d:GetAttribute("Type") :: string]
		if typeof(owner) == "string" and raw[owner] and t then
			local force = (d:GetAttribute("Force") :: number?) or 0
			raw[owner].Militaire += (t.soft + t.hard + t.defense + t.breakthrough) * force / 100 * DIVISION_WEIGHT
		end
	end
	-- commerce : ventes et contrats de la partie
	for countryId, stats in StatsService.all() do
		if raw[countryId] then
			raw[countryId].Commerce = stats.soldValue + stats.contracts * Match.contractValue
		end
	end
	return raw
end

-- Classement complet, du premier au dernier
function RankingService.compute(): { Entry }
	local raw = rawValues()
	local best: { [string]: number } = {}
	for _, values in raw do
		for domain, value in values do
			best[domain] = math.max(best[domain] or 0, value)
		end
	end
	local list: { Entry } = {}
	for countryId, values in raw do
		local domains: { [string]: number } = {}
		local score = 0
		for domain, weight in Match.scoreWeights do
			local note = if (best[domain] or 0) > 0 then values[domain] / best[domain] * 100 else 0
			domains[domain] = math.floor(note + 0.5)
			score += note * weight
		end
		local icons = ""
		for _, id in Projects.order do
			if ProjectState.winner(id) == countryId then
				score += Projects.scoreBonus
				icons ..= Projects.list[id].icon
			end
		end
		table.insert(list, { country = countryId, score = math.floor(score * 10 + 0.5) / 10, domains = domains, projects = icons, rank = 0 })
	end
	table.sort(list, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.country < b.country
	end)
	for i, entry in list do
		entry.rank = i
	end
	return list
end

-- Publie le classement et le bilan dans EtatMonde.Classement :
--   attributs du dossier : Vainqueur, Champion_<domaine>, MeilleurGeneral, PlusGrosseVente,
--     PlusLongueAlliance, PlusGrandeTrahison, Pays (nombre de pays classés)
--   un dossier par pays affiché (les Match.rankingSize premiers et les pays des joueurs) :
--     Rang, Pays, Score, Territoire, Economie, Militaire, Commerce, Joueur (pseudo ou « »)
function RankingService.publish(list: { Entry }, highlights: { [string]: string })
	local s = state()
	if not s then
		return
	end
	local old = s:FindFirstChild("Classement")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "Classement"
	folder:SetAttribute("Pays", #list)
	folder:SetAttribute("Vainqueur", if list[1] then list[1].country else "")
	folder:SetAttribute("MeilleurGeneral", highlights.general)
	folder:SetAttribute("PlusGrosseVente", highlights.sale)
	folder:SetAttribute("PlusLongueAlliance", highlights.alliance)
	folder:SetAttribute("PlusGrandeTrahison", highlights.betrayal)
	-- champion de chaque domaine (meilleure note, à égalité le mieux classé)
	for _, domain in Match.domains do
		local champion: Entry? = nil
		for _, entry in list do
			if not champion or entry.domains[domain.id] > champion.domains[domain.id] then
				champion = entry
			end
		end
		folder:SetAttribute("Champion_" .. domain.id, if champion then champion.country else "")
	end
	local pays = s:FindFirstChild("Pays")
	for _, entry in list do
		local country = pays and pays:FindFirstChild(entry.country)
		local player = country and country:GetAttribute("JoueurNom")
		local isPlayer = country ~= nil and country:GetAttribute("Joueur") ~= 0
		if entry.rank <= Match.rankingSize or isPlayer then
			local item = Instance.new("Folder")
			item.Name = "R" .. entry.rank
			item:SetAttribute("Rang", entry.rank)
			item:SetAttribute("Pays", entry.country)
			item:SetAttribute("Score", entry.score)
			for domain, note in entry.domains do
				item:SetAttribute(domain, note)
			end
			item:SetAttribute("Joueur", if isPlayer and typeof(player) == "string" then player else "")
			item:SetAttribute("Projets", entry.projects)
			-- titre affiché du joueur (succès choisi), s'il en a un
			local title = ""
			for _, player in game:GetService("Players"):GetPlayers() do
				local mine = player:GetAttribute("Titre")
				if player:GetAttribute("Pays") == entry.country and typeof(mine) == "string" then
					title = mine
				end
			end
			item:SetAttribute("Titre", title)
			item.Parent = folder
		end
	end
	folder.Parent = s
end

return RankingService
