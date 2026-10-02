--!strict
-- Bâtiments sur la carte : petit modèle low-poly par type (aciérie, usine de puces, champs de blé,
-- mine, puits, camp militaire), posé près de la ville de sa région (4 emplacements).
-- En chantier : transparent, avec le temps restant ; en service : fumée aux cheminées des usines.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Factories = require(Config:WaitForChild("Factories")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any
local FactoryState = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("FactoryState"))

local FONT = Font.fromEnum(Enum.Font.BuilderSansBold)
-- Emplacements autour de la ville (à l'ouest : l'est est occupé par la vitrine d'unités)
local SLOTS = { Vector3.new(-9, 0, -5), Vector3.new(-16, 0, 2), Vector3.new(-8, 0, 8), Vector3.new(-17, 0, 10) }
local STATUS_COLORS = {
	Construction = Color3.fromRGB(235, 190, 70),
	Active = Color3.fromRGB(120, 220, 130),
	Partielle = Color3.fromRGB(240, 160, 70),
	Arret = Color3.fromRGB(235, 95, 85),
}

local FactoryView = {}

local container: Folder? = nil
local models: { [Instance]: Model } = {}

local function part(model: Model, name: string, size: Vector3, cf: CFrame, color: Color3, class: string?, shape: Enum.PartType?): BasePart
	local p: BasePart = if class == "Wedge" then Instance.new("WedgePart") else Instance.new("Part")
	if shape then
		(p :: Part).Shape = shape
	end
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.Plastic
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Parent = model
	return p
end

-- Cheminée avec sa fumée (allumée quand l'usine tourne)
local function chimney(m: Model, cf: CFrame, color: Color3)
	local c = part(m, "Cheminee", Vector3.new(4.6, 0.7, 0.7), cf * CFrame.Angles(0, 0, math.rad(90)), color, nil, Enum.PartType.Cylinder)
	local top = Instance.new("Attachment")
	top.Name = "Sommet"
	top.Position = Vector3.new(2.3, 0, 0) -- l'axe du cylindre (X local) est vertical
	top.Parent = c
	local smoke = Instance.new("ParticleEmitter")
	smoke.Name = "Fumee"
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Rate = 3
	smoke.Lifetime = NumberRange.new(2, 3)
	smoke.Speed = NumberRange.new(1.5, 2.5)
	smoke.SpreadAngle = Vector2.new(10, 10)
	smoke.Size = NumberSequence.new(0.6, 2.5)
	smoke.Transparency = NumberSequence.new(0.4, 1)
	smoke.Color = ColorSequence.new(Color3.fromRGB(200, 200, 200))
	smoke.Acceleration = Vector3.new(0, 1, 0)
	smoke.Enabled = false
	smoke.Parent = top
end

-- Aciérie (et usine par défaut) : hangar à toit en dents de scie, deux cheminées
local function factoryModel(m: Model)
	local concrete, walls, brick = Color3.fromRGB(150, 150, 152), Color3.fromRGB(196, 190, 178), Color3.fromRGB(150, 72, 56)
	part(m, "Dalle", Vector3.new(7, 0.4, 5), CFrame.new(0, 0.2, 0), concrete)
	part(m, "Hangar", Vector3.new(5, 2.6, 3.4), CFrame.new(-0.8, 1.7, 0), walls)
	-- toit en dents de scie
	for _, z in { -0.85, 0.85 } do
		part(m, "Toit", Vector3.new(5, 0.8, 1.7), CFrame.new(-0.8, 3.4, z), Color3.fromRGB(110, 110, 118), "Wedge")
	end
	part(m, "Liseré", Vector3.new(5.02, 0.35, 0.06), CFrame.new(-0.8, 2.6, -1.72), Color3.new(1, 1, 1))
	for _, z in { -0.8, 0.8 } do
		chimney(m, CFrame.new(2.2, 2.7, z), brick)
	end
end

-- Usine de puces : bâtiment blanc moderne, bandeau vitré
local function chipModel(m: Model)
	part(m, "Dalle", Vector3.new(7, 0.4, 5), CFrame.new(0, 0.2, 0), Color3.fromRGB(170, 172, 178))
	part(m, "Batiment", Vector3.new(5, 2.2, 3.6), CFrame.new(-0.5, 1.5, 0), Color3.fromRGB(236, 238, 242))
	part(m, "Vitres", Vector3.new(5.02, 0.6, 3.62), CFrame.new(-0.5, 2, 0), Color3.fromRGB(70, 140, 200))
	part(m, "Toit", Vector3.new(4.2, 0.5, 2.8), CFrame.new(-0.5, 2.85, 0), Color3.fromRGB(205, 208, 214))
	part(m, "Liseré", Vector3.new(5.04, 0.25, 0.06), CFrame.new(-0.5, 1, -1.82), Color3.new(1, 1, 1))
	part(m, "Clim", Vector3.new(0.8, 0.5, 0.8), CFrame.new(2.6, 0.65, 1.4), Color3.fromRGB(150, 155, 160))
end

-- Champs de blé : bandes dorées et vertes, grange rouge et silo
local function farmModel(m: Model)
	part(m, "Dalle", Vector3.new(7, 0.3, 5), CFrame.new(0, 0.15, 0), Color3.fromRGB(110, 86, 52))
	local colors = { Color3.fromRGB(226, 190, 82), Color3.fromRGB(120, 168, 70), Color3.fromRGB(232, 200, 96) }
	for i, color in colors do
		part(m, "Champ", Vector3.new(4.2, 0.35, 1.3), CFrame.new(-1.2, 0.35, -3 + i * 1.5), color)
	end
	part(m, "Grange", Vector3.new(1.6, 1.4, 1.8), CFrame.new(2.4, 1, -0.9), Color3.fromRGB(168, 52, 44))
	part(m, "Toit", Vector3.new(1.8, 0.7, 1.9), CFrame.new(2.4, 2.05, -0.9), Color3.fromRGB(90, 40, 34), "Wedge")
	part(m, "Silo", Vector3.new(2.6, 1, 1), CFrame.new(2.6, 1.45, 1.4) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(200, 200, 205), nil, Enum.PartType.Cylinder)
	part(m, "Liseré", Vector3.new(0.1, 0.3, 1.82), CFrame.new(1.58, 1.3, -0.9), Color3.new(1, 1, 1))
end

-- Mine : chevalement (deux montants et une poulie), tas de minerai, wagonnet
local function mineModel(m: Model)
	part(m, "Dalle", Vector3.new(6, 0.4, 5), CFrame.new(0, 0.2, 0), Color3.fromRGB(96, 88, 80))
	for _, z in { -0.7, 0.7 } do
		part(m, "Montant", Vector3.new(0.3, 4, 0.3), CFrame.new(-1, 2.3, z) * CFrame.Angles(math.rad(if z > 0 then -10 else 10), 0, 0), Color3.fromRGB(60, 62, 70))
	end
	part(m, "Traverse", Vector3.new(0.3, 0.3, 1.6), CFrame.new(-1, 4.1, 0), Color3.fromRGB(60, 62, 70))
	part(m, "Poulie", Vector3.new(0.25, 1.1, 1.1), CFrame.new(-1, 4.1, 0), Color3.fromRGB(170, 60, 50), nil, Enum.PartType.Cylinder)
	part(m, "Minerai", Vector3.new(2.2, 1.2, 2.2), CFrame.new(1.6, 0.9, 0.6), Color3.fromRGB(45, 42, 40), "Wedge")
	part(m, "Wagonnet", Vector3.new(1, 0.6, 0.7), CFrame.new(1.2, 0.7, -1.5), Color3.fromRGB(120, 90, 60))
	part(m, "Liseré", Vector3.new(1.02, 0.15, 0.72), CFrame.new(1.2, 0.95, -1.5), Color3.new(1, 1, 1))
end

-- Puits de pétrole et de gaz : chevalet de pompage et réservoir
local function wellModel(m: Model)
	part(m, "Dalle", Vector3.new(6, 0.4, 5), CFrame.new(0, 0.2, 0), Color3.fromRGB(150, 140, 120))
	part(m, "Pied", Vector3.new(0.5, 2.2, 0.5), CFrame.new(-0.6, 1.5, 0), Color3.fromRGB(70, 72, 80))
	part(m, "Balancier", Vector3.new(4, 0.4, 0.4), CFrame.new(-0.6, 2.7, 0) * CFrame.Angles(0, 0, math.rad(12)), Color3.fromRGB(230, 170, 40))
	part(m, "Tete", Vector3.new(0.6, 1.1, 0.6), CFrame.new(-2.4, 2.2, 0), Color3.fromRGB(40, 40, 46))
	part(m, "Reservoir", Vector3.new(2, 1.6, 1.6), CFrame.new(2, 1.2, 0.8) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(205, 205, 210), nil, Enum.PartType.Cylinder)
	part(m, "Liseré", Vector3.new(0.3, 1.62, 1.62), CFrame.new(2, 1.2, 0.8) * CFrame.Angles(0, 0, math.rad(90)), Color3.new(1, 1, 1), nil, Enum.PartType.Cylinder)
end

-- Camp militaire : tentes kaki, mât et drapeau aux couleurs du pays
local function campModel(m: Model)
	part(m, "Dalle", Vector3.new(7, 0.3, 5), CFrame.new(0, 0.15, 0), Color3.fromRGB(120, 112, 84))
	for i = 0, 2 do
		part(m, "Tente", Vector3.new(1.4, 1.1, 0.9), CFrame.new(-2.4 + i * 1.8, 0.85, -1.45), Color3.fromRGB(96, 110, 70), "Wedge")
		part(m, "Tente", Vector3.new(1.4, 1.1, 0.9), CFrame.new(-2.4 + i * 1.8, 0.85, -0.55) * CFrame.Angles(0, math.rad(180), 0), Color3.fromRGB(86, 100, 62), "Wedge")
	end
	part(m, "Mat", Vector3.new(0.15, 3.6, 0.15), CFrame.new(2.4, 2.1, 1.4), Color3.fromRGB(200, 200, 200))
	part(m, "Liseré", Vector3.new(1.2, 0.7, 0.06), CFrame.new(3.05, 3.5, 1.4), Color3.new(1, 1, 1))
	part(m, "Caisses", Vector3.new(0.8, 0.6, 0.8), CFrame.new(0.4, 0.6, 1.5), Color3.fromRGB(130, 100, 60))
end

-- Modèle d'un bâtiment centré sur l'origine, posé sur y = 0, avec son étiquette (nom, état)
local function makeModel(typeId: string): Model
	local m = Instance.new("Model")
	m.Name = "Usine"
	if typeId == "Ferme" then
		farmModel(m)
	elseif typeId == "Mine" then
		mineModel(m)
	elseif typeId == "Puits" then
		wellModel(m)
	elseif typeId == "UsinePuces" then
		chipModel(m)
	elseif typeId == "CampMilitaire" then
		campModel(m)
	else
		factoryModel(m)
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "Etiquette"
	gui.Size = UDim2.fromOffset(190, 40)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 7, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 300
	for i, name in { "Nom", "Statut" } do
		local label = Instance.new("TextLabel")
		label.Name = name
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromOffset(0, (i - 1) * 20)
		label.Size = UDim2.new(1, 0, 0, 20)
		label.FontFace = FONT
		label.TextSize = if i == 1 then 16 else 14
		label.TextColor3 = Color3.new(1, 1, 1)
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1.5
		stroke.Parent = label
		label.Parent = gui
	end
	gui.Parent = m
	m.WorldPivot = CFrame.identity -- pivot au centre de la dalle, au niveau du sol
	return m
end

local function slotPosition(factory: Instance): Vector3?
	local regionId = factory:GetAttribute("Region")
	local region = if typeof(regionId) == "string" then Regions[regionId] else nil
	local city = region and region.city
	if not city then
		return nil
	end
	local index = table.find(FactoryState.inRegion(regionId :: string), factory) or 1
	local base = MapProjection.toVector3(city.lon, city.lat, MapSettings.regionTop)
	return base + SLOTS[math.clamp(index, 1, #SLOTS)]
end

local function statusText(factory: Instance): (string, Color3)
	local status = factory:GetAttribute("Statut")
	if status == "Construction" then
		local left = (factory:GetAttribute("FinConstruction") :: number) - workspace:GetServerTimeNow()
		return `Construction : {math.max(0, math.ceil(left))} s`, STATUS_COLORS.Construction
	elseif status == "Active" then
		return "En service", STATUS_COLORS.Active
	elseif status == "Partielle" then
		return `Ralentie : manque {factory:GetAttribute("Manque")}`, STATUS_COLORS.Partielle
	end
	return `Arrêtée : manque {factory:GetAttribute("Manque")}`, STATUS_COLORS.Arret
end

local function update(factory: Instance)
	local model = models[factory]
	if not model then
		return
	end
	local kind = Factories.types[factory:GetAttribute("Type") :: string]
	local building = factory:GetAttribute("Statut") == "Construction"
	local running = factory:GetAttribute("Statut") == "Active" or factory:GetAttribute("Statut") == "Partielle"
	local owner = Countries[factory:GetAttribute("Proprietaire") :: string]

	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Transparency = if building and d.Name ~= "Dalle" then 0.65 else 0
		elseif d:IsA("ParticleEmitter") then
			d.Enabled = running
		end
	end
	local stripe = model:FindFirstChild("Liseré") :: BasePart?
	if stripe and owner then
		stripe.Color = owner.color
	end
	local gui = model:FindFirstChild("Etiquette") :: BillboardGui
	local nameLabel = gui:FindFirstChild("Nom") :: TextLabel
	local statusLabel = gui:FindFirstChild("Statut") :: TextLabel
	nameLabel.Text = `{kind.icon} {kind.name} niv. {factory:GetAttribute("Niveau")}`
	local text, color = statusText(factory)
	statusLabel.Text = text
	statusLabel.TextColor3 = color
end

local function ensure(factory: Instance)
	if models[factory] or not container then
		return
	end
	local position = slotPosition(factory)
	if not position then
		return
	end
	local model = makeModel(factory:GetAttribute("Type") :: string)
	model.Name = factory.Name
	model:PivotTo(CFrame.new(position) * CFrame.Angles(0, math.rad(180), 0))
	model.Parent = container
	models[factory] = model
end

function FactoryView.start(carte: Model)
	local folder = Instance.new("Folder")
	folder.Name = "Usines"
	folder.Parent = carte
	container = folder

	FactoryState.onChanged(function(factory: Instance, removed: boolean)
		if removed then
			local model = models[factory]
			if model then
				model:Destroy()
				models[factory] = nil
			end
			return
		end
		ensure(factory)
		update(factory)
	end)
	for _, factory in FactoryState.list() do
		ensure(factory)
		update(factory)
	end

	-- compte à rebours des chantiers (4 fois par seconde suffit)
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed < 0.25 then
			return
		end
		elapsed = 0
		for factory in models do
			if factory:GetAttribute("Statut") == "Construction" then
				update(factory)
			end
		end
	end)
end

return FactoryView
