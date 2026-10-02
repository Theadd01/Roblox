--!strict
-- Lecture du déroulé de la partie publié par le serveur (server/Session/MatchService), pour le
-- serveur comme pour le client. Attributs de ReplicatedStorage.EtatMonde :
--   Partie       "EnCours" | "Fin" | "Reinitialisation"
--   PartieDebut  heure serveur du début de la partie
--   PartieFin    heure serveur de la fin prévue
--   Phase        numéro de la phase en cours (Config/Match.phases)
--   PartieNumero numéro de la partie sur ce serveur (1, 2...)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Match = require(script.Parent:WaitForChild("Config"):WaitForChild("Match")) :: any

local MatchState = {}

local function state(): Instance?
	return ReplicatedStorage:FindFirstChild("EtatMonde")
end

local function number(name: string): number?
	local s = state()
	local value = s and s:GetAttribute(name)
	return if typeof(value) == "number" then value else nil
end

-- "EnCours", "Fin" ou "Reinitialisation" (« EnCours » tant que le serveur n'a rien publié)
function MatchState.status(): string
	local s = state()
	local value = s and s:GetAttribute("Partie")
	return if typeof(value) == "string" then value else "EnCours"
end

function MatchState.isRunning(): boolean
	return MatchState.status() == "EnCours"
end

-- Secondes écoulées depuis le début de la partie
function MatchState.elapsed(): number
	local start = number("PartieDebut")
	return if start then math.max(0, workspace:GetServerTimeNow() - start) else 0
end

-- Secondes restantes avant la fin de la partie
function MatchState.timeLeft(): number
	local finish = number("PartieFin")
	return if finish then math.max(0, finish - workspace:GetServerTimeNow()) else Match.duration
end

function MatchState.phaseIndex(): number
	return number("Phase") or 1
end

-- Phase en cours (voir Config/Match.phases)
function MatchState.phase(): any
	return Match.phases[math.clamp(MatchState.phaseIndex(), 1, #Match.phases)]
end

-- Numéro de la partie (change à chaque nouvelle partie)
function MatchState.number(): number
	return number("PartieNumero") or 1
end

-- Difficulté de la partie (Config/Match.difficulties) : son nom et ses réglages
function MatchState.difficulty(): (string, any)
	local chosen = workspace:GetAttribute("Difficulte")
	local name = if typeof(chosen) == "string" and Match.difficulties[chosen] then chosen else Match.difficulty
	return name, Match.difficulties[name]
end

return MatchState
