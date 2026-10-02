--!strict
-- Point d'entrée du serveur.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RegionService = require(script.Parent:WaitForChild("Map"):WaitForChild("RegionService"))
local UnitModels = require(script.Parent:WaitForChild("Units"):WaitForChild("UnitModels"))
local CountryAssignment = require(script.Parent:WaitForChild("Session"):WaitForChild("CountryAssignment"))
local PlayerRelay = require(script.Parent:WaitForChild("Session"):WaitForChild("PlayerRelay"))
local DiplomacyService = require(script.Parent:WaitForChild("Politics"):WaitForChild("DiplomacyService"))
local Stability = require(script.Parent:WaitForChild("Politics"):WaitForChild("Stability"))
local Economy = script.Parent:WaitForChild("Economy")
local Stocks = require(Economy:WaitForChild("Stocks"))
local PopulationService = require(Economy:WaitForChild("PopulationService"))
local ProductionService = require(Economy:WaitForChild("ProductionService"))
local FactoryService = require(Economy:WaitForChild("FactoryService"))
local MarketService = require(Economy:WaitForChild("MarketService"))
local AutoSellService = require(Economy:WaitForChild("AutoSellService"))
local ContractService = require(Economy:WaitForChild("ContractService"))
local ProjectService = require(Economy:WaitForChild("ProjectService"))
local ResearchService = require(Economy:WaitForChild("ResearchService"))
local Military = script.Parent:WaitForChild("Military")
local ArmyService = require(Military:WaitForChild("ArmyService"))
local MilitaryLoop = require(Military:WaitForChild("MilitaryLoop"))
local Divisions = require(Military:WaitForChild("Divisions"))
local Commands = require(Military:WaitForChild("Commands"))
local Movement = require(Military:WaitForChild("Movement"))
local BattleService = require(Military:WaitForChild("BattleService"))
local BattleManager = require(Military:WaitForChild("BattleManager"))
local Fortifications = require(Military:WaitForChild("Fortifications"))
local Supply = require(Military:WaitForChild("Supply"))
local Armies = require(Military:WaitForChild("Armies"))
local AIService = require(script.Parent:WaitForChild("AI"):WaitForChild("AIService"))
local BalanceService = require(script.Parent:WaitForChild("Politics"):WaitForChild("BalanceService"))
local NewsService = require(script.Parent:WaitForChild("News"):WaitForChild("NewsService"))
local StatsService = require(script.Parent:WaitForChild("Session"):WaitForChild("StatsService"))
local ObjectivesService = require(script.Parent:WaitForChild("Session"):WaitForChild("ObjectivesService"))
local CouncilService = require(script.Parent:WaitForChild("Politics"):WaitForChild("CouncilService"))
local DilemmaService = require(script.Parent:WaitForChild("Politics"):WaitForChild("DilemmaService"))
local ExileService = require(script.Parent:WaitForChild("Session"):WaitForChild("ExileService"))
local EspionageService = require(script.Parent:WaitForChild("Politics"):WaitForChild("EspionageService"))
local MatchService = require(script.Parent:WaitForChild("Session"):WaitForChild("MatchService"))
local DailyMissions = require(script.Parent:WaitForChild("Session"):WaitForChild("DailyMissions"))
local PrivateChat = require(script.Parent:WaitForChild("Session"):WaitForChild("PrivateChat"))
local AccountService = require(script.Parent:WaitForChild("Session"):WaitForChild("AccountService"))
local WorldEventService = require(script.Parent:WaitForChild("Session"):WaitForChild("WorldEventService"))
local Achievements = require(script.Parent:WaitForChild("Session"):WaitForChild("Achievements"))

-- Pas de personnage : chaque joueur dirige un pays depuis la vue carte
Players.CharacterAutoLoads = false

-- Les aperçus construits dans Studio ne servent qu'en mode édition :
-- en jeu, chaque client construit sa propre carte (client/Map/MapBuilder)
for _, name in { "ApercuCarte", "ApercuAirMer" } do
	local preview = workspace:FindFirstChild(name)
	if preview then
		preview:Destroy()
	end
end

RegionService.init()
CountryAssignment.init()
PlayerRelay.init() -- relais joueur ↔ IA : absence (AFK) et départ
DiplomacyService.init() -- blocs, guerres, trêves, propositions
Stability.init()

-- Économie : stocks de départ puis production automatique toutes les X secondes
Stocks.init()
PopulationService.init() -- habitants de chaque région (mangent, grandissent, paient l'impôt, deviennent soldats)
FactoryService.init()
MarketService.init()
AutoSellService.init() -- vente automatique des surplus des joueurs (réglage par ressource)
ContractService.init() -- contrats commerciaux entre pays
ProjectService.init() -- course aux projets décisifs (fin de partie)
ResearchService.init() -- arbre technologique
-- Militaire terrestre façon Hearts of Iron (SYSTEME_MILITAIRE.md) : divisions, boucle centrale
Divisions.init(MilitaryLoop)
Commands.init() -- ordres des joueurs : un seul RemoteEvent CommandeMilitaire
Armies.init(MilitaryLoop, Commands) -- généraux : une armée qui absorbe ses troupes (cahier v2, section 5)
Movement.init(MilitaryLoop, Commands) -- déplacements de région en région (10 divisions au plus par région)
BattleService.init() -- raids aériens et navals ; dossier EtatMonde.Batailles
BattleManager.init(MilitaryLoop, Commands) -- batailles terrestres : un tick de 0,5 s par bataille (Combat, fonctions pures)
Fortifications.init(MilitaryLoop, Commands) -- fortifications des régions (ordre « Fortifier »)
Supply.init(MilitaryLoop) -- ravitaillement, encerclement, attrition, nourriture et pétrole des divisions
ArmyService.init()
MilitaryLoop.start()
ProductionService.start()

-- IA des pays sans joueur : produire, vendre ses surplus, acheter ses manques
AIService.start()
BalanceService.start() -- leader de la partie (les IA se coalisent contre lui)
CouncilService.start() -- Conseil mondial : un vote toutes les 15 minutes
DilemmaService.start() -- dilemmes de dirigeant (cartes à choix) et réputation
EspionageService.init() -- espionnage : révéler une région, saboter une usine
ExileService.start() -- gouvernements en exil et résistance
NewsService.start() -- journal télévisé mondial
StatsService.start() -- statistiques de la partie (objectifs, écran de fin)
ObjectivesService.start() -- objectifs nationaux des pays des joueurs
MatchService.start() -- partie de 75 minutes : phases, classement final, puis nouvelle partie
DailyMissions.start() -- missions quotidiennes (expérience de compte)
WorldEventService.start() -- événements mondiaux aléatoires (crises, grèves, catastrophes...)
PrivateChat.init() -- discussions privées entre dirigeants (chat Roblox filtré)
AccountService.start() -- comptes sauvegardés : succès, titres, parties, réglages
Achievements.start() -- détection des succès

-- Modèles 3D des unités (soldat, char), copiés ensuite par les clients
UnitModels.build(ReplicatedStorage)
