--!strict
-- Écran de fin de partie : vainqueur, ton rang, classement des meilleurs pays (score total et
-- note de chaque domaine), champions par domaine et bilan de la partie (meilleur général, plus
-- grosse vente, plus longue alliance, plus grande trahison), puis compte à rebours jusqu'à la
-- nouvelle partie. « Voir la carte » le réduit en une pastille. Données : EtatMonde.Classement.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Match = require(Config:WaitForChild("Match")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local ModalHost = require(script.Parent:WaitForChild("ModalHost"))
local Sfx = require(script.Parent.Parent:WaitForChild("Audio"):WaitForChild("Sfx"))

local NAME_MIN = 120 -- largeur minimale de la colonne des pays
local COLUMN = 46 -- largeur d'une colonne de note
local SCORE_COLUMN = 62

local EndScreen = {}

local gui: ScreenGui? = nil

local function nameOf(countryId: string): string
	return if Countries[countryId] then Countries[countryId].name else countryId
end

-- « 1er », « 2e », « 12e »
local function ordinal(n: number): string
	return if n == 1 then "1er" else `{n}e`
end

local function decimal(n: number): string
	local text = string.format("%.1f", n)
	return (text:gsub("%.", ","))
end

-- Ligne du tableau : rang, pays, score, puis une note par domaine (alignées à droite)
local function row(parent: Instance, order: number, cells: { string }, highlight: boolean?, header: boolean?): Frame
	local frame = Instance.new("Frame")
	frame.Name = "Ligne" .. order
	frame.LayoutOrder = order
	frame.Size = UDim2.new(1, 0, 0, if header then 26 else 30)
	frame.BackgroundColor3 = if highlight then UIStyle.ACCENT_SOFT else UIStyle.PANEL_ALT
	frame.BackgroundTransparency = if highlight then 0.2 elseif header then 0.08 elseif order % 2 == 0 then 0.48 else 1
	frame.BorderSizePixel = 0
	UIStyle.corner(frame, 6)
	local font = if header then UIStyle.FONT_BOLD else UIStyle.FONT_MEDIUM
	local color = if header then UIStyle.TEXT_DIM else UIStyle.TEXT
	local function label(name: string, text: string, x: UDim, width: UDim, align: Enum.TextXAlignment)
		local l = UIStyle.text(name, text, if header then 14 else 15, font, color)
		l.AutomaticSize = Enum.AutomaticSize.None
		l.Position = UDim2.new(x, UDim.new(0, 0))
		l.Size = UDim2.new(width, UDim.new(1, 0))
		l.TextXAlignment = align
		l.TextYAlignment = Enum.TextYAlignment.Center
		l.TextWrapped = false
		l.TextTruncate = Enum.TextTruncate.AtEnd
		l.Parent = frame
	end
	local domains = #Match.domains
	local right = SCORE_COLUMN + domains * COLUMN + 8
	label("Rang", cells[1], UDim.new(0, 6), UDim.new(0, 36), Enum.TextXAlignment.Left)
	label("Pays", cells[2], UDim.new(0, 44), UDim.new(1, -(44 + right)), Enum.TextXAlignment.Left)
	label("Score", cells[3], UDim.new(1, -right), UDim.new(0, SCORE_COLUMN), Enum.TextXAlignment.Right)
	for i = 1, domains do
		label("Note" .. i, cells[3 + i], UDim.new(1, -right + SCORE_COLUMN + (i - 1) * COLUMN), UDim.new(0, COLUMN), Enum.TextXAlignment.Right)
	end
	frame.Parent = parent
	return frame
end

function EndScreen.hide()
	if gui then
		gui:Destroy()
		gui = nil
	end
end

-- Affiche l'écran de fin (classement publié par le serveur)
function EndScreen.show()
	EndScreen.hide()
	ModalHost.hide()
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local classement = state:WaitForChild("Classement", 10)
	if not classement then
		return
	end
	local me = Players.LocalPlayer:GetAttribute("Pays")

	local screen = Instance.new("ScreenGui")
	screen.Name = "FinDePartie"
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 40 -- au-dessus de toute l'interface de jeu
	gui = screen

	local shade = Instance.new("Frame")
	shade.Name = "Fond"
	shade.Active = true -- la carte derrière ne reçoit plus les clics
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.35
	shade.BorderSizePixel = 0
	shade.Parent = screen

	local window = Instance.new("Frame")
	window.Name = "Fenetre"
	window.Active = true
	window.AnchorPoint = Vector2.new(0.5, 0.5)
	window.Position = UDim2.fromScale(0.5, 0.5)
	window.Size = UDim2.new(1, -24, 1, -40)
	window.BackgroundColor3 = UIStyle.PANEL
	window.BackgroundTransparency = 0.04
	UIStyle.corner(window, 14)
	UIStyle.stroke(window, 0.6)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(760, 680)
	limit.Parent = window
	window.Parent = shade

	local content = Instance.new("ScrollingFrame")
	content.Name = "Contenu"
	content.Size = UDim2.new(1, 0, 1, -64)
	content.BackgroundTransparency = 1
	content.CanvasSize = UDim2.new()
	content.AutomaticCanvasSize = Enum.AutomaticSize.XY
	content.ScrollingDirection = Enum.ScrollingDirection.XY
	UIStyle.styleScroll(content)
	UIStyle.padding(content, 16, 20)
	UIStyle.list(content, 10)
	content.Parent = window

	local order = 0
	local function text(value: string, size: number, font: Font?, color: Color3?): TextLabel
		order += 1
		local l = UIStyle.text("Texte" .. order, value, size, font, color)
		l.LayoutOrder = order
		l.Parent = content
		return l
	end

	-- vainqueur et résultat du joueur
	local winner = classement:GetAttribute("Vainqueur")
	local title = text("🏁 Fin de la partie", 30, UIStyle.FONT_BLACK)
	title.TextXAlignment = Enum.TextXAlignment.Center
	if typeof(winner) == "string" and winner ~= "" then
		local verb = if FrenchNames.isPlural(nameOf(winner)) then "remportent" else "remporte"
		local line = text(`🏆 {FrenchNames.The(nameOf(winner))} {verb} la partie !`, 22, UIStyle.FONT_BOLD, UIStyle.ACCENT)
		line.TextXAlignment = Enum.TextXAlignment.Center
	end
	local mine: Instance? = nil
	for _, item in classement:GetChildren() do
		if item:GetAttribute("Pays") == me then
			mine = item
		end
	end
	local myRank = 0
	if mine then
		myRank = (mine:GetAttribute("Rang") :: number?) or 0
		local total = (classement:GetAttribute("Pays") :: number?) or 0
		local line = text(`Avec {FrenchNames.the(nameOf(me :: string))}, tu termines <b>{ordinal(myRank)}</b> sur {total} avec <b>{decimal((mine:GetAttribute("Score") :: number?) or 0)}</b> points.`, 18)
		line.TextXAlignment = Enum.TextXAlignment.Center
	end

	-- classement
	order += 1
	local tableFrame = Instance.new("Frame")
	tableFrame.Name = "Classement"
	tableFrame.LayoutOrder = order
	tableFrame.BackgroundTransparency = 1
	tableFrame.Size = UDim2.new(1, 0, 0, 0)
	tableFrame.AutomaticSize = Enum.AutomaticSize.Y
	UIStyle.list(tableFrame, 2)
	local sizeLimit = Instance.new("UISizeConstraint")
	sizeLimit.MinSize = Vector2.new(NAME_MIN + 44 + SCORE_COLUMN + #Match.domains * COLUMN + 8, 0)
	sizeLimit.Parent = tableFrame
	tableFrame.Parent = content
	local headers = { "#", "Pays", "Score" }
	for _, domain in Match.domains do
		table.insert(headers, domain.icon)
	end
	row(tableFrame, 0, headers, false, true)
	local items = classement:GetChildren()
	table.sort(items, function(a, b)
		return ((a:GetAttribute("Rang") :: number?) or 0) < ((b:GetAttribute("Rang") :: number?) or 0)
	end)
	for _, item in items do
		local countryId = item:GetAttribute("Pays") :: string
		local country = Countries[countryId]
		local player = item:GetAttribute("Joueur")
		local title = item:GetAttribute("Titre")
		if typeof(player) == "string" and player ~= "" and typeof(title) == "string" and title ~= "" then
			player = `{player} · {title}`
		end
		local projects = item:GetAttribute("Projets") -- icônes des projets décisifs remportés
		local name = `<font color="#{country and country.color:ToHex() or "FFFFFF"}">●</font> {nameOf(countryId)}`
			.. (if typeof(projects) == "string" and projects ~= "" then " " .. projects else "")
			.. (if typeof(player) == "string" and player ~= "" then ` <font color="{UIStyle.GREY_HEX}">({player})</font>` else "")
		local cells = { tostring(item:GetAttribute("Rang")), name, decimal((item:GetAttribute("Score") :: number?) or 0) }
		for _, domain in Match.domains do
			table.insert(cells, tostring(item:GetAttribute(domain.id) or 0))
		end
		row(tableFrame, (item:GetAttribute("Rang") :: number?) or 99, cells, countryId == me)
	end

	-- champions par domaine
	local champions = {}
	for _, domain in Match.domains do
		local id = classement:GetAttribute("Champion_" .. domain.id)
		if typeof(id) == "string" and id ~= "" then
			table.insert(champions, `{domain.icon} {domain.name} : <b>{nameOf(id)}</b>`)
		end
	end
	text("<b>Champions</b>", 19, UIStyle.FONT_BOLD)
	text(table.concat(champions, "\n"), 16, UIStyle.FONT_MEDIUM)

	-- bilan de la partie
	text("<b>Bilan de la partie</b>", 19, UIStyle.FONT_BOLD)
	for _, entry in {
		{ "🎖️ Meilleur général", "MeilleurGeneral" },
		{ "💰 Plus grosse vente", "PlusGrosseVente" },
		{ "🤝 Plus longue alliance", "PlusLongueAlliance" },
		{ "🗡️ Plus grande trahison", "PlusGrandeTrahison" },
	} do
		local value = classement:GetAttribute(entry[2])
		text(`{entry[1]} : <font color="{UIStyle.GREY_HEX}">{if typeof(value) == "string" then value else "—"}</font>`, 16)
	end

	-- pied : compte à rebours et bouton pour regarder la carte
	local footer = Instance.new("Frame")
	footer.Name = "Pied"
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.new(0, 16, 1, -10)
	footer.Size = UDim2.new(1, -32, 0, 46)
	footer.BackgroundTransparency = 1
	footer.Parent = window
	local countdown = UIStyle.text("Rebours", "", 16, UIStyle.FONT_MEDIUM, UIStyle.TEXT_DIM)
	countdown.AutomaticSize = Enum.AutomaticSize.None
	countdown.Size = UDim2.new(1, -190, 1, 0)
	countdown.TextYAlignment = Enum.TextYAlignment.Center
	countdown.Parent = footer
	local mapButton = UIStyle.button("VoirCarte", "🗺️ Voir la carte", true)
	mapButton.AnchorPoint = Vector2.new(1, 0)
	mapButton.Position = UDim2.fromScale(1, 0)
	mapButton.Size = UDim2.new(0, 180, 1, 0)
	mapButton.TextSize = 17
	mapButton.Parent = footer

	-- pastille pour rouvrir le classement
	local pill = UIStyle.button("Classement", "🏁 Classement final", true)
	pill.AnchorPoint = Vector2.new(0.5, 0)
	pill.Position = UDim2.new(0.5, 0, 0, 70)
	pill.Size = UDim2.fromOffset(220, 44)
	pill.TextSize = 17
	pill.Visible = false
	pill.Parent = screen
	mapButton.Activated:Connect(function()
		shade.Visible = false
		pill.Visible = true
	end)
	pill.Activated:Connect(function()
		shade.Visible = true
		pill.Visible = false
	end)

	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	Sfx.play(if myRank >= 1 and myRank <= 3 then "Victoire" else "Verdict")

	task.spawn(function()
		while gui == screen do
			local at = state:GetAttribute("NouvellePartie")
			local left = if typeof(at) == "number" then math.max(0, math.ceil(at - workspace:GetServerTimeNow())) else 0
			countdown.Text = if MatchState.status() == "Fin" then `Nouvelle partie dans <b>{left} s</b> : tu choisiras un pays.` else "Nouvelle partie en préparation…"
			pill.Text = `🏁 Classement · {left} s`
			task.wait(0.5)
		end
	end)
end

return EndScreen
