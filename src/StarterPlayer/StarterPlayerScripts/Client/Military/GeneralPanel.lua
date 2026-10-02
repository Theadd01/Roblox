--!strict
-- Fiche d'un général (SYSTEME_MILITAIRE.md, 4.1), ouverte en touchant son modèle sur la carte ou
-- depuis l'onglet Armée : nom, niveau, expérience, traits, quartier général, divisions de son armée.
-- Pour ses propres généraux : ajouter les divisions sélectionnées à l'armée, les en retirer,
-- sélectionner toute l'armée, déplacer le quartier général (toucher ensuite la région), renvoyer.
-- Les ordres partent par CommandeMilitaire ; le serveur vérifie tout.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local MilitaryConfig = require(Config:WaitForChild("Military")) :: any
local GeneralsConfig = require(Config:WaitForChild("Generals")) :: any
local GeneralTraits = require(Shared:WaitForChild("GeneralTraits")) :: any
local Client = script.Parent.Parent
local UIStyle = require(Client:WaitForChild("UI"):WaitForChild("UIStyle"))
local Toast = require(Client:WaitForChild("UI"):WaitForChild("Toast"))
local RegionSelector = require(Client:WaitForChild("Map"):WaitForChild("RegionSelector"))
local CameraController = require(Client:WaitForChild("Map"):WaitForChild("CameraController"))
local MilitaryState = require(script.Parent:WaitForChild("MilitaryState"))
local Selection = require(script.Parent:WaitForChild("Selection"))
local CommandSender = require(script.Parent:WaitForChild("CommandSender"))
local GeneralRenderer = require(script.Parent:WaitForChild("GeneralRenderer"))
local ScreenSpace = require(script.Parent:WaitForChild("ScreenSpace"))

local REFRESH = 0.5
local CONFIRM_TIME = 3 -- secondes pour confirmer le renvoi

local GeneralPanel = {}

local frame: Frame? = nil
local content: ScrollingFrame? = nil
local current: Instance? = nil
local signature = ""
local picking = false -- en attente de la région du nouveau quartier général
local confirmDismiss = 0
local busy = false
-- boutons ajoutés par d'autres modules (plans de bataille : PlanPanel)
local extraButtons: { (general: Instance, parent: Instance, order: number) -> () } = {}

local function myCountry(): string?
	local me = Players.LocalPlayer:GetAttribute("Pays")
	return if typeof(me) == "string" and me ~= "" then me else nil
end

local function regionName(id: unknown): string
	local region = if typeof(id) == "string" then Regions[id] else nil
	return if region then region.name else "?"
end

-- Divisions de l'armée d'un général
function GeneralPanel.divisionsOf(general: Instance): { Instance }
	local list = {}
	for _, d in MilitaryState.list() do
		if d:GetAttribute("Armee") == general.Name then
			table.insert(list, d)
		end
	end
	return list
end

local function send(order: string, data: { [string]: any }, success: string?)
	if busy then
		return
	end
	busy = true
	local accepted, message = CommandSender.send(order, data)
	busy = false
	if not accepted then
		Toast.show(message or "Ordre refusé.", "danger", false)
	elseif message then
		Toast.show(message, "info", false)
	elseif success then
		Toast.show(success, "success", false)
	end
	signature = ""
end

