--!strict
-- Notifications importantes sur le pays du joueur (voir CLAUDE.md, « Interface ») :
--   - pénurie : une de ses armées manque d'une ressource (moral en baisse, efficacité réduite) ;
--   - stabilité qui passe sous 30 %, puis sous le seuil des révoltes ;
--   - révolte dans une de ses conquêtes, ou région libérée par une révolte ;
--   - un de ses chefs gagne un nouveau trait.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Technologies = require(Config:WaitForChild("Technologies")) :: any
local TechState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TechState")) :: any
local Politics = require(Config:WaitForChild("Politics")) :: any
local Client = script.Parent.Parent
local ArmyState = require(Client:WaitForChild("State"):WaitForChild("ArmyState"))
local Generals = require(Config:WaitForChild("Generals")) :: any
local Toast = require(script.Parent:WaitForChild("Toast"))
local GameSession = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("GameSession"))

local SHORTAGE_REPEAT = 120 -- secondes avant de reparler de la même pénurie

local CountryAlerts = {}

function CountryAlerts.start(countryId: string)
	-- messages seulement tant que le joueur dirige ce pays (il peut en changer : exil)
	local function notify(text: string, kind: string?)
		if Players.LocalPlayer:GetAttribute("Pays") == countryId then
			Toast.show(text, kind)
		end
	end
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local me = state:WaitForChild("Pays"):WaitForChild(countryId)

	-- pénuries des armées
	local lastShortage: { [string]: number } = {}
	ArmyState.onChanged(function(army: Instance, removed: boolean)
		if removed or army:GetAttribute("Proprietaire") ~= countryId then
			return
		end
		local shortage = army:GetAttribute("Penurie")
		if typeof(shortage) ~= "string" or shortage == "" then
			return
		end
		if os.clock() - (lastShortage[shortage] or -math.huge) >= SHORTAGE_REPEAT then
			lastShortage[shortage] = os.clock()
			notify(`⚠️ Pénurie ({shortage}) : tes armées sont mal ravitaillées, leur moral baisse.`, "danger")
		end
	end)

	-- nouveaux traits de ses chefs
	local knownTraits: { [Instance]: string } = {}
	ArmyState.onChanged(function(army: Instance, removed: boolean)
		if removed then
			knownTraits[army] = nil
			return
		end
		if army:GetAttribute("Proprietaire") ~= countryId then
			return
		end
		local traits = army:GetAttribute("Traits")
		if typeof(traits) ~= "string" then
			return
		end
		local before = knownTraits[army]
		knownTraits[army] = traits
		if before and before ~= traits and #traits > #before then
			local newest = traits:match("([^,]+)$")
			local trait = newest and Generals.traits[newest]
			if trait then
				notify(`🎖️ {army:GetAttribute("Nom")} gagne un trait : {trait.icon} <b>{trait.name}</b> !`, "success")
			end
		end
	end)

	-- stabilité en baisse
	local lastLevel = 3
	local function levelOf(value: number): number
		return if value >= 30 then 3 elseif value >= Politics.revolt.below then 2 else 1
	end
	GameSession.track(me:GetAttributeChangedSignal("Stabilite"):Connect(function()
		local value = me:GetAttribute("Stabilite")
		if typeof(value) ~= "number" then
			return
		end
		local level = levelOf(value)
		if level < lastLevel then
			if level == 2 then
				notify(`😐 Stabilité à {value} % : l'opinion se retourne, ta production baisse et tes recrues coûtent plus cher.`, "danger")
			else
				notify(`😠 Stabilité à {value} % : tes conquêtes risquent de se révolter ! Fais la paix ou évite les pénuries.`, "danger")
			end
		end
		lastLevel = level
	end))

	-- niveaux de technologie atteints (recherche terminée, ou volée par ses espions)
	local knownLevels = table.clone(TechState.levels(countryId))
	GameSession.track(me:GetAttributeChangedSignal("Technologies"):Connect(function()
		local current = TechState.levels(countryId)
		for id, level in current do
			local tech = Technologies.get(id)
			if tech and level > (knownLevels[id] or 0) then
				local entry = tech.levels[level]
				notify(`🧪 {tech.icon} <b>{tech.name}</b> niveau {level} : {if entry then entry.text else tech.effectText}`, "success")
			end
		end
		knownLevels = table.clone(current)
	end))

	-- révoltes qui le concernent (fil d'actualité)
	GameSession.track(state:WaitForChild("Actualites").ChildAdded:Connect(function(item: Instance)
		task.defer(function()
			local countries = item:GetAttribute("Pays")
			local category = item:GetAttribute("Categorie")
			local touched = typeof(countries) == "string" and table.find(countries:split(","), countryId) ~= nil
			if category == "Evenement" and touched then
				notify(`⚠️ Ton pays est touché : {item:GetAttribute("Texte")}`, "danger")
			elseif (category == "Revolte" or category == "Espionnage") and typeof(countries) == "string" and countries:split(",")[1] == countryId then
				notify(tostring(item:GetAttribute("Texte")), "danger")
			end
		end)
	end))
end

return CountryAlerts
