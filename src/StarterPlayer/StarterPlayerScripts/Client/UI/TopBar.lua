--!strict
-- Barre du haut, toujours visible en jeu : drapeau et nom du pays, crédits, ressources
-- (stock + gain ou perte par cycle), stabilité, temps de partie restant et phase en cours,
-- et barre jusqu'à la prochaine production.
-- Sa hauteur reste fixe : si les ressources ne tiennent plus, leur rangée défile horizontalement
-- au lieu de passer sur deux lignes. Son bas réel est publié dans l'attribut « BasBarreHaut » du
-- joueur local : les panneaux placés dessous (objectifs, onglets, tutoriel) le suivent.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Countries = require(Config:WaitForChild("Countries")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local Economy = require(Config:WaitForChild("Economy")) :: any
local Politics = require(Config:WaitForChild("Politics")) :: any
local FlagCatalog = require(Config:WaitForChild("FlagCatalog")) :: any
local MatchState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MatchState")) :: any
local Client = script.Parent.Parent
local RegionView = require(Client:WaitForChild("Map"):WaitForChild("RegionView"))
local FactoryState = require(Client:WaitForChild("State"):WaitForChild("FactoryState"))
local CountryFlows = require(Client:WaitForChild("State"):WaitForChild("CountryFlows"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local GameSession = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("GameSession"))
local ResourceText = require(script.Parent:WaitForChild("ResourceText"))
local PopulationRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PopulationRules")) :: any

local GAIN, LOSS = "#78DC82", "#EB5F55"
local ALWAYS_SHOWN = { Nourriture = true } -- toujours affichée, même à zéro
local BAR_HEIGHT = 48
local CELL_HEIGHT = 36
local GAP = 8
local IDENTITY_WIDTH = 188
local CURRENCY_WIDTH = 110
local STABILITY_WIDTH = 145
local POPULATION_WIDTH = 138
local CLOCK_WIDTH = 196
-- Les cinq commandes indépendantes (passe, profil, amis, missions, paramètres) occupent
-- cette zone. La barre s'arrête avant elles pour ne jamais se dessiner sous leurs boutons.
local TOP_RIGHT_RESERVE = 342

local TopBar = {}

-- Écran étroit (téléphone) : libellés raccourcis pour que la barre tienne
local function compact(): boolean
	return workspace.CurrentCamera.ViewportSize.X < 1100
end

local function cell(parent: Instance, name: string, order: number, width: number?): TextLabel
	local label = UIStyle.text(name, "", 17, UIStyle.FONT_MEDIUM)
	label.Size = UDim2.fromOffset(width or 0, CELL_HEIGHT)
	label.AutomaticSize = if width then Enum.AutomaticSize.None else Enum.AutomaticSize.X
	label.BackgroundColor3 = UIStyle.PANEL_ALT
	label.BackgroundTransparency = 0.18
	label.TextWrapped = false
	label.TextTruncate = if width then Enum.TextTruncate.AtEnd else Enum.TextTruncate.None
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.LayoutOrder = order
	UIStyle.corner(label, 7)
	UIStyle.stroke(label, 0.68, UIStyle.BORDER_SOFT)
	UIStyle.padding(label, 0, 9)
	label.Parent = parent
	return label
end

local function delta(n: number): string
	if n == 0 then
		return ""
	end
	return ` <font size="13" color="{if n > 0 then GAIN else LOSS}">{if n > 0 then "+" else "-"}{ResourceText.number(math.abs(n))}</font>`
end

local function stabilityColor(value: number): Color3
	for _, level in Politics.stabilityColors do
		if value >= level.min then
			return level.color
		end
	end
	return UIStyle.DANGER
end

function TopBar.show(countryId: string)
	local country = Countries[countryId]
	local folder = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Pays"):WaitForChild(countryId)
	local state = ReplicatedStorage:WaitForChild("EtatMonde")

	local gui = Instance.new("ScreenGui")
	gui.Name = "BarreHaut"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 3

	local bar = UIStyle.panel("Barre", UDim.new(1, -24))
	bar.Position = UDim2.fromOffset(12, 8)
	bar.Size = UDim2.new(1, -24, 0, BAR_HEIGHT)
	bar.AutomaticSize = Enum.AutomaticSize.None
	bar.ClipsDescendants = true
	bar.BackgroundColor3 = UIStyle.BACKDROP
	bar.BackgroundTransparency = 0.035

	-- Une rangée à géométrie fixe : les changements de stock ne modifient jamais la hauteur.
	local content = Instance.new("Frame")
	content.Name = "Contenu"
	content.Position = UDim2.fromOffset(14, 6)
	content.Size = UDim2.fromOffset(64, CELL_HEIGHT)
	content.BackgroundTransparency = 1
	content.ClipsDescendants = true
	content.Parent = bar

	-- pays : drapeau + nom
	local identity = Instance.new("Frame")
	identity.Name = "Pays"
	identity.LayoutOrder = 0
	identity.BackgroundTransparency = 1
	identity.Size = UDim2.fromOffset(IDENTITY_WIDTH, CELL_HEIGHT)
	identity.BackgroundColor3 = UIStyle.PANEL_ALT
	identity.BackgroundTransparency = 0.1
	UIStyle.corner(identity, 7)
	UIStyle.stroke(identity, 0.5, UIStyle.BORDER_SOFT)
	UIStyle.padding(identity, 0, 7)
	local identityLayout = UIStyle.list(identity, 8, true)
	identityLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	local flag = Instance.new("ImageLabel")
	flag.Name = "Drapeau"
	flag.Size = UDim2.fromOffset(42, 28)
	flag.BackgroundColor3 = country.color
	flag.BorderSizePixel = 0
	UIStyle.corner(flag, 4)
	FlagCatalog.apply(flag, countryId)
	flag.Parent = identity
	local name = UIStyle.text("Nom", country.name, 19, UIStyle.FONT_BOLD)
	name.LayoutOrder = 1
	name.Size = UDim2.fromOffset(IDENTITY_WIDTH - 64, CELL_HEIGHT)
	name.AutomaticSize = Enum.AutomaticSize.None
	name.TextWrapped = false
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.TextYAlignment = Enum.TextYAlignment.Center
	name.FontFace = UIStyle.FONT_BOLD
	name.Parent = identity
	identity.Parent = content

	-- Les crédits restent toujours visibles à côté du pays.
	local currency = Resources.currency
	local cells: { [string]: TextLabel } = {}
	local currencyCell = cell(content, currency.id, 1, CURRENCY_WIDTH)
	currencyCell.Position = UDim2.fromOffset(IDENTITY_WIDTH + GAP, 0)
	cells[currency.id] = currencyCell

	-- Les ressources utilisent l'espace central restant. En cas de valeurs longues ou de stocks
	-- nombreux, la molette fait défiler cette seule zone sans déplacer le reste du HUD.
	local resources = Instance.new("ScrollingFrame")
	resources.Name = "Ressources"
	resources.Active = true
	resources.Position = UDim2.fromOffset(IDENTITY_WIDTH + GAP + CURRENCY_WIDTH + GAP, 0)
	resources.Size = UDim2.new(
		1,
		-(IDENTITY_WIDTH + GAP + CURRENCY_WIDTH + GAP + GAP + STABILITY_WIDTH + GAP + CLOCK_WIDTH),
		1,
		0
	)
	resources.BackgroundTransparency = 1
	resources.BorderSizePixel = 0
	resources.CanvasSize = UDim2.new()
	resources.AutomaticCanvasSize = Enum.AutomaticSize.X
	resources.ScrollingDirection = Enum.ScrollingDirection.X
	resources.ElasticBehavior = Enum.ElasticBehavior.Never
	resources.ScrollBarThickness = 2
	resources.ScrollBarImageColor3 = UIStyle.ACCENT
	resources.ScrollBarImageTransparency = 0.35
	resources.ClipsDescendants = true
	local resourcesLayout = UIStyle.list(resources, GAP, true)
	resourcesLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	resources.Parent = content
	for i, id in Resources.order do
		cells[id] = cell(resources, id, i)
	end

	-- Les informations critiques restent ancrées juste avant les commandes en haut à droite.
	local status = Instance.new("Frame")
	status.Name = "EtatPartie"
	status.AnchorPoint = Vector2.new(1, 0)
	status.Position = UDim2.fromScale(1, 0)
	status.Size = UDim2.fromOffset(STABILITY_WIDTH + GAP + CLOCK_WIDTH, CELL_HEIGHT)
	status.BackgroundTransparency = 1
	local statusLayout = UIStyle.list(status, GAP, true)
	statusLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	status.Parent = content
	local stability = cell(status, "Stabilite", 1, STABILITY_WIDTH)
	local population = cell(status, "Population", 2, POPULATION_WIDTH) -- habitants et famine
	local clock = cell(status, "Partie", 3, CLOCK_WIDTH) -- temps restant et phase de la partie

	local function layoutForScreen()
		local viewportWidth = workspace.CurrentCamera.ViewportSize.X
		local available = math.max(64, viewportWidth - (24 + 14 + TOP_RIGHT_RESERVE))
		content.Size = UDim2.fromOffset(available, CELL_HEIGHT)
		local showIdentity = viewportWidth >= 600
		local showName = viewportWidth >= 900
		local showCurrency = viewportWidth >= 680
		local showStability = viewportWidth >= 800
		local showPopulation = viewportWidth >= 1100
		local showResources = viewportWidth >= 960

		local identityWidth = if showName then (if viewportWidth >= 1280 then IDENTITY_WIDTH else 150) else 56
		local currencyWidth = if viewportWidth >= 1280 then CURRENCY_WIDTH else 96
		local stabilityWidth = if viewportWidth >= 1280 then STABILITY_WIDTH else 82
		local populationWidth = if viewportWidth >= 1280 then POPULATION_WIDTH else 112
		local clockWidth = if viewportWidth >= 1280 then CLOCK_WIDTH else math.min(128, available)

		identity.Visible = showIdentity
		identity.Position = UDim2.fromOffset(0, 0)
		identity.Size = UDim2.fromOffset(identityWidth, CELL_HEIGHT)
		name.Visible = showName
		name.Size = UDim2.fromOffset(math.max(0, identityWidth - 64), CELL_HEIGHT)

		local cursor = if showIdentity then identityWidth + GAP else 0
		currencyCell.Visible = showCurrency
		currencyCell.Position = UDim2.fromOffset(cursor, 0)
		currencyCell.Size = UDim2.fromOffset(currencyWidth, CELL_HEIGHT)
		if showCurrency then
			cursor += currencyWidth + GAP
		end

		stability.Visible = showStability
		stability.Size = UDim2.fromOffset(stabilityWidth, CELL_HEIGHT)
		population.Visible = showPopulation
		population.Size = UDim2.fromOffset(populationWidth, CELL_HEIGHT)
		clock.Size = UDim2.fromOffset(clockWidth, CELL_HEIGHT)
		local statusWidth = clockWidth
			+ (if showStability then stabilityWidth + GAP else 0)
			+ (if showPopulation then populationWidth + GAP else 0)
		status.Size = UDim2.fromOffset(statusWidth, CELL_HEIGHT)

		local resourceWidth = math.max(0, available - cursor - statusWidth - GAP)
		resources.Position = UDim2.fromOffset(cursor, 0)
		resources.Size = UDim2.fromOffset(resourceWidth, CELL_HEIGHT)
		resources.Visible = showResources and resourceWidth >= 72
	end

	-- progression jusqu'à la prochaine production (liseré en bas de la barre)
	local track = Instance.new("Frame")
	track.Name = "Progression"
	track.AnchorPoint = Vector2.new(0, 1)
	track.Position = UDim2.fromScale(0, 1)
	track.Size = UDim2.new(1, 0, 0, 3)
	track.BackgroundColor3 = UIStyle.BORDER_SOFT
	track.BackgroundTransparency = 0.35
	track.BorderSizePixel = 0
	local fill = Instance.new("Frame")
	fill.Name = "Remplissage"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = UIStyle.ACCENT
	fill.BorderSizePixel = 0
	fill.Parent = track
	track.Parent = bar

	bar.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	layoutForScreen()
	GameSession.track(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(layoutForScreen))
	local function publishBottom()
		Players.LocalPlayer:SetAttribute("BasBarreHaut", bar.AbsolutePosition.Y + bar.AbsoluteSize.Y)
	end
	publishBottom()
	GameSession.track(bar:GetPropertyChangedSignal("AbsoluteSize"):Connect(publishBottom))

	local function refresh(animated: string?)
		if not gui.Parent then
			return -- partie quittée (exil, nouvelle partie)
		end
		local flows = CountryFlows.compute(countryId)
		local credits = folder:GetAttribute(currency.id)
		cells[currency.id].Text = `{currency.icon} <b>{ResourceText.number(if typeof(credits) == "number" then credits else 0)}</b>`
		for _, id in Resources.order do
			local value = folder:GetAttribute(id)
			local amount = if typeof(value) == "number" then value else 0
			local flow = flows.total[id] or 0
			local c = cells[id]
			-- on n'affiche que les ressources utiles au pays (en stock ou produites)
			c.Visible = ALWAYS_SHOWN[id] or amount > 0 or flow ~= 0
			c.Text = `{Resources.list[id].icon} <b>{ResourceText.number(amount)}</b>{delta(flow)}`
		end
		local s = folder:GetAttribute("Stabilite")
		local value = if typeof(s) == "number" then s else 0
		local label = if compact() then "⚖️" else `<font color="{UIStyle.GREY_HEX}">Stabilité</font>`
		stability.Text = `{label} <b><font color="#{stabilityColor(value):ToHex()}">{value} %</font></b>`
		-- Habitants : croissance en vert, famine en rouge. La cellule reste fixe
		-- sur ordinateur et disparaît proprement quand la largeur manque.
		local people = (folder:GetAttribute("Population") :: number?) or 0
		local trend = if folder:GetAttribute("Famine") == true
			then ` <font size="13" color="{LOSS}">▼ famine</font>`
			elseif ((folder:GetAttribute("Croissance") :: number?) or 0) > 0
			then ` <font size="13" color="{GAIN}">▲</font>`
			else ""
		population.Text = `👥 <b>{PopulationRules.format(people)}</b>{trend}`
		layoutForScreen()

		-- petit éclat quand un stock augmente
		local c = if animated then cells[animated] else nil
		if c then
			c.TextColor3 = Color3.fromRGB(150, 240, 160)
			TweenService:Create(c, TweenInfo.new(1), { TextColor3 = UIStyle.TEXT }):Play()
		end
	end

	local previous: { [string]: number } = {}
	GameSession.track(folder.AttributeChanged:Connect(function(attribute: string)
		local value = folder:GetAttribute(attribute)
		local grew = typeof(value) == "number" and previous[attribute] ~= nil and value > previous[attribute]
		if typeof(value) == "number" then
			previous[attribute] = value
		end
		refresh(if grew then attribute else nil)
	end))
	FactoryState.onChanged(function()
		refresh()
	end)
	RegionView.onOwnerChanged(function()
		refresh()
	end)
	for id in cells do
		local value = folder:GetAttribute(id)
		if typeof(value) == "number" then
			previous[id] = value
		end
	end
	refresh()

	local function updateClock()
		if not MatchState.isRunning() then
			clock.Text = "🏁 <b>Partie terminée</b>"
			return
		end
		local left = math.ceil(MatchState.timeLeft())
		local phase = MatchState.phase()
		local color = if left <= 300 then UIStyle.DANGER:ToHex() else "FFFFFF"
		local phaseText = if compact() then phase.icon else `{phase.icon} {phase.name}`
		clock.Text = `⏱ <b><font color="#{color}">{string.format("%d:%02d", left // 60, left % 60)}</font></b>  <font color="{UIStyle.GREY_HEX}">{phaseText}</font>`
	end
	updateClock()
	local lastClock = 0

	GameSession.track(RunService.RenderStepped:Connect(function()
		if os.clock() - lastClock >= 1 then
			lastClock = os.clock()
			updateClock()
		end
		local nextTime = state:GetAttribute("ProductionSuivante")
		if typeof(nextTime) == "number" then
			local left = nextTime - workspace:GetServerTimeNow()
			fill.Size = UDim2.fromScale(math.clamp(1 - left / Economy.productionInterval, 0, 1), 1)
		end
	end))
end

return TopBar
