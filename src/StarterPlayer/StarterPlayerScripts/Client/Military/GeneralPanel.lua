--!strict
-- Fiche d'un général (cahier des charges v2, 5.2), ouverte en touchant son modèle sur la carte ou
-- depuis l'onglet Armée : un général est UNE armée qui a absorbé ses troupes.
--   nom, niveau, expérience (barre de progression), traits, capacité utilisée / maximale ;
--   liste des troupes : type, nombre, PV moyens ; « Libérer » (vers la région la plus proche) ou
--   « 🗑 » (dissoudre, à confirmer) ;
--   pour ses propres généraux : ajouter des troupes (choix par type et par nombre : TroopPicker)
--   ou la sélection, choisir le bonus d'un niveau gagné, améliorer avec des crédits, renommer,
--   déplacer l'armée ou attaquer (toucher ensuite une région : une région ennemie en guerre est
--   attaquée), attaque continue, arrêter l'offensive, renvoyer.
-- Les ordres partent par CommandeMilitaire ; le serveur vérifie tout (server/Military/Armies).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local MilitaryConfig = require(Config:WaitForChild("Military")) :: any
local GeneralsConfig = require(Config:WaitForChild("Generals")) :: any
local DivisionConfig = require(Config:WaitForChild("Divisions")) :: any
local GeneralTraits = require(Shared:WaitForChild("GeneralTraits")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local Client = script.Parent.Parent
local UIStyle = require(Client:WaitForChild("UI"):WaitForChild("UIStyle"))
local Toast = require(Client:WaitForChild("UI"):WaitForChild("Toast"))
local RegionSelector = require(Client:WaitForChild("Map"):WaitForChild("RegionSelector"))
local RegionView = require(Client:WaitForChild("Map"):WaitForChild("RegionView"))
local CameraController = require(Client:WaitForChild("Map"):WaitForChild("CameraController"))
local MilitaryState = require(script.Parent:WaitForChild("MilitaryState"))
local Selection = require(script.Parent:WaitForChild("Selection"))
local CommandSender = require(script.Parent:WaitForChild("CommandSender"))
local GeneralRenderer = require(script.Parent:WaitForChild("GeneralRenderer"))
local ScreenSpace = require(script.Parent:WaitForChild("ScreenSpace"))
local TroopPicker = require(script.Parent:WaitForChild("TroopPicker"))

local REFRESH = 0.5
local CONFIRM_TIME = 3 -- secondes pour confirmer le renvoi ou la dissolution

local GeneralPanel = {}

local frame: Frame? = nil
local content: ScrollingFrame? = nil
local current: Instance? = nil
local signature = ""
local picking = false -- en attente de la région où envoyer l'armée
local confirmDismiss = 0
local confirmDisband: { type: string, expires: number }? = nil
local renaming = false
local busy = false
local continuous: { [string]: boolean } = {} -- attaque continue choisie, par général

local function myCountry(): string?
	local me = Players.LocalPlayer:GetAttribute("Pays")
	return if typeof(me) == "string" and me ~= "" then me else nil
end

local function regionName(id: unknown): string
	local region = if typeof(id) == "string" then Regions[id] else nil
	return if region then region.name else "?"
end

-- Troupes de l'armée d'un général
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
	elseif message and not success then
		Toast.show(message, "info", false)
	elseif success then
		Toast.show(success, "success", false)
	end
	signature = ""
end

local function capacityOf(general: Instance): number
	local capacity = MilitaryConfig.generals.capacity
	return capacity[math.clamp((general:GetAttribute("Niveau") :: number?) or 1, 1, #capacity)]
end

local function percent(x: number): string
	return `{math.floor(x * 100 + 0.5)} %`
end

local function bar(ratio: number, color: Color3): Frame
	local back = Instance.new("Frame")
	back.Name = "Barre"
	back.Size = UDim2.new(1, 0, 0, 8)
	back.BackgroundColor3 = Color3.fromRGB(28, 31, 38)
	back.BorderSizePixel = 0
	UIStyle.corner(back, 3)
	local fill = Instance.new("Frame")
	fill.Name = "Remplissage"
	fill.Size = UDim2.fromScale(math.clamp(ratio, 0, 1), 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	UIStyle.corner(fill, 3)
	fill.Parent = back
	return back
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
	local parts = { general:GetAttribute("Region"), general:GetAttribute("Destination"), general:GetAttribute("Traits"), general:GetAttribute("Nom"),
		general:GetAttribute("Niveau"), math.floor((general:GetAttribute("Experience") :: number?) or 0), general:GetAttribute("Desorganise"),
		general:GetAttribute("Blesse"), general:GetAttribute("ChoixBonus"), general:GetAttribute("Cible"), general:GetAttribute("AttaqueContinue"),
		#Selection.ids(), picking, renaming, os.clock() < confirmDismiss, continuous[general.Name] }
	for _, effect in MilitaryConfig.generals.choiceOrder do
		table.insert(parts, general:GetAttribute("Bonus_" .. effect))
	end
	for _, d in army do
		table.insert(parts, `{d.Name}{math.floor((d:GetAttribute("Force") :: number?) or 0)}{d:GetAttribute("Bataille")}`)
	end
	local disband = confirmDisband
	table.insert(parts, if disband and os.clock() < disband.expires then disband.type else "")
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
	local function button(name: string, text: string, primary: boolean?, enabled: boolean, onClick: () -> (), parent: Instance?): TextButton
		local b = UIStyle.button(name, text, primary)
		b.Size = UDim2.new(1, 0, 0, 36)
		b.TextSize = 15
		UIStyle.setButtonEnabled(b, enabled)
		b.Activated:Connect(function()
			if UIStyle.isEnabled(b) then
				onClick()
			end
		end)
		if parent then
			b.Parent = parent
		else
			add(b)
		end
		return b
	end
	local G = MilitaryConfig.generals
	local country = Countries[general:GetAttribute("Proprietaire") :: string]
	local color = if country then country.color else Color3.new(1, 1, 1)
	local level = math.clamp((general:GetAttribute("Niveau") :: number?) or 1, 1, G.maxLevel)
	local xp = (general:GetAttribute("Experience") :: number?) or 0
	local capacity = capacityOf(general)

	-- nom (et renommage)
	if mine and renaming then
		local row = Instance.new("Frame")
		row.Name = "Renommer"
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 36)
		local box = Instance.new("TextBox")
		box.Name = "Nom"
		box.ClearTextOnFocus = false
		box.Text = tostring(general:GetAttribute("Nom"))
		box.PlaceholderText = "Nouveau nom"
		box.FontFace = UIStyle.FONT_MEDIUM
		box.TextSize = 16
		box.TextColor3 = UIStyle.TEXT
		box.BackgroundColor3 = UIStyle.PANEL_ALT
		box.Size = UDim2.new(1, -96, 1, 0)
		UIStyle.corner(box, 6)
		box.Parent = row
		local ok = UIStyle.button("Valider", "OK", true)
		ok.AnchorPoint = Vector2.new(1, 0)
		ok.Position = UDim2.new(1, 0, 0, 0)
		ok.Size = UDim2.new(0, 44, 1, 0)
		ok.TextSize = 15
		ok.Parent = row
		local cancelRename = UIStyle.button("AnnulerNom", "×", false)
		cancelRename.AnchorPoint = Vector2.new(1, 0)
		cancelRename.Position = UDim2.new(1, -48, 0, 0)
		cancelRename.Size = UDim2.new(0, 44, 1, 0)
		cancelRename.TextSize = 16
		cancelRename.Parent = row
		ok.Activated:Connect(function()
			local name = box.Text:sub(1, G.nameMaxLength)
			renaming = false
			send("RenommerGeneral", { general = general.Name, nom = name }, "Général renommé.")
		end)
		cancelRename.Activated:Connect(function()
			renaming = false
			signature = ""
			render()
		end)
		add(row)
	else
		add(UIStyle.text("Titre", `<font color="#{color:ToHex()}">●</font> <b>{general:GetAttribute("Nom")}</b>  {string.rep("★", level)}`, 18, UIStyle.FONT_BOLD))
	end
	local destination = general:GetAttribute("Destination")
	local target = general:GetAttribute("Cible")
	local where = if typeof(destination) == "string" and destination ~= "" then `en route vers {regionName(destination)}` else `dans {regionName(general:GetAttribute("Region"))}`
	if typeof(target) == "string" and target ~= "" then
		where ..= ` · ⚔️ attaque {regionName(target)}`
	end
	if general:GetAttribute("AttaqueContinue") == true then
		where ..= " · 🔁 offensive continue"
	end
	add(UIStyle.text("Lieu", `{if country then country.name else "?"} · {where}`, 14, UIStyle.FONT, UIStyle.TEXT_DIM))
	-- niveau et expérience
	local inLevel = if level >= G.maxLevel then 1 else math.clamp((xp - (level - 1) * G.xpPerLevel) / G.xpPerLevel, 0, 1)
	add(UIStyle.text("Niveau", if level >= G.maxLevel then `Niveau {level} (maximum)` else `Niveau {level} · expérience {percent(inLevel)} vers le niveau {level + 1}`, 14, UIStyle.FONT, UIStyle.TEXT_DIM))
	add(bar(inLevel, UIStyle.ACCENT))
	-- capacité
	add(UIStyle.text("Capacite", `🪖 Troupes : <b>{#army}</b>/{capacity}`, 15, UIStyle.FONT_MEDIUM))
	add(bar(#army / math.max(capacity, 1), Color3.fromRGB(110, 170, 230)))
	local hurt = general:GetAttribute("Blesse")
	if typeof(hurt) == "number" then
		add(UIStyle.text("Blesse", `🩹 Blessé : hors combat encore {math.max(0, math.ceil(hurt - workspace:GetServerTimeNow()))} s.`, 14, UIStyle.FONT_MEDIUM, UIStyle.DANGER))
	end
	if typeof(general:GetAttribute("Desorganise")) == "number" then
		add(UIStyle.text("Desorganise", "⚠️ Armée repoussée : bonus suspendus un moment.", 14, UIStyle.FONT_MEDIUM, UIStyle.DANGER))
	end
	-- bonus de ses troupes (niveau, choix, traits)
	local bonusParts = {}
	for _, effect in { "attack", "defense", "speed", "morale", "recovery" } do
		local value = GeneralTraits.total(general, effect)
		if value > 0 then
			local choice = G.choices[effect]
			table.insert(bonusParts, `{choice.icon} {choice.name} +{math.floor(value * 100 + 0.5)} %`)
		end
	end
	if #bonusParts > 0 then
		add(UIStyle.text("Bonus", `Bonus de ses troupes : {table.concat(bonusParts, " · ")}`, 14))
	end
	for _, traitId in GeneralTraits.of(general) do
		add(UIStyle.text("Trait", GeneralTraits.describe(traitId, level), 14))
	end
	local traits = #GeneralTraits.of(general)
	if traits < 3 then
		local nextLevel = if traits < 2 then GeneralsConfig.secondTraitLevel else GeneralsConfig.thirdTraitLevel
		add(UIStyle.text("Prochain", `Nouveau trait au niveau {nextLevel}.`, 13, UIStyle.FONT, UIStyle.TEXT_DIM))
	end
	-- bonus à choisir (niveau gagné)
	local pending = (general:GetAttribute("ChoixBonus") :: number?) or 0
	if mine and pending > 0 then
		add(UIStyle.text("Choix", `🎁 <b>Niveau gagné : choisis un bonus</b>{if pending > 1 then ` ({pending} à choisir)` else ""}`, 15, UIStyle.FONT_MEDIUM, UIStyle.ACCENT))
		for _, effect in G.choiceOrder do
			local choice = G.choices[effect]
			button("Bonus_" .. effect, `{choice.icon} {choice.name} : {choice.text}`, false, true, function()
				send("ChoisirBonusGeneral", { general = general.Name, bonus = effect }, `{choice.icon} Bonus « {choice.name} » choisi.`)
			end)
		end
	end
	-- troupes, par type
	add(UIStyle.text("TitreTroupes", "<b>Troupes</b>", 15, UIStyle.FONT_BOLD))
	local byType: { [string]: { count: number, health: number, fighting: number } } = {}
	for _, d in army do
		local typeId = d:GetAttribute("Type") :: string
		local entry = byType[typeId] or { count = 0, health = 0, fighting = 0 }
		entry.count += 1
		entry.health += ((d:GetAttribute("Force") :: number?) or 0) / 100
		if d:GetAttribute("Bataille") ~= nil then
			entry.fighting += 1
		end
		byType[typeId] = entry
	end
	if #army == 0 then
		add(UIStyle.text("Aucune", "Aucune troupe : ajoute-lui des divisions.", 14, UIStyle.FONT, UIStyle.TEXT_DIM))
	end
	local typeOrder = table.clone(DivisionConfig.order)
	table.insert(typeOrder, "Milice")
	for _, typeId in typeOrder do
		local entry = byType[typeId]
		if not entry then
			continue
		end
		local t = DivisionConfig.types[typeId]
		local row = Instance.new("Frame")
		row.Name = "Troupe_" .. typeId
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 30)
		local label = UIStyle.text("Type", `{t.icon} {t.name} : <b>{entry.count}</b> <font color="{UIStyle.GREY_HEX}">· PV {percent(entry.health / entry.count)}{if entry.fighting > 0 then ` · ⚔️ {entry.fighting}` else ""}</font>`, 14)
		label.AutomaticSize = Enum.AutomaticSize.None
		label.TextWrapped = false
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.Size = UDim2.new(1, if mine then -150 else 0, 1, 0)
		label.TextYAlignment = Enum.TextYAlignment.Center
		label.Parent = row
		if mine then
			local free = entry.count - entry.fighting
			local function small(name: string, text: string, x: number, width: number, enabled: boolean, onClick: () -> ())
				local b = UIStyle.button(name, text, false)
				b.AnchorPoint = Vector2.new(1, 0.5)
				b.Position = UDim2.new(1, -x, 0.5, 0)
				b.Size = UDim2.fromOffset(width, 26)
				b.TextSize = 13
				UIStyle.setButtonEnabled(b, enabled)
				b.Activated:Connect(function()
					if UIStyle.isEnabled(b) then
						onClick()
					end
				end)
				b.Parent = row
			end
			local confirming = disband ~= nil and disband.type == typeId and os.clock() < disband.expires
			small("Supprimer", if confirming then "Sûr ?" else "🗑", 0, 40, free > 0, function()
				if confirming then
					confirmDisband = nil
					send("SupprimerTroupes", { general = general.Name, type = typeId, nombre = 1 }, `{t.icon} 1 division dissoute.`)
				else
					confirmDisband = { type = typeId, expires = os.clock() + CONFIRM_TIME }
					signature = ""
					render()
				end
			end)
			small("LibererTout", "Tout", 44, 44, free > 0, function()
				send("LibererTroupes", { general = general.Name, type = typeId, nombre = free }, nil)
			end)
			small("Liberer", "Libérer 1", 92, 58, free > 0, function()
				send("LibererTroupes", { general = general.Name, type = typeId, nombre = 1 }, nil)
			end)
		end
		add(row)
	end
	if not mine then
		return
	end
	-- actions
	button("Ajouter", "➕ Ajouter des troupes (par type et par nombre)", true, #army < capacity, function()
		TroopPicker.open(general)
	end)
	local selected = Selection.ids()
	if #selected > 0 then
		button("AjouterSelection", `➕ Ajouter la sélection ({#selected})`, false, #army < capacity, function()
			send("AssignerDivisions", { general = general.Name, ids = Selection.ids() }, "Divisions rattachées à son armée.")
		end)
	end
	local isContinuous = continuous[general.Name] == true
	button("Deplacer", if picking then "🧭 Touche une région sur la carte…" else "🧭 Déplacer l'armée / attaquer une région", false, true, function()
		picking = not picking
		signature = ""
		if picking then
			Toast.show("Touche une de tes régions pour y aller, ou une région ennemie (en guerre) pour l'attaquer.", "info", false)
		end
	end)
	button("Continue", `🔁 Attaque continue : {if isContinuous then "oui" else "non"}`, false, true, function()
		continuous[general.Name] = not isContinuous
		signature = ""
		render()
	end)
	if general:GetAttribute("AttaqueContinue") == true or (typeof(target) == "string" and target ~= "") then
		button("Arreter", "⏹ Arrêter l'offensive", false, true, function()
			send("AttaqueContinueGeneral", { general = general.Name, actif = false }, "L'armée s'arrêtera après cette bataille.")
		end)
	end
	if level < G.maxLevel then
		local price = G.upgradeCost[level]
		button("Ameliorer", `⬆️ Améliorer au niveau {level + 1} : {price} 💰`, false, true, function()
			send("AmeliorerGeneral", { general = general.Name }, `⬆️ {general:GetAttribute("Nom")} passe au niveau {level + 1}.`)
		end)
	end
	if not renaming then
		button("Renommer", "✏️ Renommer", false, true, function()
			renaming = true
			signature = ""
			render()
		end)
	end
	local confirmingDismiss = os.clock() < confirmDismiss
	button("Renvoyer", if confirmingDismiss then "✖ Confirmer le renvoi ?" else "✖ Renvoyer ce général (ses troupes sont libérées)", false, true, function()
		if os.clock() < confirmDismiss then
			confirmDismiss = 0
			send("RenvoyerGeneral", { general = general.Name }, "Général renvoyé : ses troupes reviennent sur la carte.")
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
	renaming = false
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

-- Ouvre la fiche puis le choix des troupes (après l'achat d'un général)
function GeneralPanel.openNew(general: Instance)
	GeneralPanel.focus(general)
	TroopPicker.open(general)
end

function GeneralPanel.close()
	current = nil
	picking = false
	renaming = false
	if frame then
		frame.Visible = false
	end
end

function GeneralPanel.current(): Instance?
	return current
end

function GeneralPanel.refresh()
	signature = ""
	render()
end

-- Toucher la carte pendant le choix de la région : l'armée y va, ou l'attaque (vrai si utilisé)
function GeneralPanel.handlePick(screenPos: Vector2): boolean
	local general = current
	if not picking or not general then
		return false
	end
	picking = false
	signature = ""
	local regionId = RegionSelector.regionAt(screenPos)
	if regionId then
		local me = myCountry()
		local owner = RegionView.getOwner(regionId)
		local hostile = me ~= nil and owner ~= nil and owner ~= me and not DiplomacyState.areAllies(me, owner)
		local text = if hostile then `⚔️ L'armée marche sur {regionName(regionId)}.` else `L'armée part pour {regionName(regionId)}.`
		task.spawn(send, "DeplacerGeneral", { general = general.Name, region = regionId, continu = continuous[general.Name] == true }, text)
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
