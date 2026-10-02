--!strict
-- Fiche d'une région : nom, propriétaire, capitale, production et voisins.
-- En bas à gauche sur ordinateur, sur toute la largeur sur téléphone.
-- Une zone « Supplement » en bas de la fiche est remplie par d'autres modules (usines...) ;
-- d'autres zones peuvent être ajoutées (RegionPanel.addSection : espionnage...).
-- Brouillard de guerre : la défense d'une région hors de vue est inconnue.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Economy = require(Config:WaitForChild("Economy")) :: any
local Personalities = require(Config:WaitForChild("Personalities")) :: any
local DiplomacyState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DiplomacyState")) :: any
local RegionResources = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RegionResources")) :: any
local RegionView = require(script.Parent.Parent:WaitForChild("Map"):WaitForChild("RegionView"))
local Fog = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("Fog"))
local MilitaryState = require(script.Parent.Parent:WaitForChild("Military"):WaitForChild("MilitaryState"))
local ResourceText = require(script.Parent:WaitForChild("ResourceText"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))

local GREY = UIStyle.GREY_HEX
local NARROW_SCREEN = 600 -- largeur (pixels) en dessous de laquelle la fiche prend toute la largeur

local RegionPanel = {}

local frame: Frame? = nil
local content: ScrollingFrame? = nil
local title: TextLabel? = nil
local accent: Frame? = nil
local rows: { [string]: TextLabel } = {}
local shownRegion: string? = nil
local onClose: (() -> ())? = nil
local extra: Frame? = nil
local watched: RBXScriptConnection? = nil -- suit la garnison de la région affichée
local watchedCountry: string? = nil -- pays dont on suit le dirigeant (joueur ou IA)
local countryWatch: { RBXScriptConnection } = {}
local showListeners: { (regionId: string?, container: Frame) -> () } = {}

local function row(name: string, order: number, parent: Instance): TextLabel
	local label = UIStyle.text(name, "", 16, UIStyle.FONT)
	label.LayoutOrder = order
	label.Parent = parent
	return label
end

local function toHex(c: Color3): string
	return "#" .. c:ToHex()
end

