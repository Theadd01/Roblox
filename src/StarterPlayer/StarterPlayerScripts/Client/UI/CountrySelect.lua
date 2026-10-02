--!strict
-- Écran de choix du pays (version basique) : la carte sert de sélecteur.
--   Bandeau en haut : « Choisis ton pays », boutons Au hasard / Recommandé pour débuter
--   Fiche en bas : drapeau simplifié, statut (libre ou pris, personnalité de l'IA), difficulté,
--   capitale, territoire, ressources, forces, trésor, situation (guerres), points forts et faibles.
--   Elle se met à jour toute seule pendant qu'elle est ouverte (la partie continue).
--   Bouton « Diriger ce pays » : demande au serveur, qui valide (Remotes.ChoisirPays)
--   Jouer entre amis : la fiche signale le pays d'un ami et ses voisins ; le bouton « Près de mes
--   amis » propose un pays libre voisin d'un ami.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Countries = require(Config:WaitForChild("Countries")) :: any
local FlagCatalog = require(Config:WaitForChild("FlagCatalog")) :: any
local CountrySelection = require(Config:WaitForChild("CountrySelection")) :: any
local CountryStats = require(Shared:WaitForChild("CountryStats")) :: any
local RegionResources = require(Shared:WaitForChild("RegionResources")) :: any
local Personalities = require(Config:WaitForChild("Personalities")) :: any
local Units = require(Config:WaitForChild("Units")) :: any
local CountryInfo = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("CountryInfo"))
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local RegionView = require(script.Parent.Parent:WaitForChild("Map"):WaitForChild("RegionView"))
local Friends = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("Friends"))
local Regions = require(Config:WaitForChild("Regions")) :: any
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local ModalHost = require(script.Parent:WaitForChild("ModalHost"))
local ResourceText = require(script.Parent:WaitForChild("ResourceText"))

export type Options = {
	selectRegion: (regionId: string?) -> (), -- met une région en surbrillance
	focusCountry: (countryId: string) -> (), -- centre la caméra sur un pays
	onConfirmed: (countryId: string) -> (), -- le serveur a accepté le choix
	remoteName: string?, -- demande envoyée au serveur (« ChoisirPays » par défaut, « ChangerDePays » en exil)
}

local REFRESH_INTERVAL = 2 -- secondes entre deux mises à jour de la fiche ouverte
local BANNER_BOTTOM_ATTRIBUTE = "ChoixPaysBandeauBas"
local BANNER_DESKTOP_MIN_WIDTH = 820
local NARROW_SCREEN = 700
local TOP_RIGHT_GUIS: { [string]: boolean } = {
	BoutonProfil = true,
	BoutonAmis = true,
	BoutonMissions = true,
	BoutonParametres = true,
	Commerce = true,
}

local CountrySelect = {}

local options: Options? = nil
local screen: ScreenGui? = nil
local sheet: ScrollingFrame? = nil
local sheetLimit: UISizeConstraint? = nil
local banner: Frame? = nil
local bannerLayout: UIListLayout? = nil
local bannerTitle: TextLabel? = nil
local bannerButtons: { TextButton } = {}
local shown: string? = nil -- pays affiché dans la fiche
local refs: { [string]: any } = {}
local nearButton: TextButton? = nil -- « Près de mes amis »
local openConnections: { RBXScriptConnection } = {}
local hiddenTopRight: { [ScreenGui]: boolean } = {}

local function disconnectOpenConnections()
	for _, connection in openConnections do
		connection:Disconnect()
	end
	table.clear(openConnections)
end

local function hideTopRightGui(instance: Instance)
	if instance:IsA("ScreenGui") and TOP_RIGHT_GUIS[instance.Name] and hiddenTopRight[instance] == nil then
		hiddenTopRight[instance] = instance.Enabled
		instance.Enabled = false
	end
end

local function hideTopRightGuis()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	for _, child in playerGui:GetChildren() do
		hideTopRightGui(child)
	end
	table.insert(openConnections, playerGui.ChildAdded:Connect(hideTopRightGui))
end

