--!strict
-- Style de jeu des joueurs : chaque demande validée d'un joueur donne des points à une
-- personnalité (Config/Session.style). Quand l'IA reprend son pays (départ ou absence),
-- elle prend la personnalité la plus proche de sa façon de jouer (closest).
-- Seules les demandes des joueurs comptent : les services appellent recordAction depuis
-- leurs remotes, jamais pour les décisions de l'IA.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Session = require(Config:WaitForChild("Session")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local RegionService = require(script.Parent.Parent:WaitForChild("Map"):WaitForChild("RegionService"))

local PlayStyle = {}

local points: { [string]: { [string]: number } } = {} -- pays -> personnalité -> points
local actionListeners: { (countryId: string, action: string, a: unknown, b: unknown) -> () } = {}

local function add(countryId: string, gains: { [string]: number })
	local total = points[countryId]
	if not total then
		total = {}
		points[countryId] = total
	end
	for personality, n in gains do
		total[personality] = (total[personality] or 0) + n
	end
end

-- Un pays est-il en guerre (dans une bataille en cours) ou affaibli (il a perdu une de ses régions) ?
local function isWeak(countryId: string): boolean
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local batailles = state and state:FindFirstChild("Batailles")
	for _, battle in (if batailles then batailles:GetChildren() else {}) do
		if battle:GetAttribute("Attaquant") == countryId or battle:GetAttribute("Defenseur") == countryId then
			return true
		end
	end
	for regionId, region in Regions do
		if region.startOwner == countryId and RegionService.getOwner(regionId) ~= countryId then
			return true
		end
	end
	return false
end

-- listener(pays, action, a, b) : une demande d'un joueur vient d'être validée (missions quotidiennes)
function PlayStyle.onAction(listener: (countryId: string, action: string, a: unknown, b: unknown) -> ())
	table.insert(actionListeners, listener)
end

-- À appeler après chaque demande validée d'un joueur (a, b : arguments de la remote)
function PlayStyle.recordAction(countryId: string, action: string, a: unknown, b: unknown)
	for _, listener in actionListeners do
		task.spawn(listener, countryId, action, a, b)
	end
	local S = Session.style
	if action == "Acheter" or action == "Vendre" or action == "ProposerContrat" or action == "RepondreContrat" then
		add(countryId, S.trade)
	elseif action == "ConstruireUsine" or action == "AmeliorerUsine" or action == "InvestirProjet" or action == "Rechercher" then
		add(countryId, S.factory)
	elseif action == "NommerGeneral" or action == "Recruter" then
		add(countryId, S.recruit)
	elseif action == "ProposerAlliance" then
		add(countryId, S.defend)
	elseif action == "ProposerVote" and (a == "Paix" or a == "Treve") then
		add(countryId, S.trade) -- chercher la paix : plutôt commerçant
	elseif action == "DeclarerGuerre" or action == "SaboterProjet" then
		add(countryId, S.attack)
	elseif action == "OrdreArmee" then
		if b == "Defendre" or b == "Tenir" then
			add(countryId, S.defend)
		end
	elseif action == "DeplacerArmee" and typeof(b) == "string" then
		local owner = RegionService.getOwner(b)
		if owner == countryId then
			add(countryId, S.defend)
		elseif owner and isWeak(owner) then
			add(countryId, S.opportunistAttack)
		else
			add(countryId, S.attack)
		end
	end
end

-- Nouveau dirigeant : on oublie le style du précédent
function PlayStyle.reset(countryId: string)
	points[countryId] = nil
end

-- Personnalité la plus proche du style du joueur (nil s'il n'a pas assez joué)
function PlayStyle.closest(countryId: string): string?
	local total = points[countryId]
	if not total then
		return nil
	end
	local best: string? = nil
	local bestPoints, sum = 0, 0
	for personality, n in total do
		sum += n
		if n > bestPoints then
			best, bestPoints = personality, n
		end
	end
	return if sum >= Session.styleMinimum then best else nil
end

return PlayStyle
