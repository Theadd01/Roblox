--!strict
-- Effets sur la carte quand une région change de mains (conquête, révolte, soulèvement) :
-- la région s'illumine aux couleurs du nouveau propriétaire et une onde part de son centre.
-- Même effet, couleur terre, quand une catastrophe naturelle la frappe (événement mondial).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local MatchState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MatchState")) :: any
local RegionView = require(script.Parent:WaitForChild("RegionView"))

local FLASH_TIME = 1.8
local DISASTER_COLOR = Color3.fromRGB(150, 110, 70)
local WAVE_TIME = 1.6

local MapEffects = {}

local known: { [string]: string } = {} -- région -> propriétaire connu (pour repérer les changements)
local carte: Model? = nil

-- Disque lumineux qui s'élargit en s'effaçant
local function wave(center: Vector3, color: Color3, size: number, delay: number)
	task.delay(delay, function()
		local map = carte
		if not map then
			return
		end
		local disc = Instance.new("Part")
		disc.Name = "Onde"
		disc.Shape = Enum.PartType.Cylinder
		disc.Material = Enum.Material.Neon
		disc.Color = color
		disc.Anchored = true
		disc.CanCollide = false
		disc.CanQuery = false
		disc.CanTouch = false
		disc.CastShadow = false
		disc.Transparency = 0.25
		disc.Size = Vector3.new(0.3, 2, 2)
		disc.CFrame = CFrame.new(center) * CFrame.Angles(0, 0, math.rad(90)) -- axe du cylindre vertical
		disc.Parent = map
		local tween = TweenService:Create(disc, TweenInfo.new(WAVE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(0.3, size, size),
			Transparency = 1,
		})
		tween:Play()
		tween.Completed:Connect(function()
			disc:Destroy()
		end)
	end)
end

local function play(regionId: string, color: Color3)
	local map = carte
	local regions = map and map:FindFirstChild("Regions")
	local model = regions and regions:FindFirstChild(regionId)
	if not model or not model:IsA("Model") then
		return
	end
	-- la région s'illumine puis reprend ses couleurs
	local glow = Instance.new("Highlight")
	glow.Name = "Conquete"
	glow.FillColor = color
	glow.FillTransparency = 0.15
	glow.OutlineColor = Color3.new(1, 1, 1)
	glow.OutlineTransparency = 0
	glow.DepthMode = Enum.HighlightDepthMode.Occluded
	glow.Adornee = model
	glow.Parent = model
	local fade = TweenService:Create(glow, TweenInfo.new(FLASH_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		FillTransparency = 1,
		OutlineTransparency = 1,
	})
	fade:Play()
	fade.Completed:Connect(function()
		glow:Destroy()
	end)
	-- deux ondes depuis le centre de la région (point de son étiquette)
	local anchor = model:FindFirstChild("Ancre")
	local size = model:GetExtentsSize()
	local radius = math.clamp(math.max(size.X, size.Z) * 0.9, 25, 160)
	if anchor and anchor:IsA("BasePart") then
		local center = anchor.Position + Vector3.new(0, 0.5, 0)
		wave(center, color, radius, 0)
		wave(center, color, radius * 0.6, 0.35)
	end
end

function MapEffects.start(map: Model)
	carte = map
	for regionId in Regions do
		local owner = RegionView.getOwner(regionId)
		if owner then
			known[regionId] = owner
		end
	end
	RegionView.onOwnerChanged(function(regionId: string)
		local owner = RegionView.getOwner(regionId)
		if not owner then
			return
		end
		local previous = known[regionId]
		known[regionId] = owner
		-- nouvelle partie : toutes les régions reviennent à leur pays, sans effet
		if previous and previous ~= owner and MatchState.isRunning() and Countries[owner] then
			play(regionId, Countries[owner].color:Lerp(Color3.new(1, 1, 1), 0.35))
		end
	end)
	-- catastrophe naturelle
	local regionStates = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Regions")
	local function watchDisaster(folder: Instance)
		folder:GetAttributeChangedSignal("Catastrophe"):Connect(function()
			local finish = folder:GetAttribute("Catastrophe")
			if typeof(finish) == "number" and finish > workspace:GetServerTimeNow() and MatchState.isRunning() then
				play(folder.Name, DISASTER_COLOR)
			end
		end)
	end
	for _, folder in regionStates:GetChildren() do
		watchDisaster(folder)
	end
	regionStates.ChildAdded:Connect(watchDisaster)
end

return MapEffects
