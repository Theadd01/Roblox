--!strict
-- Point d'entrée du client. Trois moments :
--   « titre » : écran titre sur fond de carte qui défile (le joueur ne voit jamais le monde brut)
--   « choix » : le joueur choisit son pays sur la carte, le serveur valide
--   « jeu »   : vue carte libre, fiche des régions au clic, généraux cliquables
-- En fin de partie, l'écran de fin (classement) s'affiche ; à la nouvelle partie, le joueur
-- revient au choix du pays.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any

local Map = script.Parent:WaitForChild("Map")
local UI = script.Parent:WaitForChild("UI")
local MapBuilder = require(Map:WaitForChild("MapBuilder"))
local MapLighting = require(Map:WaitForChild("MapLighting"))
local RegionView = require(Map:WaitForChild("RegionView"))
local CameraController = require(Map:WaitForChild("CameraController"))
local RegionSelector = require(Map:WaitForChild("RegionSelector"))
local FactoryView = require(Map:WaitForChild("FactoryView"))
local FactoryState = require(script.Parent:WaitForChild("State"):WaitForChild("FactoryState"))
local ArmyState = require(script.Parent:WaitForChild("State"):WaitForChild("ArmyState"))
local ArmyView = require(Map:WaitForChild("ArmyView"))
local BattleView = require(Map:WaitForChild("BattleView"))
local TitleScreen = require(UI:WaitForChild("TitleScreen"))
local CountrySelect = require(UI:WaitForChild("CountrySelect"))
local RegionPanel = require(UI:WaitForChild("RegionPanel"))
local TopBar = require(UI:WaitForChild("TopBar"))
local TabBar = require(UI:WaitForChild("TabBar"))
local FactoryPanel = require(UI:WaitForChild("FactoryPanel"))
local ControlsHint = require(UI:WaitForChild("ControlsHint"))
local AttackAlert = require(UI:WaitForChild("AttackAlert"))
local AbsenceBanner = require(UI:WaitForChild("AbsenceBanner"))
local DiplomacyAlerts = require(UI:WaitForChild("DiplomacyAlerts"))
local NewsTicker = require(UI:WaitForChild("NewsTicker"))
local CountryAlerts = require(UI:WaitForChild("CountryAlerts"))
local ObjectivesWidget = require(UI:WaitForChild("ObjectivesWidget"))
local CouncilPanel = require(UI:WaitForChild("CouncilPanel"))
local DilemmaCard = require(UI:WaitForChild("DilemmaCard"))
local ExilePanel = require(UI:WaitForChild("ExilePanel"))
local Tooltips = require(UI:WaitForChild("Tooltips"))
local Tutorial = require(UI:WaitForChild("Tutorial"))
local SettingsPanel = require(UI:WaitForChild("SettingsPanel"))
local MatchProgress = require(UI:WaitForChild("MatchProgress"))
local EndScreen = require(UI:WaitForChild("EndScreen"))
local MissionsPanel = require(UI:WaitForChild("MissionsPanel"))
local SocialPanel = require(UI:WaitForChild("SocialPanel"))
local UIScaler = require(UI:WaitForChild("UIScaler"))
local ProfilePanel = require(UI:WaitForChild("ProfilePanel"))
local EspionagePanel = require(UI:WaitForChild("EspionagePanel"))
local Fog = require(script.Parent:WaitForChild("State"):WaitForChild("Fog"))
local Settings = require(script.Parent:WaitForChild("State"):WaitForChild("Settings"))
local GameSession = require(script.Parent:WaitForChild("State"):WaitForChild("GameSession"))
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local MoveArrows = require(Map:WaitForChild("MoveArrows"))
local ArmyOrders = require(Map:WaitForChild("ArmyOrders"))
local MilitaryFolder = script.Parent:WaitForChild("Military")
local MilitaryState = require(MilitaryFolder:WaitForChild("MilitaryState"))
local UnitRenderer = require(MilitaryFolder:WaitForChild("UnitRenderer"))
local Selection = require(MilitaryFolder:WaitForChild("Selection"))
local SelectionPanel = require(MilitaryFolder:WaitForChild("SelectionPanel"))
local ScreenSpace = require(MilitaryFolder:WaitForChild("ScreenSpace"))
local OrderInput = require(MilitaryFolder:WaitForChild("OrderInput"))
local DivisionArrows = require(MilitaryFolder:WaitForChild("DivisionArrows"))
local BattlePanel = require(MilitaryFolder:WaitForChild("BattlePanel"))
local BattleRenderer = require(MilitaryFolder:WaitForChild("BattleRenderer"))
local FortificationView = require(MilitaryFolder:WaitForChild("FortificationView"))
local SupplyView = require(MilitaryFolder:WaitForChild("SupplyView"))
local GeneralRenderer = require(MilitaryFolder:WaitForChild("GeneralRenderer"))
local GeneralPanel = require(MilitaryFolder:WaitForChild("GeneralPanel"))
local PlanPanel = require(MilitaryFolder:WaitForChild("PlanPanel"))
local PlanRenderer = require(MilitaryFolder:WaitForChild("PlanRenderer"))
local MapEffects = require(Map:WaitForChild("MapEffects"))
local LabelLOD = require(Map:WaitForChild("LabelLOD"))
local AudioFolder = script.Parent:WaitForChild("Audio")
local Sfx = require(AudioFolder:WaitForChild("Sfx"))
local Music = require(AudioFolder:WaitForChild("Music"))
local Mood = require(AudioFolder:WaitForChild("Mood"))
local UISounds = require(AudioFolder:WaitForChild("UISounds"))
local Presence = require(script.Parent:WaitForChild("State"):WaitForChild("Presence"))

