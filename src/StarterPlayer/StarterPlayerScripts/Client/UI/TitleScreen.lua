--!strict
-- Écran titre : nom du jeu sur fond de carte qui défile, boutons Jouer / Tutoriel / Paramètres / Crédits.
-- Un rideau noir cache le monde pendant la construction de la carte (TitleScreen.reveal l'enlève).

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local SettingsPanel = require(script.Parent:WaitForChild("SettingsPanel"))

local GAME_NAME = "WORLD FRONT"
local TAGLINE = "La Troisième Guerre mondiale vient d'éclater. Choisis ton pays et mène-le à la victoire."
local INFOS = {
	Credits = {
		title = "Crédits",
		text = GAME_NAME
			.. " : jeu de grande stratégie en développement.\nDonnées cartographiques : Natural Earth (domaine public).\nMusiques : APM Music. Sons : Roblox et Pro Sound Effects (bibliothèques sous licence Roblox).\nTous les dirigeants et factions du jeu sont fictifs.",
	},
}

local TitleScreen = {}

local curtain: Frame? = nil
local playButton: TextButton? = nil

local function fitScale(scale: UIScale)
	local viewport = workspace.CurrentCamera.ViewportSize
	scale.Scale = math.clamp(math.min(viewport.X / 1100, viewport.Y / 700), 0.55, 1)
end

-- Fenêtre d'information (crédits)
local function makeInfoBox(parent: Instance): (string) -> ()
	local box = UIStyle.panel("Info", UDim.new(0, 440))
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.Position = UDim2.fromScale(0.5, 0.5)
	box.Visible = false
	box.ZIndex = 5
	UIStyle.padding(box, 18, 20)
	UIStyle.list(box, 12)
	local title = UIStyle.text("Titre", "", 28, UIStyle.FONT_BOLD)
	title.LayoutOrder = 1
	title.Parent = box
	local body = UIStyle.text("Texte", "", 18, UIStyle.FONT, UIStyle.TEXT_DIM)
	body.LayoutOrder = 2
	body.Parent = box
	local close = UIStyle.button("Fermer", "Fermer")
	close.LayoutOrder = 3
	close.Parent = box
	close.Activated:Connect(function()
		box.Visible = false
	end)
	box.Parent = parent
	return function(key: string)
		local info = INFOS[key]
		title.Text = info.title
		body.Text = info.text
		box.Visible = true
	end
end

-- Affiche l'écran titre. onPlay(tutoriel) est appelé quand le joueur clique sur Jouer
-- (tutoriel = faux) ou sur Tutoriel (tutoriel = vrai : le tutoriel guidé suivra le choix du pays).
function TitleScreen.show(onPlay: (tutorial: boolean) -> ())
	local screen = Instance.new("ScreenGui")
	screen.Name = "EcranTitre"
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 10
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- voile sombre à gauche pour lire le titre ; la carte reste visible à droite
	local shade = Instance.new("Frame")
	shade.Name = "Voile"
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BorderSizePixel = 0
	local gradient = Instance.new("UIGradient")
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.55, 0.65),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = shade
	shade.Parent = screen

	local content = Instance.new("CanvasGroup")
	content.Name = "Contenu"
	content.AnchorPoint = Vector2.new(0, 0.5)
	content.Position = UDim2.new(0, 64, 0.5, 0)
	content.Size = UDim2.new(0, 460, 0, 0)
	content.AutomaticSize = Enum.AutomaticSize.Y
	content.BackgroundTransparency = 1
	UIStyle.list(content, 14)
	local scale = Instance.new("UIScale")
	scale.Parent = content
	fitScale(scale)
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		fitScale(scale)
	end)

	local title = UIStyle.text("Titre", GAME_NAME, 76, UIStyle.FONT_BLACK)
	title.LayoutOrder = 1
	title.Parent = content
	local line = Instance.new("Frame")
	line.Name = "Trait"
	line.LayoutOrder = 2
	line.Size = UDim2.fromOffset(120, 4)
	line.BackgroundColor3 = UIStyle.ACCENT
	line.BorderSizePixel = 0
	line.Parent = content
	local tagline = UIStyle.text("Accroche", TAGLINE, 20, UIStyle.FONT_MEDIUM, Color3.fromRGB(205, 210, 220))
	tagline.LayoutOrder = 3
	tagline.Parent = content

	local buttons = Instance.new("Frame")
	buttons.Name = "Boutons"
	buttons.LayoutOrder = 4
	buttons.BackgroundTransparency = 1
	buttons.Size = UDim2.new(0, 280, 0, 0)
	buttons.AutomaticSize = Enum.AutomaticSize.Y
	UIStyle.list(buttons, 10)
	local topSpace = Instance.new("UIPadding")
	topSpace.PaddingTop = UDim.new(0, 18)
	topSpace.Parent = buttons
	buttons.Parent = content

	content.Parent = screen

	local showInfo = makeInfoBox(screen)
	local play = UIStyle.button("Jouer", "Jouer", true)
	play.LayoutOrder = 1
	play.TextSize = 24
	play.Size = UDim2.new(1, 0, 0, 58)
	UIStyle.setButtonEnabled(play, false) -- actif quand la carte est prête
	play.Parent = buttons
	local function start(tutorial: boolean)
		if not UIStyle.isEnabled(play) then
			return
		end
		UIStyle.setButtonEnabled(play, false)
		local info = TweenInfo.new(0.5)
		TweenService:Create(content, info, { GroupTransparency = 1 }):Play()
		TweenService:Create(shade, info, { BackgroundTransparency = 1 }):Play()
		task.delay(0.5, function()
			screen:Destroy()
		end)
		onPlay(tutorial)
	end

	for i, entry in { { "Tutoriel", "Tutoriel" }, { "Parametres", "Paramètres" }, { "Credits", "Crédits" } } do
		local b = UIStyle.button(entry[1], entry[2])
		b.LayoutOrder = i + 1
		b.Parent = buttons
		b.Activated:Connect(function()
			if entry[1] == "Tutoriel" then
				start(true) -- choisir un pays, puis suivre le tutoriel guidé
			elseif entry[1] == "Parametres" then
				SettingsPanel.toggle() -- volumes, messages
			else
				showInfo(entry[1])
			end
		end)
	end

	play.Activated:Connect(function()
		start(false)
	end)

	-- rideau noir tant que la carte n'est pas construite
	local c = Instance.new("Frame")
	c.Name = "Rideau"
	c.Size = UDim2.fromScale(1, 1)
	c.BackgroundColor3 = Color3.new(0, 0, 0)
	c.BorderSizePixel = 0
	c.ZIndex = 10
	c.Parent = screen

	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	curtain, playButton = c, play
end

-- La carte est prête : on lève le rideau et on active le bouton Jouer
function TitleScreen.reveal()
	local c = curtain
	if c then
		TweenService:Create(c, TweenInfo.new(1), { BackgroundTransparency = 1 }):Play()
		task.delay(1, function()
			c.Visible = false
		end)
	end
	if playButton then
		UIStyle.setButtonEnabled(playButton, true)
	end
end

return TitleScreen
