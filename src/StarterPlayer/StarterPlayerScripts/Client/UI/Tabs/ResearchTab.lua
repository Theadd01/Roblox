--!strict
-- Onglet « Recherche » (cahier des charges v2, section 4) : arbre technologique à niveaux, façon
-- Hearts of Iron IV.
--   en haut : la file de recherche (plusieurs emplacements en parallèle, barre de progression,
--     temps restant, annulation) ;
--   des onglets par catégorie (Infanterie, Blindés, Artillerie, Aviation, Marine, Économie,
--     Industrie, Renseignement) ;
--   l'arbre de la catégorie : une carte par technologie (nom, niveau actuel / maximum, état),
--     reliée à ses prérequis par des flèches (« niv. 2 » : niveau demandé) ;
--   la fiche de la technologie choisie : effet du niveau actuel et du suivant, coût, durée,
--     prérequis, bouton « Rechercher » (ou « Annuler »).
-- Les données viennent de Config/Technologies et shared/TechState ; le serveur décide de tout
-- (Remotes.Rechercher, Remotes.AnnulerRecherche).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
local RESEARCHING = UIStyle.ACCENT
local LOCKED = Color3.fromRGB(74, 82, 96)
local CARD = Color3.fromRGB(27, 33, 44)
local CARD_SELECTED = Color3.fromRGB(40, 47, 60)
local TREE_BACKGROUND = Color3.fromRGB(13, 17, 24)

local NODE_WIDTH = 184
local NODE_HEIGHT = 96
local COLUMN_GAP = 64
local ROW_GAP = 22
local TREE_PADDING = 18
local TREE_HEIGHT = 330
local SLOT_HEIGHT = 46

type NodeView = {
	tech: any,
	button: TextButton,
	outline: UIStroke,
	stripe: Frame,
	level: TextLabel,
	status: TextLabel,
	progressBack: Frame,
	progressFill: Frame,
}

type EdgeView = {
	requirement: any,
	toId: string,
	segments: { Frame },
	label: TextLabel,
}

type SlotView = {
	frame: Frame,
	name: TextLabel,
	timer: TextLabel,
	fill: Frame,
	cancel: TextButton,
}

local ResearchTab = {}

local function stock(folder: Instance, id: string): number
	local value = folder:GetAttribute(id)
	return if typeof(value) == "number" then value else 0
end

local function costText(costs: { [string]: number }): string
	local parts = {}
	if costs[Resources.currency.id] then
		table.insert(parts, `{costs[Resources.currency.id]} {Resources.currency.icon}`)
	end
	for _, id in Resources.order do
		if costs[id] then
			table.insert(parts, `{costs[id]} {Resources.list[id].icon}`)
		end
	end
	return if #parts > 0 then table.concat(parts, " + ") else "gratuit"
end

