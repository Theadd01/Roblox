--!strict
-- Bandeau d'actualités façon journal télévisé, juste au-dessus des onglets : les derniers flashs
-- (ReplicatedStorage.EtatMonde.Actualites) défilent de droite à gauche. Un toucher ouvre la liste
-- complète (avec l'heure) ; les flashs qui concernent le joueur sont mis en avant.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local News = require(Config:WaitForChild("News")) :: any
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local GameSession = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("GameSession"))

local BOTTOM = 96 -- au-dessus de la barre d'onglets
local HEIGHT = 30

local NewsTicker = {}

local function sorted(folder: Instance): { Instance }
	local items = folder:GetChildren()
	table.sort(items, function(a: Instance, b: Instance): boolean
		return (tonumber(a.Name:sub(2)) or 0) > (tonumber(b.Name:sub(2)) or 0)
	end)
	return items
end

local function ago(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	if seconds < 60 then
		return `il y a {seconds} s`
	end
	return `il y a {math.floor(seconds / 60)} min`
end

function NewsTicker.start(countryId: string)
	local actualites = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Actualites")

	local gui = Instance.new("ScreenGui")
	gui.Name = "Actualites"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 3

	-- bandeau
	local band = Instance.new("TextButton")
	band.Name = "Bandeau"
	band.AutoButtonColor = false
	band.Text = ""
	band.AnchorPoint = Vector2.new(0.5, 1)
	band.Position = UDim2.new(0.5, 0, 1, -BOTTOM)
	band.Size = UDim2.new(1, -24, 0, HEIGHT)
	band.BackgroundColor3 = Color3.fromRGB(110, 24, 28)
	band.BackgroundTransparency = 0.1
	band.ClipsDescendants = true
	UIStyle.corner(band, 8)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(820, HEIGHT)
	limit.Parent = band
	local tag = UIStyle.text("Etiquette", "<b>📰 INFO</b>", 14, UIStyle.FONT_BLACK)
	tag.AutomaticSize = Enum.AutomaticSize.None
	tag.Size = UDim2.new(0, 74, 1, 0)
	tag.TextXAlignment = Enum.TextXAlignment.Center
	tag.TextYAlignment = Enum.TextYAlignment.Center
	tag.BackgroundColor3 = Color3.fromRGB(200, 40, 45)
	tag.BackgroundTransparency = 0
	tag.ZIndex = 3
	UIStyle.corner(tag, 8)
	tag.Parent = band
	local window = Instance.new("Frame")
	window.Name = "Fenetre"
	window.BackgroundTransparency = 1
	window.Position = UDim2.fromOffset(80, 0)
	window.Size = UDim2.new(1, -84, 1, 0)
	window.ClipsDescendants = true
	window.Parent = band
	local scroll = UIStyle.text("Defilant", "", 15, UIStyle.FONT_MEDIUM)
	scroll.AutomaticSize = Enum.AutomaticSize.X
	scroll.Size = UDim2.new(0, 0, 1, 0)
	scroll.TextWrapped = false
	scroll.TextYAlignment = Enum.TextYAlignment.Center
	scroll.Parent = window
	band.Visible = false
	band.Parent = gui

	-- liste complète
	local list = Instance.new("ScrollingFrame")
	list.Name = "Liste"
	list.Active = true
	list.AnchorPoint = Vector2.new(0.5, 1)
	list.Position = UDim2.new(0.5, 0, 1, -(BOTTOM + HEIGHT + 6))
	list.Size = UDim2.new(1, -24, 0, 260)
	list.BackgroundColor3 = UIStyle.PANEL
	list.BackgroundTransparency = 0.06
	list.ScrollBarThickness = 6
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Visible = false
	UIStyle.corner(list, 10)
	UIStyle.padding(list, 10, 12)
	UIStyle.list(list, 6)
	local listLimit = Instance.new("UISizeConstraint")
	listLimit.MaxSize = Vector2.new(820, 260)
	listLimit.Parent = list
	list.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function concernsMe(item: Instance): boolean
		local countries = item:GetAttribute("Pays")
		return typeof(countries) == "string" and table.find(countries:split(","), countryId) ~= nil
	end

	local function rebuildList()
		for _, child in list:GetChildren() do
			if child:IsA("TextLabel") then
				child:Destroy()
			end
		end
		local now = workspace:GetServerTimeNow()
		for i, item in sorted(actualites) do
			local mine = concernsMe(item)
			local label = UIStyle.text("Flash", `{if mine then "<b>" else ""}{item:GetAttribute("Texte")}{if mine then "</b>" else ""}  <font color="{UIStyle.GREY_HEX}">{ago(now - (item:GetAttribute("Heure") :: number))}</font>`, 15)
			label.LayoutOrder = i
			label.Parent = list
		end
	end

	local offset = 0
	local function rebuildBand()
		local items = sorted(actualites)
		band.Visible = #items > 0
		local parts = {}
		for i = 1, math.min(News.tickerCount, #items) do
			table.insert(parts, tostring(items[i]:GetAttribute("Texte")))
		end
		scroll.Text = table.concat(parts, "      •      ")
		offset = 0
		if list.Visible then
			rebuildList()
		end
	end

	band.Activated:Connect(function()
		list.Visible = not list.Visible
		if list.Visible then
			rebuildList()
		end
	end)
	GameSession.track(actualites.ChildAdded:Connect(function()
		task.defer(rebuildBand)
	end))
	rebuildBand()

	-- défilement de droite à gauche, en boucle
	GameSession.track(RunService.RenderStepped:Connect(function(dt: number)
		if not band.Visible then
			return
		end
		offset += dt * News.tickerSpeed
		local width = scroll.AbsoluteSize.X
		local room = window.AbsoluteSize.X
		if offset > width + room then
			offset = 0
		end
		scroll.Position = UDim2.fromOffset(room - offset, 0)
	end))
end

return NewsTicker
