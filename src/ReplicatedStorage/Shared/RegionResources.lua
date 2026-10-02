--!strict
-- Production de base des régions (unités par cycle, au dixième près), calculée depuis la configuration.
-- Chaque pays produit la MÊME valeur (Config/Economy.national.value, au prix de base du marché),
-- partagée selon ses spécialités : la nourriture selon sa fertilité, et ses gisements les plus
-- importants (Config/ResourceDeposits). La France fait surtout du blé et n'a pas de pétrole ;
-- l'Iran fait du pétrole et du gaz, et le minimum de blé.
-- La production d'un pays est ensuite répartie entre ses régions (et ses territoires : Groenland
-- pour le Danemark...) : gisements selon les gisements de chaque territoire, puis selon la taille
-- des régions, un peu dispersés au hasard (toujours le même) ; nourriture selon la taille.
-- Une région conquise produit moins pour son occupant (Config/Economy.occupiedProduction).

local Config = script.Parent.Config
local Types = require(script.Parent.Types)
local Economy = require(Config.Economy)
local Market = require(Config.Market)
local MapGeometry = require(Config.MapGeometry)
local Regions = require(Config.Regions)
local Resources = require(Config.Resources)
local ResourceDeposits = require(Config.ResourceDeposits)

local RegionResources = {}

local fertility: { [string]: number } = {}
local class: { [string]: string } = {}
for _, id in ResourceDeposits.fertile do
	fertility[id] = Economy.fertileFactor
	class[id] = "fertile"
end
for _, id in ResourceDeposits.arid do
	fertility[id] = Economy.aridFactor
	class[id] = "arid"
end

-- Pays d'origine d'une région : « FRA_3 » -> « FRA », « NCL » -> « NCL »
local function homeOf(regionId: string): string
	return regionId:match("^(%u+)") or regionId
end

-- Nombre pseudo-aléatoire stable entre 0 et 1 (même résultat à chaque lancement)
local function noise(key: string): number
	local h = 7
	for i = 1, #key do
		h = (h * 31 + string.byte(key, i)) % 1000003
	end
	return h / 1000003
end

local function round1(x: number): number
	return math.floor(x * 10 + 0.5) / 10
end

-- Partage `amount` unités entre des clés selon leurs poids (méthode des plus forts restes :
-- le total reste exact)
local function share(amount: number, weights: { [string]: number }): { [string]: number }
	local total = 0
	for _, w in weights do
		total += w
	end
	local result: { [string]: number } = {}
	local rests = {}
	local given = 0
	for id, w in weights do
		local exact = if total > 0 then amount * w / total else 0
		local whole = math.floor(exact)
		result[id] = whole
		given += whole
		table.insert(rests, { id = id, rest = exact - whole })
	end
	table.sort(rests, function(a, b): boolean
		if a.rest == b.rest then
			return a.id < b.id
		end
		return a.rest > b.rest
	end)
	for i = 1, amount - given do
		local entry = rests[i]
		if entry then
			result[entry.id] += 1
		end
	end
	return result
end