-- Texte sans balises (un pseudo ne doit pas casser le texte enrichi)
local function escape(text: string): string
	return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function countryState(countryId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
end

-- Qui dirige le pays : un joueur, ou l'IA avec sa dernière décision
local function leaderText(countryId: string): string
	local folder = countryState(countryId)
	local label = `<font color="{GREY}">Dirigeant</font>   `
	local playerId = folder and folder:GetAttribute("Joueur")
	if folder and typeof(playerId) == "number" and playerId ~= 0 then
		local who = if playerId == Players.LocalPlayer.UserId then "Toi" else escape(tostring(folder:GetAttribute("JoueurNom")))
		if folder:GetAttribute("Absent") == true then
			-- joueur inactif : l'IA dirige le pays en attendant son retour
			local personality = Personalities.list[folder:GetAttribute("Personnalite") or ""]
			local ai = if personality then `🤖 IA {personality.icon} {personality.name}` else "🤖 IA"
			return label .. `💤 {who} (absent) · {ai}`
		end
		return label .. `👤 {who}`
	end
	local personality = Personalities.list[folder and folder:GetAttribute("Personnalite") or ""]
	local ai = if personality then `🤖 IA {personality.icon} {personality.name}` else "🤖 IA"
	local decision = folder and folder:GetAttribute("DecisionIA")
	if typeof(decision) == "string" and decision ~= "" then
		return label .. `{ai}   <font color="{GREY}">{decision}</font>`
	end
	return label .. ai
end

local function updateLeader()
	local region = if shownRegion then Regions[shownRegion] else nil
	if region and rows.Dirigeant then
		rows.Dirigeant.Text = leaderText(RegionView.getOwner(region.id) or region.startOwner)
	end
end

-- Suit le dirigeant du propriétaire affiché (joueur qui arrive ou part, décisions de l'IA)
local function watchCountry(countryId: string)
	if watchedCountry == countryId then
		return
	end
	for _, connection in countryWatch do
		connection:Disconnect()
	end
	table.clear(countryWatch)
	watchedCountry = countryId
	local folder = countryState(countryId)
	if folder then
		for _, attribute in { "Joueur", "JoueurNom", "DecisionIA", "Personnalite", "Absent" } do
			table.insert(countryWatch, folder:GetAttributeChangedSignal(attribute):Connect(updateLeader))
		end
	end
end

local function layoutForScreen()
	local f = frame
	if not f then
		return
	end
	local width = workspace.CurrentCamera.ViewportSize.X
	local viewport = workspace.CurrentCamera.ViewportSize
	local panelHeight = math.clamp(viewport.Y - 190, 220, 580)
	if width < NARROW_SCREEN then
		f.Position = UDim2.new(0, 12, 1, -84)
		f.Size = UDim2.new(1, -24, 0, panelHeight)
	else
		f.Position = UDim2.new(0, 16, 1, -84)
		f.Size = UDim2.new(0, 370, 0, panelHeight)
	end
end

local function refresh()
	local regionId = shownRegion
	local f = frame
	if not f or not title or not accent then
		return
	end
	local region = if regionId then Regions[regionId] else nil
	if not region then
		f.Visible = false
		return
	end
	local ownerId = RegionView.getOwner(region.id) or region.startOwner
	local owner = Countries[ownerId]

	title.Text = region.name
	accent.BackgroundColor3 = owner.color
	rows.Proprietaire.Text = `<font color="{GREY}">Propriétaire</font>   <font color="{toHex(owner.color)}">●</font> {owner.name}`
	watchCountry(ownerId)
	rows.Dirigeant.Text = leaderText(ownerId)
	-- relation avec le pays du joueur, et bloc du propriétaire
	local me = Players.LocalPlayer:GetAttribute("Pays")
	local bloc = DiplomacyState.blocName(ownerId)
	local relation = ""
	if typeof(me) == "string" and me ~= "" and me ~= ownerId then
		local r = DiplomacyState.relation(me, ownerId)
		relation = if r == "Allie" then `<font color="#78DC82">🤝 allié</font>`
			elseif r == "Guerre" then `<font color="#EB5F55">⚔️ en guerre avec toi</font>`
			elseif r == "Treve" then `<font color="#FF9A78">🕊️ trêve ({math.ceil(DiplomacyState.truceLeft(me, ownerId))} s)</font>`
			else "☮️ en paix"
	end
	local protection = DiplomacyState.protectionLeft(ownerId)
	if protection > 0 then
		relation ..= `{if relation ~= "" then " · " else ""}🛡️ protégé ({math.ceil(protection)} s)`
	end
	rows.Relation.Visible = relation ~= "" or bloc ~= nil
	rows.Relation.Text = `<font color="{GREY}">Relation</font>   ` .. relation .. (if bloc then `{if relation ~= "" then " · " else ""}bloc {bloc}` else "")
	-- capitale ou ville principale d'un territoire (les autres régions n'ont pas de ville)
	local city = region.city
	if city and not (city.isCapital or city.isMain) then
		city = nil
	end
	rows.Capitale.Visible = city ~= nil
	if city then
		local label = if city.isCapital then "Capitale" else "Ville principale"
		rows.Capitale.Text = `<font color="{GREY}">{label}</font>   {city.name}`
	end

	local names = {}
	for _, link in region.neighbors do
		local neighbor = Regions[link.region]
		if neighbor then
			table.insert(names, if link.bySea then `{neighbor.name} <font color="{GREY}">(mer)</font>` else neighbor.name)
		end
	end
	rows.Voisins.Text = `<font color="{GREY}">Voisins</font>   ` .. (if #names > 0 then table.concat(names, ", ") else "aucun")
	rows.Production.Text = `<font color="{GREY}">Production / {Economy.productionInterval} s</font>   `
		.. ResourceText.production(RegionResources.production(region.id))
	-- catastrophe naturelle (événement mondial) : production arrêtée un moment
	local events = ReplicatedStorage:FindFirstChild("EtatMonde")
	local disasterState = events and events:FindFirstChild("Regions") and events.Regions:FindFirstChild(region.id)
	local disaster = disasterState and disasterState:GetAttribute("Catastrophe")
	if typeof(disaster) == "number" and disaster > workspace:GetServerTimeNow() then
		rows.Production.Text = `<font color="{GREY}">Production</font>   <font color="#EB5F55">{disasterState:GetAttribute("CatastropheType") or "catastrophe"} : arrêtée encore {math.ceil(disaster - workspace:GetServerTimeNow())} s</font>`
	end
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local regionState = state and state:FindFirstChild("Regions") and state.Regions:FindFirstChild(region.id)
	-- défense : les divisions présentes dans la région (une région sans division est vide)
	local defenders = MilitaryState.inRegion(region.id)
	local icons = {}
	for _, d in defenders do
		table.insert(icons, MilitaryState.typeOf(d).icon)
	end
	local fighting = regionState and regionState:GetAttribute("Bataille")
	if Fog.isRegionVisible(region.id) then
		rows.Garnison.Text = `<font color="{GREY}">Défense</font>   ` .. (if #defenders > 0 then `{#defenders} division{if #defenders > 1 then "s" else ""}  {table.concat(icons, "")}` else "aucune division")
			.. (if fighting then `   <font color="#FF9A78">⚔️ bataille en cours</font>` else "")
	else
		rows.Garnison.Text = `<font color="{GREY}">Défense</font>   🌫️ inconnue (brouillard de guerre)`
	end
	f.Visible = true
	if extra then
		for _, listener in showListeners do
			listener(region.id, extra)
		end
	end
end

function RegionPanel.create(closeCallback: () -> ())
	onClose = closeCallback
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "FicheRegion"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local f = UIStyle.panel("Fiche", UDim.new(0, 370))
	f.AnchorPoint = Vector2.new(0, 1)
	f.Position = UDim2.new(0, 16, 1, -84) -- au-dessus des onglets
	f.Active = true -- un clic sur la fiche ne traverse pas jusqu'à la carte
	f.AutomaticSize = Enum.AutomaticSize.None
	f.ClipsDescendants = true
	f.Visible = false

	-- En-tête : nom de la région + bouton fermer
	local header = Instance.new("Frame")
	header.Name = "EnTete"
	header.Position = UDim2.fromOffset(12, 10)
	header.BackgroundColor3 = UIStyle.PANEL_ALT
	header.BackgroundTransparency = 0.14
	header.Size = UDim2.new(1, -24, 0, 42)
	UIStyle.corner(header, 7)
	UIStyle.stroke(header, 0.62, UIStyle.BORDER_SOFT)
	header.Parent = f

	local t = UIStyle.text("Titre", "", 23, UIStyle.FONT_BOLD)
	t.AutomaticSize = Enum.AutomaticSize.None
	t.Position = UDim2.fromOffset(11, 0)
	t.Size = UDim2.new(1, -58, 1, 0)
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.TextYAlignment = Enum.TextYAlignment.Center
	t.TextTruncate = Enum.TextTruncate.AtEnd
	t.Parent = header

	local close = UIStyle.button("Fermer", "×")
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.new(1, -3, 0.5, 0)
	close.Size = UDim2.fromOffset(34, 34)
	close.TextSize = 20
	close.Parent = header
	close.Activated:Connect(function()
		if onClose then
			onClose()
		end
	end)

	-- Liseré aux couleurs du propriétaire
	local bar = Instance.new("Frame")
	bar.Name = "Couleur"
	bar.Position = UDim2.fromOffset(14, 58)
	bar.BorderSizePixel = 0
	bar.Size = UDim2.new(1, -28, 0, 4)
	UIStyle.corner(bar, 2)
	bar.Parent = f

	local body = Instance.new("ScrollingFrame")
	body.Name = "Contenu"
	body.Position = UDim2.fromOffset(12, 70)
	body.Size = UDim2.new(1, -24, 1, -82)
	body.BackgroundTransparency = 1
	body.CanvasSize = UDim2.new()
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.ScrollingDirection = Enum.ScrollingDirection.Y
	UIStyle.styleScroll(body)
	UIStyle.padding(body, 2, 2)
	UIStyle.list(body, 7)
	body.Parent = f

	rows.Proprietaire = row("Proprietaire", 3, body)
	rows.Dirigeant = row("Dirigeant", 4, body)
	rows.Relation = row("Relation", 5, body)
	rows.Capitale = row("Capitale", 6, body)
	rows.Production = row("Production", 7, body)
	rows.Garnison = row("Garnison", 8, body)
	rows.Voisins = row("Voisins", 9, body)

	local container = Instance.new("Frame")
	container.Name = "Supplement"
	container.LayoutOrder = 20
	container.BackgroundTransparency = 1
	container.Size = UDim2.new(1, 0, 0, 0)
	container.AutomaticSize = Enum.AutomaticSize.Y
	container.Visible = false
	container.Parent = body
	extra = container

	f.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")

	frame, content, title, accent = f, body, t, bar
	layoutForScreen()
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(layoutForScreen)
	RegionView.onOwnerChanged(function(regionId: string)
		if regionId == shownRegion then
			refresh()
		end
	end)
end

-- Affiche la fiche d'une région (nil = masquer)
function RegionPanel.show(regionId: string?)
	shownRegion = regionId
	if watched then
		watched:Disconnect()
		watched = nil
	end
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local regions = state and state:FindFirstChild("Regions")
	local regionState = regionId and regions and regions:FindFirstChild(regionId)
	if regionState then
		-- garnison et bataille changent pendant les combats
		watched = regionState.AttributeChanged:Connect(function()
			refresh()
		end)
	end
	refresh()
end

-- Région affichée en ce moment (nil si la fiche est fermée)
function RegionPanel.getShown(): string?
	return shownRegion
end

-- Redessine la fiche (par exemple après un changement d'usine)
function RegionPanel.refresh()
	refresh()
end

-- Ajoute une zone en bas de la fiche (après « Supplement ») ; un module la remplit dans son
-- écouteur onShow. À appeler après RegionPanel.create.
function RegionPanel.addSection(name: string, order: number): Frame
	local container = Instance.new("Frame")
	container.Name = name
	container.LayoutOrder = order
	container.BackgroundTransparency = 1
	container.Size = UDim2.new(1, 0, 0, 0)
	container.AutomaticSize = Enum.AutomaticSize.Y
	container.Visible = false
	container.Parent = content or frame
	return container
end

-- listener(regionId, container) est appelé à chaque affichage de la fiche :
-- il peut remplir la zone « Supplement » en bas de la fiche
function RegionPanel.onShow(listener: (regionId: string?, container: Frame) -> ())
	table.insert(showListeners, listener)
end

return RegionPanel
