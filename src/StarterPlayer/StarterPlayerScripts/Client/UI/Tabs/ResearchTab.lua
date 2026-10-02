--!strict
-- Onglet « Recherche » : arbre technologique en trois branches.
-- Les prérequis viennent de Config/Technologies et le serveur reste seul décisionnaire.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Technologies = require(Config:WaitForChild("Technologies")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local TechState = require(Shared:WaitForChild("TechState")) :: any
local UI = script.Parent.Parent
local UIStyle = require(UI:WaitForChild("UIStyle"))
local Sfx = require(UI.Parent:WaitForChild("Audio"):WaitForChild("Sfx"))

local COMPLETE = Color3.fromRGB(72, 175, 106)
local AVAILABLE = Color3.fromRGB(78, 132, 184)
local LOCKED = Color3.fromRGB(74, 82, 96)
local CARD = Color3.fromRGB(27, 33, 44)
local CARD_SELECTED = Color3.fromRGB(37, 43, 54)
local TREE_BACKGROUND = Color3.fromRGB(13, 17, 24)

local NODE_WIDTH = 170
local NODE_HEIGHT = 104
local COLUMN_GAP = 48
local ROW_GAP = 14
local TREE_PADDING_X = 20
local TREE_HEADER_HEIGHT = 48
local TREE_HEIGHT = 374
local LANE_COUNT = 3

local ERA_LABELS = {
	"I · FONDATIONS",
	"II · SPÉCIALISATION",
	"III · SUPÉRIORITÉ",
	"IV · DOCTRINE",
}

-- Métadonnées uniquement visuelles : elles mettent en évidence les bifurcations existantes.
-- Toute future technologie absente de cette table reçoit automatiquement une voie libre.
local LANE_HINTS: { [string]: number } = {
	Logistique = 2,
	BlindesModernes = 1,
	Drones = 3,
	Missiles = 3,
	Radars = 2,
	SatellitesEspions = 1,
	Cyberdefense = 3,
	Agriculture = 1,
	Automatisation = 3,
	ReseauIntelligent = 3,
}

type NodeView = {
	tech: any,
	button: TextButton,
	outline: UIStroke,
	stripe: Frame,
	status: TextLabel,
	progressBack: Frame,
	progressFill: Frame,
}

type EdgeView = {
	fromId: string,
	toId: string,
	segments: { Frame },
}

local ResearchTab = {}

local function stock(folder: Instance, id: string): number
	local value = folder:GetAttribute(id)
	return if typeof(value) == "number" then value else 0
end

local function costText(costs: { [string]: number }): string
	local parts = {}
	if costs[Resources.currency.id] then
		table.insert(parts, string.format("%s %s", costs[Resources.currency.id], Resources.currency.icon))
	end
	for _, id in Resources.order do
		if costs[id] then
			table.insert(parts, string.format("%s %s", costs[id], Resources.list[id].icon))
		end
	end
	return table.concat(parts, " + ")
end

local function missingPrerequisites(countryId: string, tech: any): { any }
	local missing = {}
	for _, required in tech.requires do
		if not TechState.has(countryId, required) then
			local dependency = Technologies.get(required)
			table.insert(missing, dependency or { id = required, name = required })
		end
	end
	return missing
end

-- Remplit container ; renvoie une fonction qui arrête toutes les mises à jour.
function ResearchTab.build(container: Instance, countryId: string): () -> ()
	local folder = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Pays"):WaitForChild(countryId)
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Rechercher") :: RemoteFunction

	local frame = Instance.new("Frame")
	frame.Name = "Recherche"
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.Parent = container
	UIStyle.list(frame, 10)

	local running = true
	local busy = false
	local message: string? = nil
	local activeBranch: string = Technologies.branches[1].id
	local selectedTechId: string? = nil
	local lastStateSignature = ""
	local nodeViews: { [string]: NodeView } = {}
	local edgeViews: { EdgeView } = {}
	local branchButtons: { [string]: TextButton } = {}

	local summary = UIStyle.text("Resume", "", 14, UIStyle.FONT_MEDIUM, UIStyle.TEXT_DIM)
	summary.LayoutOrder = 1
	summary.Parent = frame

	local activeCard = Instance.new("Frame")
	activeCard.Name = "RechercheActive"
	activeCard.LayoutOrder = 2
	activeCard.BackgroundColor3 = CARD
	activeCard.BackgroundTransparency = 0.08
	activeCard.Size = UDim2.new(1, 0, 0, 86)
	activeCard.Parent = frame
	UIStyle.corner(activeCard, 8)
	UIStyle.stroke(activeCard, 0.72)

	local activeCaption = UIStyle.text("Libelle", "RECHERCHE EN COURS", 11, UIStyle.FONT_BOLD, UIStyle.TEXT_DIM)
	activeCaption.AutomaticSize = Enum.AutomaticSize.None
	activeCaption.Position = UDim2.fromOffset(12, 9)
	activeCaption.Size = UDim2.new(1, -24, 0, 16)
	activeCaption.Parent = activeCard

	local activeName = UIStyle.text("Technologie", "", 17, UIStyle.FONT_BOLD)
	activeName.AutomaticSize = Enum.AutomaticSize.None
	activeName.Position = UDim2.fromOffset(12, 28)
	activeName.Size = UDim2.new(1, -98, 0, 28)
	activeName.TextWrapped = false
	activeName.TextTruncate = Enum.TextTruncate.AtEnd
	activeName.Parent = activeCard

	local activeTimer = UIStyle.text("Temps", "", 15, UIStyle.FONT_BOLD, UIStyle.ACCENT)
	activeTimer.AutomaticSize = Enum.AutomaticSize.None
	activeTimer.AnchorPoint = Vector2.new(1, 0)
	activeTimer.Position = UDim2.new(1, -12, 0, 30)
	activeTimer.Size = UDim2.fromOffset(76, 24)
	activeTimer.TextXAlignment = Enum.TextXAlignment.Right
	activeTimer.Parent = activeCard

	local activeProgressBack = Instance.new("Frame")
	activeProgressBack.Name = "ProgressionFond"
	activeProgressBack.AnchorPoint = Vector2.new(0, 1)
	activeProgressBack.Position = UDim2.new(0, 12, 1, -11)
	activeProgressBack.Size = UDim2.new(1, -24, 0, 7)
	activeProgressBack.BackgroundColor3 = LOCKED
	activeProgressBack.BackgroundTransparency = 0.3
	activeProgressBack.ClipsDescendants = true
	activeProgressBack.Parent = activeCard
	UIStyle.corner(activeProgressBack, 4)

	local activeProgressFill = Instance.new("Frame")
	activeProgressFill.Name = "Progression"
	activeProgressFill.Size = UDim2.fromScale(0, 1)
	activeProgressFill.BackgroundColor3 = UIStyle.ACCENT
	activeProgressFill.BorderSizePixel = 0
	activeProgressFill.Parent = activeProgressBack
	UIStyle.corner(activeProgressFill, 4)

	local errorLabel = UIStyle.text("Erreur", "", 14, UIStyle.FONT_MEDIUM, UIStyle.DANGER)
	errorLabel.LayoutOrder = 3
	errorLabel.Visible = false
	errorLabel.Parent = frame

	local branchTitle = UIStyle.text("TitreBranche", "", 16, UIStyle.FONT_BOLD)
	branchTitle.LayoutOrder = 4
	branchTitle.Parent = frame

	local branchTabs = Instance.new("Frame")
	branchTabs.Name = "Branches"
	branchTabs.LayoutOrder = 5
	branchTabs.BackgroundTransparency = 1
	branchTabs.Size = UDim2.new(1, 0, 0, 50)
	branchTabs.Parent = frame
	local branchLayout = UIStyle.list(branchTabs, 6, true)
	branchLayout.VerticalAlignment = Enum.VerticalAlignment.Center

	local treeViewport = Instance.new("ScrollingFrame")
	treeViewport.Name = "ArbreTechnologique"
	treeViewport.LayoutOrder = 6
	treeViewport.Active = true
	treeViewport.BackgroundColor3 = TREE_BACKGROUND
	treeViewport.BackgroundTransparency = 0.04
	treeViewport.BorderSizePixel = 0
	treeViewport.Size = UDim2.new(1, 0, 0, TREE_HEIGHT)
	treeViewport.CanvasSize = UDim2.fromOffset(0, 0)
	treeViewport.AutomaticCanvasSize = Enum.AutomaticSize.None
	treeViewport.ScrollingDirection = Enum.ScrollingDirection.XY
	treeViewport.ScrollBarThickness = 5
	treeViewport.ScrollBarImageColor3 = UIStyle.ACCENT
	treeViewport.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	treeViewport.Parent = frame
	UIStyle.corner(treeViewport, 8)
	UIStyle.stroke(treeViewport, 0.78)

	local treeCanvas = Instance.new("Frame")
	treeCanvas.Name = "Canvas"
	treeCanvas.BackgroundTransparency = 1
	treeCanvas.Size = UDim2.fromOffset(0, 0)
	treeCanvas.Parent = treeViewport

	local detail = Instance.new("Frame")
	detail.Name = "FicheTechnologie"
	detail.LayoutOrder = 7
	detail.BackgroundColor3 = CARD
	detail.BackgroundTransparency = 0.05
	detail.Size = UDim2.new(1, 0, 0, 0)
	detail.AutomaticSize = Enum.AutomaticSize.Y
	detail.Parent = frame

	local hint = UIStyle.text(
		"Aide",
		"Sélectionne une technologie pour voir ses prérequis, son coût et lancer la recherche.",
		13,
		UIStyle.FONT,
		UIStyle.TEXT_DIM
	)
	hint.LayoutOrder = 8
	hint.Parent = frame

	local function canAfford(costs: { [string]: number }): boolean
		for id, amount in costs do
			if stock(folder, id) < amount then
				return false
			end
		end
		return true
	end

	local function missingCostText(costs: { [string]: number }): string
		local parts = {}
		local currencyId = Resources.currency.id
		local currencyCost = costs[currencyId]
		if currencyCost and stock(folder, currencyId) < currencyCost then
			table.insert(parts, string.format("%s %s", currencyCost - stock(folder, currencyId), Resources.currency.icon))
		end
		for _, id in Resources.order do
			local amount = costs[id]
			if amount and stock(folder, id) < amount then
				table.insert(parts, string.format("%s %s", amount - stock(folder, id), Resources.list[id].icon))
			end
		end
		return table.concat(parts, " + ")
	end

	local refreshAll: (boolean?) -> ()
	local renderTree: () -> ()

	local function ask(techId: string)
		if busy then
			return
		end
		busy = true
		refreshAll(true)
		local ok, accepted, reason = pcall(function()
			return remote:InvokeServer(techId)
		end)
		busy = false
		Sfx.actionResult("Rechercher", ok and accepted == true)
		message = if ok and accepted == true
			then nil
			elseif ok and typeof(reason) == "string" then reason
			else "Le serveur ne répond pas."
		lastStateSignature = ""
		refreshAll(true)
	end

	local function selectTech(techId: string)
		selectedTechId = techId
		lastStateSignature = ""
		refreshAll(true)
	end

	local function addSegment(name: string, x: number, y: number, width: number, height: number): Frame
		local segment = Instance.new("Frame")
		segment.Name = name
		segment.BackgroundColor3 = LOCKED
		segment.BackgroundTransparency = 0.18
		segment.BorderSizePixel = 0
		segment.Position = UDim2.fromOffset(x, y)
		segment.Size = UDim2.fromOffset(math.max(2, width), math.max(2, height))
		segment.ZIndex = 1
		segment.Parent = treeCanvas
		return segment
	end

	local function createEdge(fromId: string, toId: string, fromPosition: Vector2, toPosition: Vector2)
		local startX = fromPosition.X + NODE_WIDTH
		local startY = fromPosition.Y + math.floor(NODE_HEIGHT / 2)
		local endX = toPosition.X
		local endY = toPosition.Y + math.floor(NODE_HEIGHT / 2)
		local middleX = math.floor((startX + endX) / 2)
		local topY = math.min(startY, endY)
		local segments = {
			addSegment("Lien_" .. fromId .. "_" .. toId .. "_A", startX, startY - 1, middleX - startX, 2),
			addSegment("Lien_" .. fromId .. "_" .. toId .. "_B", middleX - 1, topY, 2, math.abs(endY - startY) + 2),
			addSegment("Lien_" .. fromId .. "_" .. toId .. "_C", middleX, endY - 1, endX - middleX, 2),
		}
		local arrow = addSegment("Lien_" .. fromId .. "_" .. toId .. "_Pointe", endX - 5, endY - 5, 9, 9)
		arrow.Rotation = 45
		table.insert(segments, arrow)
		table.insert(edgeViews, { fromId = fromId, toId = toId, segments = segments })
	end

	local function createNode(tech: any, position: Vector2): NodeView
		local button = Instance.new("TextButton")
		button.Name = tech.id
		button.AutoButtonColor = false
		button.Text = ""
		button.BackgroundColor3 = CARD
		button.BackgroundTransparency = 0.04
		button.BorderSizePixel = 0
		button.Position = UDim2.fromOffset(position.X, position.Y)
		button.Size = UDim2.fromOffset(NODE_WIDTH, NODE_HEIGHT)
		button.ZIndex = 2
		button.Parent = treeCanvas
		UIStyle.corner(button, 7)

		local outline = Instance.new("UIStroke")
		outline.Name = "Contour"
		outline.Color = LOCKED
		outline.Transparency = 0.2
		outline.Thickness = 1
		outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		outline.Parent = button

		local stripe = Instance.new("Frame")
		stripe.Name = "Etat"
		stripe.BackgroundColor3 = LOCKED
		stripe.BorderSizePixel = 0
		stripe.Size = UDim2.fromOffset(4, NODE_HEIGHT)
		stripe.ZIndex = 3
		stripe.Parent = button
		UIStyle.corner(stripe, 4)

		local icon = UIStyle.text("Icone", tech.icon, 25, UIStyle.FONT_BOLD)
		icon.AutomaticSize = Enum.AutomaticSize.None
		icon.Position = UDim2.fromOffset(10, 7)
		icon.Size = UDim2.fromOffset(26, 30)
		icon.TextXAlignment = Enum.TextXAlignment.Center
		icon.TextYAlignment = Enum.TextYAlignment.Center
		icon.ZIndex = 3
		icon.Parent = button

		local name = UIStyle.text("Nom", tech.name, 14, UIStyle.FONT_BOLD)
		name.AutomaticSize = Enum.AutomaticSize.None
		name.Position = UDim2.fromOffset(42, 7)
		name.Size = UDim2.new(1, -50, 0, 34)
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.ZIndex = 3
		name.Parent = button

		local effect = UIStyle.text("Effet", tech.effectText, 11, UIStyle.FONT, UIStyle.TEXT_DIM)
		effect.AutomaticSize = Enum.AutomaticSize.None
		effect.Position = UDim2.fromOffset(10, 43)
		effect.Size = UDim2.new(1, -20, 0, 29)
		effect.TextTruncate = Enum.TextTruncate.AtEnd
		effect.ZIndex = 3
		effect.Parent = button

		local meta = UIStyle.text(
			"Cout",
			string.format("%s s · %s", tech.time, costText(tech.cost)),
			10,
			UIStyle.FONT_MEDIUM,
			UIStyle.TEXT_DIM
		)
		meta.AutomaticSize = Enum.AutomaticSize.None
		meta.Position = UDim2.fromOffset(10, 73)
		meta.Size = UDim2.new(1, -20, 0, 14)
		meta.TextWrapped = false
		meta.TextTruncate = Enum.TextTruncate.AtEnd
		meta.ZIndex = 3
		meta.Parent = button

		local status = UIStyle.text("Statut", "", 10, UIStyle.FONT_BOLD)
		status.AutomaticSize = Enum.AutomaticSize.None
		status.Position = UDim2.fromOffset(10, 87)
		status.Size = UDim2.new(1, -20, 0, 14)
		status.TextWrapped = false
		status.ZIndex = 3
		status.Parent = button

		local progressBack = Instance.new("Frame")
		progressBack.Name = "ProgressionFond"
		progressBack.AnchorPoint = Vector2.new(0, 1)
		progressBack.Position = UDim2.new(0, 4, 1, -2)
		progressBack.Size = UDim2.new(1, -8, 0, 3)
		progressBack.BackgroundColor3 = LOCKED
		progressBack.BackgroundTransparency = 0.35
		progressBack.BorderSizePixel = 0
		progressBack.ClipsDescendants = true
		progressBack.Visible = false
		progressBack.ZIndex = 3
		progressBack.Parent = button

		local progressFill = Instance.new("Frame")
		progressFill.Name = "Progression"
		progressFill.Size = UDim2.fromScale(0, 1)
		progressFill.BackgroundColor3 = UIStyle.ACCENT
		progressFill.BorderSizePixel = 0
		progressFill.ZIndex = 4
		progressFill.Parent = progressBack

		button.Activated:Connect(function()
			selectTech(tech.id)
		end)

		return {
			tech = tech,
			button = button,
			outline = outline,
			stripe = stripe,
			status = status,
			progressBack = progressBack,
			progressFill = progressFill,
		}
	end

	local function calculateColumn(tech: any, memo: { [string]: number }, visiting: { [string]: boolean }): number
		if memo[tech.id] then
			return memo[tech.id]
		end
		if visiting[tech.id] then
			return 1
		end
		visiting[tech.id] = true
		local column = 1
		for _, required in tech.requires do
			local dependency = Technologies.get(required)
			if dependency and dependency.branch == tech.branch then
				column = math.max(column, calculateColumn(dependency, memo, visiting) + 1)
			end
		end
		visiting[tech.id] = nil
		memo[tech.id] = column
		return column
	end

	renderTree = function()
		for _, child in treeCanvas:GetChildren() do
			child:Destroy()
		end
		table.clear(nodeViews)
		table.clear(edgeViews)

		local branchTechs = {}
		for _, tech in Technologies.list do
			if tech.branch == activeBranch then
				table.insert(branchTechs, tech)
			end
		end

		local current = TechState.research(countryId)
		local selected = if selectedTechId then Technologies.get(selectedTechId) else nil
		if not selected or selected.branch ~= activeBranch then
			selectedTechId = nil
			for _, tech in branchTechs do
				if tech.id == current then
					selectedTechId = tech.id
					break
				end
			end
			if not selectedTechId then
				for _, tech in branchTechs do
					if TechState.available(countryId, tech.id) then
						selectedTechId = tech.id
						break
					end
				end
			end
			if not selectedTechId and branchTechs[1] then
				selectedTechId = branchTechs[1].id
			end
		end

		local columns: { [string]: number } = {}
		local visiting: { [string]: boolean } = {}
		local positions: { [string]: Vector2 } = {}
		local usedLanes: { [number]: { [number]: boolean } } = {}
		local maximumColumn = 1

		for _, tech in branchTechs do
			local column = calculateColumn(tech, columns, visiting)
			local hint = LANE_HINTS[tech.id]
			if hint then
				usedLanes[column] = usedLanes[column] or {}
				usedLanes[column][hint] = true
			end
			maximumColumn = math.max(maximumColumn, column)
		end

		for _, tech in branchTechs do
			local column = columns[tech.id]
			local lane = LANE_HINTS[tech.id]
			if not lane then
				usedLanes[column] = usedLanes[column] or {}
				for candidate = 1, LANE_COUNT do
					if not usedLanes[column][candidate] then
						lane = candidate
						usedLanes[column][candidate] = true
						break
					end
				end
				lane = lane or LANE_COUNT
			end
			local x = TREE_PADDING_X + (column - 1) * (NODE_WIDTH + COLUMN_GAP)
			local y = TREE_HEADER_HEIGHT + (lane - 1) * (NODE_HEIGHT + ROW_GAP)
			positions[tech.id] = Vector2.new(x, y)
		end

		local shownColumns = math.max(3, maximumColumn)
		local contentWidth = TREE_PADDING_X * 2 + shownColumns * NODE_WIDTH + (shownColumns - 1) * COLUMN_GAP
		local contentHeight = TREE_HEADER_HEIGHT + LANE_COUNT * NODE_HEIGHT + (LANE_COUNT - 1) * ROW_GAP + 18
		contentWidth = math.max(contentWidth, math.max(0, treeViewport.AbsoluteSize.X))
		treeCanvas.Size = UDim2.fromOffset(contentWidth, contentHeight)
		treeViewport.CanvasSize = UDim2.fromOffset(contentWidth, contentHeight)
		treeViewport.CanvasPosition = Vector2.zero

		for column = 1, shownColumns do
			local label = UIStyle.text(
				"Epoque_" .. column,
				ERA_LABELS[column] or ("PALIER " .. column),
				11,
				UIStyle.FONT_BOLD,
				UIStyle.TEXT_DIM
			)
			label.AutomaticSize = Enum.AutomaticSize.None
			label.Position = UDim2.fromOffset(TREE_PADDING_X + (column - 1) * (NODE_WIDTH + COLUMN_GAP), 13)
			label.Size = UDim2.fromOffset(NODE_WIDTH, 22)
			label.TextXAlignment = Enum.TextXAlignment.Center
			label.ZIndex = 2
			label.Parent = treeCanvas
		end

		for _, tech in branchTechs do
			local childPosition = positions[tech.id]
			for _, required in tech.requires do
				local parentPosition = positions[required]
				if parentPosition and childPosition then
					createEdge(required, tech.id, parentPosition, childPosition)
				end
			end
		end

		for _, tech in branchTechs do
			nodeViews[tech.id] = createNode(tech, positions[tech.id])
		end

		lastStateSignature = ""
		refreshAll(true)
	end

	local function clearDetail()
		for _, child in detail:GetChildren() do
			child:Destroy()
		end
		UIStyle.corner(detail, 8)
		UIStyle.stroke(detail, 0.75)
		UIStyle.padding(detail, 11, 12)
		UIStyle.list(detail, 7)
	end

	local function addDetailText(name: string, value: string, size: number, font: Font?, color: Color3?): TextLabel
		local label = UIStyle.text(name, value, size, font, color)
		label.Parent = detail
		return label
	end

	local function buildDetail()
		clearDetail()
		local tech = if selectedTechId then Technologies.get(selectedTechId) else nil
		if not tech then
			addDetailText("Vide", "Sélectionne une technologie dans l'arbre.", 15, UIStyle.FONT, UIStyle.TEXT_DIM)
			return
		end

		local current = TechState.research(countryId)
		local has = TechState.has(countryId, tech.id)
		local missing = missingPrerequisites(countryId, tech)
		local affordable = canAfford(tech.cost)
		local statusText: string
		local statusColor: Color3
		if has then
			statusText, statusColor = "✓ TECHNOLOGIE ACQUISE", COMPLETE
		elseif current == tech.id then
			statusText, statusColor = "● RECHERCHE EN COURS", UIStyle.ACCENT
		elseif #missing > 0 then
			statusText, statusColor = "VERROUILLÉE", LOCKED:Lerp(UIStyle.TEXT, 0.35)
		elseif affordable and current == nil then
			statusText, statusColor = "DISPONIBLE", AVAILABLE:Lerp(UIStyle.TEXT, 0.28)
		elseif not affordable then
			statusText, statusColor = "RESSOURCES INSUFFISANTES", UIStyle.DANGER
		else
			statusText, statusColor = "FILE DE RECHERCHE OCCUPÉE", UIStyle.TEXT_DIM
		end

		addDetailText("Nom", string.format("%s <b>%s</b>", tech.icon, tech.name), 19, UIStyle.FONT_BOLD)
		addDetailText("Statut", statusText, 12, UIStyle.FONT_BOLD, statusColor)
		addDetailText("Effet", tech.effectText, 15, UIStyle.FONT_MEDIUM)
		addDetailText(
			"Cout",
			string.format("<b>Coût</b>  %s     <b>Durée</b>  %s s", costText(tech.cost), tech.time),
			14,
			UIStyle.FONT,
			UIStyle.TEXT_DIM
		)

		if #tech.requires == 0 then
			addDetailText("Prerequis", "Point de départ de cette branche.", 13, UIStyle.FONT, UIStyle.TEXT_DIM)
		else
			local names = {}
			for _, required in tech.requires do
				local dependency = Technologies.get(required)
				table.insert(names, if dependency then dependency.name else required)
			end
			addDetailText(
				"Prerequis",
				"<b>Prérequis</b>  " .. table.concat(names, "  +  "),
				13,
				UIStyle.FONT,
				UIStyle.TEXT_DIM
			)
		end

		if #missing > 0 then
			local names = {}
			for _, dependency in missing do
				table.insert(names, dependency.name)
			end
			addDetailText(
				"Blocage",
				"Il faut d'abord : <b>" .. table.concat(names, ", ") .. "</b>.",
				14,
				UIStyle.FONT_MEDIUM,
				UIStyle.TEXT_DIM
			)
		elseif not has and current ~= tech.id then
			if not affordable then
				addDetailText(
					"Manque",
					"Il manque : <b>" .. missingCostText(tech.cost) .. "</b>.",
					14,
					UIStyle.FONT_MEDIUM,
					UIStyle.DANGER
				)
			end
			local text = if busy then "Transmission..." else string.format("Lancer la recherche · %s s", tech.time)
			local research = UIStyle.button("Rechercher_" .. tech.id, text, true)
			research.Size = UDim2.new(1, 0, 0, 42)
			research.TextSize = 15
			UIStyle.setButtonEnabled(research, not busy and current == nil and affordable)
			research.Activated:Connect(function()
				if UIStyle.isEnabled(research) then
					task.spawn(ask, tech.id)
				end
			end)
			research.Parent = detail
		end
	end

	local function updateActiveProgress()
		local current, finish = TechState.research(countryId)
		local tech = if current then Technologies.get(current) else nil
		if not current or not finish or not tech then
			activeName.Text = "Aucune recherche en cours"
			activeName.TextColor3 = UIStyle.TEXT_DIM
			activeTimer.Text = "LIBRE"
			activeTimer.TextColor3 = COMPLETE
			activeProgressFill.Size = UDim2.fromScale(0, 1)
			activeProgressBack.Visible = false
			return
		end

		local now = workspace:GetServerTimeNow()
		local left = math.max(0, math.ceil(finish - now))
		local elapsed = math.clamp(1 - ((finish - now) / math.max(1, tech.time)), 0, 1)
		activeName.Text = string.format("%s %s", tech.icon, tech.name)
		activeName.TextColor3 = UIStyle.TEXT
		activeTimer.Text = string.format("%s s", left)
		activeTimer.TextColor3 = UIStyle.ACCENT
		activeProgressBack.Visible = true
		activeProgressFill.Size = UDim2.fromScale(elapsed, 1)

		local node = nodeViews[current]
		if node then
			node.progressBack.Visible = true
			node.progressFill.Size = UDim2.fromScale(elapsed, 1)
		end
	end

	local function stateSignature(): string
		local current = TechState.research(countryId)
		local parts = {
			activeBranch,
			selectedTechId or "",
			message or "",
			tostring(busy),
			tostring(current),
			table.concat(TechState.list(countryId), ","),
			tostring(stock(folder, Resources.currency.id)),
		}
		for _, id in Resources.order do
			table.insert(parts, tostring(stock(folder, id)))
		end
		return table.concat(parts, "|")
	end

	local function updateNode(view: NodeView)
		local tech = view.tech
		local current = TechState.research(countryId)
		local has = TechState.has(countryId, tech.id)
		local available = TechState.available(countryId, tech.id)
		local affordable = canAfford(tech.cost)
		local selected = selectedTechId == tech.id
		local color: Color3
		local statusText: string
		local statusColor: Color3

		if has then
			color = COMPLETE
			statusText = "✓ ACQUISE"
			statusColor = COMPLETE
		elseif current == tech.id then
			color = UIStyle.ACCENT
			statusText = "● EN RECHERCHE"
			statusColor = UIStyle.ACCENT
		elseif available and affordable and current == nil then
			color = AVAILABLE
			statusText = "DISPONIBLE"
			statusColor = AVAILABLE:Lerp(UIStyle.TEXT, 0.3)
		elseif available and not affordable then
			color = UIStyle.DANGER
			statusText = "RESSOURCES"
			statusColor = UIStyle.DANGER
		elseif available then
			color = LOCKED:Lerp(UIStyle.TEXT, 0.2)
			statusText = "EN ATTENTE"
			statusColor = UIStyle.TEXT_DIM
		else
			color = LOCKED
			statusText = "VERROUILLÉE"
			statusColor = UIStyle.TEXT_DIM
		end

		view.button.BackgroundColor3 = if selected then CARD_SELECTED else CARD
		view.button.BackgroundTransparency = if has or current == tech.id then 0 else if available then 0.04 else 0.22
		view.outline.Color = if selected then UIStyle.ACCENT else color
		view.outline.Thickness = if selected then 3 else if current == tech.id then 2 else 1
		view.outline.Transparency = if selected or current == tech.id then 0 else 0.22
		view.stripe.BackgroundColor3 = color
		view.status.Text = statusText
		view.status.TextColor3 = statusColor
		view.progressBack.Visible = current == tech.id
	end

	local function updateEdges()
		local current = TechState.research(countryId)
		for _, edge in edgeViews do
			local fromHas = TechState.has(countryId, edge.fromId)
			local toHas = TechState.has(countryId, edge.toId)
			local toAvailable = TechState.available(countryId, edge.toId)
			local color = LOCKED
			local transparency = 0.3
			if fromHas and toHas then
				color = COMPLETE
				transparency = 0
			elseif current == edge.toId or toAvailable then
				color = UIStyle.ACCENT
				transparency = 0.05
			elseif fromHas then
				color = UIStyle.ACCENT:Lerp(LOCKED, 0.4)
				transparency = 0.16
			end
			for _, segment in edge.segments do
				segment.BackgroundColor3 = color
				segment.BackgroundTransparency = transparency
			end
		end
	end

	local function updateBranchButtons()
		for _, branch in Technologies.branches do
			local acquired = 0
			local total = 0
			for _, tech in Technologies.list do
				if tech.branch == branch.id then
					total += 1
					if TechState.has(countryId, tech.id) then
						acquired += 1
					end
				end
			end
			local button = branchButtons[branch.id]
			button.Text = string.format("%s %s\n%s/%s", branch.icon, string.upper(branch.name), acquired, total)
			if branch.id == activeBranch then
				UIStyle.setButtonColor(button, UIStyle.ACCENT, Color3.fromRGB(30, 26, 18), 0)
			else
				UIStyle.setButtonColor(button, CARD, UIStyle.TEXT, 0.05)
			end
		end
	end

	refreshAll = function(force: boolean?)
		if not running or not frame.Parent then
			return
		end
		local owned = #TechState.list(countryId)
		summary.Text = string.format("<b>%s/%s</b> technologies acquises · une recherche active maximum", owned, #Technologies.list)
		errorLabel.Text = message or ""
		errorLabel.Visible = message ~= nil

		local branchName = activeBranch
		for _, branch in Technologies.branches do
			if branch.id == activeBranch then
				branchName = branch.name
				break
			end
		end
		branchTitle.Text = "<b>BRANCHE " .. string.upper(branchName) .. "</b> · progression de gauche à droite"

		updateActiveProgress()
		updateBranchButtons()
		for _, view in nodeViews do
			updateNode(view)
		end
		updateEdges()

		local signature = stateSignature()
		if force or signature ~= lastStateSignature then
			lastStateSignature = signature
			buildDetail()
		end
	end

	for index, branch in Technologies.branches do
		local button = UIStyle.button("Branche_" .. branch.id, branch.name)
		button.LayoutOrder = index
		button.Size = UDim2.new(1 / #Technologies.branches, -4, 1, 0)
		button.TextSize = 12
		button.LineHeight = 1.05
		button.RichText = true
		button.Parent = branchTabs
		branchButtons[branch.id] = button
		button.Activated:Connect(function()
			if activeBranch == branch.id then
				return
			end
			activeBranch = branch.id
			selectedTechId = nil
			renderTree()
		end)
	end

	local currentAtOpen = TechState.research(countryId)
	if currentAtOpen then
		local activeTech = Technologies.get(currentAtOpen)
		if activeTech then
			activeBranch = activeTech.branch
			selectedTechId = activeTech.id
		end
	end

	renderTree()

	local attributeConnection = folder.AttributeChanged:Connect(function()
		refreshAll(false)
	end)
	local viewportConnection = treeViewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		local width = math.max(treeCanvas.AbsoluteSize.X, treeViewport.AbsoluteSize.X)
		local height = math.max(treeCanvas.AbsoluteSize.Y, treeViewport.AbsoluteSize.Y)
		treeViewport.CanvasSize = UDim2.fromOffset(width, height)
	end)

	task.spawn(function()
		local stateAccumulator = 0
		while running and frame.Parent do
			task.wait(0.2)
			if not running or not frame.Parent then
				break
			end
			updateActiveProgress()
			stateAccumulator += 0.2
			if stateAccumulator >= 0.8 then
				stateAccumulator = 0
				refreshAll(false)
			end
		end
	end)

	return function()
		if not running then
			return
		end
		running = false
		attributeConnection:Disconnect()
		viewportConnection:Disconnect()
	end
end

return ResearchTab
