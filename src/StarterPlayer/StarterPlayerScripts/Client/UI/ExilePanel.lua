--!strict
-- Gouvernement en exil côté joueur : quand son pays n'a plus aucune région (attribut « Exil »),
-- une carte le lui dit, montre la résistance dans ses régions perdues (avec un bouton pour la
-- financer) et propose de diriger un autre pays libre. Le serveur valide (ExileService).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Politics = require(Config:WaitForChild("Politics")) :: any
local FrenchNames = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FrenchNames")) :: any
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local GameSession = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("GameSession"))
local Sfx = require(script.Parent.Parent:WaitForChild("Audio"):WaitForChild("Sfx"))
local RegionView = require(script.Parent.Parent:WaitForChild("Map"):WaitForChild("RegionView"))

local ExilePanel = {}

function ExilePanel.start(countryId: string, onSwitch: () -> ())
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local country = state:WaitForChild("Pays"):WaitForChild(countryId)
	local regionsState = state:WaitForChild("Regions")
	local remotes = ReplicatedStorage:WaitForChild("Remotes")

	local gui = Instance.new("ScreenGui")
	gui.Name = "Exil"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	gui.Enabled = false
	local card = UIStyle.panel("Carte", UDim.new(0, 340))
	card.Position = UDim2.fromOffset(12, 150)
	UIStyle.padding(card, 12, 14)
	UIStyle.list(card, 8)
	card.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local message: string? = nil
	local bars: { { region: string, label: TextLabel } } = {}

	local function lostRegions(): { string }
		local list = {}
		for regionId, region in Regions do
			if region.startOwner == countryId and RegionView.getOwner(regionId) ~= countryId then
				table.insert(list, regionId)
			end
		end
		table.sort(list)
		return list
	end

	local function resistanceText(regionId: string): string
		local folder = regionsState:FindFirstChild(regionId)
		local value = folder and folder:GetAttribute("Resistance")
		local occupier = RegionView.getOwner(regionId)
		return `✊ <b>{Regions[regionId].name}</b> <font color="{UIStyle.GREY_HEX}">(occupée par {if occupier and Countries[occupier] then FrenchNames.the(Countries[occupier].name) else "?"})</font>\n`
			.. `résistance {if typeof(value) == "number" then math.floor(value) else 0}/{Politics.exile.uprisingAt}`
	end

	local render: () -> ()
	local function ask(remoteName: string, value: any)
		local remote = remotes:WaitForChild(remoteName) :: RemoteFunction
		local ok, accepted, reason = pcall(function()
			return remote:InvokeServer(value)
		end)
		Sfx.actionResult(remoteName, ok and accepted == true)
		message = if ok and accepted == true then nil elseif ok and typeof(reason) == "string" then reason else "Le serveur ne répond pas."
		render()
	end

	render = function()
		if Players.LocalPlayer:GetAttribute("Pays") ~= countryId then
			gui.Enabled = false
			return
		end
		gui.Enabled = country:GetAttribute("Exil") == true
		if not gui.Enabled then
			return
		end
		for _, child in card:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		table.clear(bars)
		local order = 0
		local function add(instance: GuiObject)
			order += 1
			instance.LayoutOrder = order
			instance.Parent = card
		end
		add(UIStyle.text("Titre", "🏳️ <b>Gouvernement en exil</b>", 19, UIStyle.FONT_BOLD))
		add(UIStyle.text("Texte", "Ton pays a perdu toutes ses régions. Tu gardes ta voix au Conseil mondial et tes crédits : finance la résistance pour reprendre ton territoire, ou dirige un autre pays.", 14, UIStyle.FONT, UIStyle.TEXT_DIM))
		for _, regionId in lostRegions() do
			local row = Instance.new("Frame")
			row.Name = "Resistance_" .. regionId
			row.BackgroundTransparency = 1
			row.Size = UDim2.new(1, 0, 0, 0)
			row.AutomaticSize = Enum.AutomaticSize.Y
			local label = UIStyle.text("Info", resistanceText(regionId), 14)
			label.Size = UDim2.new(1, -110, 0, 0)
			label.Parent = row
			local fund = UIStyle.button("Financer_" .. regionId, `Financer ({Politics.exile.resistanceCost} 💰)`)
			fund.AnchorPoint = Vector2.new(1, 0.5)
			fund.Position = UDim2.new(1, 0, 0.5, 0)
			fund.Size = UDim2.fromOffset(104, 34)
			fund.TextSize = 13
			fund.Activated:Connect(function()
				ask("FinancerResistance", regionId)
			end)
			fund.Parent = row
			add(row)
			table.insert(bars, { region = regionId, label = label })
		end
		local switch = UIStyle.button("AutrePays", "Diriger un autre pays", true)
		switch.Size = UDim2.new(1, 0, 0, 40)
		switch.TextSize = 15
		switch.Activated:Connect(onSwitch)
		add(switch)
		if message then
			add(UIStyle.text("Message", message, 14, UIStyle.FONT_MEDIUM, UIStyle.DANGER))
		end
	end

	GameSession.track(country:GetAttributeChangedSignal("Exil"):Connect(render))
	task.spawn(function()
		while gui.Parent do
			task.wait(2)
			for _, item in bars do
				if item.label.Parent then
					item.label.Text = resistanceText(item.region)
				end
			end
		end
	end)
	render()
end

return ExilePanel
