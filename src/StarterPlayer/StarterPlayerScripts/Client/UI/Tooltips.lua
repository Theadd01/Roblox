--!strict
-- Info-bulles au survol de chaque bouton et ressource (voir Config/Tooltips) ; sur écran tactile,
-- un appui long les affiche. Les éléments sont reconnus par leur nom, dès qu'ils apparaissent
-- dans l'interface du joueur : les modules d'interface n'ont rien à faire.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Tooltips = require(Config:WaitForChild("Tooltips")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local Units = require(Config:WaitForChild("Units")) :: any
local Combat = require(Config:WaitForChild("Combat")) :: any
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))

local TooltipModule = {}

local label: TextLabel? = nil
local hovered: GuiObject? = nil
-- marqueur posé sur chaque élément déjà équipé (un attribut : un élément déplacé n'est pas équipé deux fois)
local MARK = "InfoBulle"

local function unitText(typeId: string): string?
	local unit = Units.types[typeId]
	local stats = Combat.units[typeId]
	if not unit or not stats then
		return nil
	end
	local upkeep = {}
	for resourceId, amount in unit.upkeep do
		table.insert(upkeep, `{amount} {Resources.list[resourceId].icon}`)
	end
	return `{unit.icon} {unit.name} : attaque {stats.attack}, vie {stats.health}`
		.. (if #upkeep > 0 then `, entretien {table.concat(upkeep, " + ")} par cycle` else ", sans entretien")
end

-- Texte de l'info-bulle d'un élément (nil s'il n'en a pas)
local function textFor(gui: Instance): string?
	local parent = gui.Parent
	local path = if parent then parent.Name .. "." .. gui.Name else gui.Name
	if Tooltips.byPath[path] then
		return Tooltips.byPath[path]
	end
	if Tooltips.byName[gui.Name] then
		return Tooltips.byName[gui.Name]
	end
	local resource = Resources.list[gui.Name]
	if resource then
		return `{resource.icon} {resource.name} : {resource.use}`
	end
	local typeId = gui.Name:match("^Recruter_(.+)$")
	if typeId then
		return unitText(typeId)
	end
	for prefix, text in Tooltips.byPrefix do
		if gui.Name:sub(1, #prefix) == prefix then
			return text
		end
	end
	return nil
end

local function place()
	local l = label
	if not l or not l.Visible then
		return
	end
	local mouse = UserInputService:GetMouseLocation()
	local viewport = workspace.CurrentCamera.ViewportSize
	local size = l.AbsoluteSize
	local x = math.clamp(mouse.X + 16, 8, viewport.X - size.X - 8)
	local y = math.clamp(mouse.Y - 36 + 18, 8, viewport.Y - size.Y - 8)
	l.Position = UDim2.fromOffset(x, y)
end

local function show(text: string)
	local l = label
	if l then
		l.Text = text
		l.Visible = true
		place()
	end
end

local function hide()
	hovered = nil
	if label then
		label.Visible = false
	end
end

local function hook(gui: Instance)
	if not gui:IsA("GuiObject") or gui:GetAttribute(MARK) then
		return
	end
	local text = textFor(gui)
	if not text then
		return
	end
	gui:SetAttribute(MARK, true)
	local object = gui :: GuiObject
	object.MouseEnter:Connect(function()
		hovered = object
		task.delay(Tooltips.delay, function()
			if hovered == object and object.Visible then
				show(textFor(object) or text)
			end
		end)
	end)
	object.MouseLeave:Connect(function()
		if hovered == object then
			hide()
		end
	end)
	-- écran tactile : appui long
	object.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			hovered = object
			task.delay(Tooltips.holdDelay, function()
				if hovered == object and input.UserInputState ~= Enum.UserInputState.End then
					show(textFor(object) or text)
					task.delay(3, function()
						if hovered == object then
							hide()
						end
					end)
				end
			end)
		end
	end)
	object.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch and hovered == object and not (label and label.Visible) then
			hovered = nil
		end
	end)
	object.Destroying:Connect(function()
		if hovered == object then
			hide()
		end
	end)
end

function TooltipModule.start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "InfoBulle"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 30
	gui.IgnoreGuiInset = true
	local l = UIStyle.text("Bulle", "", 14, UIStyle.FONT_MEDIUM)
	l.AutomaticSize = Enum.AutomaticSize.XY
	l.Size = UDim2.fromOffset(0, 0)
	l.BackgroundColor3 = Color3.fromRGB(8, 10, 14)
	l.BackgroundTransparency = 0.05
	l.Visible = false
	UIStyle.corner(l, 6)
	UIStyle.padding(l, 6, 8)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(Tooltips.maxWidth, math.huge)
	limit.Parent = l
	l.Parent = gui
	gui.Parent = playerGui
	label = l

	for _, descendant in playerGui:GetDescendants() do
		hook(descendant)
	end
	playerGui.DescendantAdded:Connect(function(descendant: Instance)
		task.defer(hook, descendant)
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			place()
		end
	end)
end

return TooltipModule
