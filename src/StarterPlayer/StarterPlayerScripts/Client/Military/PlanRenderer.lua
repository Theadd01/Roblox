--!strict
-- Plans de bataille sur la carte (SYSTEME_MILITAIRE.md, 7.2), côté client, purement visuel, pour
-- le général dont la fiche est ouverte (lisibilité ; Roblox limite aussi le nombre de contours) :
--   régions du front entourées d'un contour aux couleurs de l'armée ;
--   flèches d'offensive au sol, du front vers chaque région visée ;
--   ligne de repli : petits jalons gris sur ses régions.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any
local GeneralPanel = require(script.Parent:WaitForChild("GeneralPanel"))

local MAX_OUTLINES = 12
local LIFT = Vector3.new(0, 0.7, 0)
local REFRESH = 0.4
-- couleur de chaque armée (d'après le numéro du général)
local PALETTE = {
	Color3.fromRGB(255, 200, 60), Color3.fromRGB(80, 200, 255), Color3.fromRGB(255, 120, 200),
	Color3.fromRGB(140, 230, 110), Color3.fromRGB(255, 150, 70), Color3.fromRGB(180, 140, 255),
}

local PlanRenderer = {}

local folder: Folder? = nil
local carteModel: Model? = nil
local support: BasePart? = nil -- pièce fixe qui porte les attaches des flèches
local attachments: { Attachment } = {}
local signature = ""

local function anchorOf(regionId: string): Vector3?
	local region = Regions[regionId]
	local city = region and region.city
	return if city then MapProjection.toVector3(city.lon, city.lat, MapSettings.regionTop) else nil
end

local function list(general: Instance, attribute: string): { string }
	local raw = general:GetAttribute(attribute)
	return if typeof(raw) == "string" and raw ~= "" then string.split(raw, ",") else {}
end

-- Couleur de l'armée d'un général
function PlanRenderer.colorOf(general: Instance): Color3
	local n = tonumber(general.Name:match("%d+")) or 1
	return PALETTE[(n - 1) % #PALETTE + 1]
end

local function clear()
	if folder then
		folder:ClearAllChildren()
	end
	for _, a in attachments do
		a:Destroy()
	end
	table.clear(attachments)
end

local function attachment(position: Vector3): Attachment
	local a = Instance.new("Attachment")
	a.Parent = support or workspace.Terrain
	a.WorldPosition = position
	table.insert(attachments, a)
	return a
end

-- Flèche au sol de `from` à `to`
local function arrow(from: Vector3, to: Vector3, color: Color3)
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	if flat.Magnitude < 0.5 then
		return
	end
	local direction = flat.Unit
	local headLength = math.clamp(flat.Magnitude * 0.2, 2, 6)
	local a0 = attachment(from + LIFT)
	local a1 = attachment(to - direction * headLength + LIFT)
	local a2 = attachment(to + LIFT)
	local function beam(x: Attachment, y: Attachment, width0: number, width1: number)
		local b = Instance.new("Beam")
		b.Attachment0 = x
		b.Attachment1 = y
		b.FaceCamera = true
		b.Width0 = width0
		b.Width1 = width1
		b.Color = ColorSequence.new(color)
		b.Transparency = NumberSequence.new(0.15)
		b.LightEmission = 0.5
		b.LightInfluence = 0
		b.Parent = x
	end
	beam(a0, a1, 1.1, 1.1)
	beam(a1, a2, 3.2, 0.05)
end

local function marker(position: Vector3, color: Color3)
	local p = Instance.new("Part")
	p.Name = "Jalon"
	p.Shape = Enum.PartType.Cylinder
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = Vector3.new(0.15, 2.2, 2.2)
	p.CFrame = CFrame.new(position + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90))
	p.Parent = folder
end

local function draw(general: Instance)
	local f = folder
	local carte = carteModel
	if not f or not carte then
		return
	end
	local color = PlanRenderer.colorOf(general)
	local regionsFolder = carte:FindFirstChild("Regions")
	local front = list(general, "Front")
	-- contours du front
	for i, regionId in front do
		if i > MAX_OUTLINES then
			break
		end
		local model = regionsFolder and regionsFolder:FindFirstChild(regionId)
		if model then
			local h = Instance.new("Highlight")
			h.Name = "Front"
			h.Adornee = model
			h.FillTransparency = 0.85
			h.FillColor = color
			h.OutlineColor = color
			h.DepthMode = Enum.HighlightDepthMode.Occluded
			h.Parent = f
		end
	end
	-- flèches : de la région du front la plus proche vers chaque objectif
	for _, target in list(general, "Objectifs") do
		local there = anchorOf(target)
		if not there then
			continue
		end
		local best: Vector3? = nil
		local bestDistance = math.huge
		for _, regionId in front do
			local here = anchorOf(regionId)
			if here and (here - there).Magnitude < bestDistance then
				best, bestDistance = here, (here - there).Magnitude
			end
		end
		if best then
			arrow(best, there, color)
		end
		marker(there, Color3.fromRGB(235, 70, 60))
	end
	-- ligne de repli
	for _, regionId in list(general, "Repli") do
		local here = anchorOf(regionId)
		if here then
			marker(here, Color3.fromRGB(170, 175, 185))
		end
	end
end

local function refresh()
	local general = GeneralPanel.current()
	local newSignature = ""
	if general and general.Parent then
		newSignature = `{general.Name}|{general:GetAttribute("Front")}|{general:GetAttribute("Objectifs")}|{general:GetAttribute("Repli")}`
	end
	if newSignature == signature then
		return
	end
	signature = newSignature
	clear()
	if general and general.Parent then
		draw(general)
	end
end

function PlanRenderer.start(carte: Model)
	local f = Instance.new("Folder")
	f.Name = "Plans"
	f.Parent = carte
	local part = Instance.new("Part")
	part.Name = "SupportFlechesPlans"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.CFrame = CFrame.identity
	part.Parent = carte
	folder, carteModel, support = f, carte, part
	local clock = 0
	RunService.RenderStepped:Connect(function(dt: number)
		clock += dt
		if clock >= REFRESH then
			clock = 0
			refresh()
		end
	end)
end

return PlanRenderer
