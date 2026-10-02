--!strict
-- Stabilité intérieure des pays (0 à 100 %), publiée dans l'attribut « Stabilite » de
-- ReplicatedStorage.EtatMonde.Pays.<code>, avec ses causes du moment dans « StabiliteRaisons ».
-- Seul le serveur la modifie (Config/Politics.stability) :
--   - elle baisse avec les pertes (unités tuées, régions perdues), les pénuries de ses armées,
--     les guerres qui durent et les conquêtes trop nombreuses ; elle remonte en paix ;
--   - ses effets (production, coût du recrutement) sont dans shared/StabilityRules ;
--   - sous Politics.revolt.below, chaque région conquise peut se révolter et revenir à son pays.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Politics = require(Config:WaitForChild("Politics")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local Divisions = require(Server:WaitForChild("Military"):WaitForChild("Divisions"))

local EVENT_MEMORY = 60 -- secondes pendant lesquelles un événement reste dans les causes affichées

type Event = { text: string, delta: number, at: number }

local Stability = {}

local exact: { [string]: number } = {} -- valeur précise (la valeur publiée est arrondie)
local events: { [string]: { Event } } = {}
local revoltListeners: { (regionId: string, from: string, to: string) -> () } = {}
local rng = Random.new()

local function folderFor(countryId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
end

local function publish(countryId: string)
	local folder = folderFor(countryId)
	if folder then
		folder:SetAttribute("Stabilite", math.clamp(math.floor((exact[countryId] or 0) + 0.5), 0, 100))
	end
end

-- « −0,3 » / « +3 »
local function signed(x: number): string
	local text = if x == math.floor(x) then tostring(math.abs(x)) else (string.format("%.1f", math.abs(x)):gsub("%.", ","))
	return (if x >= 0 then "+" else "−") .. text
end

function Stability.get(countryId: string): number
	if exact[countryId] then
		return exact[countryId]
	end
	local folder = folderFor(countryId)
	local value = folder and folder:GetAttribute("Stabilite")
	return if typeof(value) == "number" then value else Politics.startingStability
end

function Stability.set(countryId: string, value: number)
	if typeof(value) == "number" and value == value then
		exact[countryId] = math.clamp(value, 0, 100)
		publish(countryId)
	end
end

-- Événement ponctuel (région perdue, pertes au combat...) : change la stabilité tout de suite
function Stability.change(countryId: string, delta: number, reason: string)
	if not Countries[countryId] or delta == 0 then
		return
	end
	Stability.set(countryId, Stability.get(countryId) + delta)
	local list = events[countryId] or {}
	events[countryId] = list
	table.insert(list, { text = reason, delta = delta, at = time() })
end

-- listener(région, ancien propriétaire, pays libéré) : une région conquise s'est révoltée
function Stability.onRevolt(listener: (regionId: string, from: string, to: string) -> ())
	table.insert(revoltListeners, listener)
end

-- Un cycle de production : pénuries, guerres, conquêtes, paix, puis révoltes
function Stability.tick()
	local S = Politics.stability
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	local armees = state and state:FindFirstChild("Armees")
	local serverNow = workspace:GetServerTimeNow()

	-- ressources qui manquent aux armées de chaque pays
	local missing: { [string]: { [string]: boolean } } = {}
	for _, army in (if armees then armees:GetChildren() else {}) do
		local shortage = army:GetAttribute("Penurie")
		if typeof(shortage) == "string" and shortage ~= "" then
			local owner = army:GetAttribute("Proprietaire") :: string
			missing[owner] = missing[owner] or {}
			for name in shortage:gmatch("[^,]+") do
				missing[owner][(name:gsub("^%s+", ""))] = true
			end
		end
	end
	-- régions conquises par pays
	local conquered: { [string]: { string } } = {}
	for regionId, region in Regions do
		local owner = RegionService.getOwner(regionId)
		if owner and owner ~= region.startOwner then
			conquered[owner] = conquered[owner] or {}
			table.insert(conquered[owner], regionId)
		end
	end

	for _, folder in (if pays then pays:GetChildren() else {}) do
		local id = folder.Name
		local reasons = {}
		local delta = 0
		local shortages = 0
		for _ in missing[id] or {} do
			shortages += 1
		end
		if shortages > 0 then
			delta -= shortages * S.shortage
			table.insert(reasons, `pénurie {signed(-shortages * S.shortage)}`)
		end
		-- la population n'a pas eu assez à manger (PopulationService)
		if folder:GetAttribute("Famine") == true then
			delta -= S.shortage
			table.insert(reasons, `famine {signed(-S.shortage)}`)
		end
		local enemies = DiplomacyState.enemiesOf(id)
		local weariness = 0
		for _, enemy in enemies do
			local since = DiplomacyState.warSince(id, enemy)
			if since and serverNow - since >= S.warWearinessAfter then
				weariness += S.warWeariness
			end
		end
		weariness = math.min(weariness, S.maxWarWeariness)
		if weariness > 0 then
			delta -= weariness
			table.insert(reasons, `guerre qui dure {signed(-weariness)}`)
		end
		local extra = #(conquered[id] or {}) - S.freeConquests
		if extra > 0 then
			delta -= extra * S.overextension
			table.insert(reasons, `trop de conquêtes {signed(-extra * S.overextension)}`)
		end
		if #enemies == 0 and shortages == 0 and Stability.get(id) < 100 then
			delta += S.recovery
			table.insert(reasons, `paix {signed(S.recovery)}`)
		end
		if delta ~= 0 then
			Stability.set(id, Stability.get(id) + delta)
		end
		-- événements récents (région perdue, pertes...)
		local recent = {}
		for _, event in events[id] or {} do
			if time() - event.at <= EVENT_MEMORY then
				table.insert(recent, event)
				table.insert(reasons, `{event.text} {signed(event.delta)}`)
			end
		end
		events[id] = recent
		folder:SetAttribute("StabiliteRaisons", if #reasons > 0 then table.concat(reasons, " · ") .. " (par cycle, sauf événements)" else "")

		-- révoltes dans les régions conquises d'un pays instable
		if Stability.get(id) < Politics.revolt.below then
			for _, regionId in conquered[id] or {} do
				local regionFolder = state and state:FindFirstChild("Regions") and state.Regions:FindFirstChild(regionId)
				local home = Regions[regionId].startOwner
				if regionFolder and not regionFolder:GetAttribute("Bataille") and Countries[home] and rng:NextNumber() < Politics.revolt.chance then
					RegionService.setOwner(regionId, home, "Revolte")
					-- l'occupant est chassé, la région lève une milice
					Divisions.liberate(regionId, home, Politics.revolt.militia, function(countryId: string, r: string): boolean
						local owner = RegionService.getOwner(r)
						return owner == countryId or (owner ~= nil and DiplomacyState.areAllies(countryId, owner))
					end)
					for _, listener in revoltListeners do
						task.spawn(listener, regionId, id, home)
					end
				end
			end
		end
	end
end

-- Stabilité de départ pour tous les pays
local function startingValues()
	local pays = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Pays")
	for _, folder in pays:GetChildren() do
		Stability.set(folder.Name, Politics.startingStability)
		folder:SetAttribute("StabiliteRaisons", "")
	end
end

-- Nouvelle partie : stabilité de départ, événements oubliés
function Stability.reset()
	table.clear(exact)
	table.clear(events)
	startingValues()
end

-- À appeler après CountryAssignment.init() (qui crée EtatMonde.Pays)
function Stability.init()
	startingValues()
	-- régions perdues ou conquises
	RegionService.onOwnerChanged(function(_regionId: string, newOwner: string, oldOwner: string?)
		if oldOwner and oldOwner ~= newOwner then
			Stability.change(oldOwner, -Politics.stability.regionLost, "région perdue")
		end
		Stability.change(newOwner, Politics.stability.regionWon, "région conquise")
	end)
end

-- Pertes au combat (appelé par BattleService)
function Stability.casualties(countryId: string, units: number)
	if units > 0 then
		Stability.change(countryId, -units * Politics.stability.unitLost, "pertes au combat")
	end
end

return Stability
