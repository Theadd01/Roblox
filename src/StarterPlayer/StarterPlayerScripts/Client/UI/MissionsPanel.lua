--!strict
-- Missions du jour : bouton « 📅 1/3 » en haut à droite (à gauche du ⚙️) qui ouvre la liste des
-- missions (texte, progression, expérience de compte) et le temps avant les suivantes.
-- Un message salue chaque mission accomplie. Données publiées par le serveur dans
-- Player.MissionsDuJour (voir server/Session/DailyMissions).

local Players = game:GetService("Players")

local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local ModalHost = require(script.Parent:WaitForChild("ModalHost"))
local Toast = require(script.Parent:WaitForChild("Toast"))

local MissionsPanel = {}

local function items(folder: Instance): { Instance }
	local list = folder:GetChildren()
	table.sort(list, function(a, b)
		return ((a:GetAttribute("Ordre") :: number?) or 0) < ((b:GetAttribute("Ordre") :: number?) or 0)
	end)
	return list
end

-- « 5 h 12 min »
local function duration(seconds: number): string
	local h = seconds // 3600
	local m = (seconds % 3600) // 60
	return if h > 0 then `{h} h {m} min` else `{math.max(1, m)} min`
end

function MissionsPanel.start()
	local player = Players.LocalPlayer
	local folder = player:WaitForChild("MissionsDuJour", 60)
	if not folder then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")

	-- bouton
	local buttonGui = Instance.new("ScreenGui")
	buttonGui.Name = "BoutonMissions"
	buttonGui.ResetOnSpawn = false
	buttonGui.DisplayOrder = 5
	local button = UIStyle.button("Missions", "")
	button.AnchorPoint = Vector2.new(1, 0)
	button.Position = UDim2.new(1, -66, 0, 8)
	button.Size = UDim2.fromOffset(66, 46)
	local buttonIcon = UIStyle.mountIcon(button, "Missions", 20, UIStyle.TEXT_DIM)
	buttonIcon.Position = UDim2.new(0, 17, 0.5, 0)
	local counter = UIStyle.text("Compteur", "0/0", 14, UIStyle.FONT_BOLD)
	counter.AutomaticSize = Enum.AutomaticSize.None
	counter.Position = UDim2.fromOffset(32, 0)
	counter.Size = UDim2.new(1, -36, 1, 0)
	counter.TextXAlignment = Enum.TextXAlignment.Center
	counter.TextYAlignment = Enum.TextYAlignment.Center
	counter.Parent = button
	button.Parent = buttonGui
	buttonGui.Parent = playerGui

	-- fenêtre
	local gui = Instance.new("ScreenGui")
	gui.Name = "MissionsDuJour"
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
	limit.MaxSize = Vector2.new(460, 600)
	limit.Parent = panel
	panel.Parent = overlay
	local header = Instance.new("Frame")
	header.Name = "Entete"
	header.Size = UDim2.new(1, 0, 0, 88)
	header.BackgroundColor3 = UIStyle.PANEL_RAISED
	header.BackgroundTransparency = 0.12
	header.BorderSizePixel = 0
	header.Parent = panel
	local overline = UIStyle.text("Rubrique", "ÉTAT-MAJOR · OPÉRATIONS", 11, UIStyle.FONT_BOLD, UIStyle.ACCENT)
	overline.AutomaticSize = Enum.AutomaticSize.None
	overline.Position = UDim2.fromOffset(18, 10)
	overline.Size = UDim2.new(1, -36, 0, 16)
	overline.Parent = header
	local titleIcon = UIStyle.mountIcon(header, "Missions", 23, UIStyle.ACCENT)
	titleIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	titleIcon.Position = UDim2.fromOffset(30, 44)
	local title = UIStyle.text("Titre", "Missions du jour", 24, UIStyle.FONT_BLACK)
	title.AutomaticSize = Enum.AutomaticSize.None
	title.Position = UDim2.fromOffset(52, 28)
	title.Size = UDim2.new(1, -70, 0, 30)
	title.Parent = header
	local intro = UIStyle.text("Intro", "Valables dans toutes les parties : chaque mission accomplie donne de l'expérience de compte.", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
	intro.AutomaticSize = Enum.AutomaticSize.None
	intro.Position = UDim2.fromOffset(18, 58)
	intro.Size = UDim2.new(1, -36, 0, 20)
	intro.TextWrapped = false
	intro.TextTruncate = Enum.TextTruncate.AtEnd
	intro.Parent = header
	local list = Instance.new("ScrollingFrame")
	list.Name = "Liste"
	list.Position = UDim2.fromOffset(16, 100)
	list.Size = UDim2.new(1, -32, 1, -180)
	list.BackgroundTransparency = 1
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	UIStyle.styleScroll(list)
	UIStyle.list(list, 8)
	list.Parent = panel
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
	local renewal = UIStyle.text("Renouvellement", "", 14, UIStyle.FONT_MEDIUM, UIStyle.TEXT_DIM)
	renewal.AutomaticSize = Enum.AutomaticSize.None
	renewal.Position = UDim2.fromOffset(16, 0)
	renewal.Size = UDim2.new(1, -156, 1, 0)
	renewal.TextYAlignment = Enum.TextYAlignment.Center
	renewal.Parent = footer
	local close = UIStyle.button("Fermer", "Fermer", true)
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.new(1, -14, 0.5, 0)
	close.Size = UDim2.fromOffset(120, 42)
	close.Parent = footer
	gui.Parent = playerGui

	local function render()
		local done, total = 0, 0
		for _, child in list:GetChildren() do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end
		for _, item in items(folder) do
			total += 1
			local finished = item:GetAttribute("Faite") == true
			if finished then
				done += 1
			end
			local value = (item:GetAttribute("Valeur") :: number?) or 0
			local goal = (item:GetAttribute("But") :: number?) or 1
			local row = UIStyle.card(item.Name)
			row.LayoutOrder = (item:GetAttribute("Ordre") :: number?) or 0
			row.BackgroundColor3 = if finished then Color3.fromRGB(34, 74, 48) else UIStyle.PANEL_ALT
			row.BackgroundTransparency = if finished then 0.18 else 0.1
			UIStyle.padding(row, 8, 10)
			UIStyle.list(row, 4)
			local label = UIStyle.text("Texte", `{if finished then "✅" else "▫️"} <b>{item:GetAttribute("Texte")}</b>`, 16, UIStyle.FONT_MEDIUM)
			label.LayoutOrder = 1
			label.Parent = row
			local progress = UIStyle.text("Progression", `{math.floor(value)}/{math.floor(goal)}   <font color="#EBBE46">+{item:GetAttribute("XP")} XP</font>`, 14, UIStyle.FONT, UIStyle.TEXT_DIM)
			progress.LayoutOrder = 2
			progress.Parent = row
			local track = Instance.new("Frame")
			track.Name = "Barre"
			track.LayoutOrder = 3
			track.Size = UDim2.new(1, 0, 0, 6)
			track.BackgroundColor3 = UIStyle.BORDER_SOFT
			track.BackgroundTransparency = 0.22
			track.BorderSizePixel = 0
			UIStyle.corner(track, 3)
			local fill = Instance.new("Frame")
			fill.Size = UDim2.fromScale(math.clamp(value / math.max(goal, 1), 0, 1), 1)
			fill.BackgroundColor3 = if finished then UIStyle.SUCCESS else UIStyle.ACCENT
			fill.BorderSizePixel = 0
			UIStyle.corner(fill, 3)
			fill.Parent = track
			track.Parent = row
			row.Parent = list
		end
		counter.Text = `{done}/{total}`
		button:SetAttribute("InfoBulleTexte", `Missions du jour · {done}/{total}`)
		local finish = folder:GetAttribute("FinJour")
		if typeof(finish) == "number" then
			renewal.Text = `Nouvelles missions dans {duration(math.max(0, math.floor(finish - os.time())))}.`
		end
	end

	-- message quand une mission est accomplie
	local function watch(item: Instance)
		local finished = item:GetAttribute("Faite") == true
		item:GetAttributeChangedSignal("Faite"):Connect(function()
			local now = item:GetAttribute("Faite") == true
			if now and not finished then
				Toast.show(`📅 Mission du jour accomplie : <b>{item:GetAttribute("Texte")}</b> (+{item:GetAttribute("XP")} XP de compte)`, "success", "Succes")
			end
			finished = now
		end)
		item.AttributeChanged:Connect(function()
			if overlay.Visible then
				render()
			else
				task.defer(render) -- le badge du bouton reste à jour
			end
		end)
	end
	for _, item in folder:GetChildren() do
		watch(item)
	end
	folder.ChildAdded:Connect(function(item: Instance)
		watch(item)
		render()
	end)
	folder.ChildRemoved:Connect(render)

	local function syncButtonState()
		UIStyle.setButtonSelected(button, overlay.Visible)
		UIStyle.setIconColor(buttonIcon, if overlay.Visible then UIStyle.ACCENT else UIStyle.TEXT_DIM)
		counter.TextColor3 = if overlay.Visible then UIStyle.TEXT else UIStyle.TEXT_DIM
	end
	button.Activated:Connect(function()
		ModalHost.toggle(overlay, syncButtonState)
		syncButtonState()
		render()
	end)
	close.Activated:Connect(function()
		ModalHost.hide(overlay)
		syncButtonState()
	end)
	overlay.Activated:Connect(function()
		ModalHost.hide(overlay)
		syncButtonState()
	end)
	render()
	syncButtonState()
end

return MissionsPanel
