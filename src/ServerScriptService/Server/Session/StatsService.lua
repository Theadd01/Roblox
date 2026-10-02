--!strict
-- Statistiques de la partie, pays par pays (pour les objectifs nationaux et l'écran de fin) :
-- ventes (par ressource et en crédits), plus grosse vente, contrats signés, conquêtes, régions
-- perdues, batailles gagnées et perdues. Les services appellent record* ; le reste est écouté ici.
-- Bilan de fin de partie (StatsService.highlights) : meilleur général, plus grosse vente,
-- plus longue alliance, plus grande trahison.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Countries = require(Config:WaitForChild("Countries")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local FrenchNames = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FrenchNames")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))

export type Stats = {
	sold: { [string]: number }, -- unités vendues par ressource (marché et contrats)
	soldValue: number, -- crédits reçus pour ces ventes
	bestSale: number, -- plus grosse vente (crédits)
	contracts: number, -- contrats signés
	conquests: number, -- régions prises
	conquered: { [string]: boolean }, -- régions prises (identifiants)
	regionsLost: number,
	battlesWon: number,
	battlesLost: number,
	lastRegionLost: number, -- heure (time()) de la dernière région perdue
}

local StatsService = {}

local stats: { [string]: Stats } = {}
local eventListeners: { (kind: string, countryId: string, a: number, b: number) -> () } = {}

local function emit(kind: string, countryId: string, a: number, b: number)
	for _, listener in eventListeners do
		task.spawn(listener, kind, countryId, a, b)
	end
end

-- bilan de la partie
type General = { name: string, owner: string, wins: number, experience: number }
local generals: { [string]: General } = {} -- armée -> victoires de son général
local bestSale = { country = "", resource = "", quantity = 0, credits = 0 }
local longestAlliance = { name = "", members = {} :: { string }, duration = 0 }
local biggestBetrayal = { traitor = "", victims = {} :: { string } }

local function nameOf(countryId: string): string
	return if Countries[countryId] then Countries[countryId].name else countryId
end

-- « 12 400 »
local function format(n: number): string
	local text = tostring(math.floor(n + 0.5))
	local result = text:reverse():gsub("(%d%d%d)", "%1 "):reverse()
	return (result:gsub("^ ", ""))
end

-- Statistiques d'un pays (créées au besoin)
function StatsService.get(countryId: string): Stats
	local s = stats[countryId]
	if not s then
		s = {
			sold = {},
			soldValue = 0,
			bestSale = 0,
			contracts = 0,
			conquests = 0,
			conquered = {},
			regionsLost = 0,
			battlesWon = 0,
			battlesLost = 0,
			lastRegionLost = -math.huge,
		}
		stats[countryId] = s
	end
	return s
end

-- Une vente (marché mondial ou livraison d'un contrat)
function StatsService.recordSale(countryId: string, resourceId: string, quantity: number, credits: number)
	if not Countries[countryId] then
		return
	end
	local s = StatsService.get(countryId)
	s.sold[resourceId] = (s.sold[resourceId] or 0) + quantity
	s.soldValue += credits
	s.bestSale = math.max(s.bestSale, credits)
	if credits > bestSale.credits then
		bestSale = { country = countryId, resource = resourceId, quantity = quantity, credits = credits }
	end
	emit("vente", countryId, quantity, credits)
end

-- Un contrat signé entre deux pays
function StatsService.recordContract(a: string, b: string)
	StatsService.get(a).contracts += 1
	StatsService.get(b).contracts += 1
	emit("contrat", a, 1, 0)
	emit("contrat", b, 1, 0)
end

-- listener(sorte, pays, a, b) : « vente » (a = quantité, b = crédits) ou « contrat » (a = 1)
function StatsService.onEvent(listener: (kind: string, countryId: string, a: number, b: number) -> ())
	table.insert(eventListeners, listener)
end

-- Rang d'un pays parmi les vendeurs d'une ressource (1 = premier), sur toute la partie
function StatsService.exportRank(countryId: string, resourceId: string): number
	local mine = StatsService.get(countryId).sold[resourceId] or 0
	local rank = 1
	for other, s in stats do
		if other ~= countryId and (s.sold[resourceId] or 0) > mine then
			rank += 1
		end
	end
	return rank
end

-- Tous les pays suivis (pour les classements)
function StatsService.all(): { [string]: Stats }
	return stats
end

-- Bilan de la partie, en phrases prêtes à afficher (écran de fin)
function StatsService.highlights(): { general: string, sale: string, alliance: string, betrayal: string }
	-- meilleur général : le plus de victoires, puis le plus d'expérience (forces encore en vie comprises)
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local armees = state and state:FindFirstChild("Armees")
	local candidates: { General } = {}
	for _, g in generals do
		table.insert(candidates, g)
	end
	for _, army in (if armees then armees:GetChildren() else {}) do
		local experience = army:GetAttribute("Experience")
		local g = generals[army.Name]
		if g then
			if typeof(experience) == "number" then
				g.experience = experience
			end
		else
			table.insert(candidates, {
				name = tostring(army:GetAttribute("Nom")),
				owner = tostring(army:GetAttribute("Proprietaire")),
				wins = 0,
				experience = if typeof(experience) == "number" then experience else 0,
			})
		end
	end
	local best: General? = nil
	for _, g in candidates do
		if not best or g.wins > best.wins or (g.wins == best.wins and g.experience > best.experience) then
			best = g
		end
	end
	local general = "Aucun général ne s'est illustré."
	if best and (best.wins > 0 or best.experience > 0) then
		general = `{best.name} ({nameOf(best.owner)}) : {best.wins} victoire{if best.wins > 1 then "s" else ""}, {math.floor(best.experience)} points d'expérience`
	end

	local sale = "Aucune vente."
	if bestSale.credits > 0 then
		local r = Resources.list[bestSale.resource]
		local what = if r then r.icon .. " " .. string.lower(r.name) else bestSale.resource
		sale = `{FrenchNames.The(nameOf(bestSale.country))} : {format(bestSale.quantity)} {what} pour {format(bestSale.credits)} {Resources.currency.icon}`
	end

	-- plus longue alliance : blocs dissous pendant la partie, et blocs encore en place
	local longest = { name = longestAlliance.name, members = longestAlliance.members, duration = longestAlliance.duration }
	local diplomatie = state and state:FindFirstChild("Diplomatie")
	local blocs = diplomatie and diplomatie:FindFirstChild("Blocs")
	local now = workspace:GetServerTimeNow()
	for _, bloc in (if blocs then blocs:GetChildren() else {}) do
		local founded = bloc:GetAttribute("Fondation")
		if typeof(founded) == "number" and now - founded > longest.duration then
			local members = string.split(tostring(bloc:GetAttribute("Membres") or ""), ",")
			longest = { name = tostring(bloc:GetAttribute("Nom")), members = members, duration = now - founded }
		end
	end
	local alliance = "Aucune alliance."
	if longest.name ~= "" then
		local names = {}
		for _, id in longest.members do
			table.insert(names, nameOf(id))
		end
		alliance = `{FrenchNames.The(longest.name)} : {math.max(1, math.floor(longest.duration / 60))} min ({table.concat(names, ", ")})`
	end

	local betrayal = "Aucune trahison."
	if biggestBetrayal.traitor ~= "" then
		local n = #biggestBetrayal.victims
		betrayal = `{FrenchNames.The(nameOf(biggestBetrayal.traitor))} a abandonné {n} allié{if n > 1 then "s" else ""} en pleine guerre`
	end
	return { general = general, sale = sale, alliance = alliance, betrayal = betrayal }
end

-- Nouvelle partie : toutes les statistiques repartent de zéro
function StatsService.reset()
	table.clear(stats)
	table.clear(generals)
	bestSale = { country = "", resource = "", quantity = 0, credits = 0 }
	longestAlliance = { name = "", members = {}, duration = 0 }
	biggestBetrayal = { traitor = "", victims = {} }
end

-- À appeler au démarrage (après BattleService.init)
function StatsService.start()
	RegionService.onOwnerChanged(function(regionId: string, newOwner: string, oldOwner: string?)
		local s = StatsService.get(newOwner)
		s.conquests += 1
		s.conquered[regionId] = true
		if oldOwner then
			local lost = StatsService.get(oldOwner)
			lost.regionsLost += 1
			lost.lastRegionLost = time()
		end
	end)
	local BattleService = require(Server:WaitForChild("Military"):WaitForChild("BattleService"))
	BattleService.onResult(function(result: string, attacker: string, defender: string, _regionId: string, army: Instance?)
		if result == "Victoire" then
			StatsService.get(attacker).battlesWon += 1
			StatsService.get(defender).battlesLost += 1
			if not army then
				return -- bataille terrestre : pas de chef d'escadrille ou de flotte à compter
			end
			local g = generals[army.Name]
			if not g then
				g = { name = tostring(army:GetAttribute("Nom")), owner = attacker, wins = 0, experience = 0 }
				generals[army.Name] = g
			end
			g.wins += 1
			local experience = army:GetAttribute("Experience")
			if typeof(experience) == "number" then
				g.experience = experience
			end
		else
			StatsService.get(attacker).battlesLost += 1
			StatsService.get(defender).battlesWon += 1
		end
	end)
	local DiplomacyService = require(Server:WaitForChild("Politics"):WaitForChild("DiplomacyService"))
	DiplomacyService.onBetrayal(function(traitor: string, victims: { string })
		if #victims >= #biggestBetrayal.victims then
			biggestBetrayal = { traitor = traitor, victims = table.clone(victims) }
		end
	end)
	DiplomacyService.onBlocDissolved(function(blocName: string, members: { string }, duration: number)
		if duration > longestAlliance.duration then
			longestAlliance = { name = blocName, members = table.clone(members), duration = duration }
		end
	end)
end

return StatsService
