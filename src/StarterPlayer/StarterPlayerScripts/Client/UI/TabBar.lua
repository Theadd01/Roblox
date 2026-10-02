--!strict
-- Menus en onglets (en bas de l'écran, gros boutons pour le tactile) :
--   Carte, Industrie, Bâtiments, Recherche, Marché, Armée, Diplomatie.
-- « Carte » laisse la carte libre ; les autres ouvrent un panneau sur le côté droit
-- (sur toute la largeur sur téléphone).

local Players = game:GetService("Players")

local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local GameSession = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("GameSession"))
local Tabs = script.Parent:WaitForChild("Tabs")
local IndustryTab = require(Tabs:WaitForChild("IndustryTab"))
local MarketTab = require(Tabs:WaitForChild("MarketTab"))
local ArmyTab = require(Tabs:WaitForChild("ArmyTab"))
local DiplomacyTab = require(Tabs:WaitForChild("DiplomacyTab"))
local ResearchTab = require(Tabs:WaitForChild("ResearchTab"))
local BuildingsTab = require(Tabs:WaitForChild("BuildingsTab"))

type Tab = {
	id: string,
	iconKey: string,
	name: string,
	soon: string?, -- texte « bientôt disponible » pour les onglets pas encore faits
}

local TABS: { Tab } = {
	{ id = "Carte", iconKey = "Map", name = "Carte" },
	{ id = "Industrie", iconKey = "Industry", name = "Industrie" },
	{ id = "Batiments", iconKey = "Buildings", name = "Bâtiments" },
	{ id = "Recherche", iconKey = "Research", name = "Recherche" },
	{ id = "Marche", iconKey = "Market", name = "Marché" },
	{ id = "Armee", iconKey = "Army", name = "Armée" },
	{ id = "Diplomatie", iconKey = "Diplomacy", name = "Diplomatie" },
}

local NARROW_SCREEN = 700
local TOP_SPACE = 76 -- sous la barre du haut
local BOTTOM_SPACE = 92 -- au-dessus des onglets
local DEFAULT_PANEL_WIDTH = 500
local TAB_BUTTON_WIDTH = 110
local TAB_ICON_ONLY_WIDTH = 54
local TAB_ICON_ONLY_BREAKPOINT = 780
local TAB_GAP = 6
local TAB_BAR_PADDING = 12
local PANEL_WIDTHS: { [string]: number } = {
	Industrie = 900,
	Batiments = 900,
	Recherche = 1000,
	Marche = 640,
	Armee = 640,
	Diplomatie = 680,
}

export type Options = {
	countryId: string,
	focusRegion: (regionId: string) -> (),
	focusArmy: (armyId: string) -> (),
	defaultRegion: () -> string, -- où nommer un nouveau général
	onArmySelected: (armyId: string?) -> (), -- surbrillance de l'armée affichée
}

local TabBar = {}

local buttons: { [string]: TextButton } = {}
local panel: Frame? = nil
local body: ScrollingFrame? = nil
local title: TextLabel? = nil
local headerIconSlot: Frame? = nil
local current = "Carte"
local cleanup: (() -> ())? = nil
local options: Options? = nil
local pendingArmy: string? = nil -- armée à ouvrir dans l'onglet Armée

local function paintTab(button: TextButton, selected: boolean)
	if selected then
		UIStyle.setButtonColor(button, UIStyle.PANEL_RAISED, UIStyle.TEXT, 0.02)
	else
		UIStyle.setButtonColor(button, UIStyle.PANEL_ALT, UIStyle.TEXT, 0.06)
	end
	local icon = button:FindFirstChild("Icone", true)
	local label = button:FindFirstChild("Libelle")
	local marker = button:FindFirstChild("Selection")
	if icon and icon:IsA("Frame") then
		UIStyle.setIconColor(icon, if selected then UIStyle.ACCENT else UIStyle.TEXT_DIM)
	end
	if label and label:IsA("TextLabel") then
		label.TextColor3 = if selected then UIStyle.TEXT else UIStyle.TEXT_DIM
	end
	if marker and marker:IsA("Frame") then
		marker.Visible = selected
	end
	local outline = button:FindFirstChild("Contour")
	if outline and outline:IsA("UIStroke") then
		outline.Color = if selected then UIStyle.ACCENT else UIStyle.BORDER_SOFT
		outline.Transparency = if selected then 0.22 else 0.55
		button:SetAttribute("ContourBase", if selected then 0.22 else 0.55)
	end
	button:SetAttribute("Selectionne", selected)
end

-- Haut du panneau : sous le bas réel de la barre du haut (au moins TOP_SPACE)
local function topSpace(): number
	local bottom = Players.LocalPlayer:GetAttribute("BasBarreHaut")
	return if typeof(bottom) == "number" then math.max(TOP_SPACE, bottom + 8) else TOP_SPACE
end