local function restoreTopRightGuis()
	for gui, wasEnabled in hiddenTopRight do
		if gui.Parent then
			gui.Enabled = wasEnabled
		end
	end
	table.clear(hiddenTopRight)
end

local function publishBannerBottom()
	local currentBanner = banner
	if currentBanner and currentBanner.Parent then
		Players.LocalPlayer:SetAttribute(BANNER_BOTTOM_ATTRIBUTE, currentBanner.AbsolutePosition.Y + currentBanner.AbsoluteSize.Y)
	end
end

local function toHex(c: Color3): string
	return "#" .. c:ToHex()
end

local function isFree(countryId: string): boolean
	return RegionView.getController(countryId) == nil
end

-- Pays libres, éventuellement filtrés
local function freeCountries(filter: ((string) -> boolean)?): { string }
	local list = {}
	for id in Countries do
		if isFree(id) and (not filter or filter(id)) then
			table.insert(list, id)
		end
	end
	table.sort(list)
	return list
end

-- Pays libres voisins (par la terre ou la mer) d'un pays dirigé par un ami : pays -> ami.
-- Un pays compte plusieurs régions : on regarde les voisines de toutes celles de l'ami.
local function nearFriends(): { [string]: string }
	local near: { [string]: string } = {}
	local friends = Friends.countries()
	for regionId, region in Regions do
		local friendName = friends[RegionView.getOwner(regionId) or ""]
		if friendName then
			for _, link in region.neighbors do
				local id = RegionView.getOwner(link.region)
				if id and Countries[id] and not friends[id] and isFree(id) and not near[id] then
					near[id] = friendName
				end
			end
		end
	end
	return near
end

local function updateNearButton()
	if nearButton then
		nearButton.Visible = next(nearFriends()) ~= nil
	end
end

-- « · Stratège » : titre affiché du joueur qui dirige un pays (succès choisi), s'il en a un
local function titleOf(controller: any): string
	local player = if controller then Players:GetPlayerByUserId(controller.userId) else nil
	local title = player and player:GetAttribute("Titre")
	return if typeof(title) == "string" and title ~= "" then ` · {title}` else ""
end

local function pick(countryId: string)
	local o = options
	if o then
		o.selectRegion(countryId) -- la région principale d'un pays porte son code
		o.focusCountry(countryId)
	end
end

