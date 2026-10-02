--!strict
-- Déroulé d'une partie (Config/Match) : horloge de 60 à 90 minutes, phases (mise en place, essor,
-- premiers conflits, crise mondiale, course finale), fin de partie (classement et bilan), puis
-- remise à zéro du monde et nouvelle partie sur le même serveur.
-- Publié dans les attributs de ReplicatedStorage.EtatMonde (lus avec shared/MatchState) :
--   Partie "EnCours" | "Fin" | "Reinitialisation", PartieDebut, PartieFin, Phase, PartieNumero,
--   NouvellePartie (heure serveur de la remise à zéro, pendant l'écran de fin), Crise (titre)
-- La fin est décidée par l'attribut PartieFin, les phases par PartieDebut : changer ces attributs
-- (test dans Studio) avance ou retarde la partie.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Match = require(Config:WaitForChild("Match")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local Server = script.Parent.Parent
local RegionService = require(Server:WaitForChild("Map"):WaitForChild("RegionService"))
local Economy = Server:WaitForChild("Economy")
local Stocks = require(Economy:WaitForChild("Stocks"))
local FactoryService = require(Economy:WaitForChild("FactoryService"))
local MarketService = require(Economy:WaitForChild("MarketService"))
local ContractService = require(Economy:WaitForChild("ContractService"))
local TaxService = require(Economy:WaitForChild("TaxService"))
local PopulationService = require(Economy:WaitForChild("PopulationService"))
local AutoSellService = require(Economy:WaitForChild("AutoSellService"))
local ProjectService = require(Economy:WaitForChild("ProjectService"))
local ResearchService = require(Economy:WaitForChild("ResearchService"))
local ProductionService = require(Economy:WaitForChild("ProductionService"))
local Military = Server:WaitForChild("Military")
local ArmyService = require(Military:WaitForChild("ArmyService"))
local BattleService = require(Military:WaitForChild("BattleService"))
local Divisions = require(Military:WaitForChild("Divisions"))
local Movement = require(Military:WaitForChild("Movement"))
local BattleManager = require(Military:WaitForChild("BattleManager"))
local Fortifications = require(Military:WaitForChild("Fortifications"))
local Supply = require(Military:WaitForChild("Supply"))
local Armies = require(Military:WaitForChild("Armies"))
local GeneralAI = require(Military:WaitForChild("GeneralAI"))
local Politics = Server:WaitForChild("Politics")
local DiplomacyService = require(Politics:WaitForChild("DiplomacyService"))
local Stability = require(Politics:WaitForChild("Stability"))
local BalanceService = require(Politics:WaitForChild("BalanceService"))
local CouncilService = require(Politics:WaitForChild("CouncilService"))
local DilemmaService = require(Politics:WaitForChild("DilemmaService"))
local EspionageService = require(Politics:WaitForChild("EspionageService"))
local AIService = require(Server:WaitForChild("AI"):WaitForChild("AIService"))
local NewsService = require(Server:WaitForChild("News"):WaitForChild("NewsService"))
local CountryAssignment = require(script.Parent:WaitForChild("CountryAssignment"))
local PlayerRelay = require(script.Parent:WaitForChild("PlayerRelay"))
local StatsService = require(script.Parent:WaitForChild("StatsService"))
local ObjectivesService = require(script.Parent:WaitForChild("ObjectivesService"))
local ExileService = require(script.Parent:WaitForChild("ExileService"))
local RankingService = require(script.Parent:WaitForChild("RankingService"))
local WorldEventService = require(script.Parent:WaitForChild("WorldEventService"))

local MatchService = {}

local rng = Random.new()
local warned: { [number]: boolean } = {}
local finishedListeners: { (ranking: { any }) -> () } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function state(): Instance
	return ReplicatedStorage:WaitForChild("EtatMonde")
end

local function nameOf(countryId: string): string
	return if Countries[countryId] then Countries[countryId].name else countryId
end

-- Numéro de la phase en cours d'après le temps écoulé
local function phaseAt(elapsed: number): number
	local index = 1
	for i, phase in Match.phases do
		if elapsed >= phase.start then
			index = i
		end
	end
	return index
end

-- Lance une partie : horloge, première phase
local function begin()
	local s = state()
	local start = now()
	table.clear(warned)
	s:SetAttribute("PartieDebut", start)
	s:SetAttribute("PartieFin", start + Match.duration)
	s:SetAttribute("Phase", 1)
	s:SetAttribute("Crise", "")
	s:SetAttribute("NouvellePartie", nil)
	s:SetAttribute("PartieNumero", ((s:GetAttribute("PartieNumero") :: number?) or 0) + 1)
	s:SetAttribute("Partie", "EnCours")
	local phase = Match.phases[1]
	NewsService.publish(`🌍 Nouvelle partie : {math.floor(Match.duration / 60)} minutes pour mener ton pays en tête du classement mondial`, "Partie", {})
	NewsService.publish(`{phase.icon} Phase 1 : {phase.name}`, "Partie", {})
end

-- Début d'une phase : annonce, et crise mondiale si elle en déclenche une
local function enterPhase(index: number)
	local s = state()
	s:SetAttribute("Phase", index)
	local phase = Match.phases[index]
	NewsService.publish(`{phase.icon} Phase {index} : {phase.name} — {phase.text}`, "Partie", {})
	if phase.crisis and #Match.crises > 0 then
		local crisis = Match.crises[rng:NextInteger(1, #Match.crises)]
		MarketService.shock(crisis.resource, crisis.factor)
		s:SetAttribute("Crise", crisis.title)
		NewsService.publish(`🌋 Crise mondiale : {crisis.title}`, "Marche", {})
	end
end

-- Remise à zéro du monde, dans l'ordre (chaque étape protégée : une erreur n'arrête pas les autres)
local function resetWorld()
	local s = state()
	s:SetAttribute("Partie", "Reinitialisation")
	local steps: { { name: string, run: () -> () } } = {
		{ name = "batailles", run = BattleService.reset }, -- d'abord : leurs boucles s'arrêtent sans résultat
		{ name = "batailles terrestres", run = BattleManager.reset },
		{ name = "forces", run = ArmyService.reset },
		{ name = "joueurs", run = CountryAssignment.releaseAll },
		{ name = "régions", run = RegionService.reset },
		{ name = "population", run = PopulationService.reset }, -- après les régions : habitants de départ
		{ name = "mouvements", run = Movement.reset },
		{ name = "généraux", run = Armies.reset },
		{ name = "plans des généraux", run = GeneralAI.reset },
		{ name = "divisions", run = Divisions.reset }, -- après les régions : divisions de départ
		{ name = "fortifications", run = Fortifications.reset },
		{ name = "ravitaillement", run = Supply.reset },
		{ name = "stocks", run = Stocks.reset },
		{ name = "usines", run = FactoryService.reset },
		{ name = "marché", run = MarketService.reset },
		{ name = "contrats", run = ContractService.reset },
		{ name = "impôts", run = TaxService.reset },
		{ name = "vente automatique", run = AutoSellService.reset },
		{ name = "projets", run = ProjectService.reset },
		{ name = "recherche", run = ResearchService.reset },
		{ name = "diplomatie", run = DiplomacyService.reset },
		{ name = "stabilité", run = Stability.reset },
		{ name = "équilibre", run = BalanceService.reset },
		{ name = "production", run = ProductionService.reset },
		{ name = "conseil", run = CouncilService.reset },
		{ name = "dilemmes", run = DilemmaService.reset },
		{ name = "espionnage", run = EspionageService.reset },
		{ name = "objectifs", run = ObjectivesService.reset },
		{ name = "statistiques", run = StatsService.reset },
		{ name = "exil", run = ExileService.reset },
		{ name = "relais", run = PlayerRelay.reset },
		{ name = "IA", run = AIService.reset },
		{ name = "événements", run = WorldEventService.reset },
		{ name = "journal", run = NewsService.reset },
	}
	for _, step in steps do
		local ok, err = pcall(step.run)
		if not ok then
			warn(`[Partie] remise à zéro ({step.name}) : {err}`)
		end
	end
	local classement = s:FindFirstChild("Classement")
	if classement then
		classement:Destroy()
	end
	begin()
end

-- Fin de la partie : classement, bilan, écran de fin, puis nouvelle partie
local function finish()
	local s = state()
	local list = RankingService.compute()
	local ok, highlights = pcall(StatsService.highlights)
	if not ok then
		warn(`[Partie] bilan : {highlights}`)
		highlights = { general = "—", sale = "—", alliance = "—", betrayal = "—" }
	end
	RankingService.publish(list, highlights :: any)
	for _, listener in finishedListeners do
		task.spawn(listener, list)
	end
	local first, second, third = list[1], list[2], list[3]
	if first then
		local podium = if second and third
			then ` devant {FrenchNames.the(nameOf(second.country))} et {FrenchNames.the(nameOf(third.country))}`
			else ""
		NewsService.publish(`🏁 Fin de la partie : {FrenchNames.the(nameOf(first.country))} l'emporte{podium}`, "Partie", { first.country })
	end
	s:SetAttribute("NouvellePartie", now() + Match.endScreenDuration)
	s:SetAttribute("Partie", "Fin")
	task.delay(Match.endScreenDuration, resetWorld)
end

-- listener(classement) : la partie vient de finir (classement complet, du premier au dernier)
function MatchService.onFinished(listener: (ranking: { any }) -> ())
	table.insert(finishedListeners, listener)
end

-- À appeler au démarrage, après tous les autres services
function MatchService.start()
	begin()
	task.spawn(function()
		while true do
			task.wait(1)
			local s = state()
			if s:GetAttribute("Partie") ~= "EnCours" then
				continue
			end
			local start = (s:GetAttribute("PartieDebut") :: number?) or now()
			local finishAt = (s:GetAttribute("PartieFin") :: number?) or (start + Match.duration)
			-- phases
			local index = phaseAt(now() - start)
			if index ~= s:GetAttribute("Phase") then
				enterPhase(index)
			end
			-- « fin de la partie dans 10 minutes »...
			local left = finishAt - now()
			for _, seconds in Match.warnings do
				if left <= seconds and left > seconds - 30 and not warned[seconds] then
					warned[seconds] = true
					local text = if seconds >= 60 then `{math.floor(seconds / 60)} minute{if seconds >= 120 then "s" else ""}` else `{seconds} secondes`
					NewsService.publish(`⏳ Fin de la partie dans {text} : le classement final approche`, "Partie", {})
				end
			end
			if left <= 0 then
				local ok, err = pcall(finish)
				if not ok then
					warn(`[Partie] fin : {err}`)
					s:SetAttribute("Partie", "Fin")
					task.delay(Match.endScreenDuration, resetWorld)
				end
			end
		end
	end)
end

return MatchService