local function render()
	local general, list = current, content
	if not general or not list then
		return
	end
	if not general.Parent then
		GeneralPanel.close()
		return
	end
	local army = GeneralPanel.divisionsOf(general)
	local mine = general:GetAttribute("Proprietaire") == myCountry()
	local parts = { general:GetAttribute("Region"), general:GetAttribute("Destination"), general:GetAttribute("Traits"),
		general:GetAttribute("Niveau"), math.floor((general:GetAttribute("Experience") :: number?) or 0), general:GetAttribute("Desorganise"),
		#army, #Selection.ids(), picking, os.clock() < confirmDismiss, general:GetAttribute("Ordre"), general:GetAttribute("FrontPays"),
		general:GetAttribute("Front"), general:GetAttribute("Objectifs"), general:GetAttribute("Repli"),
		math.floor(((general:GetAttribute("Planification") :: number?) or 0) * 100) }
	local newSignature = ""
	for _, p in parts do
		newSignature ..= tostring(p) .. "|"
	end
	if newSignature == signature then
		return
	end
	signature = newSignature
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local order = 0
	local function add(object: GuiObject)
		order += 1
		object.LayoutOrder = order
		object.Parent = list
	end
	local country = Countries[general:GetAttribute("Proprietaire") :: string]
	local color = if country then country.color else Color3.new(1, 1, 1)
	local level = (general:GetAttribute("Niveau") :: number?) or 1
	local xp = (general:GetAttribute("Experience") :: number?) or 0
	add(UIStyle.text("Titre", `<font color="#{color:ToHex()}">●</font> <b>{general:GetAttribute("Nom")}</b>  {string.rep("★", level)}`, 18, UIStyle.FONT_BOLD))
	local destination = general:GetAttribute("Destination")
	local where = if typeof(destination) == "string" and destination ~= "" then `en route vers {regionName(destination)}` else `quartier général : {regionName(general:GetAttribute("Region"))}`
	add(UIStyle.text("Lieu", `{if country then country.name else "?"} · {where}`, 14, UIStyle.FONT, UIStyle.TEXT_DIM))
	add(UIStyle.text("Niveau", `Niveau {level} · expérience {math.floor(xp)}/100 · armée : {#army}/{MilitaryConfig.maxDivisionsPerArmy} divisions`, 14, UIStyle.FONT, UIStyle.TEXT_DIM))
	if typeof(general:GetAttribute("Desorganise")) == "number" then
		add(UIStyle.text("Desorganise", "⚠️ Quartier général perdu : bonus suspendus un moment.", 14, UIStyle.FONT_MEDIUM, UIStyle.DANGER))
	end
	for _, traitId in GeneralTraits.of(general) do
		add(UIStyle.text("Trait", GeneralTraits.describe(traitId, level), 14))
	end
	local traits = #GeneralTraits.of(general)
	if traits < 3 then
		local next = if traits < 2 then GeneralsConfig.secondTraitLevel else GeneralsConfig.thirdTraitLevel
		add(UIStyle.text("Prochain", `Nouveau trait au niveau {next}.`, 13, UIStyle.FONT, UIStyle.TEXT_DIM))
	end
	if not mine then
		return
	end
	local function button(name: string, text: string, primary: boolean?, enabled: boolean, onClick: () -> ())
		local b = UIStyle.button(name, text, primary)
		b.Size = UDim2.new(1, 0, 0, 36)
		b.TextSize = 15
		UIStyle.setButtonEnabled(b, enabled)
		b.Activated:Connect(function()
			if UIStyle.isEnabled(b) then
				onClick()
			end
		end)
		add(b)
	end
	local selected = Selection.ids()
	button("Ajouter", `➕ Ajouter la sélection à son armée ({#selected})`, true, #selected > 0, function()
		send("AssignerDivisions", { general = general.Name, ids = Selection.ids() }, "Divisions placées sous ses ordres.")
	end)
	button("Retirer", "➖ Retirer la sélection de son armée", false, #selected > 0, function()
		send("RetirerDivisions", { ids = Selection.ids() }, "Divisions en contrôle manuel.")
	end)
	button("Selectionner", `🎯 Sélectionner son armée ({#army})`, false, #army > 0, function()
		Selection.set(GeneralPanel.divisionsOf(general))
	end)
	-- boutons des plans de bataille (M11)
	for _, extra in extraButtons do
		order += 1
		extra(general, list, order)
		order += 20
	end
	button("Deplacer", if picking then "🏠 Touche la région du nouveau QG…" else "🏠 Déplacer le quartier général", false, true, function()
		picking = not picking
		signature = ""
		if picking then
			Toast.show("Touche une de tes régions sans général : ce sera son nouveau quartier général.", "info", false)
		end
	end)
	local confirming = os.clock() < confirmDismiss
	button("Renvoyer", if confirming then "✖ Confirmer le renvoi ?" else "✖ Renvoyer ce général", false, true, function()
		if os.clock() < confirmDismiss then
			confirmDismiss = 0
			send("RenvoyerGeneral", { general = general.Name }, "Général renvoyé : son armée passe en contrôle manuel.")
		else
			confirmDismiss = os.clock() + CONFIRM_TIME
			signature = ""
		end
	end)
end

function GeneralPanel.open(general: Instance)
	current = general
	signature = ""
	picking = false
	if frame then
		frame.Visible = true
	end
	render()
end

-- Ouvre la fiche et centre la caméra sur le général
function GeneralPanel.focus(general: Instance)
	GeneralPanel.open(general)
	local position = GeneralRenderer.positionOf(general)
	if position then
		CameraController.focusOn(position, 60)
	end
