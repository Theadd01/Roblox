--!strict
-- Dilemme de dirigeant côté joueur (EtatMonde.Pays.<code>.Dilemme) : une carte au milieu de
-- l'écran avec la situation, deux gros boutons (et leurs conséquences) et le temps restant ;
-- sans réponse, le choix par défaut s'applique. Le serveur valide (Remotes.ChoisirDilemme).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local ModalHost = require(script.Parent:WaitForChild("ModalHost"))
local GameSession = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("GameSession"))
local Toast = require(script.Parent:WaitForChild("Toast"))

local DilemmaCard = {}

local DILEMMA_PRIORITY = 100

function DilemmaCard.start(countryId: string)
	local country = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Pays"):WaitForChild(countryId)
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ChoisirDilemme") :: RemoteFunction

	local gui = Instance.new("ScreenGui")
	gui.Name = "Dilemme"
	gui.ResetOnSpawn = false
	-- Sous l'écran de fin (40), mais au-dessus des modales ordinaires (20)
	-- et des info-bulles (30).
	gui.DisplayOrder = 35
	gui.Enabled = false
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local current: Instance? = nil
	local currentSurface: GuiObject? = nil
	local timer: TextLabel? = nil

	-- La fin d'une partie détruit directement les interfaces propres au pays.
	-- Libère aussi l'arbitre modal afin qu'un ancien dilemme ne bloque pas
	-- l'écran de choix du pays ou les fenêtres de la partie suivante.
	gui.Destroying:Connect(function()
		local surface = currentSurface
		currentSurface = nil
		current = nil
		if surface then
			ModalHost.hide(surface)
		end
	end)

	local function show(card: Instance)
		current = card
		for _, child in gui:GetChildren() do
			child:Destroy()
		end
		local shade = Instance.new("Frame")
		shade.Name = "FondModal"
		shade.Active = true
		shade.Size = UDim2.fromScale(1, 1)
		shade.BackgroundColor3 = UIStyle.BACKDROP
		shade.BackgroundTransparency = 0.28
		shade.BorderSizePixel = 0
		shade.Visible = false
		shade.Parent = gui
		local desktop = workspace.CurrentCamera.ViewportSize.X >= 700
		local panel = UIStyle.panel("Carte", if desktop then UDim.new(0, 700) else UDim.new(1, -24))
		panel.AnchorPoint = Vector2.new(0.5, 0.5)
		panel.Position = UDim2.fromScale(0.5, 0.5)
		UIStyle.padding(panel, 14, 16)
		UIStyle.list(panel, 10)
		local limit = Instance.new("UISizeConstraint")
		limit.MaxSize = Vector2.new(math.max(260, workspace.CurrentCamera.ViewportSize.X - 24), workspace.CurrentCamera.ViewportSize.Y - 32)
		limit.Parent = panel
		local function text(name: string, content: string, size: number, order: number, font: Font?, color: Color3?): TextLabel
			local label = UIStyle.text(name, content, size, font, color)
			label.LayoutOrder = order
			label.Parent = panel
			return label
		end
		text("Type", "🃏 <b>Décision</b>", 16, 1, UIStyle.FONT_BOLD, UIStyle.ACCENT)
		text("Titre", `<b>{card:GetAttribute("Titre")}</b>`, 21, 2, UIStyle.FONT_BOLD)
		text("Texte", tostring(card:GetAttribute("Texte")), 16, 3, UIStyle.FONT, UIStyle.TEXT_DIM)
		local choices = Instance.new("Frame")
		choices.Name = "Choix"
		choices.LayoutOrder = 4
		choices.BackgroundTransparency = 1
		choices.Size = UDim2.new(1, 0, 0, if desktop then 92 else 128)
		local choicesLayout = UIStyle.list(choices, 8, desktop)
		choicesLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		choicesLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		choices.Parent = panel
		local defaultChoice = (card:GetAttribute("Defaut") :: number?) or 1
		for i, key in { "A", "B" } do
			local choice = i
			local button = UIStyle.button("Choix" .. key, "")
			button.LayoutOrder = i
			button.Size = if desktop then UDim2.new(0.5, -4, 1, 0) else UDim2.new(1, 0, 0, 60)
			button.RichText = true
			button.TextSize = 16
			button.TextWrapped = true
			button.Text = `<b>{card:GetAttribute("Choix" .. key)}</b>\n<font size="14">{card:GetAttribute("Effets" .. key)}</font>`
			UIStyle.setButtonSelected(button, choice == defaultChoice)
			button.Activated:Connect(function()
				local ok, accepted, reason = pcall(function()
					return remote:InvokeServer(choice)
				end)
				if ok and accepted == true then
					Toast.show(`✔️ {card:GetAttribute("Choix" .. key)} : {card:GetAttribute("Effets" .. key)}`, "success", "Signature")
				elseif ok and typeof(reason) == "string" then
					Toast.show(reason, "danger", "Refus")
				end
			end)
			button.Parent = choices
		end
		local default = if defaultChoice == 1 then card:GetAttribute("ChoixA") else card:GetAttribute("ChoixB")
		timer = text("Temps", "", 14, 5, UIStyle.FONT_MEDIUM, UIStyle.TEXT_DIM)
		local defaultText = tostring(default)
		task.spawn(function()
			while current == card and card.Parent do
				local left = math.max(0, math.ceil((card:GetAttribute("Fin") :: number) - workspace:GetServerTimeNow()))
				if timer then
					timer.Text = `⏳ {left} s pour décider (sinon : {defaultText})`
				end
				task.wait(1)
			end
		end)
		panel.Parent = shade
		gui.Enabled = true
		currentSurface = shade
		ModalHost.show(shade, nil, {
			priority = DILEMMA_PRIORITY,
			dismissOnEscape = false,
		})
	end

	GameSession.track(country.ChildAdded:Connect(function(child: Instance)
		if child.Name == "Dilemme" then
			task.defer(show, child)
		end
	end))
	GameSession.track(country.ChildRemoved:Connect(function(child: Instance)
		if child == current then
			current = nil
			local surface = currentSurface
			currentSurface = nil
			if surface then
				ModalHost.hide(surface)
			end
			gui.Enabled = false
		end
	end))
	local existing = country:FindFirstChild("Dilemme")
	if existing then
		show(existing)
	end
end

return DilemmaCard
