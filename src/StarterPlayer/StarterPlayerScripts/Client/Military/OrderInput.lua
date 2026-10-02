--!strict
-- Ordres manuels aux divisions sélectionnées (SYSTEME_MILITAIRE.md, 6.1 à 6.3) :
--   PC : clic droit sur une région ; au survol, la région s'illumine en vert (déplacement), en rouge
--     (attaque) ou en gris (impossible : région pleine, pas de chemin, pas en guerre...) et la raison
--     s'affiche près du curseur ;
--   mobile : toucher une région fait apparaître un bouton « Déplacer » / « Attaquer » (ou la raison).
-- Les vérifications ici ne servent qu'à l'affichage : le serveur valide tout (CommandeMilitaire).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local TechState = require(Shared:WaitForChild("TechState")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local CouncilState = require(Shared:WaitForChild("CouncilState")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local Client = script.Parent.Parent
local MilitaryState = require(script.Parent:WaitForChild("MilitaryState"))
local Selection = require(script.Parent:WaitForChild("Selection"))
local CommandSender = require(script.Parent:WaitForChild("CommandSender"))
local ScreenSpace = require(script.Parent:WaitForChild("ScreenSpace"))
local RegionView = require(Client:WaitForChild("Map"):WaitForChild("RegionView"))
local RegionSelector = require(Client:WaitForChild("Map"):WaitForChild("RegionSelector"))
local CameraController = require(Client:WaitForChild("Map"):WaitForChild("CameraController"))
local ArmyState = require(Client:WaitForChild("State"):WaitForChild("ArmyState"))
local UI = Client:WaitForChild("UI")
local UIStyle = require(UI:WaitForChild("UIStyle"))
local Toast = require(UI:WaitForChild("Toast"))
local Sfx = require(Client:WaitForChild("Audio"):WaitForChild("Sfx"))

local BAR_WIDTH = 560 -- bouton d'ordre sur mobile (pixels avant mise à l'échelle)
local BAR_HEIGHT = 48

local COLORS = {
	Deplacer = Color3.fromRGB(90, 210, 110),
	Attaquer = Color3.fromRGB(235, 80, 70),
	Impossible = Color3.fromRGB(150, 150, 150),
}

export type Options = {
	myCountry: () -> string?,
	enabled: () -> boolean,
}

type Verdict = { kind: string, text: string } -- kind : Deplacer, Attaquer ou Impossible

local OrderInput = {}

local options: Options? = nil
local highlight: Highlight? = nil
local tooltip: TextLabel? = nil
local actionBar: Frame? = nil
local actionButton: TextButton? = nil
local actionRegion: string? = nil
local busy = false

local function isTouch(): boolean
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

local function regionName(regionId: string): string
	local region = Regions[regionId]
	return if region then region.name else "?"
end

-- Une de ses flottes est-elle au port dans cette région ? (traversée de la mer)
local function fleetInPort(me: string, regionId: string): boolean
	for _, force in ArmyState.ownedBy(me) do
		if ArmyState.kind(force) == "Mer" and force:GetAttribute("Region") == regionId and not ArmyState.isMoving(force) then
			return true
		end
	end
	return false
end

-- Une division peut-elle atteindre la région (même règle de passage que le serveur, sans les durées) ?
local function reachable(me: string, from: string, goal: string): boolean
	local function passable(regionId: string): boolean
		local owner = RegionView.getOwner(regionId)
		if regionId == goal or owner == me then
			return true
		end
		return owner ~= nil and (DiplomacyState.areAllies(me, owner) or DiplomacyState.atWar(me, owner))
	end
	local seen = { [from] = true }
	local queue = { from }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		if current == goal then
			return true
		end
		local region = Regions[current]
		local port: boolean? = nil
		for _, l in (if region then region.neighbors else {}) do
			local nextId = l.region
			if not seen[nextId] and passable(nextId) then
				if l.bySea then
					if port == nil then
						port = fleetInPort(me, current)
					end
					if not port then
						continue
					end
				end
				seen[nextId] = true
				table.insert(queue, nextId)
			end
		end
	end
	return false
end

-- Que donnerait l'ordre vers cette région ? (affichage seulement)
function OrderInput.evaluate(regionId: string): Verdict?
	local o = options
	local me = o and o.myCountry()
	local selected = Selection.get()
	if not me or #selected == 0 or not Regions[regionId] then
		return nil
	end
	-- place restante (comme le serveur : les divisions qui y restent et celles en route vers elle)
	local occupancy = 0
	for _, d in MilitaryState.inRegion(regionId) do
		if not MilitaryState.isMoving(d) then
			occupancy += 1
		end
	end
	for _, d in MilitaryState.list() do
		if d:GetAttribute("Destination") == regionId and not MilitaryState.isAbsorbed(d) then
			occupancy += 1
		end
	end
	local coming = 0
	for _, d in selected do
		local staying = d:GetAttribute("Region") == regionId and not MilitaryState.isMoving(d)
		if not staying and d:GetAttribute("Destination") ~= regionId then
			coming += 1
		end
	end
	local owner = RegionView.getOwner(regionId)
	local capacity = TechState.stationingCap(owner or me)
	if coming > 0 and occupancy >= capacity then
		return { kind = "Impossible", text = `Région pleine ({capacity} divisions au maximum)` }
	end
	local hostile = owner ~= nil and owner ~= me and not DiplomacyState.areAllies(me, owner)
	if hostile then
		if not DiplomacyState.atWar(me, owner) then
			local country = Countries[owner]
			return { kind = "Impossible", text = `Pas en guerre avec {if country then FrenchNames.the(country.name) else "ce pays"} (déclare la guerre depuis la fiche de la région)` }
		end
		local ceasefire = CouncilState.ceasefireLeft()
		if ceasefire > 0 then
			return { kind = "Impossible", text = `Cessez-le-feu du Conseil mondial ({math.ceil(ceasefire)} s)` }
		end
	end
	local ok = false
	for _, d in selected do
		local from = d:GetAttribute(if MilitaryState.isMoving(d) then "Destination" else "Region") :: string
		if from == regionId or reachable(me, from, regionId) then
			ok = true
			break
		end
	end
	if not ok then
		return { kind = "Impossible", text = "Aucun chemin (pays neutre, ou mer sans flotte au port)" }
	end
	if hostile then
		local defenders = 0
		for _, d in MilitaryState.allInRegion(regionId) do
			if d:GetAttribute("Proprietaire") == owner then
				defenders += 1
			end
		end
		local defense = if defenders > 0 then ` · {defenders} division{if defenders > 1 then "s" else ""} ennemie{if defenders > 1 then "s" else ""}` else " · vide"
		return { kind = "Attaquer", text = `Attaquer {FrenchNames.the(regionName(regionId))}{defense}` }
	end
	return { kind = "Deplacer", text = `Déplacer vers {regionName(regionId)}` }
end

local function send(regionId: string)
	if busy then
		return
	end
	local verdict = OrderInput.evaluate(regionId)
	if verdict and verdict.kind == "Impossible" then
		Sfx.actionResult("DeplacerArmee", false)
		Toast.show(verdict.text, "danger", false)
		return
	end
	busy = true
	local accepted, message = CommandSender.send("Deplacer", { ids = Selection.ids(), region = regionId })
	busy = false
	Sfx.actionResult("DeplacerArmee", accepted)
	if not accepted then
		Toast.show(message or "Ordre refusé.", "danger", false)
	elseif message then
		Toast.show(message, "info", false)
	end
end

local function hideHover()
	if highlight then
		highlight.Enabled = false
	end
	if tooltip then
		tooltip.Visible = false
	end
end

local function showHover(regionId: string?, screenPos: Vector2)
	local verdict = if regionId then OrderInput.evaluate(regionId) else nil
	local h, label = highlight, tooltip
	if not verdict or not h or not label or not regionId then
		hideHover()
		return
	end
	local carte = workspace:FindFirstChild("Carte")
	local regions = carte and carte:FindFirstChild("Regions")
	local model = regions and regions:FindFirstChild(regionId)
	h.Adornee = model
	h.FillColor = COLORS[verdict.kind]
	h.OutlineColor = COLORS[verdict.kind]
	h.Enabled = model ~= nil
	label.Text = verdict.text
	label.TextColor3 = COLORS[verdict.kind]:Lerp(Color3.new(1, 1, 1), 0.35)
	label.Position = UDim2.fromOffset(screenPos.X + 18, screenPos.Y + 14)
	label.Visible = true
end

local function hideAction()
	actionRegion = nil
	if actionBar then
		actionBar.Visible = false
	end
	hideHover()
end

-- Mobile : la région touchée et le bouton d'ordre
local function showAction(regionId: string)
	local verdict = OrderInput.evaluate(regionId)
	local bar, button = actionBar, actionButton
	if not verdict or not bar or not button then
		hideAction()
		return
	end
	actionRegion = regionId
	ScreenSpace.applyScale(bar) -- même échelle que le reste de l'interface (téléphone)
	button.Text = verdict.text
	UIStyle.setButtonColor(button, COLORS[verdict.kind], Color3.fromRGB(15, 17, 20), 0.05)
	bar.Visible = true
	showHover(regionId, Vector2.new(-1000, -1000))
	if tooltip then
		tooltip.Visible = false
	end
	-- au-dessus du panneau de sélection, dans les mêmes colonnes ; s'il est caché (pas assez de
	-- place sur un téléphone), en bas de la place libre, à côté des panneaux ouverts
	local scale = ScreenSpace.scale()
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	local panel = playerGui and playerGui:FindFirstChild("PanneauSelection")
	local frame = panel and panel:FindFirstChild("Panneau")
	if frame and frame:IsA("GuiObject") and frame.Visible then
		bar.Position = UDim2.fromOffset(frame.AbsolutePosition.X + frame.AbsoluteSize.X / 2, frame.AbsolutePosition.Y - 8)
		bar.Size = UDim2.fromOffset(frame.AbsoluteSize.X / scale, BAR_HEIGHT)
	else
		local bottom = ScreenSpace.bottom()
		local x0, x1 = ScreenSpace.band(bottom - BAR_HEIGHT * scale, bottom)
		local width = math.max(0, math.min(BAR_WIDTH * scale, x1 - x0))
		local center = if x1 - x0 >= width then math.clamp(ScreenSpace.width() / 2, x0 + width / 2, x1 - width / 2) else (x0 + x1) / 2
		bar.Position = UDim2.fromOffset(center, bottom)
		bar.Size = UDim2.fromOffset(width / scale, BAR_HEIGHT)
	end