end

function GeneralPanel.close()
	current = nil
	picking = false
	if frame then
		frame.Visible = false
	end
end

function GeneralPanel.current(): Instance?
	return current
end

-- Les plans de bataille ajoutent leurs boutons dans la fiche (même ordre d'affichage)
function GeneralPanel.addButtons(builder: (general: Instance, parent: Instance, order: number) -> ())
	table.insert(extraButtons, builder)
end

function GeneralPanel.refresh()
	signature = ""
	render()
end

-- Toucher la carte pendant le choix du quartier général : la région touchée (vrai si utilisé)
function GeneralPanel.handlePick(screenPos: Vector2): boolean
	local general = current
	if not picking or not general then
		return false
	end
	picking = false
	signature = ""
	local regionId = RegionSelector.regionAt(screenPos)
	if regionId then
		task.spawn(send, "DeplacerGeneral", { general = general.Name, region = regionId }, `Le général part pour {regionName(regionId)}.`)
	end
	return true
end

function GeneralPanel.start()
	local gui = Instance.new("ScreenGui")
	gui.Name = "FicheGeneral"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 7
	local f = Instance.new("Frame")
	f.Name = "Panneau"
	f.Active = true
	f.AnchorPoint = Vector2.new(0, 0)
	f.Position = UDim2.new(0, 12, 0, 150)
	f.Size = UDim2.new(1, -24, 0, 300)
	f.BackgroundColor3 = UIStyle.PANEL
	f.BackgroundTransparency = 0.025
	f.Visible = false
	UIStyle.corner(f, 10)
	UIStyle.stroke(f, 0.28)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(360, math.huge)
	limit.Parent = f
	UIStyle.padding(f, 10, 12)
	local close = UIStyle.button("Fermer", "×")
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, 0, 0, 0)
	close.Size = UDim2.fromOffset(32, 28)
	close.TextSize = 16
	close.ZIndex = 2
	close.Parent = f
	close.Activated:Connect(GeneralPanel.close)
	-- contenu qui défile : sur un téléphone, la fiche ne dépasse pas la place libre de l'écran
	local body = Instance.new("ScrollingFrame")
	body.Name = "Contenu"
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.ScrollBarThickness = 4
	body.ScrollBarImageColor3 = UIStyle.ACCENT
	body.ScrollingDirection = Enum.ScrollingDirection.Y
	body.Size = UDim2.fromScale(1, 1)
	body.CanvasSize = UDim2.new()
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	local scrollPadding = Instance.new("UIPadding")
	scrollPadding.PaddingRight = UDim.new(0, 6)
	scrollPadding.Parent = body
	local layout = UIStyle.list(body, 6)
	body.Parent = f
	f.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	frame, content = f, body
	-- hauteur : celle du contenu, sans dépasser la place libre (sous la barre du haut, au-dessus
	-- des barres du bas, ou jusqu'en bas de l'écran sur un téléphone) ; même échelle que le reste
	-- de l'interface
	local function top(): number
		local scale = ScreenSpace.scale()
		return ScreenSpace.topAt(12, 12 + math.min(limit.MaxSize.X, ScreenSpace.width() - 24) * scale)
	end
	local function resize()
		local scale = ScreenSpace.scale()
		local available = (ScreenSpace.sideBottom() - top()) / scale
		local wanted = layout.AbsoluteContentSize.Y / scale + 20
		f.Size = UDim2.new(1, -24, 0, math.max(80, math.min(wanted, available)))
	end
	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(resize)
	ScreenSpace.onChanged(function()
		ScreenSpace.applyScale(f)
		f.Position = UDim2.fromOffset(12, top())
		resize()
	end)
	-- fiche ouverte : le panneau de sélection se place à côté
	local function publish()
		ScreenSpace.setPanel("FicheGeneral", if f.Visible then Rect.new(f.AbsolutePosition, f.AbsolutePosition + f.AbsoluteSize) else nil)
	end
	f:GetPropertyChangedSignal("Visible"):Connect(publish)
	f:GetPropertyChangedSignal("AbsolutePosition"):Connect(publish)
	f:GetPropertyChangedSignal("AbsoluteSize"):Connect(publish)
	Selection.onChanged(function()
		if current then
			render()
		end
	end)
	task.spawn(function()
		while true do
			task.wait(REFRESH)
			if current then
				render()
			end
		end
	end)
end

return GeneralPanel
