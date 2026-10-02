--!strict
-- Fenêtre modale de commerce : passe de combat, boutique et repères de caméra.
-- Toute attribution reste validée par le serveur ; cette interface ne fait qu'afficher
-- l'état répliqué et envoyer des demandes explicites.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local BattlePass = require(Config:WaitForChild("BattlePass")) :: any
local Monetization = require(Config:WaitForChild("Monetization")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any

local Client = script.Parent.Parent
local CommerceState = require(Client:WaitForChild("State"):WaitForChild("CommerceState"))
local CameraController = require(Client:WaitForChild("Map"):WaitForChild("CameraController"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local ModalHost = require(script.Parent:WaitForChild("ModalHost"))
local Toast = require(script.Parent:WaitForChild("Toast"))

type TabName = "Pass" | "Shop" | "Bookmarks"

local CommerceScreen = {}

local gui: ScreenGui? = nil
local launcher: TextButton? = nil
local launcherLevel: TextLabel? = nil
local overlay: Frame? = nil
local window: Frame? = nil
local body: ScrollingFrame? = nil
local pageTitle: TextLabel? = nil
local identityLabel: TextLabel? = nil
local tabButtons: { [TabName]: TextButton } = {}
local currentTab: TabName = "Pass"
local visible = false
local renderQueued = false

local COLORS = {
	card = UIStyle.PANEL_ALT,
	cardAlt = UIStyle.PANEL_RAISED,
	success = UIStyle.SUCCESS,
	locked = UIStyle.TEXT_DIM,
	blue = UIStyle.INFO,
}

local function plainLabel(name: string, text: string, size: number, font: Font?, color: Color3?): TextLabel
	local label = UIStyle.text(name, text, size, font, color)
	label.RichText = false
	return label
end

local function addLabel(parent: Instance, name: string, text: string, size: number, font: Font?, color: Color3?): TextLabel
	local label = plainLabel(name, text, size, font, color)
	label.Parent = parent
	return label
end

local function addPadding(parent: Instance, top: number, side: number)
	UIStyle.padding(parent, top, side)
end

local function card(parent: Instance, order: number, color: Color3?): Frame
	local frame = Instance.new("Frame")
	frame.Name = "Carte"
	frame.LayoutOrder = order
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = color or COLORS.card
	frame.BackgroundTransparency = 0.04
	UIStyle.corner(frame, 10)
	UIStyle.stroke(frame, 0.86)
	addPadding(frame, 12, 14)
	local layout = UIStyle.list(frame, 7)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	frame.Parent = parent
	return frame
end

local function smallButton(parent: Instance, name: string, text: string, width: number, primary: boolean?): TextButton
	local button = UIStyle.button(name, text, primary)
	button.Size = UDim2.fromOffset(width, 42)
	button.TextSize = 16
	button.Parent = parent
	return button
end

local function actionRow(parent: Instance, name: string, order: number): Frame
	local row = Instance.new("Frame")
	row.Name = name
	row.LayoutOrder = order
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.BackgroundTransparency = 1
	local narrow = workspace.CurrentCamera.ViewportSize.X < 700
	local layout = UIStyle.list(row, 8, not narrow)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	row.Parent = parent
	return row
end

-- Grille de cartes pensée pour une fenêtre PC : trois colonnes quand la place le
-- permet, deux sur une fenêtre moyenne et une seule sur un écran étroit.
local function tileGrid(parent: Instance, name: string, order: number, count: number, height: number, maxColumns: number?): Frame
	local viewport = workspace.CurrentCamera.ViewportSize
	local availableColumns = if viewport.X >= 900 then 3 elseif viewport.X >= 620 then 2 else 1
	local columns = math.max(1, math.min(maxColumns or 3, availableColumns, count))
	local gap = 10
	local rows = math.ceil(count / columns)

	local grid = Instance.new("Frame")
	grid.Name = name
	grid.LayoutOrder = order
	grid.Size = UDim2.new(1, 0, 0, rows * height + math.max(0, rows - 1) * gap)
	grid.BackgroundTransparency = 1

	local layout = Instance.new("UIGridLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.FillDirectionMaxCells = columns
	layout.CellPadding = UDim2.fromOffset(gap, gap)
	layout.CellSize = UDim2.new(1 / columns, -gap * (columns - 1) / columns, 0, height)
	layout.Parent = grid
	grid.Parent = parent
	return grid
end

local function fullWidthButton(parent: Instance, name: string, text: string, primary: boolean?): TextButton
	local button = UIStyle.button(name, text, primary)
	button.Size = UDim2.new(1, 0, 0, 38)
	button.TextSize = 14
	button.Parent = parent
	return button
end

local function actionResult(ok: boolean, message: string)
	Toast.show(message, if ok then "success" else "danger")
end

local function runAction(action: string, payload: any?)
	task.spawn(function()
		local ok, message = CommerceState.invoke(action, payload)
		actionResult(ok, message)
	end)
end

local function clearBody(): Frame?
	local scrolling = body
	if not scrolling then
		return nil
	end
	for _, child in scrolling:GetChildren() do
		child:Destroy()
	end
	local content = Instance.new("Frame")
	content.Name = "Contenu"
	content.BackgroundTransparency = 1
	content.Position = UDim2.fromOffset(12, 12)
	content.Size = UDim2.new(1, -24, 0, 0)
	content.AutomaticSize = Enum.AutomaticSize.Y
	local layout = UIStyle.list(content, 10)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	content.Parent = scrolling
	return content
end

local function equippedTitle(): string
	local id = CommerceState.attribute("EquippedTitle", "")
	return if typeof(id) == "string" and id ~= "" then BattlePass.unlockLabel(id) else "Aucun titre"
end

local function updateLauncher()
	local button = launcher
	if not button then
		return
	end
	local country = player:GetAttribute("Pays")
	button.Visible = not visible and typeof(country) == "string" and country ~= ""
	local level = CommerceState.attribute("Level", 1)
	local medals = CommerceState.attribute("Medals", 0)
	local levelLabel = launcherLevel
	if levelLabel then
		levelLabel.Text = `N.{level}`
	end
	button:SetAttribute("InfoBulleTexte", `Passe de combat · niveau {level} · {medals} médaille{if medals == 1 then "" else "s"}`)
end

local function renderPass(content: Frame)
	local xp = CommerceState.attribute("XP", 0)
	local level = CommerceState.attribute("Level", 1)
	local maxLevel = CommerceState.attribute("MaxLevel", BattlePass.season.maxLevel)
	local startXp = CommerceState.attribute("LevelStartXP", 0)
	local nextXp = CommerceState.attribute("NextLevelXP", BattlePass.season.xpPerLevel)
	local premium = CommerceState.attribute("Premium", false) == true

	local summary = card(content, 1, Color3.fromRGB(35, 39, 48))
	summary.Name = "ResumeSaison"
	addLabel(summary, "Saison", BattlePass.season.name, 26, UIStyle.FONT_BLACK, UIStyle.ACCENT)
	addLabel(summary, "SousTitre", BattlePass.season.subtitle, 15, UIStyle.FONT, UIStyle.TEXT_DIM)
	addLabel(summary, "Niveau", `Niveau {level}/{maxLevel}  •  {xp} XP`, 20, UIStyle.FONT_BOLD)

	local progress = Instance.new("Frame")
	progress.Name = "Progression"
	progress.LayoutOrder = 4
	progress.Size = UDim2.new(1, 0, 0, 12)
	progress.BackgroundColor3 = Color3.fromRGB(58, 64, 76)
	progress.BorderSizePixel = 0
	UIStyle.corner(progress, 6)
	local fill = Instance.new("Frame")
	fill.Name = "Remplissage"
	local ratio = if level >= maxLevel then 1 else math.clamp((xp - startXp) / math.max(1, nextXp - startXp), 0, 1)
	fill.Size = UDim2.fromScale(ratio, 1)
	fill.BackgroundColor3 = UIStyle.ACCENT
	fill.BorderSizePixel = 0
	UIStyle.corner(fill, 6)
	fill.Parent = progress
	progress.Parent = summary

	addLabel(
		summary,
		"EtatPremium",
		if premium then "Piste Premium active • récompenses rétroactives" else "Piste gratuite active • Premium ne donne aucun avantage militaire",
		15,
		UIStyle.FONT_MEDIUM,
		if premium then COLORS.success else UIStyle.TEXT_DIM
	)

	local actions = actionRow(summary, "Actions", 6)
	local claimAll = smallButton(actions, "ToutRecuperer", "Tout récupérer", 170, true)
	claimAll.Activated:Connect(function()
		runAction("ClaimAll")
	end)
	if not premium then
		local offer = Monetization.products.PremiumBattlePass
		local unlock = smallButton(actions, "Premium", CommerceState.priceText("Product", "PremiumBattlePass", offer), 260, false)
		UIStyle.setButtonEnabled(unlock, offer.id > 0)
		unlock.Activated:Connect(function()
			if UIStyle.isEnabled(unlock) then
				local ok, message = CommerceState.promptProduct("PremiumBattlePass")
				actionResult(ok, message)
			end
		end)
	end

	local explainer = card(content, 2, Color3.fromRGB(25, 52, 42))
	explainer.Name = "PromesseEquite"
	addLabel(explainer, "Equilibre", "ÉQUITABLE PAR CONCEPTION", 15, UIStyle.FONT_BLACK, COLORS.success)
	addLabel(explainer, "Texte", "Les deux pistes donnent uniquement des Médailles et des apparences. Aucune ressource, statistique d'unité, vitesse, vision ou production n'est vendue.", 15, UIStyle.FONT)

	local track = Instance.new("ScrollingFrame")
	track.Name = "PisteSaison"
	track.LayoutOrder = 10
	track.Size = UDim2.new(1, 0, 0, 278)
	track.BackgroundColor3 = UIStyle.PANEL
	track.BackgroundTransparency = 0.28
	track.BorderSizePixel = 0
	track.CanvasSize = UDim2.new()
	track.AutomaticCanvasSize = Enum.AutomaticSize.X
	track.ScrollingDirection = Enum.ScrollingDirection.X
	UIStyle.styleScroll(track)
	UIStyle.corner(track, 9)
	UIStyle.stroke(track, 0.62, UIStyle.BORDER_SOFT)
	UIStyle.padding(track, 8, 10)
	local trackLayout = UIStyle.list(track, 10, true)
	trackLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	track.Parent = content

	for index, row in BattlePass.levels do
		local reached = index <= level
		local freeClaimed = CommerceState.isClaimed("Free", index)
		local premiumClaimed = CommerceState.isClaimed("Premium", index)
		local item = card(track, index, if reached then COLORS.card else Color3.fromRGB(23, 27, 35))
		item.Name = "Palier" .. tostring(index)
		item.AutomaticSize = Enum.AutomaticSize.None
		item.Size = UDim2.fromOffset(224, 248)
		local heading = addLabel(item, "Palier", `PALIER {index}`, 18, UIStyle.FONT_BLACK, if reached then UIStyle.ACCENT else COLORS.locked)
		heading.LayoutOrder = 1
		local freeText = addLabel(item, "Gratuit", `GRATUIT\n{row.free.label}`, 14, UIStyle.FONT_BOLD)
		freeText.LayoutOrder = 2
		local premiumText = addLabel(item, "Premium", `PREMIUM\n{row.premium.label}`, 14, UIStyle.FONT_BOLD, UIStyle.ACCENT)
		premiumText.LayoutOrder = 3

		local freeButton = fullWidthButton(item, "Gratuit", if freeClaimed then "✓ Gratuit récupéré" elseif reached then "Récupérer gratuit" else "Gratuit verrouillé", reached and not freeClaimed)
		freeButton.LayoutOrder = 4
		UIStyle.setButtonEnabled(freeButton, reached and not freeClaimed)
		freeButton.Activated:Connect(function()
			if UIStyle.isEnabled(freeButton) then
				runAction("Claim", { track = "Free", level = index })
			end
		end)

		local premiumAvailable = reached and premium and not premiumClaimed
		local premiumButton = fullWidthButton(
			item,
			"Premium",
			if premiumClaimed then "✓ Premium récupéré" elseif not premium then "Passe Premium requis" elseif reached then "Récupérer Premium" else "Premium verrouillé",
			premiumAvailable
		)
		premiumButton.LayoutOrder = 5
		UIStyle.setButtonEnabled(premiumButton, premiumAvailable)
		premiumButton.Activated:Connect(function()
			if UIStyle.isEnabled(premiumButton) then
				runAction("Claim", { track = "Premium", level = index })
			end
		end)
	end
end

local function renderPassOffer(content: Frame, key: string, offer: any, order: number)
	local owned = CommerceState.ownsPass(key)
	local item = card(content, order, if owned then Color3.fromRGB(28, 55, 43) else COLORS.card)
	item.Name = "Passe" .. key
	item.AutomaticSize = Enum.AutomaticSize.None
	addLabel(item, "Nom", offer.name, 20, UIStyle.FONT_BLACK, if owned then COLORS.success else UIStyle.ACCENT)
	addLabel(item, "Description", offer.description, 15, UIStyle.FONT, UIStyle.TEXT_DIM)
	local button = smallButton(item, "Acheter", if owned then "✓ Possédé" else CommerceState.priceText("GamePass", key, offer), 270, not owned)
	button.LayoutOrder = 3
	button.Size = UDim2.new(1, 0, 0, 42)
	UIStyle.setButtonEnabled(button, not owned and offer.id > 0)
	button.Activated:Connect(function()
		if UIStyle.isEnabled(button) then
			local ok, message = CommerceState.promptGamePass(key)
			actionResult(ok, message)
		end
	end)
end

local function renderProductOffer(content: Frame, key: string, offer: any, order: number)
	local item = card(content, order)
	item.Name = "Produit" .. key
	item.AutomaticSize = Enum.AutomaticSize.None
	addLabel(item, "Nom", offer.name, 19, UIStyle.FONT_BLACK)
	addLabel(item, "Description", offer.description, 15, UIStyle.FONT, UIStyle.TEXT_DIM)
	local button = smallButton(item, "Acheter", CommerceState.priceText("Product", key, offer), 270, true)
	button.LayoutOrder = 3
	button.Size = UDim2.new(1, 0, 0, 42)
	UIStyle.setButtonEnabled(button, offer.id > 0)
	button.Activated:Connect(function()
		if UIStyle.isEnabled(button) then
			local ok, message = CommerceState.promptProduct(key)
			actionResult(ok, message)
		end
	end)
end

local function renderShop(content: Frame)
	local medals = CommerceState.attribute("Medals", 0)
	local intro = card(content, 1, Color3.fromRGB(35, 39, 48))
	intro.Name = "ResumeBoutique"
	addLabel(intro, "Titre", "BOUTIQUE ÉQUITABLE", 25, UIStyle.FONT_BLACK, UIStyle.ACCENT)
	addLabel(intro, "Medals", `{medals} Médailles cosmétiques disponibles`, 18, UIStyle.FONT_BOLD)
	addLabel(intro, "Promesse", "Les achats apportent du confort d'organisation ou des cosmétiques. Ils ne changent jamais les chances de gagner.", 15, UIStyle.FONT, UIStyle.TEXT_DIM)
	local saveMode = CommerceState.attribute("SaveMode", "unavailable")
	if saveMode == "studio" then
		addLabel(intro, "Mode", "TEST STUDIO • profil conservé pendant cette session uniquement", 14, UIStyle.FONT_BOLD, COLORS.blue)
	elseif saveMode == "unavailable" then
		addLabel(intro, "Mode", "SAUVEGARDE INDISPONIBLE • achats bloqués par sécurité", 14, UIStyle.FONT_BOLD, UIStyle.DANGER)
	end

	local passesTitle = card(content, 10, Color3.fromRGB(43, 36, 22))
	passesTitle.Name = "TitrePasses"
	addLabel(passesTitle, "Titre", "PASSES PERMANENTS", 18, UIStyle.FONT_BLACK, UIStyle.ACCENT)
	addLabel(passesTitle, "Info", "Confort, personnalisation et organisation — aucune puissance supplémentaire.", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
	local passKeys = { "CommandOffice", "Cartographer", "Herald" }
	local passGrid = tileGrid(content, "GrillePasses", 11, #passKeys, 190, 3)
	for index, key in passKeys do
		renderPassOffer(passGrid, key, Monetization.gamePasses[key], index)
	end

	local cosmeticsTitle = card(content, 20, Color3.fromRGB(32, 41, 52))
	cosmeticsTitle.Name = "TitreCosmetiques"
	addLabel(cosmeticsTitle, "Titre", "DISTINCTIONS EN MÉDAILLES", 18, UIStyle.FONT_BLACK, COLORS.blue)
	addLabel(cosmeticsTitle, "Info", "Gagnées en jouant et via le passe. Elles n'entrent jamais dans l'économie militaire.", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
	local cosmeticGrid = tileGrid(content, "GrilleCosmetiques", 21, #Monetization.cosmetics, 176, 2)
	for index, cosmetic in Monetization.cosmetics do
		local owned = CommerceState.hasUnlock(cosmetic.id)
		local equipped = CommerceState.attribute("EquippedTitle", "") == cosmetic.id
		local item = card(cosmeticGrid, index, if equipped then Color3.fromRGB(31, 57, 45) else COLORS.card)
		item.Name = "Cosmetique" .. cosmetic.id
		item.AutomaticSize = Enum.AutomaticSize.None
		addLabel(item, "Nom", cosmetic.name, 18, UIStyle.FONT_BLACK, if equipped then COLORS.success else UIStyle.TEXT)
		addLabel(item, "Description", cosmetic.description, 14, UIStyle.FONT, UIStyle.TEXT_DIM)
		local text = if equipped then "✓ Équipé" elseif owned then "Équiper" else `{cosmetic.price} Médailles`
		local button = smallButton(item, "Action", text, 210, not equipped)
		button.LayoutOrder = 3
		button.Size = UDim2.new(1, 0, 0, 42)
		UIStyle.setButtonEnabled(button, not equipped)
		button.Activated:Connect(function()
			if not UIStyle.isEnabled(button) then
				return
			end
			if owned then
				runAction("EquipTitle", cosmetic.id)
			else
				runAction("BuyCosmetic", cosmetic.id)
			end
		end)
	end

	local supportTitle = card(content, 40, Color3.fromRGB(42, 31, 37))
	supportTitle.Name = "TitreSoutien"
	addLabel(supportTitle, "Titre", "SOUTENIR LE DÉVELOPPEMENT", 18, UIStyle.FONT_BLACK, Color3.fromRGB(236, 146, 174))
	addLabel(supportTitle, "Info", "Facultatif. Remerciements purement cosmétiques, sans bonus de partie.", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
	local supportKeys = { "SupportSmall", "SupportMedium", "SupportLarge" }
	local supportGrid = tileGrid(content, "GrilleSoutien", 41, #supportKeys, 190, 3)
	for index, key in supportKeys do
		renderProductOffer(supportGrid, key, Monetization.products[key], index)
	end
end

local function currentCameraBookmark(): { slot: number, x: number, z: number, distance: number }?
	local camera = workspace.CurrentCamera
	local viewport = camera.ViewportSize
	local ray = camera:ViewportPointToRay(viewport.X / 2, viewport.Y / 2)
	if math.abs(ray.Direction.Y) < 1e-4 then
		return nil
	end
	local t = (MapSettings.regionTop - ray.Origin.Y) / ray.Direction.Y
	if t < 0 then
		return nil
	end
	local focus = ray.Origin + ray.Direction * t
	return {
		slot = 0,
		x = focus.X,
		z = focus.Z,
		distance = math.clamp((camera.CFrame.Position - focus).Magnitude, MapSettings.camera.minDistance, MapSettings.camera.maxDistance),
	}
end

local function modalClosed()
	if not visible then
		return
	end
	visible = false
	CameraController.setInputEnabled(true)
	updateLauncher()
end

local function close()
	local shade = overlay
	if shade and ModalHost.isOpen(shade) then
		ModalHost.hide(shade)
	else
		if shade then
			shade.Visible = false
		end
		modalClosed()
	end
end

local function renderBookmarks(content: Frame)
	local slots = CommerceState.attribute("BookmarkSlots", Monetization.freeBookmarkSlots)
	local saved = CommerceState.bookmarks()
	local intro = card(content, 1, Color3.fromRGB(35, 39, 48))
	intro.Name = "ResumeReperes"
	addLabel(intro, "Titre", "REPÈRES STRATÉGIQUES", 25, UIStyle.FONT_BLACK, UIStyle.ACCENT)
	addLabel(intro, "Info", `Mémorise instantanément une vue de la carte. {Monetization.freeBookmarkSlots} emplacements gratuits, 6 avec le Bureau du Commandant.`, 15, UIStyle.FONT, UIStyle.TEXT_DIM)
	addLabel(intro, "Equilibre", "Un repère ne révèle aucune information : il replace seulement ta caméra.", 14, UIStyle.FONT_BOLD, COLORS.success)

	for slot = 1, 6 do
		local bookmark = saved[slot]
		local unlocked = slot <= slots
		local item = card(content, 10 + slot, if unlocked then COLORS.card else Color3.fromRGB(24, 27, 33))
		item.Name = "Repere" .. tostring(slot)
		addLabel(item, "Nom", `REPÈRE {slot}`, 18, UIStyle.FONT_BLACK, if unlocked then UIStyle.ACCENT else COLORS.locked)
		if not unlocked then
			addLabel(item, "Etat", "Disponible avec le Bureau du Commandant", 14, UIStyle.FONT, COLORS.locked)
			local offer = Monetization.gamePasses.CommandOffice
			local upgrade = smallButton(item, "Debloquer", CommerceState.priceText("GamePass", "CommandOffice", offer), 270, false)
			upgrade.LayoutOrder = 3
			UIStyle.setButtonEnabled(upgrade, offer.id > 0)
			upgrade.Activated:Connect(function()
				if UIStyle.isEnabled(upgrade) then
					local ok, message = CommerceState.promptGamePass("CommandOffice")
					actionResult(ok, message)
				end
			end)
		else
			if bookmark then
				addLabel(item, "Coordonnees", `Vue enregistrée • X {math.round(bookmark.x)} • Z {math.round(bookmark.z)} • zoom {math.round(bookmark.distance)}`, 14, UIStyle.FONT, UIStyle.TEXT_DIM)
			else
				addLabel(item, "Etat", "Emplacement libre", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
			end

			local actions = actionRow(item, "Actions", 3)
			if bookmark then
				local go = smallButton(actions, "Aller", "Aller au repère", 150, true)
				go.Activated:Connect(function()
					CameraController.focusOn(Vector3.new(bookmark.x, MapSettings.regionTop, bookmark.z), bookmark.distance)
					close()
				end)
			end
			local save = smallButton(actions, "Enregistrer", if bookmark then "Remplacer" else "Enregistrer la vue", 175, not bookmark)
			save.Activated:Connect(function()
				local payload = currentCameraBookmark()
				if not payload then
					actionResult(false, "La caméra ne pointe pas vers la carte.")
					return
				end
				payload.slot = slot
				runAction("SaveBookmark", payload)
			end)
			if bookmark then
				local remove = smallButton(actions, "Supprimer", "Supprimer", 120, false)
				UIStyle.setButtonColor(remove, UIStyle.DANGER, UIStyle.TEXT, 0.1)
				remove.Activated:Connect(function()
					runAction("DeleteBookmark", slot)
				end)
			end
		end
	end
end

local function updateTabs()
	for tab, button in tabButtons do
		UIStyle.setButtonSelected(button, tab == currentTab)
	end
end

local function render()
	renderQueued = false
	if not visible then
		return
	end
	local content = clearBody()
	if not content then
		return
	end
	local title = pageTitle
	if title then
		title.Text = if currentTab == "Pass" then "PASSE DE COMBAT" elseif currentTab == "Shop" then "BOUTIQUE" else "REPÈRES"
	end
	local identity = identityLabel
	if identity then
		identity.Text = equippedTitle()
	end
	updateTabs()
	if currentTab == "Pass" then
		renderPass(content)
	elseif currentTab == "Shop" then
		renderShop(content)
	else
		renderBookmarks(content)
	end
end

local function queueRender()
	updateLauncher()
	if not visible or renderQueued then
		return
	end
	renderQueued = true
	task.defer(render)
end

local function open(tab: TabName?)
	if tab then
		currentTab = tab
	end
	local shade = overlay
	if shade and not ModalHost.show(shade, modalClosed) then
		return
	end
	visible = true
	CameraController.setInputEnabled(false)
	updateLauncher()
	render()
end

local function applyResponsiveLayout()
	local panel = window
	if not panel then
		return
	end
	local viewport = workspace.CurrentCamera.ViewportSize
	if viewport.X < 700 or viewport.Y < 620 then
		panel.Size = UDim2.new(1, -16, 1, -16)
	else
		panel.Size = UDim2.fromOffset(math.min(920, viewport.X - 32), math.min(680, viewport.Y - 40))
	end
	local identity = identityLabel
	if identity then
		identity.Visible = viewport.X >= 700
	end
	local tabWidth = math.clamp(math.floor((viewport.X - 64) / 3), 90, 180)
	for _, button in tabButtons do
		button.Size = UDim2.fromOffset(tabWidth, 42)
	end
	if visible then
		queueRender()
	end
end

function CommerceScreen.create()
	if gui then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")
	local screen = Instance.new("ScreenGui")
	screen.Name = "Commerce"
	screen.ResetOnSpawn = false
	-- Au-dessus des panneaux de jeu et du tutoriel, mais sous les info-bulles.
	screen.DisplayOrder = 20
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui = screen

	local launch = UIStyle.button("OuvrirCommerce", "", false)
	launch.AnchorPoint = Vector2.new(1, 0)
	launch.Position = UDim2.new(1, -248, 0, 8)
	launch.Size = UDim2.fromOffset(86, 46)
	launch.TextSize = 15
	launch.BackgroundColor3 = Color3.fromRGB(42, 35, 22)
	launch:SetAttribute("CouleurBase", launch.BackgroundColor3)
	launch:SetAttribute("IconeAccent", true)
	launch.ZIndex = 2
	launch.Visible = false
	local launchIcon = UIStyle.mountIcon(launch, "Pass", 20, UIStyle.ACCENT)
	launchIcon.Position = UDim2.new(0, 18, 0.5, 0)
	local levelLabel = plainLabel("Niveau", "N.1", 14, UIStyle.FONT_BLACK, UIStyle.TEXT)
	levelLabel.AnchorPoint = Vector2.new(0, 0.5)
	levelLabel.Position = UDim2.new(0, 34, 0.5, 0)
	levelLabel.Size = UDim2.new(1, -40, 1, 0)
	levelLabel.AutomaticSize = Enum.AutomaticSize.None
	levelLabel.TextXAlignment = Enum.TextXAlignment.Center
	levelLabel.TextYAlignment = Enum.TextYAlignment.Center
	levelLabel.ZIndex = 3
	levelLabel.Parent = launch
	launch.Activated:Connect(function()
		open("Pass")
	end)
	launch.Parent = screen
	launcher = launch
	launcherLevel = levelLabel

	local shade = Instance.new("Frame")
	shade.Name = "FondModal"
	shade.Active = true
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.32
	shade.Visible = false
	shade.ZIndex = 10
	shade.Parent = screen
	overlay = shade

	local panel = Instance.new("Frame")
	panel.Name = "Fenetre"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.BackgroundColor3 = UIStyle.PANEL
	panel.BackgroundTransparency = 0.01
	panel.ClipsDescendants = true
	panel.ZIndex = 11
	UIStyle.corner(panel, 14)
	UIStyle.stroke(panel, 0.72)
	panel.Parent = shade
	window = panel

	local header = Instance.new("Frame")
	header.Name = "Entete"
	header.Size = UDim2.new(1, 0, 0, 66)
	header.BackgroundColor3 = Color3.fromRGB(24, 29, 39)
	header.BorderSizePixel = 0
	header.ZIndex = 12
	header.Parent = panel
	local title = plainLabel("Titre", "PASSE DE COMBAT", 24, UIStyle.FONT_BLACK)
	title.Position = UDim2.fromOffset(20, 18)
	title.Size = UDim2.new(1, -150, 0, 32)
	title.AutomaticSize = Enum.AutomaticSize.None
	title.ZIndex = 13
	title.Parent = header
	pageTitle = title
	local identity = plainLabel("Identite", equippedTitle(), 14, UIStyle.FONT_MEDIUM, UIStyle.TEXT_DIM)
	identity.AnchorPoint = Vector2.new(1, 0.5)
	identity.Position = UDim2.new(1, -68, 0.5, 0)
	identity.Size = UDim2.fromOffset(190, 24)
	identity.AutomaticSize = Enum.AutomaticSize.None
	identity.TextXAlignment = Enum.TextXAlignment.Right
	identity.ZIndex = 13
	identity.Parent = header
	identityLabel = identity
	local closeButton = UIStyle.button("Fermer", "×", false)
	closeButton.AnchorPoint = Vector2.new(1, 0.5)
	closeButton.Position = UDim2.new(1, -12, 0.5, 0)
	closeButton.Size = UDim2.fromOffset(44, 44)
	closeButton.TextSize = 28
	closeButton.ZIndex = 13
	closeButton.Activated:Connect(close)
	closeButton.Parent = header

	local tabs = Instance.new("Frame")
	tabs.Name = "Onglets"
	tabs.Position = UDim2.fromOffset(12, 76)
	tabs.Size = UDim2.new(1, -24, 0, 46)
	tabs.BackgroundTransparency = 1
	tabs.ZIndex = 12
	local tabsLayout = UIStyle.list(tabs, 8, true)
	tabsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	tabsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	for index, item in {
		{ id = "Pass" :: TabName, text = "PASSE" },
		{ id = "Shop" :: TabName, text = "BOUTIQUE" },
		{ id = "Bookmarks" :: TabName, text = "REPÈRES" },
	} do
		local button = UIStyle.button(item.id, item.text, false)
		button.LayoutOrder = index
		button.Size = UDim2.fromOffset(180, 42)
		button.TextSize = 16
		button.ZIndex = 13
		button.Activated:Connect(function()
			currentTab = item.id
			local currentBody = body
			if currentBody then
				currentBody.CanvasPosition = Vector2.zero
			end
			render()
		end)
		button.Parent = tabs
		tabButtons[item.id] = button
	end
	tabs.Parent = panel

	local scrolling = Instance.new("ScrollingFrame")
	scrolling.Name = "Corps"
	scrolling.Position = UDim2.fromOffset(0, 130)
	scrolling.Size = UDim2.new(1, 0, 1, -130)
	scrolling.BackgroundTransparency = 1
	UIStyle.styleScroll(scrolling)
	scrolling.CanvasSize = UDim2.new()
	scrolling.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrolling.ScrollingDirection = Enum.ScrollingDirection.Y
	scrolling.ZIndex = 12
	scrolling.Parent = panel
	body = scrolling

	screen.Parent = playerGui
	applyResponsiveLayout()
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(applyResponsiveLayout)
	player:GetAttributeChangedSignal("Pays"):Connect(updateLauncher)
	CommerceState.onChanged(queueRender)
	updateLauncher()
end

function CommerceScreen.open(tab: TabName?)
	open(tab)
end

function CommerceScreen.close()
	close()
end

return CommerceScreen