local mode: "titre" | "choix" | "jeu" = "titre"
local myCountry: string? = nil
local lastOwnRegion: string? = nil -- dernière de tes régions cliquée (pour nommer un général)

-- Pas de joystick tactile : il n'y a pas de personnage à déplacer
pcall(function()
	GuiService.TouchControlsEnabled = false
end)
-- Ni liste des joueurs, ni sac à dos, ni barre de vie, ni emotes : pas de personnage, et le coin
-- en haut à droite reste libre pour les boutons du jeu (le chat reste, pour négocier)
for _, kind in { Enum.CoreGuiType.PlayerList, Enum.CoreGuiType.Backpack, Enum.CoreGuiType.Health, Enum.CoreGuiType.EmotesMenu } do
	pcall(function()
		game:GetService("StarterGui"):SetCoreGuiEnabled(kind, false)
	end)
end

local function capitalPosition(countryId: string): Vector3?
	local country = Countries[countryId]
	if not country then
		return nil
	end
	return MapProjection.toVector3(country.capital.lon, country.capital.lat, MapSettings.regionTop)
end

local function focusCountry(countryId: string)
	local position = capitalPosition(countryId)
	if position then
		CameraController.focusOn(position, 450)
	end
end

-- Centre la carte sur une région et ouvre sa fiche (bouton « Voir » de l'onglet Industrie)
local function focusRegion(regionId: string)
	local region = Regions[regionId]
	local city = region and region.city
	if city then
		CameraController.focusOn(MapProjection.toVector3(city.lon, city.lat, MapSettings.regionTop), 250)
	end
	RegionSelector.select(regionId)
end

-- Centre la carte sur une armée (bouton « Ouvrir » de l'onglet Armée)
local function focusArmy(armyId: string)
	local position = ArmyView.positionOf(armyId)
	if position then
		CameraController.focusOn(position, 160)
	end
end

-- Région où nommer un nouveau général : la dernière de tes régions cliquée, sinon ta capitale
local function defaultRegion(): string
	local country = myCountry :: string
	if lastOwnRegion and RegionView.getOwner(lastOwnRegion) == country then
		return lastOwnRegion
	end
	return country
end

-- Interfaces propres au pays dirigé (détruites quand le joueur change de pays)
local GAME_GUIS = { "BarreHaut", "Onglets", "Absence", "Actualites", "Objectifs", "Conseil", "Dilemme", "Exil", "Tutoriel", "PropositionTutoriel" }

local openCountrySelect: (remoteName: string?) -> ()
local wantTutorial = false -- le joueur a choisi « Tutoriel » sur l'écran titre

local function stopGame()
	GameSession.stop() -- coupe les connexions de la partie quittée
	ArmyOrders.select(nil)
	Selection.setMulti(false)
	Selection.clear()
	BattlePanel.close()
	GeneralPanel.close()
	CameraController.setLeftDragPans(true) -- hors partie, le clic gauche glissé déplace la carte
	UnitRenderer.setLabelsEnabled(false)
	Fog.setCountry(nil) -- plus de brouillard hors partie
	RegionPanel.show(nil)
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	for _, name in GAME_GUIS do
		local gui = playerGui:FindFirstChild(name)
		if gui then
			gui:Destroy()
		end
	end
end

-- Gouvernement en exil : le joueur choisit un autre pays libre (le serveur valide)
local function chooseAnotherCountry()
	stopGame()
	Mood.stop() -- musique du menu pendant le choix
	openCountrySelect("ChangerDePays")
end

local function startGame(countryId: string)
	mode = "jeu"
	myCountry = countryId
	ControlsHint.hide()
	RegionSelector.setCountryMode(nil) -- en partie, une région à la fois
	CameraController.setLeftDragPans(false) -- en partie : clic gauche glissé = rectangle de sélection
	UnitRenderer.setLabelsEnabled(true) -- de loin, une étiquette par région (elle se touche)
	RegionSelector.select(nil)
	RegionView.setSelectionMode(false)
	TopBar.show(countryId)
	TabBar.create({
		countryId = countryId,
		focusRegion = focusRegion,
		focusArmy = focusArmy,
		defaultRegion = defaultRegion,
		onArmySelected = function(armyId: string?)
			-- fiche fermée : la force sélectionnée sur la carte reste en surbrillance
			ArmyView.setSelected(armyId or ArmyOrders.getSelected())
		end,
	})
	focusCountry(countryId)
	AbsenceBanner.start(countryId) -- inactif trop longtemps : l'IA prend le relais, ce bandeau le dit
	DiplomacyAlerts.start(countryId) -- guerres, propositions, paix, contrats
	NewsTicker.start(countryId) -- journal télévisé mondial (bandeau défilant)
	CountryAlerts.start(countryId) -- pénuries, stabilité, révoltes
	task.spawn(ObjectivesWidget.start, countryId) -- objectifs nationaux (attend leur publication)
	CouncilPanel.start(countryId) -- votes du Conseil mondial
	DilemmaCard.start(countryId) -- dilemmes de dirigeant (cartes à choix)
	ExilePanel.start(countryId, chooseAnotherCountry) -- plus aucune région : exil, résistance, autre pays
	Tutorial.start(countryId, wantTutorial) -- tutoriel guidé (demandé, ou proposé une fois)
	wantTutorial = false
	Mood.start(countryId) -- musique selon la situation (paix, tension, guerre)
	Fog.setCountry(countryId) -- brouillard de guerre : on ne voit que près de ses frontières
end

function openCountrySelect(remoteName: string?)
	mode = "choix"
	local start = MapSettings.camera.startFocus
	CameraController.setAttract(false)
	CameraController.setInputEnabled(true)
	CameraController.focusOn(MapProjection.toVector3(start.lon, start.lat, MapSettings.regionTop), MapSettings.camera.startDistance)
	RegionSelector.setEnabled(true)
	RegionSelector.setCountryMode(RegionView.getOwner) -- un clic montre tout le pays
	RegionView.setSelectionMode(true)
	ControlsHint.show()
	CountrySelect.open({
		selectRegion = RegionSelector.select,
		focusCountry = focusCountry,
		onConfirmed = startGame,
		remoteName = remoteName,
	})
end

-- 1. Écran titre tout de suite, rideau noir pendant la construction de la carte
TitleScreen.show(function(tutorial: boolean)
	wantTutorial = tutorial
	openCountrySelect(nil)
end)
Tooltips.start() -- info-bulles au survol des boutons et des ressources
UIScaler.start() -- taille de l'interface selon l'écran (téléphone, tablette) et le réglage du joueur
-- son : musique du menu, sons des boutons et des actions, bouton ⚙️ des réglages
Sfx.preload()
Music.start()
Music.setMood("Titre")
UISounds.start()
SettingsPanel.attachButton()
MatchProgress.start() -- annonces : nouvelle phase, crise mondiale, fin proche
SocialPanel.start() -- 👥 jouer entre amis : invitations, alliances, discussions privées
task.spawn(MissionsPanel.start) -- 📅 missions du jour (attend leur chargement)
task.spawn(ProfilePanel.start) -- 🏅 profil : succès, titres, parties (attend le compte)
task.spawn(Settings.attach) -- réglages sauvegardés avec le compte

-- Fin de partie : classement ; nouvelle partie : retour au choix du pays
do
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local lastNumber = MatchState.number()
	state:GetAttributeChangedSignal("Partie"):Connect(function()
		if MatchState.status() == "Fin" and mode ~= "titre" then
			Mood.stop() -- musique du menu
			EndScreen.show()
		end
	end)
	state:GetAttributeChangedSignal("PartieNumero"):Connect(function()
		if MatchState.number() == lastNumber then
			return
		end
		lastNumber = MatchState.number()
		EndScreen.hide()
		if mode == "jeu" then
			stopGame()
			Mood.stop()
			openCountrySelect(nil)
		end
	end)
end

-- 2. Carte du monde (elle n'existe que chez ce joueur), sans brume
MapLighting.apply()
local carte = MapBuilder.build()
carte.Parent = workspace

RegionView.start(carte)
LabelLOD.start(carte) -- noms des régions de près, noms des pays de loin
MapEffects.start(carte) -- conquêtes : la région s'illumine, une onde part de son centre
CameraController.start()
CameraController.setInputEnabled(false)
CameraController.setAttract(true)
RegionPanel.create(function()
	RegionSelector.select(nil)
end)
-- usines : état publié par le serveur, bâtiments sur la carte, section de la fiche de région
FactoryState.start()
FactoryView.start(carte)
FactoryPanel.attach()
EspionagePanel.attach() -- espionnage dans la fiche des régions étrangères
Fog.start()
RegionSelector.start(carte, function(regionId: string?)
	if mode == "choix" then
		CountrySelect.select(regionId)
	elseif mode == "jeu" then
		RegionPanel.show(regionId)
		if regionId then
			GeneralPanel.close() -- une fiche à la fois à gauche de l'écran
		end
		if regionId and RegionView.getOwner(regionId) == myCountry then
			lastOwnRegion = regionId
		end
	end
end)
RegionSelector.setEnabled(false)
-- armées : un clic sur un général (ou ses troupes) le sélectionne, puis un clic sur une région
-- l'y envoie (prioritaire sur la sélection de la région en dessous)
ArmyState.start()
ArmyOrders.start({
	myCountry = function(): string?
		return if mode == "jeu" then myCountry else nil
	end,
	openArmy = TabBar.openArmy,
	onSelect = function()
		Selection.clear() -- une force aérienne ou navale à la fois, sans divisions
		RegionSelector.select(nil) -- ferme la fiche de région
		if TabBar.getCurrent() ~= "Carte" then
			TabBar.select("Carte") -- et le panneau d'onglet : la carte est libre pour choisir
		end
	end,
})
local lastGeneralTap: { general: Instance?, time: number } = { general = nil, time = 0 }
RegionSelector.setTapInterceptor(function(screenPos: Vector2): boolean
	if mode ~= "jeu" then
		return false
	end
	-- choix du quartier général d'un général, puis les généraux (fiche ; double-clic : son
	-- armée), les divisions (sélection), enfin escadrilles et flottes
	if PlanPanel.handlePick(screenPos) or GeneralPanel.handlePick(screenPos) then
		return true -- front, ligne offensive, repli ou nouveau quartier général
	end
	local general = GeneralRenderer.hitTest(screenPos)
	if general then
		local now = os.clock()
		if lastGeneralTap.general == general and now - lastGeneralTap.time < 0.35 then
			Selection.set(GeneralPanel.divisionsOf(general))
		else
			RegionPanel.show(nil) -- la fiche du général prend la place de celle de la région
			GeneralPanel.open(general)
		end
		lastGeneralTap = { general = general, time = now }
		return true
	end
	if Selection.handleTap(screenPos) then
		return true
	end
	if OrderInput.handleTap(screenPos) then -- mobile : région visée par les divisions sélectionnées
		return true
	end
	return ArmyOrders.handleTap(screenPos)
end)
task.spawn(ArmyView.start, carte) -- attend les modèles fabriqués par le serveur
-- divisions terrestres (SYSTEME_MILITAIRE.md) : un modèle par division, en formation dans sa région
MilitaryState.start()
task.spawn(UnitRenderer.start, carte)
-- sélection des divisions : clic, rectangle, Shift, double-clic, groupes, panneau en bas
Selection.start({
	myCountry = function(): string?
		return if mode == "jeu" then myCountry else nil
	end,
	enabled = function(): boolean
		return mode == "jeu"
	end,
})
ScreenSpace.start() -- place libre à l'écran pour les panneaux militaires (téléphone compris)
SelectionPanel.start()
-- ordres : clic droit (PC) ou bouton (mobile) ; région verte, rouge ou grise au survol
OrderInput.start({
	myCountry = function(): string?
		return if mode == "jeu" then myCountry else nil
	end,
	enabled = function(): boolean
		return mode == "jeu"
	end,
})
DivisionArrows.start(carte) -- flèches de trajet des divisions
BattlePanel.start() -- panneau d'une bataille (toucher son icône)
BattleRenderer.start(carte) -- batailles terrestres : icônes, tirs, explosions, messages
FortificationView.start(carte) -- murets autour des villes fortifiées
SupplyView.start(carte) -- poches d'encerclement : contour rouge clignotant
task.spawn(GeneralRenderer.start, carte) -- généraux : officier et fanion au quartier général
GeneralPanel.start() -- fiche d'un général (toucher son modèle)
PlanPanel.start() -- ordres de plan de bataille dans cette fiche
PlanRenderer.start(carte) -- front, flèches d'offensive et ligne de repli du général ouvert
-- la molette zoome aussi au-dessus des étiquettes de divisions et des icônes de bataille (elles se
-- touchent, mais ne bloquent pas le zoom)
CameraController.setWheelPassThrough(function(pos: Vector2): boolean
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	local labels = playerGui and playerGui:FindFirstChild("EtiquettesDivisions")
	local icons = playerGui and playerGui:FindFirstChild("IconesBatailles")
	if not playerGui or not labels then
		return false
	end
	local objects = (playerGui :: PlayerGui):GetGuiObjectsAtPosition(pos.X, pos.Y)
	for _, object in objects do
		if not object:IsDescendantOf(labels) and not (icons and object:IsDescendantOf(icons)) then
			return false
		end
	end
	return #objects > 0
end)
Selection.onChanged(function(list: { Instance })
	if #list > 0 then
		ArmyOrders.select(nil) -- divisions ou force aérienne / navale, pas les deux
	end
end)
task.spawn(BattleView.start, carte) -- raids aériens et navals : troupes déployées, tirs, explosions
MoveArrows.start(carte) -- flèches des forces en route
AttackAlert.start() -- prévient le joueur quand une force étrangère marche sur une de ses régions
Presence.start() -- signale au serveur que le joueur est actif (sinon l'IA prend le relais)

TitleScreen.reveal()

