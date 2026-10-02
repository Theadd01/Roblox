--!strict
-- Messages courts en haut de l'écran (sous la barre du haut), qui disparaissent seuls.
-- Utilisés pour les événements importants : attaque, victoire, défaite...
-- Chaque message a un petit son selon sa sorte (Config/Audio.toastSounds), ou un son choisi.
-- Le joueur peut masquer les messages d'information (Paramètres) : succès et alertes restent.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Audio = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Audio")) :: any
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local Client = script.Parent.Parent
local Settings = require(Client:WaitForChild("State"):WaitForChild("Settings"))
local Sfx = require(Client:WaitForChild("Audio"):WaitForChild("Sfx"))

local DURATION = 5
local KINDS = {
	info = Color3.fromRGB(18, 22, 30),
	success = Color3.fromRGB(38, 92, 52),
	danger = Color3.fromRGB(110, 36, 34),
}

local Toast = {}

local stack: Frame? = nil

local function getStack(): Frame
	if stack then
		return stack
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "Messages"
	gui.ResetOnSpawn = false
	-- Les confirmations doivent rester visibles au-dessus des fenêtres modales.
	gui.DisplayOrder = 25
	local frame = Instance.new("Frame")
	frame.Name = "Pile"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, 84)
	frame.Size = UDim2.new(0, 520, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundTransparency = 1
	local layout = UIStyle.list(frame, 8)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(math.max(240, workspace.CurrentCamera.ViewportSize.X - 32), math.huge)
	limit.Parent = frame
	frame.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	stack = frame
	return frame
end

-- kind : "info" | "success" | "danger" ; sound : son à jouer (nom dans Config/Audio.sounds),
-- false pour aucun son, nil pour le son de la sorte de message
function Toast.show(text: string, kind: string?, sound: (string | boolean)?)
	local k = kind or "info"
	if k == "info" and Settings.get("infoMessages") == false then
		return
	end
	if sound ~= false then
		local name = if typeof(sound) == "string" then sound else Audio.toastSounds[k]
		if name then
			Sfx.play(name)
		end
	end
	local parent = getStack()
	local box = Instance.new("TextLabel")
	box.Name = "Message"
	box.LayoutOrder = math.floor(os.clock() * 1000) % 1000000
	box.Size = UDim2.new(1, 0, 0, 0)
	box.AutomaticSize = Enum.AutomaticSize.Y
	box.BackgroundColor3 = KINDS[kind or "info"] or KINDS.info
	box.BackgroundTransparency = 0.05
	box.FontFace = UIStyle.FONT_BOLD
	box.TextSize = 18
	box.TextColor3 = UIStyle.TEXT
	box.TextWrapped = true
	box.RichText = true
	box.Text = text
	UIStyle.corner(box, 10)
	UIStyle.stroke(box, 0.75)
	UIStyle.padding(box, 10, 16)
	box.Parent = parent
	task.delay(DURATION, function()
		local fade = TweenService:Create(box, TweenInfo.new(0.6), { BackgroundTransparency = 1, TextTransparency = 1 })
		fade:Play()
		fade.Completed:Wait()
		box:Destroy()
	end)
end

return Toast
