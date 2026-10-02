--!strict
-- Rappel des commandes en haut de l'écran, qui s'efface après quelques secondes.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UIStyle = require(script.Parent:WaitForChild("UIStyle"))

local DURATION = 10 -- secondes avant de disparaître
local BANNER_BOTTOM_ATTRIBUTE = "ChoixPaysBandeauBas"

local ControlsHint = {}

local current: ScreenGui? = nil

function ControlsHint.show()
	ControlsHint.hide()
	local isTouch = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
	local text = if isTouch
		then "Glisser pour se déplacer  ·  Pincer pour zoomer  ·  Toucher un pays pour le choisir"
		else "Clic + glisser pour se déplacer  ·  Molette pour zoomer  ·  Clic sur un pays pour le choisir"

	local gui = Instance.new("ScreenGui")
	gui.Name = "AideCommandes"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 1

	local label = UIStyle.text("Raccourcis", text, 15, UIStyle.FONT_MEDIUM, UIStyle.TEXT_DIM)
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0, 82)
	label.Size = UDim2.fromOffset(0, 0)
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.BackgroundColor3 = UIStyle.PANEL_ALT
	label.BackgroundTransparency = 0.06
	label.TextXAlignment = Enum.TextXAlignment.Center
	UIStyle.corner(label, 7)
	UIStyle.stroke(label, 0.45, UIStyle.BORDER_SOFT)
	UIStyle.padding(label, 8, 14)
	local sizeLimit = Instance.new("UISizeConstraint")
	sizeLimit.Parent = label
	label.TextWrapped = true
	label.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	current = gui

	local connections: { RBXScriptConnection } = {}
	local function layout()
		local viewport = workspace.CurrentCamera.ViewportSize
		sizeLimit.MaxSize = Vector2.new(math.max(220, viewport.X - 32), math.huge)
		local bannerBottom = Players.LocalPlayer:GetAttribute(BANNER_BOTTOM_ATTRIBUTE)
		label.Position = UDim2.new(0.5, 0, 0, if typeof(bannerBottom) == "number" then bannerBottom + 8 else 82)
	end
	layout()
	table.insert(connections, workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(layout))
	table.insert(connections, Players.LocalPlayer:GetAttributeChangedSignal(BANNER_BOTTOM_ATTRIBUTE):Connect(layout))
	gui.Destroying:Connect(function()
		for _, connection in connections do
			connection:Disconnect()
		end
		if current == gui then
			current = nil
		end
	end)

	task.delay(DURATION, function()
		if not gui.Parent then
			return
		end
		local info = TweenInfo.new(1)
		TweenService:Create(label, info, { BackgroundTransparency = 1, TextTransparency = 1 }):Play()
		task.wait(1)
		if gui.Parent then
			gui:Destroy()
		end
	end)
end

-- Retire le rappel tout de suite (par exemple quand la partie commence)
function ControlsHint.hide()
	if current then
		current:Destroy()
		current = nil
	end
end

return ControlsHint
