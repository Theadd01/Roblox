--!strict
-- Gouvernement en exil (voir CLAUDE.md, « Ne jamais laisser un joueur s'ennuyer ») : un pays qui
-- perd toutes ses régions n'est pas éliminé.
--   - attribut « Exil » de EtatMonde.Pays.<code> : vrai quand il n'a plus aucune région ;
--   - il garde son vote au Conseil mondial, ses crédits et ce qui reste de ses armées ;
--   - il finance la résistance dans ses régions perdues (Remotes.FinancerResistance) : attribut
--     « Resistance » (0 à 100) de EtatMonde.Regions.<id> ; à 100, la région se soulève et lui revient ;
--   - un joueur en exil peut aussi diriger un autre pays libre (Remotes.ChangerDePays).
-- Les pays IA en exil financent eux aussi la résistance. Réglages : Config/Politics.exile.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Politics = require(Config:WaitForChild("Politics")) :: any
local MatchState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MatchState")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local Divisions = require(Server:WaitForChild("Military"):WaitForChild("Divisions"))
local DiplomacyState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DiplomacyState")) :: any
local Stocks = require(Server:WaitForChild("Economy"):WaitForChild("Stocks"))
local RateLimiter = require(Server:WaitForChild("Util"):WaitForChild("RateLimiter"))
local CountryAssignment = require(script.Parent:WaitForChild("CountryAssignment"))

local CURRENCY: string = Resources.currency.id

local ExileService = {}

local rng = Random.new()

local function state(): Instance?
	return ReplicatedStorage:FindFirstChild("EtatMonde")
end

local function regionFolder(regionId: string): Instance?
	local s = state()
	local regions = s and s:FindFirstChild("Regions")
	return regions and regions:FindFirstChild(regionId)
end

local function countryFolder(countryId: string): Instance?
	local s = state()
	local pays = s and s:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
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

-- Le pays est-il en exil (plus aucune région) ?
function ExileService.isExiled(countryId: string): boolean
	return regionCount(countryId) == 0
end

-- Régions de départ perdues par un pays (où il peut financer la résistance)
function ExileService.lostRegions(countryId: string): { string }
	local list = {}
	for regionId, region in Regions do
		if region.startOwner == countryId and RegionService.getOwner(regionId) ~= countryId then
			table.insert(list, regionId)
		end
	end
	table.sort(list)
	return list
end

-- Finance la résistance dans une de ses régions perdues
function ExileService.fund(countryId: string, regionId: unknown): (boolean, string?)
	if typeof(regionId) ~= "string" or not Regions[regionId] then
		return false, "Région inconnue."
	end
	if Regions[regionId].startOwner ~= countryId then
		return false, "Tu ne peux soutenir la résistance que dans tes propres régions perdues."
	end
	local owner = RegionService.getOwner(regionId)
	if owner == countryId then
		return false, "Cette région est déjà à toi."
	end
	local folder = regionFolder(regionId)
	if not folder then
		return false, "Région inconnue."
	end
	local E = Politics.exile
	if not Stocks.spend(countryId, { [CURRENCY] = E.resistanceCost }) then
		return false, "Pas assez de crédits."
	end
	local current = folder:GetAttribute("Resistance")
	folder:SetAttribute("Resistance", math.min(E.uprisingAt, (if typeof(current) == "number" then current else 0) + E.resistanceGain))
	return true, nil
end

local function updateExile(countryId: string)
	local folder = countryFolder(countryId)
	if folder then
		folder:SetAttribute("Exil", if regionCount(countryId) == 0 then true else nil)
	end
end

-- À chaque cycle : la résistance s'essouffle un peu, ou se soulève si elle est assez forte
function ExileService.tick()
	local E = Politics.exile
	for regionId, region in Regions do
		local folder = regionFolder(regionId)
		local value = folder and folder:GetAttribute("Resistance")
		if not folder or typeof(value) ~= "number" or value <= 0 then
			continue
		end
		if RegionService.getOwner(regionId) == region.startOwner then
			folder:SetAttribute("Resistance", nil)
		elseif value >= E.uprisingAt and not folder:GetAttribute("Bataille") then
			folder:SetAttribute("Resistance", nil)
			RegionService.setOwner(regionId, region.startOwner, "Soulevement")
			-- l'occupant est chassé, la résistance devient une milice
			Divisions.liberate(regionId, region.startOwner, E.uprisingMilitia, function(countryId: string, r: string): boolean
				local owner = RegionService.getOwner(r)
				return owner == countryId or (owner ~= nil and DiplomacyState.areAllies(countryId, owner))
			end)
		else
			folder:SetAttribute("Resistance", math.max(0, value - E.resistanceDecay))
		end
	end
end

-- Nouvelle partie : plus aucun gouvernement en exil ni aucune résistance
function ExileService.reset()
	local s = state()
	local pays = s and s:FindFirstChild("Pays")
	for _, folder in (if pays then pays:GetChildren() else {}) do
		folder:SetAttribute("Exil", nil)
	end
	for regionId in Regions do
		local folder = regionFolder(regionId)
		if folder then
			folder:SetAttribute("Resistance", nil)
		end
	end
end

-- À appeler au démarrage (après CountryAssignment.init)
function ExileService.start()
	RegionService.onOwnerChanged(function(_regionId: string, newOwner: string, oldOwner: string?)
		updateExile(newOwner)
		if oldOwner then
			updateExile(oldOwner)
		end
	end)

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local limiter = RateLimiter.new(0.5)
	local fund = Instance.new("RemoteFunction")
	fund.Name = "FinancerResistance"
	fund.OnServerInvoke = function(player: Player, regionId: unknown)
		if not limiter:allow(player) then
			return false, "Doucement, réessaie dans un instant."
		end
		local countryId = CountryAssignment.getCountryOf(player)
		if not countryId then
			return false, "Choisis d'abord un pays."
		end
		return ExileService.fund(countryId, regionId)
	end
	fund.Parent = remotes
	local switch = Instance.new("RemoteFunction")
	switch.Name = "ChangerDePays"
	switch.OnServerInvoke = function(player: Player, newCountry: unknown)
		if not limiter:allow(player) then
			return false, "Doucement, réessaie dans un instant."
		end
		local countryId = CountryAssignment.getCountryOf(player)
		if countryId and not ExileService.isExiled(countryId) then
			return false, "Tu ne peux changer de pays que si le tien a perdu toutes ses régions."
		end
		return CountryAssignment.switch(player, newCountry)
	end
	switch.Parent = remotes

	-- les pays IA en exil financent la résistance
	task.spawn(function()
		while true do
			task.wait(Politics.exile.aiInterval)
			if not MatchState.isRunning() then
				continue
			end
			local s = state()
			local pays = s and s:FindFirstChild("Pays")
			for _, folder in (if pays then pays:GetChildren() else {}) do
				local id = folder.Name
				if folder:GetAttribute("Exil") and CountryAssignment.isAIControlled(id) and Stocks.get(id, CURRENCY) >= Politics.exile.resistanceCost then
					local lost = ExileService.lostRegions(id)
					if #lost > 0 then
						ExileService.fund(id, lost[rng:NextInteger(1, #lost)])
					end
				end
			end
		end
	end)
end

return ExileService
