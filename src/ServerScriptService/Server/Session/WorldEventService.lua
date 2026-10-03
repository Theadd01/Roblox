--!strict
-- Événements mondiaux (Config/WorldEvents). Cahier des charges v2, section 1 : un événement est
-- lancé par un vote au Conseil mondial que propose un joueur (CouncilService -> trigger) ; le
-- tirage automatique (un toutes les quelques minutes) ne tourne que si WorldEvents.automatic.
-- Il agit sur le marché, des usines, une région ou un pays, puis il est publié : journal
-- (catégorie « Evenement ») et attributs de EtatMonde pour le bandeau des joueurs : Evenement
-- (titre), EvenementTexte, EvenementHeure.
-- Région sinistrée : attributs « Catastrophe » (heure de fin) et « CatastropheType » de
-- EtatMonde.Regions.<région> (ProductionService n'y produit plus rien jusque-là).
-- Usines arrêtées : attributs « ArretJusqua » et « ArretRaison » (lus par FactoryService).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local WorldEvents = require(Config:WaitForChild("WorldEvents")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local TechState = require(Shared:WaitForChild("TechState")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local Economy = Server:WaitForChild("Economy")
local MarketService = require(Economy:WaitForChild("MarketService"))
local Stocks = require(Economy:WaitForChild("Stocks"))
local Divisions = require(Server:WaitForChild("Military"):WaitForChild("Divisions"))
local Stability = require(Server:WaitForChild("Politics"):WaitForChild("Stability"))
local NewsService = require(Server:WaitForChild("News"):WaitForChild("NewsService"))

local WorldEventService = {}

local rng = Random.new()
local nextAt = WorldEvents.firstDelay -- en secondes de partie

local function now(): number
	return workspace:GetServerTimeNow()
end

local function nameOf(countryId: string): string
	return if Countries[countryId] then Countries[countryId].name else countryId
end

-- « 2 min » / « 90 s »
local function duration(seconds: number): string
	return if seconds >= 120 and seconds % 60 == 0 then `{seconds // 60} min` else `{seconds} s`
end

-- « de la France, de l'Inde et du Brésil »
local function ofList(countries: { string }): string
	local parts = {}
	for _, id in countries do
		table.insert(parts, FrenchNames.of(nameOf(id)))
	end
	if #parts <= 1 then
		return parts[1] or ""
	end
	return table.concat(parts, ", ", 1, #parts - 1) .. " et " .. parts[#parts]
end

local function shuffle<T>(list: { T }): { T }
	for i = #list, 2, -1 do
		local j = rng:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

-- Pays qui possèdent au moins une région (encore sur la carte)
local function aliveCountries(): { string }
	local seen: { [string]: boolean } = {}
	local list = {}
	for regionId in Regions do
		local owner = RegionService.getOwner(regionId)
		if owner and not seen[owner] then
			seen[owner] = true
			table.insert(list, owner)
		end
	end
	return list
end

local function pick(): any
	local total = 0
	for _, event in WorldEvents.list do
		total += event.weight
	end
	local roll = rng:NextNumber(0, total)
	for _, event in WorldEvents.list do
		roll -= event.weight
		if roll <= 0 then
			return event
		end
	end
	return WorldEvents.list[#WorldEvents.list]
end

-- Applique un événement ; renvoie le texte de l'annonce et les pays touchés (nil : rien à faire)
local function apply(event: any): (string?, { string })
	local text = event.text:gsub("{duration}", duration(event.duration or 0))
	if event.kind == "market" then
		for resourceId, factor in event.shocks do
			if resourceId == "all" then
				for _, id in Resources.order do
					MarketService.shock(id, factor)
				end
			else
				MarketService.shock(resourceId, factor)
			end
		end
		return text, {}
	elseif event.kind == "factories" then
		local state = ReplicatedStorage:FindFirstChild("EtatMonde")
		local usines = state and state:FindFirstChild("Usines")
		local byCountry: { [string]: { Instance } } = {}
		for _, factory in (if usines then usines:GetChildren() else {}) do
			local owner = factory:GetAttribute("Proprietaire")
			if typeof(owner) == "string" and not (event.immuneTech and TechState.has(owner, event.immuneTech)) then
				byCountry[owner] = byCountry[owner] or {}
				table.insert(byCountry[owner], factory)
			end
		end
		local candidates = {}
		for id in byCountry do
			table.insert(candidates, id)
		end
		if #candidates == 0 then
			return nil, {}
		end
		local hit = {}
		for _, id in shuffle(candidates) do
			if #hit >= (event.countries or 1) then
				break
			end
			table.insert(hit, id)
			for _, factory in byCountry[id] do
				factory:SetAttribute("ArretJusqua", now() + (event.duration or 60))
				factory:SetAttribute("ArretRaison", event.reason or "événement")
			end
			if event.stability then
				Stability.change(id, event.stability, event.reason or "événement mondial")
			end
		end
		return (text:gsub("{countries}", ofList(hit))), hit
	elseif event.kind == "disaster" then
		local regionIds = {}
		for regionId in Regions do
			table.insert(regionIds, regionId)
		end
		local regionId = regionIds[rng:NextInteger(1, #regionIds)]
		local owner = RegionService.getOwner(regionId)
		local state = ReplicatedStorage:FindFirstChild("EtatMonde")
		local folder = state and state:FindFirstChild("Regions") and state.Regions:FindFirstChild(regionId)
		if not owner or not folder then
			return nil, {}
		end
		folder:SetAttribute("Catastrophe", now() + (event.duration or 60))
		folder:SetAttribute("CatastropheType", `{event.icon} {string.lower(event.title)}`)
		if event.organisation then
			-- les divisions de la région sont désorganisées
			for _, d in Divisions.inRegion(regionId) do
				d:SetAttribute("Org", ((d:GetAttribute("Org") :: number?) or 0) * event.organisation)
			end
		end
		if event.stability then
			Stability.change(owner, event.stability, "catastrophe naturelle")
		end
		return (text:gsub("{region}", FrenchNames.the(Regions[regionId].name))), { owner }
	elseif event.kind == "discovery" then
		local alive = aliveCountries()
		if #alive == 0 then
			return nil, {}
		end
		local countryId = alive[rng:NextInteger(1, #alive)]
		local resourceId = WorldEvents.discoveryResources[rng:NextInteger(1, #WorldEvents.discoveryResources)]
		local resource = Resources.list[resourceId]
		Stocks.add(countryId, resourceId, event.amount or 50)
		local verb = if FrenchNames.isPlural(nameOf(countryId)) then "découvrent" else "découvre"
		return `{FrenchNames.The(nameOf(countryId))} {verb} un gisement : +{event.amount} {resource.icon} {string.lower(resource.name)}.`, { countryId }
	end
	return nil, {}
end

local function trigger(chosen: any?): boolean
	local event = chosen or pick()
	local text, countries = apply(event)
	if not text then
		return false
	end
	NewsService.publish(`{event.icon} {event.title} : {text}`, "Evenement", countries)
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	state:SetAttribute("EvenementTexte", text)
	state:SetAttribute("EvenementHeure", now())
	state:SetAttribute("Evenement", `{event.icon} {event.title}`)
	return true
end

-- Lance un événement précis (vote adopté au Conseil mondial) ; vrai s'il a eu lieu
function WorldEventService.trigger(eventId: string): boolean
	for _, event in WorldEvents.list do
		if event.id == eventId then
			local ok, result = pcall(trigger, event)
			if not ok then
				warn(`[Événements] {result}`)
				return false
			end
			return result == true
		end
	end
	return false
end

-- Nouvelle partie : le premier événement attendra de nouveau WorldEvents.firstDelay
function WorldEventService.reset()
	nextAt = WorldEvents.firstDelay
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	if state then
		state:SetAttribute("Evenement", "")
		state:SetAttribute("EvenementTexte", "")
		local regions = state:FindFirstChild("Regions")
		for _, folder in (if regions then regions:GetChildren() else {}) do
			folder:SetAttribute("Catastrophe", nil)
			folder:SetAttribute("CatastropheType", nil)
		end
	end
end

-- Déclenche un événement tout de suite (test dans Studio)
function WorldEventService.triggerNow()
	trigger()
end

-- À appeler au démarrage (après MatchService.start)
function WorldEventService.start()
	task.spawn(function()
		while true do
			task.wait(5)
			if WorldEvents.automatic and MatchState.isRunning() and MatchState.elapsed() >= nextAt and MatchState.timeLeft() > WorldEvents.quietEnd then
				nextAt = MatchState.elapsed() + rng:NextNumber(WorldEvents.interval.min, WorldEvents.interval.max)
				local ok, err = pcall(trigger)
				if not ok then
					warn(`[Événements] {err}`)
				end
			end
		end
	end)
end

return WorldEventService
