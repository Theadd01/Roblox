--!strict
-- Équilibre de la partie (voir CLAUDE.md, « Équilibrage ») :
--   - le leader, pays nettement le plus puissant, est publié dans l'attribut « Leader » de
--     ReplicatedStorage.EtatMonde (vide s'il n'y en a pas) : les IA ont tendance à s'allier
--     contre lui (DiplomacyAI) ;
--   - un pays qui a perdu des régions reçoit une aide internationale (crédits à chaque cycle,
--     attribut « Aide » de EtatMonde.Pays.<code>) et ses miliciens se battent mieux (BattleService).
-- Puissance = régions x regionWeight + troupes + crédits / creditsDivisor (Config/Politics.balance).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Politics = require(Config:WaitForChild("Politics")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Units = require(Config:WaitForChild("Units")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local Stocks = require(Server:WaitForChild("Economy"):WaitForChild("Stocks"))

local CURRENCY: string = Resources.currency.id

local BalanceService = {}

local function state(): Instance?
	return ReplicatedStorage:FindFirstChild("EtatMonde")
end

-- Puissance de chaque pays
function BalanceService.powers(): { [string]: number }
	local B = Politics.balance
	local powers: { [string]: number } = {}
	for regionId in Regions do
		local owner = RegionService.getOwner(regionId)
		if owner then
			powers[owner] = (powers[owner] or 0) + B.regionWeight
		end
	end
	local s = state()
	local armees = s and s:FindFirstChild("Armees")
	for _, army in (if armees then armees:GetChildren() else {}) do
		local owner = army:GetAttribute("Proprietaire") :: string
		for _, typeId in Units.kinds[Units.kindOf(army)].order do
			powers[owner] = (powers[owner] or 0) + ((army:GetAttribute(typeId) :: number?) or 0)
		end
	end
	local divisions = s and s:FindFirstChild("Divisions")
	for _, d in (if divisions then divisions:GetChildren() else {}) do
		local owner = d:GetAttribute("Proprietaire") :: string
		powers[owner] = (powers[owner] or 0) + B.divisionWeight * ((d:GetAttribute("Force") :: number?) or 0) / 100
	end
	for countryId, power in powers do
		powers[countryId] = power + Stocks.get(countryId, CURRENCY) / B.creditsDivisor
	end
	return powers
end

-- Leader actuel (nil s'il n'y en a pas)
function BalanceService.leader(): string?
	local s = state()
	local leader = s and s:GetAttribute("Leader")
	return if typeof(leader) == "string" and leader ~= "" then leader else nil
end

-- Régions de départ perdues par un pays
function BalanceService.lostRegions(countryId: string): number
	local lost = 0
	for regionId, region in Regions do
		if region.startOwner == countryId and RegionService.getOwner(regionId) ~= countryId then
			lost += 1
		end
	end
	return lost
end

-- Un pays affaibli (il a perdu des régions) : ses miliciens se battent mieux
function BalanceService.militiaFactor(countryId: string): number
	return if BalanceService.lostRegions(countryId) > 0 then Politics.balance.underdogMilitia else 1
end

-- Aide internationale, à chaque cycle de production (appelé par ProductionService)
function BalanceService.tick()
	local B = Politics.balance
	local s = state()
	local pays = s and s:FindFirstChild("Pays")
	local owned: { [string]: boolean } = {}
	for regionId in Regions do
		local owner = RegionService.getOwner(regionId)
		if owner then
			owned[owner] = true
		end
	end
	for _, folder in (if pays then pays:GetChildren() else {}) do
		local id = folder.Name
		local aid = 0
		if owned[id] then -- un pays sans territoire relève du gouvernement en exil
			aid = math.min(BalanceService.lostRegions(id) * B.aidPerLostRegion, B.aidMax)
		end
		if aid > 0 then
			Stocks.add(id, CURRENCY, aid)
		end
		folder:SetAttribute("Aide", aid)
	end
end

-- Nouvelle partie : plus de leader, plus d'aide internationale
function BalanceService.reset()
	local s = state()
	if s then
		s:SetAttribute("Leader", "")
		local pays = s:FindFirstChild("Pays")
		for _, folder in (if pays then pays:GetChildren() else {}) do
			folder:SetAttribute("Aide", 0)
		end
	end
end

-- Calcule le leader régulièrement (à appeler au démarrage)
function BalanceService.start()
	local B = Politics.balance
	task.spawn(function()
		while true do
			task.wait(B.interval)
			local powers = BalanceService.powers()
			local first, second = nil :: string?, 0
			local best = 0
			for countryId, power in powers do
				if power > best then
					second = best
					first, best = countryId, power
				elseif power > second then
					second = power
				end
			end
			local regions, conquests = 0, 0
			for regionId, region in Regions do
				if RegionService.getOwner(regionId) == first then
					regions += 1
					if region.startOwner ~= first then
						conquests += 1
					end
				end
			end
			local s = state()
			if s then
				local isLeader = first ~= nil and best >= second * B.leaderRatio and regions >= B.leaderMinRegions
					and conquests >= B.leaderMinConquests
				s:SetAttribute("Leader", if isLeader then first else "")
			end
		end
	end)
end

return BalanceService
