--!strict
-- Objectifs nationaux du joueur (EtatMonde.Pays.<code>.Objectifs) : une petite carte en haut à
-- gauche montre l'objectif en cours, son avancement et sa récompense ; un toucher déplie la
-- chaîne complète. Un message salue chaque objectif atteint.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local Toast = require(script.Parent:WaitForChild("Toast"))
local GameSession = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("GameSession"))

local TOP = 78 -- sous la barre du haut
local WIDTH = 320

local ObjectivesWidget = {}

local function items(folder: Instance): { Instance }
	local list = folder:GetChildren()
	table.sort(list, function(a: Instance, b: Instance): boolean
		return ((a:GetAttribute("Ordre") :: number?) or 0) < ((b:GetAttribute("Ordre") :: number?) or 0)
	end)
	return list
end

function ObjectivesWidget.start(countryId: string)
	-- messages seulement tant que le joueur dirige ce pays (il peut en changer : exil)
	local function notify(text: string, kind: string?)
		if Players.LocalPlayer:GetAttribute("Pays") == countryId then
			Toast.show(text, kind)
		end
	end
	local country = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Pays"):WaitForChild(countryId)
	local folder = country:WaitForChild("Objectifs", 30)
	if not folder then
		return
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "Objectifs"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 2
	local card = Instance.new("TextButton")
	card.Name = "Carte"
	card.AutoButtonColor = false
	card.Text = ""
	card.Position = UDim2.fromOffset(12, TOP)
	-- sous le bas réel de la barre du haut (elle peut passer sur deux lignes)
	local function follow()
		local bottom = Players.LocalPlayer:GetAttribute("BasBarreHaut")
		card.Position = UDim2.fromOffset(12, if typeof(bottom) == "number" then math.max(TOP, bottom + 8) else TOP)
	end
	follow()
	GameSession.track(Players.LocalPlayer:GetAttributeChangedSignal("BasBarreHaut"):Connect(follow))
	card.Size = UDim2.fromOffset(WIDTH, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = UIStyle.PANEL
	card.BackgroundTransparency = 0.12
	UIStyle.corner(card, 10)
	UIStyle.stroke(card)
	UIStyle.padding(card, 8, 10)
	UIStyle.list(card, 4)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(math.max(220, workspace.CurrentCamera.ViewportSize.X - 24), math.huge)
	limit.Parent = card
	local title = UIStyle.text("Titre", "", 15, UIStyle.FONT_MEDIUM)
	title.LayoutOrder = 1
	title.Parent = card
	local bar = Instance.new("Frame")
	bar.Name = "Barre"
	bar.LayoutOrder = 2
	bar.Size = UDim2.new(1, 0, 0, 6)
	bar.BackgroundColor3 = Color3.fromRGB(40, 44, 54)
	bar.BorderSizePixel = 0
	UIStyle.corner(bar, 3)
	local fill = Instance.new("Frame")
	fill.Name = "Remplissage"
	fill.BackgroundColor3 = UIStyle.ACCENT
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	UIStyle.corner(fill, 3)
	fill.Parent = bar
	bar.Parent = card
	local details = UIStyle.text("Liste", "", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
	details.LayoutOrder = 3
	details.Visible = false
	details.Parent = card
	card.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local expanded = false
	local done: { [Instance]: boolean } = {}

	local function refresh()
		local list = items(folder)
		local current: Instance? = nil
		local finished = 0
		local lines = {}
		for _, item in list do
			local status = item:GetAttribute("Etat")
			if status == "Fait" then
				finished += 1
				table.insert(lines, `✅ <s>{item:GetAttribute("Texte")}</s>`)
			elseif status == "EnCours" then
				current = item
				table.insert(lines, `▶️ <b>{item:GetAttribute("Texte")}</b>  🎁 {item:GetAttribute("Recompense")}`)
			else
				table.insert(lines, `🔒 {item:GetAttribute("Texte")}  🎁 {item:GetAttribute("Recompense")}`)
			end
		end
		if current then
			local value = (current:GetAttribute("Valeur") :: number?) or 0
			local target = math.max(1, (current:GetAttribute("But") :: number?) or 1)
			local count = if target > 1 then `  <font color="{UIStyle.GREY_HEX}">{math.floor(value)}/{target}</font>` else ""
			title.Text = `🎯 <b>Objectif {finished + 1}/{#list}</b> : {current:GetAttribute("Texte")}{count}\n<font color="{UIStyle.GREY_HEX}">🎁 {current:GetAttribute("Recompense")}  ·  touche pour tout voir</font>`
			fill.Size = UDim2.fromScale(math.clamp(value / target, 0, 1), 1)
			bar.Visible = true
		else
			title.Text = `🏆 <b>Tous tes objectifs nationaux sont atteints !</b>`
			bar.Visible = false
		end
		details.Text = table.concat(lines, "\n")
		details.Visible = expanded
	end

	-- message quand un objectif est atteint
	local function watch(item: Instance)
		done[item] = item:GetAttribute("Etat") == "Fait"
		item:GetAttributeChangedSignal("Etat"):Connect(function()
			if item:GetAttribute("Etat") == "Fait" and not done[item] then
				done[item] = true
				notify(`✅ Objectif atteint : {item:GetAttribute("Texte")}  🎁 {item:GetAttribute("Recompense")}`, "success")
			end
			refresh()
		end)
		item.AttributeChanged:Connect(refresh)
	end
	for _, item in folder:GetChildren() do
		watch(item)
	end
	folder.ChildAdded:Connect(function(item: Instance)
		watch(item)
		refresh()
	end)
	card.Activated:Connect(function()
		expanded = not expanded
		refresh()
	end)
	refresh()
end

return ObjectivesWidget