local function layoutForScreen()
	local p = panel
	if not p then
		return
	end
	local top = topSpace()
	local viewport = workspace.CurrentCamera.ViewportSize
	local narrow = viewport.X < NARROW_SCREEN
	if narrow then
		p.AnchorPoint = Vector2.new(0.5, 0)
		p.Position = UDim2.new(0.5, 0, 0, top)
		p.Size = UDim2.new(1, -24, 1, -(top + BOTTOM_SPACE))
	else
		p.AnchorPoint = Vector2.new(1, 0)
		p.Position = UDim2.new(1, -12, 0, top)
		local requested = PANEL_WIDTHS[current] or DEFAULT_PANEL_WIDTH
		local width = math.min(requested, viewport.X - 24)
		p.Size = UDim2.new(0, width, 1, -(top + BOTTOM_SPACE))
	end
end

local function clearBody()
	if cleanup then
		cleanup()
		cleanup = nil
	end
	local b = body
	if b then
		for _, child in b:GetChildren() do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end
	end
end

-- Contenu d'un onglet pas encore disponible
local function comingSoon(container: Instance, tab: Tab)
	local iconRow = Instance.new("Frame")
	iconRow.Name = "Icone"
	iconRow.LayoutOrder = 1
	iconRow.Size = UDim2.new(1, 0, 0, 56)
	iconRow.BackgroundTransparency = 1
	local icon = UIStyle.mountIcon(iconRow, tab.iconKey, 42, UIStyle.ACCENT)
	icon.Name = "Pictogramme"
	iconRow.Parent = container
	local label = UIStyle.text("Bientot", "<b>Bientôt disponible</b>", 22, UIStyle.FONT_BOLD)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.LayoutOrder = 2
	label.Parent = container
	local text = UIStyle.text("Texte", tab.soon or "", 17, UIStyle.FONT, UIStyle.TEXT_DIM)
	text.TextXAlignment = Enum.TextXAlignment.Center
	text.LayoutOrder = 3
	text.Parent = container
end

-- Ouvre un onglet (« Carte » ferme le panneau)
function TabBar.select(tabId: string)
	current = tabId
	layoutForScreen()
	for id, button in buttons do
		paintTab(button, id == tabId)
	end
	clearBody()
	local p, b, t, o, iconSlot = panel, body, title, options, headerIconSlot
	if not p or not b or not t or not o then
		return
	end
	if tabId == "Carte" then
		p.Visible = false
		return
	end
	for _, tab in TABS do
		if tab.id == tabId then
			t.Text = `<b>{tab.name}</b>`
			if iconSlot then
				for _, child in iconSlot:GetChildren() do
					child:Destroy()
				end
				UIStyle.mountIcon(iconSlot, tab.iconKey, 24, UIStyle.ACCENT)
			end
			if tabId == "Industrie" then
				cleanup = IndustryTab.build(b, o.countryId, {
					focusRegion = function(regionId: string)
						TabBar.select("Carte")
						o.focusRegion(regionId)
					end,
				})
			elseif tabId == "Batiments" then
				cleanup = BuildingsTab.build(b, o.countryId, {
					focusRegion = function(regionId: string)
						TabBar.select("Carte")
						o.focusRegion(regionId)
					end,
				})
			elseif tabId == "Recherche" then
				cleanup = ResearchTab.build(b, o.countryId)
			elseif tabId == "Marche" then
				cleanup = MarketTab.build(b, o.countryId)
			elseif tabId == "Armee" then
				cleanup = ArmyTab.build(b, o.countryId, {
					selected = pendingArmy,
					focusArmy = o.focusArmy,
					defaultRegion = o.defaultRegion,
					onSelect = o.onArmySelected,
				})
				pendingArmy = nil
			elseif tabId == "Diplomatie" then
				cleanup = DiplomacyTab.build(b, o.countryId)
			else
				comingSoon(b, tab)
			end
		end
	end
	b.CanvasPosition = Vector2.zero
	p.Visible = true
end

-- Ouvre l'onglet Armée sur la fiche d'une armée (clic sur un général)
function TabBar.openArmy(armyId: string)
	pendingArmy = armyId
	TabBar.select("Armee")
end

function TabBar.getCurrent(): string
	return current
end