-- territoires (pays d'origine) : leurs régions avec leur surface, et le pays qui les possède au départ
type Group = { owner: string, areas: { [string]: number }, area: number }
local groups: { [string]: Group } = {}
for regionId, region in Regions do
	local home = homeOf(regionId)
	local g = groups[home]
	if not g then
		g = { owner = region.startOwner :: string, areas = {}, area = 0 }
		groups[home] = g
	end
	local shape = MapGeometry.countries[region.geometry]
	local area = if shape then math.max(shape.area, 1) else 1
	g.areas[regionId] = area
	g.area += area
end
local homesOf: { [string]: { string } } = {}
for home, g in groups do
	local list = homesOf[g.owner] or {}
	homesOf[g.owner] = list
	table.insert(list, home)
end

-- Nourriture d'un territoire d'après sa taille et sa fertilité (sert à partager celle du pays)
local function territoryFood(home: string): number
	local g = groups[home]
	local base = math.clamp(math.floor(math.sqrt(g.area) / Economy.foodAreaDivisor + 0.5), Economy.foodMin, Economy.foodMax)
	return math.max(1, base * (fertility[home] or 1))
end

-- Production nationale d'un pays : même valeur pour tous, partagée selon ses spécialités
local function nationalOf(countryId: string, homes: { string }): Types.Production
	local N = Economy.national
	local deposits = {}
	for resourceId, producers in ResourceDeposits.deposits do
		local weight = 0
		for _, home in homes do
			weight += producers[home] or 0
		end
		if weight > 0 then
			table.insert(deposits, { id = resourceId, weight = weight })
		end
	end
	table.sort(deposits, function(a, b): boolean
		if a.weight == b.weight then
			return a.id < b.id
		end
		return a.weight > b.weight
	end)
	local kept = {}
	for i, entry in deposits do
		if i <= N.maxSpecialties and entry.weight >= deposits[1].weight * N.minSpecialtyShare then
			table.insert(kept, entry)
		end
	end
	local foodWeight = N.foodWeight[class[countryId] or "normal"]
	local total = foodWeight
	for _, entry in kept do
		total += entry.weight
	end
	local production: Types.Production = {
		Nourriture = math.max(N.foodMin, round1(N.value * foodWeight / total / Market.basePrices.Nourriture)),
	}
	for _, entry in kept do
		production[entry.id] = math.max(0.1, round1(N.value * entry.weight / total / Market.basePrices[entry.id]))
	end
	return production
end

-- calcul une fois pour toutes au chargement
local national: { [string]: Types.Production } = {}
local byRegion: { [string]: Types.Production } = {}
for regionId in Regions do
	byRegion[regionId] = {}
end
for countryId, homes in homesOf do
	table.sort(homes)
	local production = nationalOf(countryId, homes)
	national[countryId] = production
	for resourceId, amount in production do
		-- entre territoires : selon leurs gisements (nourriture : selon leur taille et leur fertilité)
		local territoryWeights: { [string]: number } = {}
		for _, home in homes do
			local weight = if resourceId == "Nourriture" then territoryFood(home) else (ResourceDeposits.deposits[resourceId][home] or 0)
			if weight > 0 then
				territoryWeights[home] = weight
			end
		end
		for home, tenths in share(math.floor(amount * 10 + 0.5), territoryWeights) do
			if tenths <= 0 then
				continue
			end
			-- entre régions : selon leur taille (gisements un peu dispersés au hasard)
			local regionWeights: { [string]: number } = {}
			for regionId, area in groups[home].areas do
				regionWeights[regionId] = if resourceId == "Nourriture" then area else area * (0.3 + 1.4 * noise(regionId .. resourceId))
			end
			for regionId, part in share(tenths, regionWeights) do
				if part > 0 then
					byRegion[regionId][resourceId] = part / 10
				end
			end
		end
	end
end

-- Production d'une région (table vide si inconnue). Ne pas modifier la table renvoyée.
function RegionResources.production(regionId: string): Types.Production
	return byRegion[regionId] or {}
end

-- Production de base d'un pays (toutes ses régions de départ). Ne pas modifier la table renvoyée.
function RegionResources.national(countryId: string): Types.Production
	return national[countryId] or {}
end

-- Part de la production d'une région qui revient à son propriétaire (1 ; moins si elle est conquise)
function RegionResources.ownerFactor(regionId: string, ownerId: string?): number
	local region = Regions[regionId]
	return if region and region.startOwner ~= ownerId then Economy.occupiedProduction else 1
end

-- Ressources d'une production, de la plus abondante à la moins abondante (en valeur)
function RegionResources.sorted(production: Types.Production): { string }
	local list = {}
	for _, id in Resources.order do
		if (production[id] or 0) > 0 then
			table.insert(list, id)
		end
	end
	local function value(id: string): number
		return production[id] * (Market.basePrices[id] or 1)
	end
	table.sort(list, function(a: string, b: string): boolean
		if value(a) == value(b) then
			return a < b
		end
		return value(a) > value(b)
	end)
	return list
end

-- Production totale des régions possédées : ownerOf(regionId) donne le propriétaire actuel
-- (régions conquises comptées pour leur part, voir ownerFactor)
function RegionResources.countryProduction(countryId: string, ownerOf: (string) -> string?): Types.Production
	local total: Types.Production = {}
	for regionId, production in byRegion do
		if ownerOf(regionId) == countryId then
			local factor = RegionResources.ownerFactor(regionId, countryId)
			for resourceId, amount in production do
				total[resourceId] = (total[resourceId] or 0) + amount * factor
			end
		end
	end
	for resourceId, amount in total do
		total[resourceId] = round1(amount)
	end
	return total
end

return RegionResources
