--!strict
-- Fortifications sur la carte (SYSTEME_MILITAIRE.md, 5.5), côté client, purement visuel : un
-- anneau de murets de béton autour de la ville d'une région fortifiée, plus fermé à chaque niveau
-- (niveau 3 : deux casemates en plus). Seulement près de la caméra (performance).
-- Le serveur publie le niveau dans ReplicatedStorage.EtatMonde.Regions.<id> (attribut Fortification).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any

local SHOW_DISTANCE = 420 -- comme les modèles des divisions
local MAX_HEIGHT = 300
local REFRESH = 0.5
local RADIUS = 7 -- rayon de l'anneau autour de la ville (studs)
local SEGMENTS = { 6, 9, 12 } -- murets par niveau
local CONCRETE = Color3.fromRGB(150, 150, 145)

local FortificationView = {}

local container: Folder? = nil
local levels: { [string]: number } = {} -- régions fortifiées -> niveau
local shown: { [string]: Model } = {}

local function anchorOf(regionId: string): Vector3?
	local region = Regions[regionId]
	local city = region and region.city
	return if city then MapProjection.toVector3(city.lon, city.lat, MapSettings.regionTop) else nil
end

local function block(model: Model, size: Vector3, cf: CFrame)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Concrete
	p.Color = CONCRETE
	p.Size = size
	p.CFrame = cf
	p.Parent = model
end

local function build(regionId: string, level: number): Model?
	local here = anchorOf(regionId)
	if not here or not container then
		return nil
	end
	local model = Instance.new("Model")
	model.Name = regionId
	local count = SEGMENTS[math.clamp(level, 1, #SEGMENTS)]
	for i = 1, count do
		local angle = (i - 1) / count * math.pi * 2
		local cf = CFrame.new(here) * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0.35, -RADIUS)
		block(model, Vector3.new(2.2, 0.7, 0.5), cf)
	end
	if level >= 3 then
		-- deux casemates de part et d'autre de la ville
		for _, side in { -1, 1 } do
			local cf = CFrame.new(here + Vector3.new(side * (RADIUS + 1.2), 0.5, 0))
			block(model, Vector3.new(1.6, 1, 1.6), cf)
			block(model, Vector3.new(0.9, 0.25, 0.3), cf * CFrame.new(0, 0.15, -0.85)) -- meurtrière
		end
	end
	model.Parent = container
	return model
end

local function refresh()
	local camera = workspace.CurrentCamera.CFrame.Position
	for regionId, level in levels do
		local here = anchorOf(regionId)
		local visible = here ~= nil and camera.Y < MAX_HEIGHT and (here - camera).Magnitude < SHOW_DISTANCE
		local model = shown[regionId]
		if visible and (not model or model:GetAttribute("Niveau") ~= level) then
			if model then
				model:Destroy()
			end
			local built = build(regionId, level)
			if built then
				built:SetAttribute("Niveau", level)
				shown[regionId] = built
			end
		elseif not visible and model then
			model:Destroy()
			shown[regionId] = nil
		end
	end
	for regionId, model in shown do
		if not levels[regionId] then
			model:Destroy()
			shown[regionId] = nil
		end
	end
end

function FortificationView.start(carte: Model)
	local folder = Instance.new("Folder")
	folder.Name = "Fortifications"
	folder.Parent = carte
	container = folder
	local regions = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Regions")
	local function watch(region: Instance)
		local function update()
			local level = region:GetAttribute("Fortification")
			levels[region.Name] = if typeof(level) == "number" and level > 0 then level else nil
		end
		update()
		region:GetAttributeChangedSignal("Fortification"):Connect(update)
	end
	for _, region in regions:GetChildren() do
		watch(region)
	end
	regions.ChildAdded:Connect(watch)
	local clock = 0
	RunService.RenderStepped:Connect(function(dt: number)
		clock += dt
		if clock >= REFRESH then
			clock = 0
			refresh()
		end
	end)
end

return FortificationView
