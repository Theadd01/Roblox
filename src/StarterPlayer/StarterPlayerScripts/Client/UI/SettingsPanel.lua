--!strict
-- Fenêtre « Paramètres » : volume de la musique et des effets (boutons − et +, faciles au doigt),
-- messages d'information affichés ou masqués, taille de l'interface (petite, normale, grande). Ouverte par le bouton Paramètres de l'écran titre,
-- ou par le bouton ⚙️ en haut à droite de l'écran pendant la partie.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Audio = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Audio")) :: any
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local ModalHost = require(script.Parent:WaitForChild("ModalHost"))
local Settings = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("Settings"))

local ROW_HEIGHT = 46

local SettingsPanel = {}

local window: TextButton? = nil
local launcher: TextButton? = nil
local launcherIcon: Frame? = nil

local function syncLauncherState()
	local button, icon, backdrop = launcher, launcherIcon, window
	if button and icon then
		local selected = if backdrop then backdrop.Visible else false
		UIStyle.setButtonSelected(button, selected)
		UIStyle.setIconColor(icon, if selected then UIStyle.ACCENT else UIStyle.TEXT_DIM)
	end
end

local function createBackdrop(gui: ScreenGui): TextButton
	local backdrop = Instance.new("TextButton")
	backdrop.Name = "FondModal"
	backdrop.Active = true
	backdrop.AutoButtonColor = false
	backdrop.Selectable = false
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = UIStyle.BACKDROP
	backdrop.BackgroundTransparency = 0.2
	backdrop.BorderSizePixel = 0
	backdrop.Text = ""
	backdrop.Visible = false
	backdrop.Parent = gui
	return backdrop
end

local function row(parent: Instance, order: number, name: string, label: string): Frame
	local frame = UIStyle.card(name, ROW_HEIGHT)
	frame.LayoutOrder = order
	UIStyle.padding(frame, 0, 12)
	local title = UIStyle.text("Titre", label, 18, UIStyle.FONT_BOLD)
	title.AutomaticSize = Enum.AutomaticSize.None
	title.Size = UDim2.new(1, -170, 1, 0)
	title.TextYAlignment = Enum.TextYAlignment.Center
	title.Parent = frame
	frame.Parent = parent
	return frame
end

local function smallButton(name: string, text: string, x: number): TextButton
	local b = UIStyle.button(name, text)
	b.AnchorPoint = Vector2.new(1, 0.5)
	b.Position = UDim2.new(1, x, 0.5, 0)
	b.Size = UDim2.fromOffset(ROW_HEIGHT, ROW_HEIGHT)
	b.TextSize = 24
	return b
end

-- Ligne de volume : « 🎵 Musique   [−] 50 % [+] »
local function volumeRow(parent: Instance, order: number, name: string, label: string, key: string)
	local frame = row(parent, order, name, label)
	local minus = smallButton("Moins", "−", -(ROW_HEIGHT + 76))
	minus.Parent = frame
	local value = UIStyle.text("Valeur", "", 18, UIStyle.FONT_BOLD)
	value.AutomaticSize = Enum.AutomaticSize.None
	value.AnchorPoint = Vector2.new(1, 0.5)
	value.Position = UDim2.new(1, -(ROW_HEIGHT + 4), 0.5, 0)
	value.Size = UDim2.fromOffset(68, ROW_HEIGHT)
	value.TextXAlignment = Enum.TextXAlignment.Center
	value.TextYAlignment = Enum.TextYAlignment.Center
	value.Parent = frame
	local plus = smallButton("Plus", "+", 0)
	plus.Parent = frame

	local function refresh()
		local v: number = Settings.get(key)
		value.Text = if v <= 0.001 then "🔇" else `{math.floor(v * 100 + 0.5)} %`
		UIStyle.setButtonEnabled(minus, v > 0.001)
		UIStyle.setButtonEnabled(plus, v < 0.999)
	end
	local function change(delta: number)
		local v: number = Settings.get(key)
		-- arrondi au pas près (évite 0,30000004)
		local steps = math.floor((v + delta) / Audio.volumeStep + 0.5)
		Settings.set(key, math.clamp(steps * Audio.volumeStep, 0, 1))
		refresh()
	end
	minus.Activated:Connect(function()
		if UIStyle.isEnabled(minus) then
			change(-Audio.volumeStep)
		end
	end)
	plus.Activated:Connect(function()
		if UIStyle.isEnabled(plus) then
			change(Audio.volumeStep)
		end
	end)
	refresh()
