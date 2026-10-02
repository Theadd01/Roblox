--!strict
-- Panneau d'une bataille terrestre (cahier des charges v2, section 2), ouvert en touchant son
-- icône : soldats au front et en réserve de chaque camp (l'armée d'un général en une ligne), moral
-- et PV de chaque camp, pertes, modificateurs actifs (terrain, rivière, défenseur, retranchement,
-- fortification, ravitaillement), front et prévision.
-- Purement visuel : tout vient de ReplicatedStorage.EtatMonde (Batailles, Divisions, Regions).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Terrain = require(Config:WaitForChild("Terrain")) :: any
local MilitaryConfig = require(Config:WaitForChild("Military")) :: any
local CombatConfig = require(Config:WaitForChild("CombatConfig")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local Client = script.Parent.Parent
local UIStyle = require(Client:WaitForChild("UI"):WaitForChild("UIStyle"))
local MilitaryState = require(script.Parent:WaitForChild("MilitaryState"))
local ScreenSpace = require(script.Parent:WaitForChild("ScreenSpace"))

local REFRESH = 0.5 -- secondes entre deux mises à jour du panneau ouvert
local ROW_HEIGHT = 26
local GOOD = Color3.fromRGB(105, 205, 126)
local CARD = Color3.fromRGB(26, 31, 41)

local BattlePanel = {}

local frame: Frame? = nil
local titleLabel: TextLabel? = nil
local content: ScrollingFrame? = nil
local current: Instance? = nil -- dossier de la bataille affichée
local signature = ""
local lastSides: { [Instance]: { attackers: { Instance }, defenders: { Instance } } } = {} -- camps vus en dernier

local function myCountry(): string?
	local me = Players.LocalPlayer:GetAttribute("Pays")
	return if typeof(me) == "string" and me ~= "" then me else nil
end

local function countryName(id: unknown): string
	local country = if typeof(id) == "string" then Countries[id] else nil
	return if country then country.name else "?"
end

local function regionName(id: unknown): string
	local region = if typeof(id) == "string" then Regions[id] else nil
	return if region then region.name else "?"
end

local function hex(color: Color3): string
	return "#" .. color:ToHex()
end

local function percent(x: number): string
	return `{math.floor(x * 100 + 0.5)} %`
end

local function signed(x: number): string
	local n = math.floor(x * 100 + 0.5)
	return if n >= 0 then `+{n} %` else `−{-n} %`
end

-- Divisions engagées : attaquants (hors de la région disputée) et défenseurs (dans la région)
local function sides(battle: Instance): ({ Instance }, { Instance })
	local regionId = battle:GetAttribute("Region")
	local attackers, defenders = {}, {}
	for _, d in MilitaryState.list() do
		if d:GetAttribute("Bataille") == battle.Name then
			if d:GetAttribute("Region") == regionId then
				table.insert(defenders, d)
			else
				table.insert(attackers, d)
			end
		end
	end
	local function order(a: Instance, b: Instance): boolean
		local la, lb = a:GetAttribute("EnLigne") == true, b:GetAttribute("EnLigne") == true
		if la ~= lb then
			return la
		end
		return a.Name < b.Name
	end
	table.sort(attackers, order)
	table.sort(defenders, order)
	return attackers, defenders
end

local function orgOf(list: { Instance }): number
	local org, orgMax = 0, 0
	for _, d in list do
		org += (d:GetAttribute("Org") :: number?) or 0
		orgMax += (d:GetAttribute("OrgMax") :: number?) or 0
	end
	return if orgMax > 0 then org / orgMax else 0
end

-- Bloc intérieur arrondi (même rendu avec l'ancien et le nouveau style d'interface)
local function card(name: string): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = UDim2.new(1, 0, 0, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.BackgroundColor3 = CARD
	f.BackgroundTransparency = 0.1
	UIStyle.corner(f, 8)
	return f
end

local function bar(parent: Instance, name: string, ratio: number, color: Color3, height: number, width: UDim, position: UDim2?): Frame
	local back = Instance.new("Frame")
	back.Name = name
	back.Size = UDim2.new(width, UDim.new(0, height))
	back.Position = position or UDim2.new()
	back.BackgroundColor3 = Color3.fromRGB(28, 31, 38)
	back.BorderSizePixel = 0
	local fill = Instance.new("Frame")
	fill.Name = "Remplissage"
	fill.Size = UDim2.fromScale(math.clamp(ratio, 0, 1), 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = back
	UIStyle.corner(back, 2)
	UIStyle.corner(fill, 2)
	back.Parent = parent
	return back
end

-- Une ligne par division : icône et nom, barres de moral (vert) et de PV (orange), au front ou en réserve
local function divisionRow(parent: Instance, d: Instance, order: number)
	local row = Instance.new("Frame")
	row.Name = d.Name
	row.LayoutOrder = order
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	local t = MilitaryState.typeOf(d)
	local name = UIStyle.text("Nom", `{t.icon} {d:GetAttribute("Nom")}`, 14)
	name.AutomaticSize = Enum.AutomaticSize.None
	name.TextWrapped = false
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Size = UDim2.new(0.52, -4, 1, 0)
	name.TextYAlignment = Enum.TextYAlignment.Center
	name.Parent = row
	local org = (d:GetAttribute("Org") :: number?) or 0
	local orgMax = math.max((d:GetAttribute("OrgMax") :: number?) or 1, 1)
	local force = (d:GetAttribute("Force") :: number?) or 0
	bar(row, "Org", org / orgMax, Color3.fromRGB(110, 210, 110), 5, UDim.new(0.22, 0), UDim2.new(0.53, 0, 0, 7))
	bar(row, "Force", force / 100, Color3.fromRGB(240, 160, 60), 5, UDim.new(0.22, 0), UDim2.new(0.53, 0, 0, 14))
	local line = d:GetAttribute("EnLigne") == true
	local state = UIStyle.text("Etat", if line then "au front" else "réserve", 13, UIStyle.FONT, if line then UIStyle.TEXT else UIStyle.TEXT_DIM)
	state.AutomaticSize = Enum.AutomaticSize.None
	state.TextWrapped = false
	state.Size = UDim2.new(0.23, 0, 1, 0)
	state.Position = UDim2.new(0.77, 0, 0, 0)
	state.TextXAlignment = Enum.TextXAlignment.Right
	state.TextYAlignment = Enum.TextYAlignment.Center
	state.Parent = row
	row.Parent = parent
end

local function healthOf(list: { Instance }): number
	local total = 0
	for _, d in list do
		total += ((d:GetAttribute("Force") :: number?) or 0) / 100
	end
	return if #list > 0 then total / #list else 0
end

-- L'armée d'un général en une ligne : nom, troupes au front / en tout, PV moyens
local function armyRow(parent: Instance, generalId: string, troops: { Instance }, order: number)
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local generals = state and state:FindFirstChild("Generaux")
	local general = generals and generals:FindFirstChild(generalId)
	local inLine = 0
	for _, d in troops do
		if d:GetAttribute("EnLigne") == true then
			inLine += 1
		end
	end
	local name = if general then tostring(general:GetAttribute("Nom")) else "Général"
	local row = UIStyle.text("Armee_" .. generalId, `🎖️ <b>{name}</b> : 🪖 {#troops} ({inLine} au front) · PV {percent(healthOf(troops))}`, 14)
	row.LayoutOrder = order
	row.Parent = parent
end

-- Bloc d'un camp : pays, moral et PV, soldats (l'armée d'un général en une ligne)
local function sideBlock(parent: Instance, order: number, title: string, countryId: unknown, list: { Instance }, losses: number)
	local block = card("Camp" .. order)
	block.LayoutOrder = order
	UIStyle.padding(block, 8, 10)
	UIStyle.list(block, 4)
	local country = if typeof(countryId) == "string" then Countries[countryId] else nil
	local color = if country then country.color else Color3.fromRGB(150, 150, 150)
	local inLine = 0
	for _, d in list do
		if d:GetAttribute("EnLigne") == true then
			inLine += 1
		end
	end
	local header = UIStyle.text("Titre", `<font color="{hex(color)}">●</font> <b>{title}</b> : {countryName(countryId)} · {#list} soldat{if #list > 1 then "s" else ""} ({inLine} au front)`, 15, UIStyle.FONT_MEDIUM)
	header.LayoutOrder = 1
	header.Parent = block
	local ratio = orgOf(list)
	local orgLine = UIStyle.text("Moral", `Moral {percent(ratio)} · PV {percent(healthOf(list))}{if losses > 0 then ` · tombés : {losses}` else ""}`, 13, UIStyle.FONT, UIStyle.TEXT_DIM)
	orgLine.LayoutOrder = 2
	orgLine.Parent = block
	local total = bar(block, "BarreOrg", ratio, Color3.fromRGB(110, 210, 110), 6, UDim.new(1, 0))
	total.LayoutOrder = 3
	-- les divisions sur la carte une par une ; l'armée de chaque général en une ligne
	local armies: { [string]: { Instance } } = {}
	local armyOrder: { string } = {}
	local row = 0
	for _, d in list do
		local generalId = d:GetAttribute("Armee")
		if typeof(generalId) == "string" and generalId ~= "" then
			if not armies[generalId] then
				armies[generalId] = {}
				table.insert(armyOrder, generalId)
			end
			table.insert(armies[generalId], d)
		else
			row += 1
			divisionRow(block, d, 10 + row)
		end
	end
	for i, generalId in armyOrder do
		armyRow(block, generalId, armies[generalId], 5 + i)
	end
	block.Parent = parent
end

-- Modificateurs actifs, du point de vue de l'attaquant et du défenseur
local function modifiers(battle: Instance, attackers: { Instance }, defenders: { Instance }): { string }
	local lines = {}
	local terrainId = battle:GetAttribute("Terrain")
	local terrain = Terrain.types[if typeof(terrainId) == "string" then terrainId else Terrain.default] or Terrain.types[Terrain.default]
	table.insert(lines, `{terrain.icon} Terrain : {terrain.name}{if terrain.attack ~= 0 then ` (attaque {signed(terrain.attack)})` else ""}`)
	if battle:GetAttribute("Riviere") == true then
		table.insert(lines, `🌊 Rivière à franchir pour une partie des attaquants (attaque {signed(Terrain.rivers.Riviere.attack)} ou plus)`)
	end
	table.insert(lines, `🛡️ Défenseur : +{math.floor(CombatConfig.defenderBonus * 100 + 0.5)} % de défense (il connaît le terrain)`)
	local entrench = 0
	for _, d in defenders do
		entrench += (d:GetAttribute("Retranchement") :: number?) or 0
	end
	if #defenders > 0 and entrench > 0 then
		table.insert(lines, `⛏️ Retranchement du défenseur : défense {signed(entrench / #defenders * MilitaryConfig.entrenchMax)}`)
	end
	local regions = ReplicatedStorage:WaitForChild("EtatMonde"):FindFirstChild("Regions")
	local region = regions and regions:FindFirstChild(battle:GetAttribute("Region") :: string)
	local fortification = (region and region:GetAttribute("Fortification") :: number?) or 0
	if fortification > 0 then
		table.insert(lines, `🏰 Fortification niveau {fortification} : défense {signed(fortification * MilitaryConfig.fortification.defensePerLevel)}`)
	end
	local function unsupplied(list: { Instance }): number
		local n = 0
		for _, d in list do
			if d:GetAttribute("Ravitaillee") == false then
				n += 1
			end
		end
		return n
	end
	local a, b = unsupplied(attackers), unsupplied(defenders)
	if a + b > 0 then
		table.insert(lines, `📦 Sans ravitaillement : {a} attaquante{if a > 1 then "s" else ""}, {b} en défense (attaque et défense {signed(MilitaryConfig.combat.outOfSupply - 1)})`)
	end
	-- soutien aérien (AirSupport) : supériorité et appui au sol
	local superiority = battle:GetAttribute("Superiorite")
	if superiority == "Attaquant" or superiority == "Defenseur" then
		table.insert(lines, `✈️ Supériorité aérienne : {if superiority == "Attaquant" then "l'attaquant" else "le défenseur"} (attaque et défense jusqu'à {signed(MilitaryConfig.air.superiorityBonus)})`)
	end
	local supportA, supportD = battle:GetAttribute("AppuiAttaque") == true, battle:GetAttribute("AppuiDefense") == true
	if supportA or supportD then
		local who = if supportA and supportD then "les deux camps" elseif supportA then "l'attaquant" else "le défenseur"
		table.insert(lines, `💣 Appui au sol : {who} (moral en moins pour la ligne ennemie)`)
	end
	local directions = battle:GetAttribute("Directions")
	local count = if typeof(directions) == "string" and directions ~= "" then #string.split(directions, ",") else 1
	table.insert(lines, `↔️ Front : {CombatConfig.frontWidth} soldats au plus par camp en même temps ; attaque depuis {count} région{if count > 1 then "s" else ""} voisine{if count > 1 then "s" else ""}`)
	table.insert(lines, `🏳️ Un soldat à 0 PV se replie avec {math.floor(CombatConfig.retreatHealth * 100 + 0.5)} % de PV (il meurt s'il est encerclé) ; un camp à bout de moral se replie`)
	return lines
end

local function forecast(battle: Instance): (string, Color3)
	local prevision = battle:GetAttribute("Prevision")
	local me = myCountry()
	local mine = if me == battle:GetAttribute("Attaquant") then "Attaquant" elseif me == battle:GetAttribute("Defenseur") then "Defenseur" else nil
	if prevision == "Indecis" or prevision == nil then
		return "⚖️ Prévision : indécise", UIStyle.ACCENT
	end
	local text = if prevision == "Attaquant" then "l'attaquant devrait l'emporter" else "le défenseur devrait tenir"
	local color = if mine == nil then UIStyle.TEXT elseif mine == prevision then GOOD else UIStyle.DANGER
	return `🔮 Prévision : {text}`, color
end

local function render()
	local battle, list, title = current, content, titleLabel
	if not battle or not list or not title then
		return
	end
	if not battle.Parent then
		lastSides[battle] = nil
		BattlePanel.close()
		return
	end
	local attackers, defenders = sides(battle)
	-- bataille finie : les divisions ne sont plus engagées, on montre les dernières connues
	if battle:GetAttribute("Etat") ~= "EnCours" and lastSides[battle] then
		attackers, defenders = {}, {}
		for _, d in lastSides[battle].attackers do
			if d.Parent then
				table.insert(attackers, d)
			end
		end
		for _, d in lastSides[battle].defenders do
			if d.Parent then
				table.insert(defenders, d)
			end
		end
	elseif battle:GetAttribute("Etat") == "EnCours" then
		lastSides[battle] = { attackers = attackers, defenders = defenders }
	end
	-- rien n'a changé depuis le dernier dessin : on ne refait rien
	local parts = { tostring(battle:GetAttribute("Etat")), tostring(battle:GetAttribute("Tick")), tostring(battle:GetAttribute("Prevision")) }
	for _, d in attackers do
		table.insert(parts, `{d.Name}{math.floor((d:GetAttribute("Org") :: number?) or 0)}{math.floor((d:GetAttribute("Force") :: number?) or 0)}{d:GetAttribute("EnLigne")}`)
	end
	for _, d in defenders do
		table.insert(parts, `{d.Name}{math.floor((d:GetAttribute("Org") :: number?) or 0)}{math.floor((d:GetAttribute("Force") :: number?) or 0)}{d:GetAttribute("EnLigne")}`)
	end
	local newSignature = table.concat(parts, "|")
	if newSignature == signature then
		return
	end
	signature = newSignature
	title.Text = `⚔️ Bataille : {regionName(battle:GetAttribute("Region"))}`
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local state = battle:GetAttribute("Etat")
	local elapsed = math.max(0, workspace:GetServerTimeNow() - ((battle:GetAttribute("Debut") :: number?) or workspace:GetServerTimeNow()))
	local summary = `{FrenchNames.The(countryName(battle:GetAttribute("Attaquant")))} attaque {FrenchNames.the(countryName(battle:GetAttribute("Defenseur")))} · depuis {math.floor(elapsed)} s`
	if state == "Victoire" then
		summary = `🏆 Région prise par {FrenchNames.the(countryName(battle:GetAttribute("Attaquant")))}`
	elseif state == "Repli" then
		summary = `🛡️ L'attaque a échoué : {FrenchNames.the(countryName(battle:GetAttribute("Defenseur")))} tient la région`
	end
	local summaryLabel = UIStyle.text("Resume", summary, 15)
	summaryLabel.LayoutOrder = 1
	summaryLabel.Parent = list
	if state == "EnCours" then
		local text, color = forecast(battle)
		local forecastLabel = UIStyle.text("Prevision", `<b>{text}</b>`, 15, UIStyle.FONT_MEDIUM, color)
		forecastLabel.LayoutOrder = 2
		forecastLabel.Parent = list
	end
	sideBlock(list, 3, "Attaque", battle:GetAttribute("Attaquant"), attackers, (battle:GetAttribute("PertesAttaque") :: number?) or 0)
	sideBlock(list, 4, "Défense", battle:GetAttribute("Defenseur"), defenders, (battle:GetAttribute("PertesDefense") :: number?) or 0)
	local block = card("Modificateurs")
	block.LayoutOrder = 5
	UIStyle.padding(block, 8, 10)
	UIStyle.list(block, 3)
	local heading = UIStyle.text("Titre", "<b>Modificateurs</b>", 15, UIStyle.FONT_MEDIUM)
	heading.LayoutOrder = 0
	heading.Parent = block
	for i, line in modifiers(battle, attackers, defenders) do
		local label = UIStyle.text("Ligne" .. i, line, 13, UIStyle.FONT, UIStyle.TEXT_DIM)
		label.LayoutOrder = i
		label.Parent = block
	end
	block.Parent = list
end

function BattlePanel.open(battle: Instance)
	current = battle
	signature = ""
	if frame then
		frame.Visible = true
	end
	render()
end

function BattlePanel.close()
	current = nil
	signature = ""
	if frame then
		frame.Visible = false
	end
end

function BattlePanel.isOpen(): boolean
	return current ~= nil
end

function BattlePanel.start()
	local gui = Instance.new("ScreenGui")
	gui.Name = "PanneauBataille"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 7
	local f = Instance.new("Frame")
	f.Name = "Panneau"
	f.Active = true
	f.AnchorPoint = Vector2.new(1, 0)
	f.Position = UDim2.new(1, -12, 0, 150)
	f.Size = UDim2.new(1, -24, 0, 400)
	f.BackgroundColor3 = UIStyle.PANEL
	f.BackgroundTransparency = 0.025
	f.Visible = false
	UIStyle.corner(f, 10)
	UIStyle.stroke(f, 0.28)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(380, 560)
	limit.Parent = f
	local header = Instance.new("Frame")
	header.Name = "Entete"
	header.BackgroundTransparency = 1
	header.Position = UDim2.fromOffset(12, 8)
	header.Size = UDim2.new(1, -24, 0, 34)
	header.Parent = f
	local title = UIStyle.text("Titre", "", 17, UIStyle.FONT_BOLD)
	title.AutomaticSize = Enum.AutomaticSize.None
	title.TextWrapped = false
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.Size = UDim2.new(1, -44, 1, 0)
	title.TextYAlignment = Enum.TextYAlignment.Center
	title.Parent = header
	local close = UIStyle.button("Fermer", "×")
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.new(1, 0, 0.5, 0)
	close.Size = UDim2.fromOffset(36, 30)
	close.TextSize = 18
	close.Parent = header
	close.Activated:Connect(BattlePanel.close)
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Contenu"
	scroll.BackgroundTransparency = 1
	scroll.Position = UDim2.fromOffset(12, 48)
	scroll.Size = UDim2.new(1, -18, 1, -58)
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 5
	scroll.ScrollBarImageColor3 = UIStyle.ACCENT
	UIStyle.list(scroll, 8)
	local padding = Instance.new("UIPadding")
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = scroll
	scroll.Parent = f
	f.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	frame, titleLabel, content = f, title, scroll
	-- place libre à l'écran (téléphone compris), à l'échelle du reste de l'interface, sous les
	-- boutons flottants de la colonne de droite
	ScreenSpace.onChanged(function()
		ScreenSpace.applyScale(f)
		local scale = ScreenSpace.scale()
		local right = ScreenSpace.width() - 12
		local top = ScreenSpace.topAt(right - math.min(limit.MaxSize.X, ScreenSpace.width() - 24) * scale, right)
		f.Position = UDim2.new(1, -12, 0, top)
		f.Size = UDim2.new(1, -24, 0, math.max(120, (ScreenSpace.sideBottom() - top) / scale))
	end)
	-- panneau ouvert : le panneau de sélection se place à côté
	local function publish()
		ScreenSpace.setPanel("PanneauBataille", if f.Visible then Rect.new(f.AbsolutePosition, f.AbsolutePosition + f.AbsoluteSize) else nil)
	end
	f:GetPropertyChangedSignal("Visible"):Connect(publish)
	f:GetPropertyChangedSignal("AbsolutePosition"):Connect(publish)
	f:GetPropertyChangedSignal("AbsoluteSize"):Connect(publish)

	task.spawn(function()
		while true do
			task.wait(REFRESH)
			if current then
				render()
			end
		end
	end)
end

return BattlePanel