function TabBar.create(opts: Options)
	options = opts
	local gui = Instance.new("ScreenGui")
	gui.Name = "Onglets"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 4

	-- barre d'onglets
	local bar = Instance.new("Frame")
	bar.Name = "Barre"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -12)
	bar.Size = UDim2.fromOffset(0, 58)
	bar.AutomaticSize = Enum.AutomaticSize.X
	bar.BackgroundColor3 = UIStyle.BACKDROP
	bar.BackgroundTransparency = 0.04
	bar.Active = true -- un clic sur la barre ne traverse pas jusqu'à la carte
	UIStyle.corner(bar, 14)
	UIStyle.stroke(bar)
	UIStyle.padding(bar, 6, 6)
	local layout = UIStyle.list(bar, TAB_GAP, true)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	local scale = Instance.new("UIScale")
	scale.Parent = bar

	for i, tab in TABS do
		local button = UIStyle.button(tab.id, "")
		button.LayoutOrder = i
		button.Size = UDim2.fromOffset(TAB_BUTTON_WIDTH, 46)
		button:SetAttribute("InfoBulleTexte", tab.name)

		local icon = UIStyle.mountIcon(button, tab.iconKey, 21, UIStyle.TEXT_DIM)
		icon.Name = "Icone"
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.new(0, 20, 0.5, 0)

		local label = UIStyle.text("Libelle", tab.name, 13, UIStyle.FONT_BOLD)
		label.AutomaticSize = Enum.AutomaticSize.None
		label.Position = UDim2.fromOffset(39, 0)
		label.Size = UDim2.new(1, -45, 1, 0)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Center
		label.TextWrapped = false
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.Parent = button

		local marker = Instance.new("Frame")
		marker.Name = "Selection"
		marker.AnchorPoint = Vector2.new(0.5, 1)
		marker.Position = UDim2.new(0.5, 0, 1, -3)
		marker.Size = UDim2.new(0.46, 0, 0, 2)
		marker.BackgroundColor3 = UIStyle.ACCENT
		marker.BorderSizePixel = 0
		marker.Visible = false
		UIStyle.corner(marker, 1)
		marker.Parent = button

		button.Parent = bar
		button.Activated:Connect(function()
			TabBar.select(if current == tab.id and tab.id ~= "Carte" then "Carte" else tab.id)
		end)
		buttons[tab.id] = button
	end
	bar.Parent = gui

	-- panneau de l'onglet ouvert
	local p = UIStyle.panel("Panneau", UDim.new(0, 460))
	p.AutomaticSize = Enum.AutomaticSize.None
	p.Visible = false
	local header = Instance.new("Frame")
	header.Name = "EnTete"
	header.BackgroundColor3 = UIStyle.PANEL_ALT
	header.BackgroundTransparency = 0.16
	header.Position = UDim2.fromOffset(10, 10)
	header.Size = UDim2.new(1, -20, 0, 44)
	UIStyle.corner(header, 8)
	UIStyle.stroke(header, 0.62, UIStyle.BORDER_SOFT)
	header.Parent = p
	local accent = Instance.new("Frame")
	accent.Name = "Accent"
	accent.Position = UDim2.fromOffset(0, 8)
	accent.Size = UDim2.fromOffset(3, 28)
	accent.BackgroundColor3 = UIStyle.ACCENT
	accent.BorderSizePixel = 0
	UIStyle.corner(accent, 2)
	accent.Parent = header
	local iconSlot = Instance.new("Frame")
	iconSlot.Name = "IconeRubrique"
	iconSlot.Position = UDim2.fromOffset(14, 7)
	iconSlot.Size = UDim2.fromOffset(30, 30)
	iconSlot.BackgroundTransparency = 1
	iconSlot.Parent = header
	local t = UIStyle.text("Titre", "", 24, UIStyle.FONT_BOLD)
	t.AutomaticSize = Enum.AutomaticSize.None
	t.Position = UDim2.fromOffset(52, 0)
	t.Size = UDim2.new(1, -104, 1, 0)
	t.TextYAlignment = Enum.TextYAlignment.Center
	t.Parent = header
	local close = UIStyle.button("Fermer", "×")
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.fromScale(1, 0)
	close.Size = UDim2.fromOffset(40, 40)
	close.Parent = header
	close.Activated:Connect(function()
		TabBar.select("Carte")
	end)

	local b = Instance.new("ScrollingFrame")
	b.Name = "Contenu"
	b.BackgroundTransparency = 1
	b.BorderSizePixel = 0
	b.Position = UDim2.fromOffset(0, 62)
	b.Size = UDim2.new(1, 0, 1, -66)
	b.CanvasSize = UDim2.new()
	b.AutomaticCanvasSize = Enum.AutomaticSize.Y
	UIStyle.styleScroll(b)
	b.ScrollingDirection = Enum.ScrollingDirection.Y
	UIStyle.padding(b, 4, 16)
	UIStyle.list(b, 10)
	b.Parent = p
	p.Parent = gui

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	panel, body, title, headerIconSlot = p, b, t, iconSlot

	local function fit()
		layoutForScreen()
		local width = workspace.CurrentCamera.ViewportSize.X
		local iconOnly = width < TAB_ICON_ONLY_BREAKPOINT
		local buttonWidth = if iconOnly then TAB_ICON_ONLY_WIDTH else TAB_BUTTON_WIDTH
		for _, button in buttons do
			button.Size = UDim2.fromOffset(buttonWidth, 46)
			local icon = button:FindFirstChild("Icone")
			if icon and icon:IsA("Frame") then
				icon.Position = if iconOnly then UDim2.fromScale(0.5, 0.5) else UDim2.new(0, 20, 0.5, 0)
			end
			local label = button:FindFirstChild("Libelle")
			if label and label:IsA("TextLabel") then
				label.Visible = not iconOnly
			end
		end
		local naturalWidth = #TABS * buttonWidth + (#TABS - 1) * TAB_GAP + TAB_BAR_PADDING
		scale.Scale = math.min(1, math.max(0.4, (width - 24) / naturalWidth))
	end
	fit()
	GameSession.track(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit))
	GameSession.track(Players.LocalPlayer:GetAttributeChangedSignal("BasBarreHaut"):Connect(layoutForScreen))
	TabBar.select("Carte")
end

return TabBar