end

-- Ligne oui / non : « 💬 Messages d'information   [Affichés] »
local function toggleRow(parent: Instance, order: number, name: string, label: string, key: string, onText: string, offText: string)
	local frame = row(parent, order, name, label)
	local b = UIStyle.button("Choix", "")
	b.AnchorPoint = Vector2.new(1, 0.5)
	b.Position = UDim2.new(1, 0, 0.5, 0)
	b.Size = UDim2.fromOffset(160, ROW_HEIGHT)
	b.TextSize = 17
	b.Parent = frame
	local function refresh()
		b.Text = if Settings.get(key) then onText else offText
	end
	b.Activated:Connect(function()
		Settings.set(key, not Settings.get(key))
		refresh()
	end)
	refresh()
end

-- Ligne à choix multiples : « 🔠 Taille de l'interface   [Normale] » (chaque appui passe au suivant)
local function choiceRow(parent: Instance, order: number, name: string, label: string, key: string, choices: { string })
	local frame = row(parent, order, name, label)
	local b = UIStyle.button("Choix", "")
	b.AnchorPoint = Vector2.new(1, 0.5)
	b.Position = UDim2.new(1, 0, 0.5, 0)
	b.Size = UDim2.fromOffset(160, ROW_HEIGHT)
	b.TextSize = 17
	b.Parent = frame
	local function refresh()
		b.Text = tostring(Settings.get(key))
	end
	b.Activated:Connect(function()
		local index = table.find(choices, Settings.get(key)) or 0
		Settings.set(key, choices[index % #choices + 1])
		refresh()
	end)
	refresh()
end

local function build(): TextButton
	local gui = Instance.new("ScreenGui")
	gui.Name = "Parametres"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20 -- au-dessus de l'écran titre
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local backdrop = createBackdrop(gui)
	local panel = UIStyle.panel("Fenetre", UDim.new(1, -32))
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.AutomaticSize = Enum.AutomaticSize.None
	panel.Size = UDim2.new(1, -32, 1, -48)
	panel.ClipsDescendants = true
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(460, 500)
	limit.Parent = panel
	panel.Parent = backdrop

	local header = Instance.new("Frame")
	header.Name = "Entete"
	header.Size = UDim2.new(1, 0, 0, 76)
	header.BackgroundColor3 = UIStyle.PANEL_RAISED
	header.BackgroundTransparency = 0.12
	header.BorderSizePixel = 0
	header.Parent = panel
	local overline = UIStyle.text("Rubrique", "CONFIGURATION DU POSTE", 11, UIStyle.FONT_BOLD, UIStyle.ACCENT)
	overline.AutomaticSize = Enum.AutomaticSize.None
	overline.Position = UDim2.fromOffset(20, 11)
	overline.Size = UDim2.new(1, -40, 0, 16)
	overline.Parent = header
	local titleIcon = UIStyle.mountIcon(header, "Settings", 24, UIStyle.ACCENT)
	titleIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	titleIcon.Position = UDim2.fromOffset(31, 46)
	local title = UIStyle.text("Titre", "Paramètres", 26, UIStyle.FONT_BLACK)
	title.AutomaticSize = Enum.AutomaticSize.None
	title.Position = UDim2.fromOffset(54, 29)
	title.Size = UDim2.new(1, -74, 0, 34)
	title.Parent = header
	local headerDivider = UIStyle.divider("SeparateurEntete")
	headerDivider.AnchorPoint = Vector2.new(0, 1)
	headerDivider.Position = UDim2.fromScale(0, 1)
	headerDivider.Parent = header

	local content = Instance.new("ScrollingFrame")
	content.Name = "Contenu"
	content.Position = UDim2.fromOffset(18, 88)
	content.Size = UDim2.new(1, -36, 1, -164)
	content.BackgroundTransparency = 1
	content.CanvasSize = UDim2.new()
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	UIStyle.styleScroll(content)
	UIStyle.list(content, 10)
	content.Parent = panel
	local audioLabel = UIStyle.text("SectionAudio", "AUDIO", 12, UIStyle.FONT_BOLD, UIStyle.TEXT_DIM)
	audioLabel.LayoutOrder = 1
	audioLabel.Parent = content
	volumeRow(content, 2, "Musique", "🎵 Musique", "musicVolume")
	volumeRow(content, 3, "Effets", "🔊 Effets sonores", "effectsVolume")
	local sectionDivider = UIStyle.divider("SeparateurSections")
	sectionDivider.LayoutOrder = 4
	sectionDivider.Parent = content
	local interfaceLabel = UIStyle.text("SectionInterface", "INTERFACE", 12, UIStyle.FONT_BOLD, UIStyle.TEXT_DIM)
	interfaceLabel.LayoutOrder = 5
	interfaceLabel.Parent = content
	toggleRow(content, 6, "Messages", "💬 Messages d'info", "infoMessages", "Affichés", "Masqués")
	choiceRow(content, 7, "Taille", "🔠 Taille de l'interface", "uiSize", { "Petite", "Normale", "Grande" })
	local note = UIStyle.text("Note", "Les succès et les alertes restent toujours affichés.", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
	note.LayoutOrder = 8
	note.Parent = content

	local footer = Instance.new("Frame")
	footer.Name = "Pied"
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.fromScale(0, 1)
	footer.Size = UDim2.new(1, 0, 0, 66)
	footer.BackgroundColor3 = UIStyle.PANEL_ALT
	footer.BackgroundTransparency = 0.08
	footer.BorderSizePixel = 0
	footer.Parent = panel
	local footerDivider = UIStyle.divider("SeparateurPied")
	footerDivider.Parent = footer
	local close = UIStyle.button("Fermer", "Fermer", true)
	close.Position = UDim2.fromOffset(18, 12)
	close.Size = UDim2.new(1, -36, 0, 42)
	close.Parent = footer
	close.Activated:Connect(function()
		ModalHost.hide(backdrop)
		syncLauncherState()
	end)
	backdrop.Activated:Connect(function()
		ModalHost.hide(backdrop)
		syncLauncherState()
	end)
	return backdrop
end

-- Ouvre (ou referme) la fenêtre
function SettingsPanel.toggle()
	local panel = window or build()
	window = panel
	ModalHost.toggle(panel, syncLauncherState)
	syncLauncherState()
end

-- Bouton ⚙️ en haut à droite de l'écran (toute la partie)
function SettingsPanel.attachButton()
	local gui = Instance.new("ScreenGui")
	gui.Name = "BoutonParametres"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	local b = UIStyle.button("Parametres", "")
	b.AnchorPoint = Vector2.new(1, 0)
	b.Position = UDim2.new(1, -12, 0, 8)
	b.Size = UDim2.fromOffset(46, 46)
	b:SetAttribute("InfoBulleTexte", "Paramètres")
	local icon = UIStyle.mountIcon(b, "Settings", 23, UIStyle.TEXT_DIM)
	b.Parent = gui
	b.Activated:Connect(SettingsPanel.toggle)
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	launcher = b
	launcherIcon = icon
	syncLauncherState()
end

return SettingsPanel
