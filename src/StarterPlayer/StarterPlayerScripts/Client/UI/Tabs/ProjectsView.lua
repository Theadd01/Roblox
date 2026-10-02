--!strict
-- Course aux projets décisifs, dans l'onglet Industrie : les projets, leur effet, le coût d'une
-- étape, les pays en tête (étapes faites, chantier en cours) et les boutons Investir / Saboter.
-- Avant la phase « Course finale » : quand la course commencera. Le serveur valide tout.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Projects = require(Config:WaitForChild("Projects")) :: any
local Match = require(Config:WaitForChild("Match")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local ProjectState = require(Shared:WaitForChild("ProjectState")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local UI = script.Parent.Parent
local UIStyle = require(UI:WaitForChild("UIStyle"))
local Sfx = require(UI.Parent:WaitForChild("Audio"):WaitForChild("Sfx"))

local SHOWN_RACERS = 3 -- pays en tête affichés par projet (plus le tien)
local GREEN = "#78DC82"

local ProjectsView = {}

local function nameOf(countryId: string): string
	return if Countries[countryId] then Countries[countryId].name else countryId
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
	return table.concat(parts, " + ")
end

-- « ▰▰▱▱ 2/4 »
local function bar(stages: number): string
	return string.rep("▰", stages) .. string.rep("▱", Projects.stages - stages) .. ` {stages}/{Projects.stages}`
end

-- Place un bloc de projets dans `container` (LayoutOrder `order`) ; renvoie la fonction d'arrêt
function ProjectsView.build(container: Instance, order: number, countryId: string): () -> ()
	local folder = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Pays"):WaitForChild(countryId)
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local frame = Instance.new("Frame")
	frame.Name = "Projets"
	frame.LayoutOrder = order
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.Parent = container

	local message: string? = nil
	local busy = false
	local lastSignature = ""
	local running = true
	local live: { { label: TextLabel, text: () -> string } } = {} -- comptes à rebours mis à jour chaque seconde
	local render: () -> ()

	local function canAfford(costs: { [string]: number }): boolean
		for id, amount in costs do
			local value = folder:GetAttribute(id)
			if typeof(value) ~= "number" or value < amount then
				return false
			end
		end
		return true
	end

	local function ask(remoteName: string, a: any, b: any)
		if busy then
			return
		end
		busy = true
		local remote = remotes:WaitForChild(remoteName) :: RemoteFunction
		local ok, accepted, reason = pcall(function()
			return remote:InvokeServer(a, b)
		end)
		busy = false
		Sfx.actionResult(remoteName, ok and accepted == true)
		message = if ok and accepted == true then nil elseif ok and typeof(reason) == "string" then reason else "Le serveur ne répond pas."
		lastSignature = ""
		render()
	end

	-- Résumé de ce qui est affiché : on ne redessine que s'il change (évite de perdre un clic)
	local function signature(): string
		local width = workspace.CurrentCamera.ViewportSize.X
		local layoutColumns = if width >= 1050 then 3 elseif width >= 700 then 2 else 1
		local parts = { tostring(ProjectState.isOpen()), message or "", tostring(folder:GetAttribute("Credits")), "colonnes=" .. tostring(layoutColumns) }
		for _, id in Projects.order do
			table.insert(parts, `{id}:{ProjectState.winner(id) or ""}`)
			for _, racer in ProjectState.racers(id) do
				table.insert(parts, `{racer.country}={racer.stages}:{racer.buildingUntil ~= nil}`)
			end
			table.insert(parts, tostring(canAfford(Projects.list[id].stageCost)))
		end
		table.insert(parts, table.concat(DiplomacyState.enemiesOf(countryId), ","))
		return table.concat(parts, "|")
	end

	local count = 0
	local target: Instance = frame
	local function add(instance: GuiObject): GuiObject
		count += 1
		instance.LayoutOrder = count
		instance.Parent = target
		return instance
	end
	local function text(content: string, size: number?, font: Font?, color: Color3?): TextLabel
		return add(UIStyle.text("Texte", content, size or 15, font, color)) :: TextLabel
	end
	local function button(name: string, label: string, primary: boolean, enabled: boolean, onClick: () -> ()): TextButton
		local b = UIStyle.button(name, label, primary)
		b.Size = UDim2.new(1, 0, 0, 40)
		b.TextSize = 15
		b.TextWrapped = true
		UIStyle.setButtonEnabled(b, enabled)
		b.Activated:Connect(function()
			if UIStyle.isEnabled(b) then
				onClick()
			end
		end)
		add(b)
		return b
	end

	render = function()
		local sig = signature()
		if sig == lastSignature then
			return
		end
		lastSignature = sig
		for _, child in frame:GetChildren() do
			child:Destroy()
		end
		table.clear(live)
		count = 0
		target = frame
		UIStyle.list(frame, 6)
		local open = ProjectState.isOpen()
		frame.LayoutOrder = if open then 0 else order -- en tête de l'onglet pendant la course
		text("<b>🚀 Projets décisifs</b>", 19, UIStyle.FONT_BOLD)

		if not open then
			local start = Match.phases[Projects.unlockPhase].start
			local note = text("", 15, UIStyle.FONT, UIStyle.TEXT_DIM)
			local function waitText(): string
				local minutes = math.max(0, math.ceil((start - MatchState.elapsed()) / 60))
				return `La course commence avec la phase « Course finale » (dans {minutes} min). Le premier pays à terminer un projet gagne +{Projects.scoreBonus} points au classement final et un effet jusqu'à la fin de la partie.`
			end
			note.Text = waitText()
			table.insert(live, { label = note, text = waitText })
			return
		end

		text(`Le premier à finir les {Projects.stages} étapes d'un projet gagne <b>+{Projects.scoreBonus} points</b> au classement final. Un seul projet par pays ; chaque étape demande {Projects.stageTime} s de chantier.`, 15, UIStyle.FONT, UIStyle.TEXT_DIM)
		local mine = ProjectState.projectOf(countryId)

		local viewportWidth = workspace.CurrentCamera.ViewportSize.X
		local columns = if viewportWidth >= 1050 then 3 elseif viewportWidth >= 700 then 2 else 1
		local gap = 10
		local tileHeight = 430
		local rows = math.ceil(#Projects.order / columns)
		local grid = Instance.new("Frame")
		grid.Name = "GrilleProjets"
		count += 1
		grid.LayoutOrder = count
		grid.Size = UDim2.new(1, 0, 0, rows * tileHeight + math.max(0, rows - 1) * gap)
		grid.BackgroundTransparency = 1
		local gridLayout = Instance.new("UIGridLayout")
		gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
		gridLayout.FillDirectionMaxCells = columns
		gridLayout.CellPadding = UDim2.fromOffset(gap, gap)
		gridLayout.CellSize = UDim2.new(1 / columns, -gap * (columns - 1) / columns, 0, tileHeight)
		gridLayout.Parent = grid
		grid.Parent = frame

		for projectIndex, id in Projects.order do
			local project = Projects.list[id]
			local winner = ProjectState.winner(id)
			local projectCard = UIStyle.card("Projet_" .. id, tileHeight)
			projectCard.LayoutOrder = projectIndex
			projectCard.ClipsDescendants = true
			projectCard.Parent = grid
			-- Une guerre peut proposer plusieurs sabotages. Le contenu reste donc
			-- accessible dans la carte même s'il dépasse sa hauteur de grille.
			local projectContent = Instance.new("ScrollingFrame")
			projectContent.Name = "Contenu"
			projectContent.Size = UDim2.fromScale(1, 1)
			projectContent.BackgroundTransparency = 1
			projectContent.CanvasSize = UDim2.new()
			projectContent.AutomaticCanvasSize = Enum.AutomaticSize.Y
			projectContent.ScrollingDirection = Enum.ScrollingDirection.Y
			projectContent.ElasticBehavior = Enum.ElasticBehavior.Never
			UIStyle.styleScroll(projectContent)
			UIStyle.padding(projectContent, 12, 12)
			UIStyle.list(projectContent, 7)
			projectContent.Parent = projectCard
			target = projectContent
			text(`{project.icon} <b>{project.name}</b> <font color="{UIStyle.GREY_HEX}">· {project.effectText}</font>`, 17, UIStyle.FONT_BOLD)
			if winner then
				text(`<font color="{GREEN}">✅ Terminé par {FrenchNames.the(nameOf(winner))}{if winner == countryId then " (toi !)" else ""}</font>`, 15)
				target = frame
				continue
			end
			-- pays en tête (et toi)
			local racers = ProjectState.racers(id)
			local shown = 0
			for _, racer in racers do
				shown += 1
				if shown > SHOWN_RACERS and racer.country ~= countryId then
					continue
				end
				local country = Countries[racer.country]
				local label = text("", 15, UIStyle.FONT_MEDIUM, if racer.country == countryId then UIStyle.ACCENT else nil)
				local who = racer.country
				local function racerText(): string
					local untilTime = ProjectState.buildingUntil(id, who)
					local building = if untilTime then `  🏗️ {math.max(0, math.ceil(untilTime - workspace:GetServerTimeNow()))} s` else ""
					return `<font color="#{country and country.color:ToHex() or "FFFFFF"}">●</font> {nameOf(who)}  {bar(ProjectState.stages(id, who))}{building}`
				end
				label.Text = racerText()
				table.insert(live, { label = label, text = racerText })
			end
			if #racers == 0 then
				text("Personne n'a encore lancé ce projet.", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
			end
			-- ton action
			local stages = ProjectState.stages(id, countryId)
			if mine and mine ~= id then
				text(`Tu mènes déjà le projet {Projects.list[mine].name}.`, 14, UIStyle.FONT, UIStyle.TEXT_DIM)
			elseif ProjectState.buildingUntil(id, countryId) then
				text(`🏗️ Ton étape {stages + 1}/{Projects.stages} est en chantier.`, 15, UIStyle.FONT_MEDIUM, UIStyle.ACCENT)
			else
				local affordable = canAfford(project.stageCost)
				button(
					"Investir_" .. id,
					`{if stages == 0 then "Lancer" else "Investir"} : étape {stages + 1}/{Projects.stages} ({costText(project.stageCost)})`,
					true,
					affordable,
					function()
						ask("InvestirProjet", id)
					end
				)
			end
			-- sabotage : les pays en guerre contre toi qui avancent sur ce projet
			for _, racer in racers do
				if racer.country ~= countryId and DiplomacyState.atWar(countryId, racer.country) then
					local target = racer.country
					button(
						"Saboter_" .. id .. "_" .. target,
						`💥 Saboter le chantier {FrenchNames.of(nameOf(target))} ({costText(Projects.sabotage.cost)})`,
						false,
						canAfford(Projects.sabotage.cost),
						function()
							ask("SaboterProjet", id, target)
						end
					)
				end
			end
			target = frame
		end
		if message then
			text(message, 15, UIStyle.FONT_MEDIUM, UIStyle.DANGER)
		end
	end

	render()
	task.spawn(function()
		while running and frame.Parent do
			task.wait(1)
			render()
			for _, entry in live do
				entry.label.Text = entry.text()
			end
		end
	end)
	return function()
		running = false
	end
end

return ProjectsView
