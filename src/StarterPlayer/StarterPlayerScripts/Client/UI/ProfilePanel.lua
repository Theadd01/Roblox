--!strict
-- Profil du compte : bouton Profil en haut à droite. Il montre le niveau de compte (passe de saison,
-- s'il est présent), les parties jouées et gagnées, le meilleur rang, les succès (débloqués ou
-- non) et permet de choisir le titre affiché à côté de son pseudo. Un message salue chaque succès
-- débloqué. Données : Player.Compte (voir server/Session/AccountService).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Achievements = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Achievements")) :: any
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local ModalHost = require(script.Parent:WaitForChild("ModalHost"))
local Toast = require(script.Parent:WaitForChild("Toast"))

local GREEN = "#78DC82"

local ProfilePanel = {}

-- Niveau et expérience du passe de saison (ajouté à part dans le jeu), s'il existe
local function seasonLevel(): (number?, number?)
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local root = state and state:FindFirstChild("Monetisation")
	local mine = root and root:FindFirstChild(tostring(Players.LocalPlayer.UserId))
	if not mine then
		return nil, nil
	end
	return mine:GetAttribute("Level") :: number?, mine:GetAttribute("XP") :: number?
end

function ProfilePanel.start()
	local player = Players.LocalPlayer
	local account = player:WaitForChild("Compte", 60)
	if not account then
		return
	end
	local unlocked = account:WaitForChild("Succes")
	local playerGui = player:WaitForChild("PlayerGui")
	local remotes = ReplicatedStorage:WaitForChild("Remotes")

	-- bouton
	local buttonGui = Instance.new("ScreenGui")
	buttonGui.Name = "BoutonProfil"
	buttonGui.ResetOnSpawn = false
	buttonGui.DisplayOrder = 5
	local button = UIStyle.button("Profil", "")
	button.AnchorPoint = Vector2.new(1, 0)
	button.Position = UDim2.new(1, -194, 0, 8)
	button.Size = UDim2.fromOffset(46, 46)
	button:SetAttribute("InfoBulleTexte", "Profil et distinctions")
	local buttonIcon = UIStyle.mountIcon(button, "Profile", 23, UIStyle.TEXT_DIM)
	button.Parent = buttonGui
	buttonGui.Parent = playerGui

	-- fenêtre
	local gui = Instance.new("ScreenGui")
	gui.Name = "Profil"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	local overlay = Instance.new("TextButton")
	overlay.Name = "FondModal"
	overlay.Active = true
	overlay.AutoButtonColor = false
	overlay.Selectable = false
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = UIStyle.BACKDROP
	overlay.BackgroundTransparency = 0.2
	overlay.BorderSizePixel = 0
	overlay.Text = ""
	overlay.Visible = false
	overlay.Parent = gui
	local panel = UIStyle.panel("Fenetre", UDim.new(1, -32))
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.AutomaticSize = Enum.AutomaticSize.None
	panel.Size = UDim2.new(1, -32, 1, -48)
	panel.ClipsDescendants = true
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(520, 650)
	limit.Parent = panel
	panel.Parent = overlay
	local header = Instance.new("Frame")
	header.Name = "Entete"
	header.Size = UDim2.new(1, 0, 0, 82)
	header.BackgroundColor3 = UIStyle.PANEL_RAISED
	header.BackgroundTransparency = 0.12
	header.BorderSizePixel = 0
	header.Parent = panel
	local overline = UIStyle.text("Rubrique", "DOSSIER DU COMMANDANT", 11, UIStyle.FONT_BOLD, UIStyle.ACCENT)
	overline.AutomaticSize = Enum.AutomaticSize.None
	overline.Position = UDim2.fromOffset(18, 10)
	overline.Size = UDim2.new(1, -36, 0, 16)
	overline.Parent = header
	local headingIcon = UIStyle.mountIcon(header, "Profile", 23, UIStyle.ACCENT)
	headingIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	headingIcon.Position = UDim2.fromOffset(30, 45)
	local heading = UIStyle.text("Titre", "Profil et distinctions", 24, UIStyle.FONT_BLACK)
	heading.AutomaticSize = Enum.AutomaticSize.None
	heading.Position = UDim2.fromOffset(52, 29)
	heading.Size = UDim2.new(1, -70, 0, 32)
	heading.Parent = header
	local subtitle = UIStyle.text("SousTitre", "Progression du compte · titres purement cosmétiques", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
	subtitle.AutomaticSize = Enum.AutomaticSize.None
	subtitle.Position = UDim2.fromOffset(18, 59)
	subtitle.Size = UDim2.new(1, -36, 0, 18)
	subtitle.Parent = header
	local content = Instance.new("ScrollingFrame")
	content.Name = "Contenu"
	content.Position = UDim2.fromOffset(16, 94)
	content.Size = UDim2.new(1, -32, 1, -174)
	content.BackgroundTransparency = 1
	content.CanvasSize = UDim2.new()
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	UIStyle.styleScroll(content)
	content.Parent = panel
	local footer = Instance.new("Frame")
	footer.Name = "Pied"
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.fromScale(0, 1)
	footer.Size = UDim2.new(1, 0, 0, 68)
	footer.BackgroundColor3 = UIStyle.PANEL_ALT
	footer.BackgroundTransparency = 0.08
	footer.BorderSizePixel = 0
	footer.Parent = panel
	local footerDivider = UIStyle.divider("SeparateurPied")
	footerDivider.Parent = footer
	local close = UIStyle.button("Fermer", "Fermer", true)
	close.Position = UDim2.fromOffset(16, 13)
	close.Size = UDim2.new(1, -32, 0, 42)
	close.Parent = footer
	gui.Parent = playerGui

	local message: string? = nil
	local render: () -> ()

	local function chooseTitle(id: string)
		local remote = remotes:WaitForChild("ChoisirTitre") :: RemoteFunction
		local ok, accepted, reason = pcall(function()
			return remote:InvokeServer(id)
		end)
		message = if ok and accepted == true then nil elseif ok and typeof(reason) == "string" then reason else "Le serveur ne répond pas."
		task.defer(render)
	end

	render = function()
		for _, child in content:GetChildren() do
			child:Destroy()
		end
		UIStyle.padding(content, 16, 18)
		UIStyle.list(content, 8)
		local order = 0
		local function add(instance: GuiObject): GuiObject
			order += 1
			instance.LayoutOrder = order
			instance.Parent = content
			return instance
		end
		local function text(value: string, size: number, font: Font?, color: Color3?)
			add(UIStyle.text("Texte", value, size, font, color))
		end

		local title = player:GetAttribute("Titre")
		text(`🏅 <b>{player.DisplayName}</b>`, 24, UIStyle.FONT_BLACK)
		text(if typeof(title) == "string" and title ~= "" then `Titre affiché : <b>« {title} »</b>` else "Aucun titre affiché.", 16, UIStyle.FONT_MEDIUM, UIStyle.ACCENT)
		local level, xp = seasonLevel()
		if level then
			text(`Niveau de compte <b>{level}</b>  <font color="{UIStyle.GREY_HEX}">({xp or 0} XP)</font>`, 16)
		end
		local games = (account:GetAttribute("Parties") :: number?) or 0
		local best = (account:GetAttribute("MeilleurRang") :: number?) or 0
		text(`Parties finies : <b>{games}</b>  ·  Victoires : <b>{account:GetAttribute("Victoires") or 0}</b>  ·  Podiums : <b>{account:GetAttribute("Podiums") or 0}</b>`
			.. (if best > 0 then `  ·  Meilleur rang : <b>{best}{if best == 1 then "er" else "e"}</b>` else ""), 15)

		local count = 0
		for _, a in Achievements.list do
			if unlocked:GetAttribute(a.id) then
				count += 1
			end
		end
		text(`<b>Succès</b>  <font color="{UIStyle.GREY_HEX}">{count}/{#Achievements.list}</font>`, 19, UIStyle.FONT_BOLD)
		local chosen = account:GetAttribute("TitreChoisi")
		-- les succès débloqués d'abord
		local sorted = table.clone(Achievements.list)
		table.sort(sorted, function(x, y)
			local dx, dy = unlocked:GetAttribute(x.id) == true, unlocked:GetAttribute(y.id) == true
			if dx ~= dy then
				return dx
			end
			return (table.find(Achievements.list, x) :: number) < (table.find(Achievements.list, y) :: number)
		end)
		local columns = if workspace.CurrentCamera.ViewportSize.X >= 700 then 2 else 1
		local gap = 8
		local tileHeight = 154
		local grid = Instance.new("Frame")
		grid.Name = "GrilleSucces"
		grid.Size = UDim2.new(1, 0, 0, math.ceil(#sorted / columns) * tileHeight + math.max(0, math.ceil(#sorted / columns) - 1) * gap)
		grid.BackgroundTransparency = 1
		local gridLayout = Instance.new("UIGridLayout")
		gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
		gridLayout.FillDirectionMaxCells = columns
		gridLayout.CellPadding = UDim2.fromOffset(gap, gap)
		gridLayout.CellSize = UDim2.new(1 / columns, -gap * (columns - 1) / columns, 0, tileHeight)
		gridLayout.Parent = grid
		add(grid)

		for index, a in sorted do
			local done = unlocked:GetAttribute(a.id) == true
			local row = UIStyle.card(a.id)
			row.LayoutOrder = index
			row.AutomaticSize = Enum.AutomaticSize.None
			row.BackgroundColor3 = if done then Color3.fromRGB(34, 74, 48) else UIStyle.PANEL_ALT
			row.BackgroundTransparency = if done then 0.2 else 0.12
			UIStyle.padding(row, 8, 10)
			UIStyle.list(row, 4)
			local head = UIStyle.text("Nom", `{if done then a.icon else "🔒"} <b>{a.name}</b>`, 16, UIStyle.FONT_MEDIUM, if done then nil else UIStyle.TEXT_DIM)
			head.LayoutOrder = 1
			head.Parent = row
			local info = UIStyle.text("Texte", `{a.text}  <font color="{if done then GREEN else UIStyle.GREY_HEX}">Titre « {a.title} »</font>`, 14, UIStyle.FONT, UIStyle.TEXT_DIM)
			info.LayoutOrder = 2
			info.Parent = row
			if done then
				local isChosen = chosen == a.id
				local b = UIStyle.button("Porter", if isChosen then "Titre affiché ✓ (retirer)" else "Afficher ce titre")
				b.LayoutOrder = 3
				b.Size = UDim2.new(1, 0, 0, 36)
				b.TextSize = 15
				UIStyle.setButtonSelected(b, isChosen)
				b.Activated:Connect(function()
					chooseTitle(if isChosen then "" else a.id)
				end)
				b.Parent = row
			end
			row.Parent = grid
		end
		if message then
			text(message, 15, UIStyle.FONT_MEDIUM, UIStyle.DANGER)
		end
	end

	-- succès débloqué : un message, et la fenêtre se met à jour
	local known: { [string]: boolean } = {}
	for _, a in Achievements.list do
		known[a.id] = unlocked:GetAttribute(a.id) == true
	end
	unlocked.AttributeChanged:Connect(function(id: string)
		local a = Achievements.get(id)
		if a and unlocked:GetAttribute(id) == true and not known[id] then
			known[id] = true
			Toast.show(`🏅 Succès débloqué : <b>{a.name}</b> — titre « {a.title} » (bouton Profil)`, "success", "Victoire")
		end
		if overlay.Visible then
			render()
		end
	end)
	account.AttributeChanged:Connect(function()
		if overlay.Visible then
			render()
		end
	end)
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		if overlay.Visible then
			render()
		end
	end)
	local function syncButtonState()
		UIStyle.setButtonSelected(button, overlay.Visible)
		UIStyle.setIconColor(buttonIcon, if overlay.Visible then UIStyle.ACCENT else UIStyle.TEXT_DIM)
	end
	button.Activated:Connect(function()
		ModalHost.toggle(overlay, syncButtonState)
		syncButtonState()
		if overlay.Visible then
			message = nil
			render()
		end
	end)
	close.Activated:Connect(function()
		ModalHost.hide(overlay)
		syncButtonState()
	end)
	overlay.Activated:Connect(function()
		ModalHost.hide(overlay)
		syncButtonState()
	end)
	syncButtonState()
end

return ProfilePanel