end

-- Toucher (mobile) avec une sélection : choisir la région visée plutôt que vider la sélection
function OrderInput.handleTap(screenPos: Vector2): boolean
	local o = options
	if not o or not o.enabled() or not isTouch() or #Selection.get() == 0 then
		return false
	end
	local regionId = RegionSelector.regionAt(screenPos)
	if not regionId then
		-- toucher la mer : plus de sélection
		hideAction()
		Selection.clear()
		return true
	end
	showAction(regionId)
	return true
end

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "OrdresDivisions"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 6
	local label = Instance.new("TextLabel")
	label.Name = "Infobulle"
	label.BackgroundColor3 = Color3.fromRGB(14, 17, 22)
	label.BackgroundTransparency = 0.15
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Size = UDim2.fromOffset(0, 0)
	label.FontFace = UIStyle.FONT_MEDIUM
	label.TextSize = 15
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Visible = false
	label.Active = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = label
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingBottom = UDim.new(0, 4)
	padding.Parent = label
	label.Parent = gui

	local bar = Instance.new("Frame")
	bar.Name = "Action"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -280)
	bar.Size = UDim2.new(1, -24, 0, BAR_HEIGHT)
	bar.BackgroundTransparency = 1
	bar.Visible = false
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(BAR_WIDTH, BAR_HEIGHT)
	limit.Parent = bar
	local button = UIStyle.button("Ordre", "", true)
	button.Size = UDim2.new(1, -54, 1, 0)
	button.TextSize = 17
	button.Parent = bar
	button.Activated:Connect(function()
		local regionId = actionRegion
		hideAction()
		if regionId then
			send(regionId)
		end
	end)
	local close = UIStyle.button("Fermer", "×")
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.fromScale(1, 0)
	close.Size = UDim2.fromOffset(48, 48)
	close.TextSize = 20
	close.Parent = bar
	close.Activated:Connect(hideAction)
	bar.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	tooltip, actionBar, actionButton = label, bar, button

	local h = Instance.new("Highlight")
	h.Name = "OrdreSurvol"
	h.FillTransparency = 0.6
	h.OutlineTransparency = 0
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Enabled = false
	h.Parent = workspace
	highlight = h
end

function OrderInput.start(opts: Options)
	options = opts
	build()
	-- PC : clic droit sur une région = ordre
	CameraController.onRightTap(function(screenPos: Vector2)
		if not opts.enabled() or #Selection.get() == 0 then
			return
		end
		local regionId = RegionSelector.regionAt(screenPos)
		if regionId then
			task.spawn(send, regionId)
		end
	end)
	-- PC : survol d'une région avec une sélection = vert, rouge ou gris, et la raison
	UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement or isTouch() then
			return
		end
		if not opts.enabled() or #Selection.get() == 0 or processed then
			hideHover()
			return
		end
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		showHover(RegionSelector.regionAt(pos), pos)
	end)
	-- plus de sélection : plus d'ordre en préparation
	Selection.onChanged(function(list: { Instance })
		if #list == 0 then
			hideAction()
		elseif actionRegion then
			showAction(actionRegion)
		end
	end)
end

return OrderInput