local function duration(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	if seconds >= 60 then
		return string.format("%d min %02d s", seconds // 60, seconds % 60)
	end
	return `{seconds} s`
end

local function nodePosition(tech: any): Vector2
	return Vector2.new(
		TREE_PADDING + (tech.column - 1) * (NODE_WIDTH + COLUMN_GAP),
		TREE_PADDING + (tech.row - 1) * (NODE_HEIGHT + ROW_GAP)
	)
end

-- Remplit container ; renvoie une fonction qui arrête toutes les mises à jour.
function ResearchTab.build(container: Instance, countryId: string): () -> ()
	local folder = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Pays"):WaitForChild(countryId)
	local remotes = ReplicatedStorage:WaitForChild("Remotes")

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
	local lastSignature = ""
	local nodeViews: { [string]: NodeView } = {}
	local edgeViews: { EdgeView } = {}
	local branchButtons: { [string]: TextButton } = {}
	local slotViews: { SlotView } = {}

	local summary = UIStyle.text("Resume", "", 14, UIStyle.FONT_MEDIUM, UIStyle.TEXT_DIM)
	summary.LayoutOrder = 1
	summary.Parent = frame

	-- File de recherche
	local queueCard = Instance.new("Frame")
	queueCard.Name = "FileDeRecherche"
	queueCard.LayoutOrder = 2
	queueCard.BackgroundColor3 = CARD
	queueCard.BackgroundTransparency = 0.08
	queueCard.Size = UDim2.new(1, 0, 0, 0)
	queueCard.AutomaticSize = Enum.AutomaticSize.Y
	queueCard.Parent = frame
	UIStyle.corner(queueCard, 8)
	UIStyle.stroke(queueCard, 0.72)
	UIStyle.padding(queueCard, 8, 12)
	UIStyle.list(queueCard, 6)
	local queueCaption = UIStyle.text("Libelle", "FILE DE RECHERCHE", 11, UIStyle.FONT_BOLD, UIStyle.TEXT_DIM)
	queueCaption.LayoutOrder = 0
	queueCaption.Parent = queueCard

	local errorLabel = UIStyle.text("Erreur", "", 14, UIStyle.FONT_MEDIUM, UIStyle.DANGER)
	errorLabel.LayoutOrder = 3
	errorLabel.Visible = false
	errorLabel.Parent = frame

	-- Onglets des catégories (défilent si l'écran est étroit)
	local branchTabs = Instance.new("ScrollingFrame")
	branchTabs.Name = "Branches"
	branchTabs.LayoutOrder = 4
	branchTabs.BackgroundTransparency = 1
	branchTabs.BorderSizePixel = 0
	branchTabs.Size = UDim2.new(1, 0, 0, 48)
	branchTabs.CanvasSize = UDim2.new()
	branchTabs.AutomaticCanvasSize = Enum.AutomaticSize.X
	branchTabs.ScrollingDirection = Enum.ScrollingDirection.X
	branchTabs.ScrollBarThickness = 3
	branchTabs.ScrollBarImageColor3 = UIStyle.ACCENT
	branchTabs.Parent = frame
	local branchLayout = UIStyle.list(branchTabs, 6, true)
	branchLayout.VerticalAlignment = Enum.VerticalAlignment.Center

	local treeViewport = Instance.new("ScrollingFrame")
	treeViewport.Name = "ArbreTechnologique"
	treeViewport.LayoutOrder = 5
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
	detail.LayoutOrder = 6
	detail.BackgroundColor3 = CARD
	detail.BackgroundTransparency = 0.05
	detail.Size = UDim2.new(1, 0, 0, 0)
	detail.AutomaticSize = Enum.AutomaticSize.Y
	detail.Parent = frame
	UIStyle.corner(detail, 8)
	UIStyle.stroke(detail, 0.72)
	UIStyle.padding(detail, 10, 12)
	UIStyle.list(detail, 6)

	local function canAfford(costs: { [string]: number }): boolean
		for id, amount in costs do
			if stock(folder, id) < amount then
				return false
			end
		end
		return true
	end

	local function missingCostText(costs: { [string]: number }): string
		local missing: { [string]: number } = {}
		for id, amount in costs do
			if stock(folder, id) < amount then
				missing[id] = amount - stock(folder, id)
			end
		end
		return costText(missing)
	end

	local refreshAll: (boolean?) -> ()

	local function ask(remoteName: string, techId: string)
		if busy then
			return
		end
		busy = true
		refreshAll(true)
		local remote = remotes:WaitForChild(remoteName) :: RemoteFunction
		local ok, accepted, reason = pcall(function()
			return remote:InvokeServer(techId)
		end)
		busy = false
		Sfx.actionResult("Rechercher", ok and accepted == true)
		message = if ok and accepted == true
			then nil
			elseif ok and typeof(reason) == "string" then reason
			else "Le serveur ne répond pas."
		lastSignature = ""
		refreshAll(true)
	end

	-- ---- Arbre --------------------------------------------------------------------------------

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

	-- Flèche d'un prérequis vers une technologie (coudée si elles ne sont pas sur la même ligne)
	local function createEdge(requirement: any, toTech: any)
		local fromTech = Technologies.get(requirement.id)
		if not fromTech or fromTech.branch ~= toTech.branch then
			return
		end
		local fromPosition, toPosition = nodePosition(fromTech), nodePosition(toTech)
		local startX = fromPosition.X + NODE_WIDTH
		local startY = fromPosition.Y + math.floor(NODE_HEIGHT / 2)
		local endX = toPosition.X
		local endY = toPosition.Y + math.floor(NODE_HEIGHT / 2)
		local middleX = math.floor((startX + endX) / 2)
		local topY = math.min(startY, endY)
		local name = "Lien_" .. fromTech.id .. "_" .. toTech.id
		local segments = {
			addSegment(name .. "_A", startX, startY - 1, middleX - startX, 2),
			addSegment(name .. "_B", middleX - 1, topY, 2, math.abs(endY - startY) + 2),
			addSegment(name .. "_C", middleX, endY - 1, endX - middleX, 2),
		}
		local arrow = addSegment(name .. "_Pointe", endX - 6, endY - 5, 9, 9)
		arrow.Rotation = 45
		table.insert(segments, arrow)
		local label = UIStyle.text(name .. "_Niveau", `niv. {requirement.level}`, 11, UIStyle.FONT_BOLD, UIStyle.TEXT_DIM)
		label.AutomaticSize = Enum.AutomaticSize.None
		label.Size = UDim2.fromOffset(46, 14)
		label.Position = UDim2.fromOffset(middleX + 4, endY - 17)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.ZIndex = 2
		label.Parent = treeCanvas
		table.insert(edgeViews, { requirement = requirement, toId = toTech.id, segments = segments, label = label })
	end

	local function createNode(tech: any): NodeView
		local position = nodePosition(tech)
		local button = Instance.new("TextButton")
		button.Name = tech.id
		button.AutoButtonColor = false
		button.Text = ""
		button.BackgroundColor3 = CARD
		button.BackgroundTransparency = 0.04
		button.Position = UDim2.fromOffset(position.X, position.Y)
		button.Size = UDim2.fromOffset(NODE_WIDTH, NODE_HEIGHT)
		button.ZIndex = 3
		button.Parent = treeCanvas
		UIStyle.corner(button, 8)
		local outline = UIStyle.stroke(button, 0.4, LOCKED, 1.5)

		local stripe = Instance.new("Frame")
		stripe.Name = "Bande"
		stripe.BackgroundColor3 = LOCKED
		stripe.BorderSizePixel = 0
		stripe.Size = UDim2.new(0, 4, 1, -12)
		stripe.Position = UDim2.fromOffset(6, 6)
		stripe.ZIndex = 4
		stripe.Parent = button
		UIStyle.corner(stripe, 2)

		local title = UIStyle.text("Nom", `{tech.icon} {tech.name}`, 14, UIStyle.FONT_BOLD)
		title.AutomaticSize = Enum.AutomaticSize.None
		title.Position = UDim2.fromOffset(16, 6)
		title.Size = UDim2.new(1, -22, 0, 36)
		title.TextWrapped = true
		title.TextYAlignment = Enum.TextYAlignment.Top
		title.ZIndex = 4
		title.Parent = button

		local level = UIStyle.text("Niveau", "", 13, UIStyle.FONT_BOLD, UIStyle.ACCENT)
		level.AutomaticSize = Enum.AutomaticSize.None
		level.Position = UDim2.fromOffset(16, 44)
		level.Size = UDim2.new(1, -22, 0, 16)
		level.ZIndex = 4
		level.Parent = button

		local status = UIStyle.text("Etat", "", 12, UIStyle.FONT_MEDIUM, UIStyle.TEXT_DIM)
		status.AutomaticSize = Enum.AutomaticSize.None
		status.Position = UDim2.fromOffset(16, 62)
		status.Size = UDim2.new(1, -22, 0, 16)
		status.TextWrapped = false
		status.TextTruncate = Enum.TextTruncate.AtEnd
		status.ZIndex = 4
		status.Parent = button

		local progressBack = Instance.new("Frame")
		progressBack.Name = "Progression"
		progressBack.Position = UDim2.new(0, 16, 1, -12)
		progressBack.Size = UDim2.new(1, -26, 0, 5)
		progressBack.BackgroundColor3 = LOCKED
		progressBack.BackgroundTransparency = 0.3
		progressBack.BorderSizePixel = 0
		progressBack.ZIndex = 4
		progressBack.Visible = false
		progressBack.Parent = button
		UIStyle.corner(progressBack, 3)
		local progressFill = Instance.new("Frame")
		progressFill.Name = "Remplissage"
		progressFill.BackgroundColor3 = RESEARCHING
		progressFill.BorderSizePixel = 0
		progressFill.Size = UDim2.fromScale(0, 1)
		progressFill.ZIndex = 5
		progressFill.Parent = progressBack
		UIStyle.corner(progressFill, 3)

		button.Activated:Connect(function()
			selectedTechId = tech.id
			lastSignature = ""
			refreshAll(true)
		end)
		return { tech = tech, button = button, outline = outline, stripe = stripe, level = level, status = status, progressBack = progressBack, progressFill = progressFill }
	end

	local function buildTree()
		for _, child in treeCanvas:GetChildren() do
			child:Destroy()
		end
		table.clear(nodeViews)
		table.clear(edgeViews)
		local maxX, maxY = 0, 0
		local first: string? = nil
		for _, tech in Technologies.list do
			if tech.branch ~= activeBranch then
				continue
			end
			first = first or tech.id
			nodeViews[tech.id] = createNode(tech)
			local position = nodePosition(tech)
			maxX = math.max(maxX, position.X + NODE_WIDTH)
			maxY = math.max(maxY, position.Y + NODE_HEIGHT)
			for _, requirement in tech.requires do
				createEdge(requirement, tech)
			end
		end
		local size = Vector2.new(maxX + TREE_PADDING, maxY + TREE_PADDING)
		treeCanvas.Size = UDim2.fromOffset(size.X, size.Y)
		treeViewport.CanvasSize = UDim2.fromOffset(size.X, size.Y)
		treeViewport.CanvasPosition = Vector2.zero
		if not selectedTechId or not nodeViews[selectedTechId] then
			selectedTechId = first
		end
	end

	for index, branch in Technologies.branches do
		local b = UIStyle.button("Branche_" .. branch.id, `{branch.icon} {branch.name}`, false)
		b.LayoutOrder = index
		b.AutomaticSize = Enum.AutomaticSize.X
		b.Size = UDim2.fromOffset(0, 38)
		b.TextSize = 15
		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, 12)
		padding.PaddingRight = UDim.new(0, 12)
		padding.Parent = b
		b.Parent = branchTabs
		branchButtons[branch.id] = b
		b.Activated:Connect(function()
			if activeBranch ~= branch.id then
				activeBranch = branch.id
				selectedTechId = nil
				buildTree()
				lastSignature = ""
				refreshAll(true)
			end
		end)
	end

	-- ---- État ---------------------------------------------------------------------------------

	local function queueEntry(techId: string): any?
		for _, r in TechState.queue(countryId) do
			if r.id == techId then
				return r
			end
		end
		return nil
	end

	local function progressOf(r: any): number
		return math.clamp((workspace:GetServerTimeNow() - r.start) / math.max(r.finish - r.start, 0.001), 0, 1)
	end

	local function refreshNodes()
		for techId, view in nodeViews do
			local tech = view.tech
			local level = TechState.level(countryId, techId)
			local maxLevel = Technologies.maxLevel(tech)
			local queued = queueEntry(techId)
			local color, statusText = LOCKED, ""
			if queued then
				color, statusText = RESEARCHING, `⏳ niveau {queued.level} en cours`
			elseif level >= maxLevel then
				color, statusText = COMPLETE, "✔ niveau maximum"
			elseif TechState.requirementsMet(countryId, techId) then
				color, statusText = AVAILABLE, `prochain : {costText(tech.levels[level + 1].cost)}`
			else
				statusText = "🔒 prérequis manquants"
			end
			view.stripe.BackgroundColor3 = color
			view.outline.Color = if selectedTechId == techId then UIStyle.ACCENT else color
			view.outline.Transparency = if selectedTechId == techId then 0 else 0.4
			view.button.BackgroundColor3 = if selectedTechId == techId then CARD_SELECTED else CARD
			view.level.Text = `Niv. {level}/{maxLevel}  {string.rep("●", level)}{string.rep("○", maxLevel - level)}`
			view.level.TextColor3 = if level > 0 then UIStyle.ACCENT else UIStyle.TEXT_DIM
			view.status.Text = statusText
			view.progressBack.Visible = queued ~= nil
			if queued then
				view.progressFill.Size = UDim2.fromScale(progressOf(queued), 1)
			end
		end
		for _, edge in edgeViews do
			local met = TechState.level(countryId, edge.requirement.id) >= edge.requirement.level
			for _, segment in edge.segments do
				segment.BackgroundColor3 = if met then COMPLETE else LOCKED
			end
			edge.label.TextColor3 = if met then COMPLETE else UIStyle.TEXT_DIM
		end
		for id, b in branchButtons do
			UIStyle.setButtonSelected(b, id == activeBranch)
		end
	end

	local function refreshQueue()
		local queue = TechState.queue(countryId)
		local slots = TechState.slots(countryId)
		queueCaption.Text = `FILE DE RECHERCHE · {#queue}/{slots} EMPLACEMENTS`
		while #slotViews < slots do
			local index = #slotViews + 1
			local slot = Instance.new("Frame")
			slot.Name = "Emplacement" .. index
			slot.LayoutOrder = index
			slot.BackgroundColor3 = TREE_BACKGROUND
			slot.BackgroundTransparency = 0.2
			slot.Size = UDim2.new(1, 0, 0, SLOT_HEIGHT)
			UIStyle.corner(slot, 6)
			slot.Parent = queueCard
			local name = UIStyle.text("Nom", "", 14, UIStyle.FONT_BOLD)
			name.AutomaticSize = Enum.AutomaticSize.None
			name.Position = UDim2.fromOffset(10, 4)
			name.Size = UDim2.new(1, -140, 0, 22)
			name.TextWrapped = false
			name.TextTruncate = Enum.TextTruncate.AtEnd
			name.Parent = slot
			local timer = UIStyle.text("Temps", "", 13, UIStyle.FONT_BOLD, UIStyle.ACCENT)
			timer.AutomaticSize = Enum.AutomaticSize.None
			timer.AnchorPoint = Vector2.new(1, 0)
			timer.Position = UDim2.new(1, -46, 0, 4)
			timer.Size = UDim2.fromOffset(86, 22)
			timer.TextXAlignment = Enum.TextXAlignment.Right
			timer.Parent = slot
			local back = Instance.new("Frame")
			back.Name = "Progression"
			back.Position = UDim2.new(0, 10, 1, -13)
			back.Size = UDim2.new(1, -56, 0, 6)
			back.BackgroundColor3 = LOCKED
			back.BackgroundTransparency = 0.3
			back.BorderSizePixel = 0
			back.ClipsDescendants = true
			back.Parent = slot
			UIStyle.corner(back, 3)
			local fill = Instance.new("Frame")
			fill.Name = "Remplissage"
			fill.BackgroundColor3 = RESEARCHING
			fill.BorderSizePixel = 0
			fill.Size = UDim2.fromScale(0, 1)
			fill.Parent = back
			UIStyle.corner(fill, 3)
			local cancel = UIStyle.button("Annuler", "✖", false)
			cancel.AnchorPoint = Vector2.new(1, 0.5)
			cancel.Position = UDim2.new(1, -6, 0.5, 0)
			cancel.Size = UDim2.fromOffset(32, 32)
			cancel.TextSize = 14
			cancel.Parent = slot
			local view: SlotView = { frame = slot, name = name, timer = timer, fill = fill, cancel = cancel }
			cancel.Activated:Connect(function()
				local techId = slot:GetAttribute("Technologie")
				if typeof(techId) == "string" and UIStyle.isEnabled(cancel) then
					ask("AnnulerRecherche", techId)
				end
			end)
			table.insert(slotViews, view)
		end
		for index, view in slotViews do
			local r = queue[index]
			view.frame.Visible = index <= slots
			if r then
				local tech = Technologies.get(r.id)
				view.frame:SetAttribute("Technologie", r.id)
				view.name.Text = `{if tech then tech.icon .. " " .. tech.name else r.id} · niveau {r.level}`
				view.name.TextColor3 = UIStyle.TEXT
				view.timer.Text = duration(r.finish - workspace:GetServerTimeNow())
				view.fill.Size = UDim2.fromScale(progressOf(r), 1)
				view.cancel.Visible = true
				UIStyle.setButtonEnabled(view.cancel, not busy)
			else
				view.frame:SetAttribute("Technologie", nil)
				view.name.Text = "Emplacement libre"
				view.name.TextColor3 = UIStyle.TEXT_DIM
				view.timer.Text = ""
				view.fill.Size = UDim2.fromScale(0, 1)
				view.cancel.Visible = false
			end
		end
	end

	local function refreshDetail()
		for _, child in detail:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local tech = if selectedTechId then Technologies.get(selectedTechId) else nil
		if not tech then
			detail.Visible = false
			return
		end
		detail.Visible = true
		local order = 0
		local function add(object: GuiObject)
			order += 1
			object.LayoutOrder = order
			object.Parent = detail
		end
		local level = TechState.level(countryId, tech.id)
		local maxLevel = Technologies.maxLevel(tech)
		add(UIStyle.text("Titre", `{tech.icon} <b>{tech.name}</b>  <font color="{UIStyle.GREY_HEX}">niveau {level}/{maxLevel}</font>`, 17, UIStyle.FONT_BOLD))
		add(UIStyle.text("Resume", tech.effectText, 14, UIStyle.FONT, UIStyle.TEXT_DIM))
		if level >= 1 then
			add(UIStyle.text("Actuel", `✔ Niveau {level} : {tech.levels[level].text}`, 14, UIStyle.FONT_MEDIUM, COMPLETE))
		end
		local queued = queueEntry(tech.id)
		if level >= maxLevel then
			add(UIStyle.text("Max", "Niveau maximum atteint.", 14, UIStyle.FONT_MEDIUM, UIStyle.TEXT_DIM))
			return
		end
		local nextLevel = level + 1
		local entry = tech.levels[nextLevel]
		local speed = TechState.researchSpeed(countryId)
		add(UIStyle.text("Suivant", `➜ Niveau {nextLevel} : {entry.text}`, 14, UIStyle.FONT_MEDIUM))
		local affordable = canAfford(entry.cost)
		add(UIStyle.text("Cout", `Coût : {costText(entry.cost)}{if affordable then "" else ` <font color="#EB5F55">(il manque {missingCostText(entry.cost)})</font>`} · durée : {duration(entry.time / speed)}`, 14))
		if #tech.requires > 0 then
			local parts = {}
			for _, requirement in tech.requires do
				local other = Technologies.get(requirement.id)
				local met = TechState.level(countryId, requirement.id) >= requirement.level
				table.insert(parts, `{if met then "✔" else "✖"} {if other then other.name else requirement.id} niveau {requirement.level}`)
			end
			add(UIStyle.text("Prerequis", `Prérequis : {table.concat(parts, " · ")}`, 14, UIStyle.FONT, UIStyle.TEXT_DIM))
		end
		local actionButton: TextButton
		if queued then
			actionButton = UIStyle.button("Annuler", `✖ Annuler (la moitié du coût est rendue)`, false)
			actionButton.Activated:Connect(function()
				if UIStyle.isEnabled(actionButton) then
					ask("AnnulerRecherche", tech.id)
				end
			end)
		else
			local ok, why = TechState.canResearch(countryId, tech.id)
			actionButton = UIStyle.button("Rechercher", `🔬 Rechercher le niveau {nextLevel}`, true)
			UIStyle.setButtonEnabled(actionButton, ok and affordable and not busy)
			if not ok and why then
				add(UIStyle.text("Raison", why, 13, UIStyle.FONT, UIStyle.WARNING))
			end
			actionButton.Activated:Connect(function()
				if UIStyle.isEnabled(actionButton) then
					ask("Rechercher", tech.id)
				end
			end)
		end
		actionButton.Size = UDim2.new(1, 0, 0, 40)
		actionButton.TextSize = 16
		add(actionButton)
	end

	refreshAll = function(force: boolean?)
		local signature = table.concat({
			tostring(folder:GetAttribute("Technologies")),
			tostring(folder:GetAttribute("Recherches")),
			activeBranch,
			tostring(selectedTechId),
			tostring(busy),
			tostring(message),
			tostring(stock(folder, Resources.currency.id)),
			tostring(stock(folder, "Acier")),
			tostring(stock(folder, "Puces")),
			tostring(stock(folder, "Petrole")),
			tostring(stock(folder, "TerresRares")),
		}, "|")
		if not force and signature == lastSignature then
			return
		end
		lastSignature = signature
		local researched = 0
		for _, tech in Technologies.list do
			researched += math.max(0, TechState.level(countryId, tech.id) - Technologies.startLevel(tech))
		end
		local speed = TechState.researchSpeed(countryId)
		summary.Text = `🔬 {researched} niveau{if researched > 1 then "x" else ""} recherché{if researched > 1 then "s" else ""} · {TechState.slots(countryId)} recherches en parallèle`
			.. (if speed > 1 then ` · vitesse +{math.floor((speed - 1) * 100 + 0.5)} %` else "")
		errorLabel.Visible = message ~= nil
		errorLabel.Text = message or ""
		refreshQueue()
		refreshNodes()
		refreshDetail()
	end

	buildTree()
	refreshAll(true)
	local connection = folder.AttributeChanged:Connect(function()
		if running then
			refreshAll(false)
		end
	end)
	-- barres de progression et temps restant, en continu
	local clock = 0
	local heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		clock += dt
		if clock < 0.2 or not running then
			return
		end
		clock = 0
		local queue = TechState.queue(countryId)
		for index, view in slotViews do
			local r = queue[index]
			if r then
				view.timer.Text = duration(r.finish - workspace:GetServerTimeNow())
				view.fill.Size = UDim2.fromScale(progressOf(r), 1)
			end
		end
		for _, r in queue do
			local view = nodeViews[r.id]
			if view then
				view.progressFill.Size = UDim2.fromScale(progressOf(r), 1)
			end
		end
	end)

	return function()
		running = false
		connection:Disconnect()
		heartbeat:Disconnect()
		frame:Destroy()
	end
end

return ResearchTab