-- keepError : mise à jour périodique, on laisse affiché le dernier message d'erreur
local function refresh(keepError: boolean?)
	local s = sheet
	local countryId = shown
	if not s then
		return
	end
	local country = if countryId then Countries[countryId] else nil
	if not country or not countryId then
		s.Visible = false
		return
	end

	local controller = RegionView.getController(countryId)
	local free = controller == nil
	local difficulty = CountryStats.difficulty(countryId)
	local regions = CountryStats.regionCount(countryId)
	local grey = UIStyle.GREY_HEX

	refs.flag.BackgroundColor3 = country.color
	local hasFlag = FlagCatalog.apply(refs.flag, countryId)
	refs.code.Text = countryId
	refs.code.Visible = not hasFlag or not refs.flag.IsLoaded
	refs.name.Text = country.name
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local folder = state and state:FindFirstChild("Pays") and state.Pays:FindFirstChild(countryId)
	local personality = Personalities.list[folder and folder:GetAttribute("Personnalite") or ""]
	refs.status.Text = if free
		then `<font color="#6EC878">●</font> Libre, géré par l'IA` .. (if personality then ` {personality.icon} {personality.name}` else "")
		else `<font color="{toHex(UIStyle.DANGER)}">●</font> Pris par {controller and controller.name or "?"}` .. titleOf(controller)
	refs.difficulty.Text = `<font color="{grey}">Difficulté</font>   <font color="{toHex(CountrySelection.difficultyColors[difficulty])}"><b>{difficulty}</b></font>`
	refs.capital.Text = `<font color="{grey}">Capitale</font>   {country.capital.name}`
	local owned, conquered, lost = CountryInfo.territory(countryId)
	regions = owned
	refs.regions.Text = `<font color="{grey}">Territoire</font>   {regions} région{if regions > 1 then "s" else ""}`
		.. (if conquered > 0 then `  <font color="#78DC82">+{conquered} conquise{if conquered > 1 then "s" else ""}</font>` else "")
		.. (if lost > 0 then `  <font color="#EB5F55">{lost} perdue{if lost > 1 then "s" else ""}</font>` else "")

	local forces = CountryInfo.forces(countryId)
	local armyParts = {}
	for _, kind in Units.kindOrder do
		local n = forces.armies[kind] or 0
		if n > 0 then
			table.insert(armyParts, `{Units.kinds[kind].icon} {n}`)
		end
	end
	refs.forces.Text = `<font color="{grey}">Forces</font>   ⚔️ {forces.divisions} divisions`
		.. (if #armyParts > 0 then `   {table.concat(armyParts, " ")} ({forces.troops} troupes)` else "")
		.. (if forces.factories > 0 then `   🏭 {forces.factories}` else "")
	local credits = folder and folder:GetAttribute("Credits")
	local stability = folder and folder:GetAttribute("Stabilite")
	refs.economy.Text = `<font color="{grey}">Trésor</font>   💰 {ResourceText.number(if typeof(credits) == "number" then credits else 0)}`
		.. `   <font color="{grey}">Stabilité</font> {if typeof(stability) == "number" then stability else 100} %`
	local wars = CountryInfo.wars(countryId)
	local enemyNames = {}
	for _, id in wars do
		table.insert(enemyNames, if Countries[id] then Countries[id].name else id)
	end
	local bloc = DiplomacyState.blocName(countryId)
	refs.situation.Text = `<font color="{grey}">Situation</font>   `
		.. (if #wars > 0 then `<font color="#FF9A78">⚔️ en guerre : {table.concat(enemyNames, ", ")}</font>` else "☮️ en paix")
		.. (if bloc then `   🤝 {bloc}` else "")
	local strengths, weaknesses = CountryInfo.traits(countryId)
	refs.strengths.Visible = #strengths > 0
	refs.strengths.Text = `<font color="#78DC82"><b>+</b></font> {table.concat(strengths, ", ")}`
	refs.weaknesses.Visible = #weaknesses > 0
	refs.weaknesses.Text = `<font color="#EB5F55"><b>−</b></font> {table.concat(weaknesses, ", ")}`
	local production = RegionResources.countryProduction(countryId, RegionView.getOwner)
	refs.resources.Text = `<font color="{grey}">Ressources</font>   ` .. ResourceText.main(production, 3)
	refs.badge.Visible = free and CountryStats.isRecommended(countryId)
	-- jouer entre amis
	local friendName = Friends.countries()[countryId]
	local nearName = if free then nearFriends()[countryId] else nil
	refs.friends.Visible = friendName ~= nil or nearName ~= nil
	refs.friends.Text = if friendName
		then `👥 Ton ami <b>{friendName}</b> dirige ce pays : choisis un voisin pour vous allier !`
		elseif nearName then `👥 Voisin de ton ami <b>{nearName}</b> : vous pourrez vous allier dans le même bloc.`
		else ""
	if not keepError then
		refs.error.Visible = false
	end
	UIStyle.setButtonEnabled(refs.confirm, free)
	refs.confirm.Text = if free then "Diriger ce pays" else "Déjà pris"
	s.Visible = true
end

local function layoutForScreen()
	local s = sheet
	if not s then
		return
	end
	local viewport = workspace.CurrentCamera.ViewportSize
	local narrow = viewport.X < NARROW_SCREEN
	s.Size = if narrow then UDim2.new(1, -24, 0, 0) else UDim2.new(0, 400, 0, 0)
	s.Position = if narrow then UDim2.new(0, 12, 1, -12) else UDim2.new(0, 16, 1, -16)

	local topBanner, layout, title = banner, bannerLayout, bannerTitle
	if topBanner and layout and title then
		local stacked = viewport.X < BANNER_DESKTOP_MIN_WIDTH
		topBanner.AnchorPoint = Vector2.new(0.5, 0)
		topBanner.Position = UDim2.new(0.5, 0, 0, 10)
		layout.FillDirection = if stacked then Enum.FillDirection.Vertical else Enum.FillDirection.Horizontal
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		if stacked then
			topBanner.AutomaticSize = Enum.AutomaticSize.Y
			topBanner.Size = UDim2.new(1, -24, 0, 0)
			title.AutomaticSize = Enum.AutomaticSize.None
			title.Size = UDim2.new(1, 0, 0, 28)
			title.TextXAlignment = Enum.TextXAlignment.Center
			for _, button in bannerButtons do
				button.Size = UDim2.new(1, 0, 0, 42)
			end
		else
			topBanner.AutomaticSize = Enum.AutomaticSize.XY
			topBanner.Size = UDim2.fromOffset(0, 0)
			title.AutomaticSize = Enum.AutomaticSize.XY
			title.Size = UDim2.fromOffset(0, 0)
			title.TextXAlignment = Enum.TextXAlignment.Left
			for _, button in bannerButtons do
				local width = button:GetAttribute("LargeurBureau")
				button.Size = UDim2.fromOffset(if typeof(width) == "number" then width else 160, 42)
			end
		end
		task.defer(publishBannerBottom)
	end

	local limit = sheetLimit
	if limit then
		local reservedTop = 90
		if topBanner and topBanner.Parent then
			reservedTop = topBanner.AbsolutePosition.Y + topBanner.AbsoluteSize.Y + 10
		end
		-- La fiche est défilable : sa hauteur maximale doit respecter strictement
		-- l'espace laissé par le bandeau, y compris sur un écran très bas.
		local availableHeight = math.max(0, viewport.Y - reservedTop - 12)
		limit.MaxSize = Vector2.new(if narrow then math.max(240, viewport.X - 24) else 400, availableHeight)
	end
end

local function buildBanner(parent: Instance)
	local topBanner = UIStyle.panel("Bandeau", UDim.new(0, 0))
	topBanner.AutomaticSize = Enum.AutomaticSize.XY
	topBanner.AnchorPoint = Vector2.new(0.5, 0)
	topBanner.Position = UDim2.new(0.5, 0, 0, 10)
	UIStyle.padding(topBanner, 10, 16)
	local layout = UIStyle.list(topBanner, 12, true)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center

	local title = UIStyle.text("Titre", "<b>Choisis ton pays</b>", 22, UIStyle.FONT_BOLD)
	title.AutomaticSize = Enum.AutomaticSize.XY
	title.Size = UDim2.fromOffset(0, 0)
	title.TextWrapped = false
	title.LayoutOrder = 1
	title.Parent = topBanner

	local random = UIStyle.button("Hasard", "Au hasard")
	random.LayoutOrder = 2
	random.Size = UDim2.fromOffset(130, 42)
	random:SetAttribute("LargeurBureau", 130)
	random.TextSize = 17
	random.Parent = topBanner
	random.Activated:Connect(function()
		local list = freeCountries()
		if #list > 0 then
			pick(list[math.random(#list)])
		end
	end)

	local recommended = UIStyle.button("Recommande", "Recommandé pour débuter", true)
	recommended.LayoutOrder = 3
	recommended.Size = UDim2.fromOffset(220, 42)
	recommended:SetAttribute("LargeurBureau", 220)
	recommended.TextSize = 17
	recommended.Parent = topBanner
	recommended.Activated:Connect(function()
		local list = freeCountries(CountryStats.isRecommended)
		if #list == 0 then
			list = freeCountries()
		end
		if #list > 0 then
			pick(list[math.random(#list)])
		end
	end)

	-- jouer entre amis : un pays libre voisin d'un ami (visible si un ami dirige un pays)
	local near = UIStyle.button("PresAmis", "")
	near.LayoutOrder = 4
	near.Size = UDim2.fromOffset(190, 42)
	near:SetAttribute("LargeurBureau", 190)
	near:SetAttribute("InfoBulleTexte", "Choisir un pays libre près d'un ami")
	near:SetAttribute("IconeAccent", true)
	local nearIcon = UIStyle.mountIcon(near, "Social", 19, UIStyle.ACCENT)
	nearIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	nearIcon.Position = UDim2.new(0, 21, 0.5, 0)
	local nearLabel = UIStyle.text("Libelle", "Près de mes amis", 15, UIStyle.FONT_BOLD)
	nearLabel.AutomaticSize = Enum.AutomaticSize.None
	nearLabel.Position = UDim2.fromOffset(39, 0)
	nearLabel.Size = UDim2.new(1, -45, 1, 0)
	nearLabel.TextYAlignment = Enum.TextYAlignment.Center
	nearLabel.TextWrapped = false
	nearLabel.Parent = near
	near.Visible = false
	near.Parent = topBanner
	near.Activated:Connect(function()
		local list = {}
		for id in nearFriends() do
			table.insert(list, id)
		end
		if #list > 0 then
			pick(list[math.random(#list)])
		end
	end)
	nearButton = near
	banner = topBanner
	bannerLayout = layout
	bannerTitle = title
	bannerButtons = { random, recommended, near }
	updateNearButton()

	topBanner.Parent = parent
	table.insert(openConnections, topBanner:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		publishBannerBottom()
		layoutForScreen()
	end))
end

local function buildSheet(parent: Instance)
	local s = Instance.new("ScrollingFrame")
	s.Name = "Fiche"
	s.Active = true
	s.AnchorPoint = Vector2.new(0, 1)
	s.Position = UDim2.new(0, 16, 1, -16)
	s.Size = UDim2.new(0, 400, 0, 0)
	s.AutomaticSize = Enum.AutomaticSize.Y
	s.CanvasSize = UDim2.new()
	s.AutomaticCanvasSize = Enum.AutomaticSize.Y
	s.ScrollingDirection = Enum.ScrollingDirection.Y
	s.BackgroundColor3 = UIStyle.PANEL
	s.BackgroundTransparency = 0.025
	s.BorderSizePixel = 0
	s.Visible = false
	UIStyle.corner(s, 10)
	UIStyle.stroke(s, 0.28)
	UIStyle.gradient(s, 0.07)
	UIStyle.styleScroll(s)
	UIStyle.padding(s, 14, 16)
	UIStyle.list(s, 8)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(400, 560)
	limit.Parent = s
	sheetLimit = limit

	-- en-tête : drapeau simplifié + nom + statut
	local header = Instance.new("Frame")
	header.Name = "EnTete"
	header.LayoutOrder = 1
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 54)
	header.Parent = s

	local flag = Instance.new("ImageLabel")
	flag.Name = "Drapeau"
	flag.Size = UDim2.fromOffset(72, 48)
	flag.Position = UDim2.fromOffset(0, 3)
	flag.BackgroundColor3 = Color3.fromRGB(45, 47, 54)
	flag.BorderSizePixel = 0
	flag.Image = ""
	UIStyle.corner(flag, 6)
	UIStyle.stroke(flag, 0.6)
	local code = UIStyle.text("Code", "", 14, UIStyle.FONT_BOLD, Color3.new(1, 1, 1))
	code.Size = UDim2.fromScale(1, 1)
	code.AutomaticSize = Enum.AutomaticSize.None
	code.TextXAlignment = Enum.TextXAlignment.Center
	code.TextStrokeColor3 = Color3.new(0, 0, 0)
	code.TextStrokeTransparency = 0.25
	code.ZIndex = 2
	code.Parent = flag
	flag:GetPropertyChangedSignal("IsLoaded"):Connect(function()
		code.Visible = not flag.IsLoaded
	end)
	flag.Parent = header

	local name = UIStyle.text("Nom", "", 26, UIStyle.FONT_BOLD)
	name.Position = UDim2.fromOffset(86, 0)
	name.Size = UDim2.new(1, -86, 0, 30)
	name.AutomaticSize = Enum.AutomaticSize.None
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.TextWrapped = false
	name.Parent = header
	local status = UIStyle.text("Statut", "", 15, UIStyle.FONT_MEDIUM, UIStyle.TEXT_DIM)
	status.Position = UDim2.fromOffset(86, 32)
	status.Size = UDim2.new(1, -86, 0, 20)
	status.AutomaticSize = Enum.AutomaticSize.None
	status.Parent = header

	local badge = UIStyle.text("Badge", "★ Recommandé pour débuter", 15, UIStyle.FONT_BOLD, UIStyle.ACCENT)
	badge.LayoutOrder = 2
	badge.Parent = s

	local rows = {}
	for i, key in { "difficulty", "capital", "regions", "resources", "forces", "economy", "situation", "strengths", "weaknesses" } do
		local row = UIStyle.text(key, "", if i <= 4 then 17 else 16)
		row.LayoutOrder = 2 + i
		row.Parent = s
		rows[key] = row
	end

	local friends = UIStyle.text("Amis", "", 15, UIStyle.FONT_MEDIUM, UIStyle.ACCENT)
	friends.LayoutOrder = 12
	friends.Visible = false
	friends.Parent = s

	local confirm = UIStyle.button("Confirmer", "Diriger ce pays", true)
	confirm.LayoutOrder = 20
	confirm.Parent = s
	local err = UIStyle.text("Erreur", "", 15, UIStyle.FONT_MEDIUM, UIStyle.DANGER)
	err.LayoutOrder = 21
	err.Visible = false
	err.Parent = s

	confirm.Activated:Connect(function()
		local countryId = shown
		local o = options
		if not countryId or not o or not UIStyle.isEnabled(confirm) then
			return
		end
		UIStyle.setButtonEnabled(confirm, false)
		confirm.Text = "..."
		local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild(o.remoteName or "ChoisirPays") :: RemoteFunction
		local ok, accepted, message = pcall(function()
			return remote:InvokeServer(countryId)
		end)
		if ok and accepted == true then
			CountrySelect.close()
			o.onConfirmed(countryId)
		else
			refresh()
			err.Text = if ok and typeof(message) == "string" then message else "Le serveur ne répond pas, réessaie."
			err.Visible = true
		end
	end)

	s.Parent = parent
	sheet = s
	refs = {
		flag = flag,
		code = code,
		name = name,
		status = status,
		badge = badge,
		difficulty = rows.difficulty,
		capital = rows.capital,
		regions = rows.regions,
		resources = rows.resources,
		forces = rows.forces,
		economy = rows.economy,
		situation = rows.situation,
		strengths = rows.strengths,
		weaknesses = rows.weaknesses,
		friends = friends,
		confirm = confirm,
		error = err,
	}
end

-- Ouvre l'écran de choix
function CountrySelect.open(opts: Options)
	ModalHost.hideAtMost(0)
	CountrySelect.close()
	options = opts
	local gui = Instance.new("ScreenGui")
	gui.Name = "ChoixPays"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	buildBanner(gui)
	buildSheet(gui)
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	screen = gui
	hideTopRightGuis()
	layoutForScreen()
	table.insert(openConnections, workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(layoutForScreen))
	RegionView.onControllerChanged(function(countryId: string)
		if screen == gui and countryId == shown then
			refresh()
		end
	end)
	Friends.onChanged(function()
		if screen == gui then
			updateNearButton()
			refresh(true)
		end
	end)
	-- la partie continue pendant le choix : forces, guerres et trésor changent
	task.spawn(function()
		while screen == gui do
			task.wait(REFRESH_INTERVAL)
			updateNearButton()
			if screen == gui and shown and not (refs.confirm and refs.confirm.Text == "...") then
				refresh(true)
			end
		end
	end)
end

-- Une région a été cliquée sur la carte (nil = clic dans la mer)
function CountrySelect.select(regionId: string?)
	shown = if regionId then RegionView.getOwner(regionId) else nil
	refresh()
end

function CountrySelect.close()
	disconnectOpenConnections()
	restoreTopRightGuis()
	Players.LocalPlayer:SetAttribute(BANNER_BOTTOM_ATTRIBUTE, nil)
	if screen then
		screen:Destroy()
	end
	screen, sheet, sheetLimit, banner, bannerLayout, bannerTitle, shown = nil, nil, nil, nil, nil, nil, nil
	options = nil
	table.clear(refs)
	table.clear(bannerButtons)
	nearButton = nil
end

return CountrySelect
