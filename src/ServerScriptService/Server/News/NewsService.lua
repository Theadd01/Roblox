--!strict
-- Journal télévisé mondial : flashs d'info générés à partir des vraies actions des pays
-- (guerres, paix, alliances, trahisons, conquêtes, révoltes, flambées des prix, leader),
-- avec le pseudo des joueurs (« La France de Lucas_78 déclare la guerre à l'Espagne »).
-- Publiés dans ReplicatedStorage.EtatMonde.Actualites.<id> (les News.keep plus récents) :
--   Texte, Categorie, Heure (heure serveur), Pays (« FRA,DEU » : pays concernés)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local News = require(Config:WaitForChild("News")) :: any
local Market = require(Config:WaitForChild("Market")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local MarketMath = require(Shared:WaitForChild("MarketMath")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local Politics = Server:WaitForChild("Politics")
local DiplomacyService = require(Politics:WaitForChild("DiplomacyService"))
local Stability = require(Politics:WaitForChild("Stability"))
local CouncilService = require(Politics:WaitForChild("CouncilService"))
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local Projects = require(Config:WaitForChild("Projects")) :: any
local ProjectService = require(Server:WaitForChild("Economy"):WaitForChild("ProjectService"))
local EspionageService = require(Politics:WaitForChild("EspionageService"))

local NewsService = {}

local folder: Folder? = nil
local nextId = 0
local lastMarketNews: { [string]: number } = {}

local function nameOf(countryId: string): string
	return if Countries[countryId] then Countries[countryId].name else countryId
end

-- Pseudo du joueur qui dirige le pays (« » pour l'IA)
local function playerOf(countryId: string): string
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	local country = pays and pays:FindFirstChild(countryId)
	local name = country and country:GetAttribute("JoueurNom")
	return if country and country:GetAttribute("Joueur") ~= 0 and typeof(name) == "string" and name ~= "" then name else ""
end

-- « La France de Lucas_78 » en début de phrase, « la France de Lucas_78 » ailleurs
local function subject(countryId: string): string
	local player = playerOf(countryId)
	return FrenchNames.The(nameOf(countryId)) .. (if player ~= "" then ` de {player}` else "")
end
local function object(countryId: string): string
	local player = playerOf(countryId)
	return FrenchNames.the(nameOf(countryId)) .. (if player ~= "" then ` de {player}` else "")
end
local function toCountry(countryId: string): string
	local player = playerOf(countryId)
	return FrenchNames.to(nameOf(countryId)) .. (if player ~= "" then ` de {player}` else "")
end

-- Verbe accordé avec le pays : « la France déclare », « les États-Unis déclarent »
local function verb(countryId: string, singular: string, plural: string): string
	return if FrenchNames.isPlural(nameOf(countryId)) then plural else singular
end

-- Publie un flash (rien pendant l'écran de fin de partie ni pendant la remise à zéro)
function NewsService.publish(text: string, category: string, countries: { string })
	local f = folder
	if not f or not MatchState.isRunning() then
		return
	end
	nextId += 1
	local item = Instance.new("Folder")
	item.Name = "N" .. nextId
	item:SetAttribute("Texte", text)
	item:SetAttribute("Categorie", category)
	item:SetAttribute("Heure", workspace:GetServerTimeNow())
	item:SetAttribute("Pays", table.concat(countries, ","))
	item.Parent = f
	-- on ne garde que les plus récents
	local items = f:GetChildren()
	if #items > News.keep then
		table.sort(items, function(a: Instance, b: Instance): boolean
			return (tonumber(a.Name:sub(2)) or 0) < (tonumber(b.Name:sub(2)) or 0)
		end)
		for i = 1, #items - News.keep do
			items[i]:Destroy()
		end
	end
end

local function regionCount(countryId: string): number
	local count = 0
	for regionId in Regions do
		if RegionService.getOwner(regionId) == countryId then
			count += 1
		end
	end
	return count
end

-- Vrai si `winner` ne tient qu'une seule région de départ de `loser` : celle qu'il vient de prendre
local function firstConquest(winner: string, loser: string): boolean
	local count = 0
	for regionId, region in Regions do
		if region.startOwner == loser and RegionService.getOwner(regionId) == winner then
			count += 1
		end
	end
	return count == 1
end

-- Flambées et effondrements des prix (après chaque recalcul du marché)
local function watchMarket()
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local marche = state:WaitForChild("Marche")
	while true do
		task.wait(Market.priceInterval)
		local now = time()
		for _, id in Resources.order do
			local history = MarketMath.parseHistory(marche:GetAttribute("Historique_" .. id))
			local change = MarketMath.variation(history, Market.variationPoints) / 100
			if math.abs(change) >= News.marketSwing and now - (lastMarketNews[id] or -math.huge) >= News.marketCooldown then
				lastMarketNews[id] = now
				local percent = math.floor(math.abs(change) * 100 + 0.5)
				local what = News.resources[id] or id
				NewsService.publish(if change > 0
					then `📈 Le prix {what} s'envole : +{percent} % en une minute`
					else `📉 Le prix {what} s'effondre : -{percent} % en une minute`, "Marche", {})
			end
		end
	end
end

-- Nouvelle partie : le journal repart de zéro
function NewsService.reset()
	if folder then
		folder:ClearAllChildren()
	end
	table.clear(lastMarketNews)
end

-- À appeler au démarrage (après DiplomacyService.init et Stability.init)
function NewsService.start()
	local actualites = Instance.new("Folder")
	actualites.Name = "Actualites"
	actualites.Parent = ReplicatedStorage:WaitForChild("EtatMonde")
	folder = actualites

	DiplomacyService.onWar(function(attacker: string, target: string)
		local bloc = DiplomacyState.blocName(target)
		NewsService.publish(`⚔️ {subject(attacker)} {verb(attacker, "déclare", "déclarent")} la guerre {toCountry(target)}`
			.. (if bloc then ` : {FrenchNames.the(bloc)} entre en guerre` else ""), "Guerre", { attacker, target })
	end)
	DiplomacyService.onPeace(function(a: string, b: string)
		NewsService.publish(`🕊️ Paix signée entre {object(a)} et {object(b)}`, "Paix", { a, b })
	end)
	DiplomacyService.onAlliance(function(blocName: string, joined: { string }, founded: boolean)
		if founded then
			NewsService.publish(`🤝 {subject(joined[1])} et {object(joined[2])} fondent {FrenchNames.the(blocName)}`, "Alliance", joined)
		else
			NewsService.publish(`🤝 {subject(joined[1])} {verb(joined[1], "rejoint", "rejoignent")} {FrenchNames.the(blocName)}`, "Alliance", joined)
		end
	end)
	DiplomacyService.onBetrayal(function(traitor: string, victims: { string })
		local list = table.clone(victims)
		table.insert(list, traitor)
		NewsService.publish(`🗡️ Trahison : {object(traitor)} {verb(traitor, "quitte", "quittent")} ses alliés en pleine guerre`, "Trahison", list)
	end)
	RegionService.onOwnerChanged(function(regionId: string, newOwner: string, oldOwner: string?, reason: string)
		local region = Regions[regionId]
		if not region or not oldOwner then
			return
		end
		local place = region.name
		if reason == "Revolte" then
			local plural = FrenchNames.isPlural(place)
			NewsService.publish(`✊ Révolte : {FrenchNames.the(place)} {if plural then "se soulèvent et chassent" else "se soulève et chasse"} {object(oldOwner)}`, "Revolte", { oldOwner, newOwner })
		elseif reason == "Soulevement" then
			NewsService.publish(`✊ Soulèvement : la résistance libère {FrenchNames.the(place)}, qui revient {toCountry(newOwner)}`, "Revolte", { oldOwner, newOwner })
		elseif regionId == oldOwner then
			-- la région qui porte le code du pays est celle de sa capitale
			NewsService.publish(`🚩 {subject(newOwner)} {verb(newOwner, "envahit", "envahissent")} {object(oldOwner)} et {verb(newOwner, "prend", "prennent")} {region.city and region.city.name or region.name}`, "Conquete", { newOwner, oldOwner })
		elseif playerOf(newOwner) ~= "" or playerOf(oldOwner) ~= "" or firstConquest(newOwner, oldOwner) then
			-- un pays compte plusieurs régions : entre deux IA, seule la première région prise fait
			-- la une (sinon le journal ne parlerait que de ça) ; tout ce qui touche un joueur est annoncé
			NewsService.publish(`🚩 {subject(newOwner)} {verb(newOwner, "s'empare", "s'emparent")} {FrenchNames.of(region.name)}`, "Conquete", { newOwner, oldOwner })
		end
		if regionCount(oldOwner) == 0 then
			NewsService.publish(`💀 {FrenchNames.The(nameOf(oldOwner))} {verb(oldOwner, "disparaît", "disparaissent")} de la carte`, "Conquete", { oldOwner })
		end
	end)
	-- leader de la partie (BalanceService)
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local lastLeader = ""
	state:GetAttributeChangedSignal("Leader"):Connect(function()
		local leader = state:GetAttribute("Leader")
		if typeof(leader) ~= "string" or leader == lastLeader then
			return
		end
		if leader ~= "" then
			NewsService.publish(`👑 {subject(leader)} {verb(leader, "domine", "dominent")} désormais la partie : ses voisins s'inquiètent`, "Leader", { leader })
		elseif lastLeader ~= "" then
			NewsService.publish(`⚖️ Plus aucun pays ne domine la partie`, "Leader", {})
		end
		lastLeader = leader
	end)
	CouncilService.onOpen(function(title: string)
		NewsService.publish(`🏛️ Le Conseil mondial vote : « {title} »`, "Conseil", {})
	end)
	CouncilService.onResult(function(title: string, adopted: boolean, yes: number, no: number)
		NewsService.publish(`🏛️ Le Conseil mondial {if adopted then "adopte" else "rejette"} « {title} » ({yes} pour, {no} contre)`, "Conseil", {})
	end)
	ProjectService.onEvent(function(event: string, projectId: string, countryId: string, other: string?)
		local project = Projects.list[projectId]
		if event == "Lancement" then
			NewsService.publish(`🚀 {subject(countryId)} {verb(countryId, "lance", "lancent")} le projet {project.icon} {project.name}`, "Projet", { countryId })
		elseif event == "Termine" then
			NewsService.publish(`{project.icon} {subject(countryId)} {verb(countryId, "achève", "achèvent")} le projet {project.name} : +{Projects.scoreBonus} points au classement final`, "Projet", { countryId })
		elseif event == "Sabotage" and other then
			NewsService.publish(`💥 Sabotage : {subject(other)} {verb(other, "retarde", "retardent")} le projet {project.name} {FrenchNames.of(nameOf(countryId))}`, "Projet", { other, countryId })
		elseif event == "Capitale" then
			NewsService.publish(`🏚️ {subject(countryId)} {verb(countryId, "perd sa", "perdent leur")} capitale : le projet {project.name} recule`, "Projet", { countryId })
		end
	end)
	EspionageService.onEvent(function(event: string, spy: string, target: string, regionId: string)
		local place = Regions[regionId] and Regions[regionId].name or regionId
		if event == "Sabotage" then
			NewsService.publish(`💥 Sabotage : une usine {FrenchNames.of(place)} est à l'arrêt`, "Espionnage", { target })
		elseif event == "Vol" then
			NewsService.publish(`🧪 Vol de technologie : des plans secrets {FrenchNames.of(nameOf(target))} ont disparu`, "Espionnage", { target })
		elseif event == "Demasque" then
			NewsService.publish(`🕵️ Des espions {FrenchNames.of(nameOf(spy))} démasqués sur le territoire {FrenchNames.of(nameOf(target))}`, "Espionnage", { target, spy })
		end
	end)
	task.spawn(watchMarket)
end

return NewsService
