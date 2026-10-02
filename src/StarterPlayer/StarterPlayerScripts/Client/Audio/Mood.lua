--!strict
-- Choisit l'ambiance musicale selon la situation du pays dirigé :
--   Guerre  : une bataille le concerne (en cours, ou finie depuis moins d'une minute)
--   Tension : en guerre sans combat, force étrangère en route vers une de ses régions,
--             pays instable ou gouvernement en exil
--   Paix    : sinon
-- On passe tout de suite à une ambiance plus intense ; on ne redescend qu'après 30 s de calme.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Audio = require(Shared:WaitForChild("Config"):WaitForChild("Audio")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local Client = script.Parent.Parent
local ArmyState = require(Client:WaitForChild("State"):WaitForChild("ArmyState"))
local RegionView = require(Client:WaitForChild("Map"):WaitForChild("RegionView"))
local Music = require(script.Parent:WaitForChild("Music"))

local Mood = {}

local session = 0 -- change à chaque partie (ou retour au choix du pays) : l'ancienne boucle s'arrête

local function battleMood(me: string, batailles: Instance): boolean
	for _, battle in batailles:GetChildren() do
		if battle:GetAttribute("Attaquant") == me or battle:GetAttribute("Defenseur") == me then
			return true -- en cours, ou résultat encore affiché
		end
	end
	return false
end

local function tense(me: string, country: Instance?): boolean
	if country then
		if country:GetAttribute("Exil") == true then
			return true
		end
		local stability = country:GetAttribute("Stabilite")
		if typeof(stability) == "number" and stability < Audio.mood.lowStability then
			return true
		end
	end
	if #DiplomacyState.enemiesOf(me) > 0 then
		return true
	end
	for _, army in ArmyState.list() do
		local destination = army:GetAttribute("Destination")
		if army:GetAttribute("Proprietaire") ~= me and typeof(destination) == "string" and ArmyState.isMoving(army)
			and RegionView.getOwner(destination) == me and not DiplomacyState.areAllies(me, army:GetAttribute("Proprietaire")) then
			return true
		end
	end
	return false
end

-- Suit la situation de ce pays (appelé au début de chaque partie)
function Mood.start(countryId: string)
	session += 1
	local mySession = session
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local batailles = state:WaitForChild("Batailles")
	local pays = state:WaitForChild("Pays")
	local order = Audio.mood.order
	local current = "Paix"
	local lastBattle = -math.huge
	local calmSince: number? = nil
	Music.setMood(current)
	task.spawn(function()
		while session == mySession do
			if battleMood(countryId, batailles) then
				lastBattle = os.clock()
			end
			local wanted = "Paix"
			if os.clock() - lastBattle < Audio.mood.battleLinger then
				wanted = "Guerre"
			elseif tense(countryId, pays:FindFirstChild(countryId)) then
				wanted = "Tension"
			end
			if order[wanted] > order[current] then
				current, calmSince = wanted, nil
				Music.setMood(current)
			elseif order[wanted] < order[current] then
				calmSince = calmSince or os.clock()
				if os.clock() - (calmSince :: number) >= Audio.mood.calmDelay then
					current, calmSince = wanted, nil
					Music.setMood(current)
				end
			else
				calmSince = nil
			end
			task.wait(Audio.mood.checkInterval)
		end
	end)
end

-- Plus de pays dirigé (écran titre, choix d'un autre pays) : musique du menu
function Mood.stop()
	session += 1
	Music.setMood("Titre")
end

return Mood
