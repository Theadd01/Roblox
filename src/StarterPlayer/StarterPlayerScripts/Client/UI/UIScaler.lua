--!strict
-- Taille de l'interface (téléphone, tablette, ordinateur) : chaque panneau des interfaces du jeu
-- reçoit une échelle (UIScale « EchelleInterface ») qui dépend de la taille de l'écran (plus petite
-- sur téléphone) et du réglage du joueur (Paramètres : petite, normale, grande).
-- Les fonds plein écran ne sont pas réduits : pour un FondModal, seul son panneau enfant reçoit
-- l'échelle. L'écran titre et l'écran de fin ont leur propre mise à l'échelle. Les interfaces sont
-- repérées par leur nom, dès qu'elles apparaissent.

local Players = game:GetService("Players")

local Settings = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("Settings"))

-- Interfaces du jeu mises à l'échelle (noms des ScreenGui)
local SCALED = {
	BarreHaut = true,
	-- Onglets gère déjà sa barre et ses panneaux responsifs dans TabBar ; lui ajouter
	-- une seconde UIScale réduisait deux fois les commandes sur les petits écrans.
	Objectifs = true,
	Messages = true,
	Annonces = true,
	Conseil = true,
	Dilemme = true,
	Exil = true,
	Tutoriel = true,
	PropositionTutoriel = true,
	-- FicheRegion et ChoixPays calculent eux-mêmes leur largeur à chaque changement
	-- de viewport. Une UIScale ajoutée avant ce calcul cassait leur pleine largeur.
	Actualites = true,
	Absence = true,
	AideCommandes = true,
	Parametres = true,
	MissionsDuJour = true,
	JouerEntreAmis = true,
	Profil = true,
	Confirmation = true, -- fenêtre de confirmation (guerre, attaque, votes)
	ChoixTroupes = true, -- troupes à rattacher à un général
	Votes = true, -- votes des trêves et des événements mondiaux
	-- Les commandes du coin supérieur droit gardent toutes leur grille native de
	-- 46 px. Les mettre à l'échelle séparément décalait leurs espacements et ne
	-- correspondait pas au lanceur du passe, intégré à son propre ScreenGui.
}
local SIZE_FACTORS = { Petite = 0.85, Normale = 1, Grande = 1.15 }
local SCALE_NAME = "EchelleInterface"

local UIScaler = {}

-- échelles posées (table normale : une table faible peut perdre des instances encore en place)
local scales: { [UIScale]: boolean } = {}

-- Échelle d'après l'écran (plus petite sur téléphone) et le réglage du joueur
function UIScaler.factor(): number
	local viewport = workspace.CurrentCamera.ViewportSize
	local shortest = math.min(viewport.X, viewport.Y)
	local screen = if shortest < 450 then 0.8 elseif shortest < 650 then 0.9 else 1
	local setting = SIZE_FACTORS[Settings.get("uiSize") :: string] or 1
	return math.clamp(screen * setting, 0.65, 1.3)
end

local function isFullScreen(gui: GuiObject): boolean
	return gui.Size.X.Scale >= 0.99 and gui.Size.Y.Scale >= 0.99
end

local function addScale(child: Instance)
	if not child:IsA("GuiObject") or child:FindFirstChild(SCALE_NAME) then
		return
	end
	local s = Instance.new("UIScale")
	s.Name = SCALE_NAME
	s.Scale = UIScaler.factor()
	s.Parent = child
	scales[s] = true
	s.Destroying:Connect(function()
		scales[s] = nil
	end)
end

local function scale(child: Instance)
	if not child:IsA("GuiObject") then
		return
	end
	if isFullScreen(child) then
		if child.Name == "FondModal" then
			-- Le voile doit toujours couvrir l'écran ; l'échelle appartient à la
			-- fenêtre qu'il contient (Paramètres, Missions, Profil, Social, dilemme…).
			for _, content in child:GetChildren() do
				addScale(content)
			end
			child.ChildAdded:Connect(addScale)
		end
		return
	end
	addScale(child)
end

local function watch(gui: Instance)
	if not gui:IsA("ScreenGui") or not SCALED[gui.Name] then
		return
	end
	for _, child in gui:GetChildren() do
		scale(child)
	end
	gui.ChildAdded:Connect(scale)
end

local function refresh()
	local value = UIScaler.factor()
	for s in scales do
		if s.Parent then
			s.Scale = value
		else
			scales[s] = nil
		end
	end
end

function UIScaler.start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	for _, gui in playerGui:GetChildren() do
		watch(gui)
	end
	playerGui.ChildAdded:Connect(watch)
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(refresh)
	Settings.onChanged(function(key: string)
		if key == "uiSize" then
			refresh()
		end
	end)
end

return UIScaler
