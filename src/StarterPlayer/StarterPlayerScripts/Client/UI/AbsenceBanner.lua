--!strict
-- Bandeau « absent » : quand le joueur est resté inactif, l'IA dirige son pays. Le bandeau
-- le lui dit (avec la personnalité prise par l'IA) et l'invite à bouger pour reprendre la main.
-- À son retour, un message confirme qu'il dirige de nouveau son pays.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Countries = require(Config:WaitForChild("Countries")) :: any
local FrenchNames = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FrenchNames")) :: any
local Personalities = require(Config:WaitForChild("Personalities")) :: any
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local GameSession = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("GameSession"))
local Toast = require(script.Parent:WaitForChild("Toast"))

local AbsenceBanner = {}

function AbsenceBanner.start(countryId: string)
	-- messages seulement tant que le joueur dirige ce pays (il peut en changer : exil)
	local function notify(text: string, kind: string?)
		if Players.LocalPlayer:GetAttribute("Pays") == countryId then
			Toast.show(text, kind)
		end
	end
	local folder = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Pays"):WaitForChild(countryId)

	local gui = Instance.new("ScreenGui")
	gui.Name = "Absence"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 9
	gui.Enabled = false
	local frame = Instance.new("Frame")
	frame.Name = "Bandeau"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.45)
	frame.Size = UDim2.new(0, 460, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = UIStyle.PANEL
	frame.BackgroundTransparency = 0.08
	UIStyle.corner(frame, 12)
	UIStyle.stroke(frame)
	UIStyle.padding(frame, 16, 18)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(math.max(240, workspace.CurrentCamera.ViewportSize.X - 32), math.huge)
	limit.Parent = frame
	local label = UIStyle.text("Texte", "", 18, UIStyle.FONT_MEDIUM)
	label.Size = UDim2.new(1, 0, 0, 0)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.Parent = frame
	frame.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local wasAbsent = false
	local function update()
		local absent = folder:GetAttribute("Absent") == true
		gui.Enabled = absent
		if absent then
			local personality = Personalities.list[folder:GetAttribute("Personnalite") or ""]
			local style = if personality then ` ({personality.icon} {personality.name})` else ""
			label.Text = `💤 <b>Tu étais absent</b> : l'IA dirige {FrenchNames.the(Countries[countryId].name)}{style} à ta place.\n`
				.. `<font color="{UIStyle.GREY_HEX}">Bouge la souris ou touche l'écran pour reprendre la main.</font>`
		elseif wasAbsent then
			notify(`👋 Te revoilà : tu diriges de nouveau {FrenchNames.the(Countries[countryId].name)}.`, "success")
		end
		wasAbsent = absent
	end
	GameSession.track(folder:GetAttributeChangedSignal("Absent"):Connect(update))
	GameSession.track(folder:GetAttributeChangedSignal("Personnalite"):Connect(update))
	update()
end

return AbsenceBanner
