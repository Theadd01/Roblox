--!strict
-- Généraux sur la carte (SYSTEME_MILITAIRE.md, 7.2), côté client, purement visuel : un officier
-- (modèle « General », un peu plus grand qu'un soldat) dans sa région quartier général, derrière
-- ses divisions, avec un fanion aux couleurs de son pays et son nom au-dessus ; il marche vers
-- son nouveau quartier général quand il change de région. Seulement près de la caméra.
-- Ses généraux et ceux des alliés sont toujours visibles ; les autres, selon le brouillard.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any
local UnitPainter = require(Shared:WaitForChild("UnitPainter")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local GeneralTraits = require(Shared:WaitForChild("GeneralTraits")) :: any
local Client = script.Parent.Parent
local Fog = require(Client:WaitForChild("State"):WaitForChild("Fog"))

local SHOW_DISTANCE = 420
local MAX_HEIGHT = 300
local LABEL_DISTANCE = 220
local HEIGHT = 3.1 -- taille du modèle (studs), un peu plus grand qu'un soldat (2,4)
local BEHIND = 5 -- derrière la formation des divisions (vers le sud de la ville)
local REFRESH = 0.3

type View = {
	general: Instance,
	model: Model,
	lift: number,
	label: TextLabel,
}

local GeneralRenderer = {}

local container: Folder? = nil
local templates: Instance? = nil
local folder: Instance? = nil -- EtatMonde.Generaux
local views: { [Instance]: View } = {}

local function anchorOf(regionId: unknown): Vector3?
	local region = if typeof(regionId) == "string" then Regions[regionId] else nil
	local city = region and region.city
	return if city then MapProjection.toVector3(city.lon, city.lat, MapSettings.regionTop) else nil
end

local function myCountry(): string?
	local me = Players.LocalPlayer:GetAttribute("Pays")
	return if typeof(me) == "string" and me ~= "" then me else nil
end

local function visible(g: Instance): boolean
	local owner = g:GetAttribute("Proprietaire")
	local me = myCountry()
	if me and (owner == me or (typeof(owner) == "string" and DiplomacyState.areAllies(me, owner))) then
		return true
	end
	local regionId = g:GetAttribute("Region")
	return typeof(regionId) == "string" and Fog.isRegionVisible(regionId)
end

-- Position du général : au quartier général, ou en route vers le nouveau
local function positionOf(g: Instance): Vector3?
	local here = anchorOf(g:GetAttribute("Region"))
	if not here then
		return nil
	end
	here += Vector3.new(0, 0, BEHIND)
	local destination = g:GetAttribute("Destination")
	if typeof(destination) == "string" and destination ~= "" then
		local there = anchorOf(destination)
		if there then
			local start, finish = (g:GetAttribute("Depart") :: number?) or 0, (g:GetAttribute("Arrivee") :: number?) or 0
			local t = math.clamp((workspace:GetServerTimeNow() - start) / math.max(finish - start, 0.001), 0, 1)
			return here:Lerp(there + Vector3.new(0, 0, BEHIND), t)
		end
	end
	return here
end

local function labelText(g: Instance): string
	local level = (g:GetAttribute("Niveau") :: number?) or 1
	local stars = string.rep("★", math.clamp(level, 1, 5))
	local disorganized = typeof(g:GetAttribute("Desorganise")) == "number"
	return `{g:GetAttribute("Nom")} {stars} {GeneralTraits.icons(g)}{if disorganized then " ⚠" else ""}`
end

local function makeView(g: Instance): View?
	local template = templates and templates:FindFirstChild("General")
	if not container or not template or not template:IsA("Model") then
		return nil
	end
	local model = template:Clone()
	local country = Countries[g:GetAttribute("Proprietaire") :: string]
	local color = if country then country.color else Color3.fromRGB(150, 150, 150)
	UnitPainter.paint(model, color)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = true -- cliquable
			part.CastShadow = false
		end
	end
	local _, size = model:GetBoundingBox()
	model:ScaleTo(HEIGHT / math.max(size.Y, 0.1))
	-- fanion aux couleurs du pays, planté à côté de lui
	local box, scaled = model:GetBoundingBox()
	local pole = Instance.new("Part")
	pole.Name = "Hampe"
	pole.Anchored = true
	pole.CanCollide = false
	pole.CanTouch = false
	pole.CanQuery = true
	pole.CastShadow = false
	pole.Color = Color3.fromRGB(90, 70, 50)
	pole.Size = Vector3.new(0.12, scaled.Y * 1.5, 0.12)
	pole.CFrame = CFrame.new(box.Position + Vector3.new(scaled.X * 0.7, scaled.Y * 0.25, 0))
	pole.Parent = model
	local flag = Instance.new("Part")
	flag.Name = "Fanion"
	flag.Anchored = true
	flag.CanCollide = false
	flag.CanTouch = false
	flag.CanQuery = true
	flag.CastShadow = false
	flag.Material = Enum.Material.SmoothPlastic
	flag.Color = color
	flag.Size = Vector3.new(0.9, 0.55, 0.05)
	flag.CFrame = pole.CFrame * CFrame.new(0.45, pole.Size.Y / 2 - 0.3, 0)
	flag.Parent = model
	-- zone invisible qui couvre l'officier et son fanion : plus facile à toucher (mobile)
	local all, allSize = model:GetBoundingBox()
	local hitbox = Instance.new("Part")
	hitbox.Name = "ZoneDeClic"
	hitbox.Anchored = true
	hitbox.CanCollide = false
	hitbox.CanTouch = false
	hitbox.CanQuery = true
	hitbox.CastShadow = false
	hitbox.Transparency = 1
	hitbox.Size = allSize + Vector3.new(0.6, 0.4, 0.8)
	hitbox.CFrame = all
	hitbox.Parent = model
	model:SetAttribute("GeneralId", g.Name)
	model.Name = g.Name
	local pivot = model:GetPivot()
	local bottom = box.Position.Y - scaled.Y / 2
	local lift = pivot.Position.Y - bottom
	local gui = Instance.new("BillboardGui")
	gui.Name = "Nom"
	gui.Adornee = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	gui.Size = UDim2.fromOffset(180, 22)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = LABEL_DISTANCE
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.FontFace = Font.fromEnum(Enum.Font.BuilderSansBold)
	label.TextSize = 14
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.Text = labelText(g)
	label.Parent = gui
	gui.Parent = model
	model.Parent = container
	return { general = g, model = model, lift = lift, label = label }
end

local function removeView(g: Instance)
	local view = views[g]
	if view then
		view.model:Destroy()
		views[g] = nil
	end
end

local function refresh()
	if not folder then
		return
	end
	local camera = workspace.CurrentCamera.CFrame.Position
	for _, g in folder:GetChildren() do
		local position = positionOf(g)
		local show = position ~= nil and camera.Y < MAX_HEIGHT and ((position :: Vector3) - camera).Magnitude < SHOW_DISTANCE and visible(g)
		if show and not views[g] then
			local view = makeView(g)
			if view then
				views[g] = view
			end
		elseif not show and views[g] then
			removeView(g)
		end
	end
	for g in views do
		if not g.Parent then
			removeView(g)
		end
	end
end

function GeneralRenderer.start(carte: Model)
	local f = Instance.new("Folder")
	f.Name = "Generaux"
	f.Parent = carte
	container = f
	templates = ReplicatedStorage:WaitForChild("Modeles", 30)
	folder = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Generaux")
	local generaux = folder :: Instance
	generaux.ChildRemoved:Connect(removeView)
	local function watch(g: Instance)
		g.AttributeChanged:Connect(function()
			local view = views[g]
			if view then
				view.label.Text = labelText(g)
			end
		end)
	end
	for _, g in generaux:GetChildren() do
		watch(g)
	end
	generaux.ChildAdded:Connect(watch)
	local clock = 0
	RunService.RenderStepped:Connect(function(dt: number)
		clock += dt
		if clock >= REFRESH then
			clock = 0
			refresh()
		end
		for g, view in views do
			local position = positionOf(g)
			if position then
				local cf = CFrame.new(position + Vector3.new(0, view.lift, 0)) * CFrame.Angles(0, math.rad(180), 0)
				if (view.model:GetPivot().Position - cf.Position).Magnitude > 0.01 then
					view.model:PivotTo(cf)
				end
			end
		end
	end)
end

-- Général dont le modèle est sous une position de l'écran (ou nil)
function GeneralRenderer.hitTest(screenPos: Vector2): Instance?
	if not container then
		return nil
	end
	local ray = workspace.CurrentCamera:ScreenPointToRay(screenPos.X, screenPos.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { container }
	local result = workspace:Raycast(ray.Origin, ray.Direction * 20000, params)
	local node: Instance? = if result then result.Instance else nil
	while node and node ~= container do
		local id = node:GetAttribute("GeneralId")
		if typeof(id) == "string" then
			return if folder then folder:FindFirstChild(id) else nil
		end
		node = node.Parent
	end
	return nil
end

-- Position d'un général sur la carte (même sans modèle affiché)
function GeneralRenderer.positionOf(g: Instance): Vector3?
	return positionOf(g)
end

return GeneralRenderer
