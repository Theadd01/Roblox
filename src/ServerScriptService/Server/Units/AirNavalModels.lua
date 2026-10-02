--!strict
-- Modèles low-poly complémentaires pour l'air et la mer (même style que StrategicModels) :
--   Drone, Helicoptere, PorteAvions, Cargo
-- L'avant est orienté vers -Z. Pièces ancrées ; « Teinte » = couleur donnée par UnitPainter.

local AirNavalModels = {}

local DEG = math.pi / 180
local GLASS = Color3.fromRGB(74, 139, 166)
local DARK = Color3.fromRGB(43, 47, 50)
local DECK = Color3.fromRGB(70, 74, 78)
local WHITE = Color3.fromRGB(225, 226, 220)
local CONTAINERS = { Color3.fromRGB(194, 54, 48), Color3.fromRGB(48, 102, 153), Color3.fromRGB(238, 194, 55), Color3.fromRGB(58, 105, 69) }

local function part(model: Model, class: string, name: string, size: Vector3, cf: CFrame, tint: string?, color: Color3?, material: Enum.Material?, shape: Enum.PartType?): BasePart
	local p = Instance.new(class) :: BasePart
	if shape then
		(p :: Part).Shape = shape
	end
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Material = material or Enum.Material.Plastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if tint then
		p:SetAttribute("Teinte", tint)
	else
		p.Color = color or WHITE
	end
	p.Parent = model
	return p
end

local function block(m: Model, name: string, size: Vector3, cf: CFrame, tint: string?, color: Color3?, material: Enum.Material?): BasePart
	return part(m, "Part", name, size, cf, tint, color, material, Enum.PartType.Block)
end
local function wedge(m: Model, name: string, size: Vector3, cf: CFrame, tint: string?, color: Color3?, material: Enum.Material?): BasePart
	return part(m, "WedgePart", name, size, cf, tint, color, material)
end
local function cylinder(m: Model, name: string, size: Vector3, cf: CFrame, tint: string?, color: Color3?, material: Enum.Material?): BasePart
	return part(m, "Part", name, size, cf, tint, color, material, Enum.PartType.Cylinder)
end
local function ball(m: Model, name: string, size: Vector3, cf: CFrame, tint: string?, color: Color3?, material: Enum.Material?): BasePart
	return part(m, "Part", name, size, cf, tint, color, material, Enum.PartType.Ball)
end

local function finish(model: Model, primary: BasePart): Model
	model.PrimaryPart = primary
	model:SetAttribute("ModeleStrategique", true)
	model:SetAttribute("OrientationAvant", "-Z")
	return model
end

-- Drone de reconnaissance : fuselage fin, grandes ailes droites, queue en V, hélice arrière
local function buildDrone(): Model
	local m = Instance.new("Model")
	m.Name = "Drone"
	local body = cylinder(m, "Fuselage", Vector3.new(4.2, 0.55, 0.55), CFrame.new(0, 1, 0) * CFrame.Angles(0, 90 * DEG, 0), "Principale", nil, Enum.Material.SmoothPlastic)
	ball(m, "Nez", Vector3.new(0.7, 0.7, 1.1), CFrame.new(0, 1.05, -2.1), "Secondaire")
	block(m, "Aile", Vector3.new(6.4, 0.1, 0.75), CFrame.new(0, 1.05, -0.2), "Principale", nil, Enum.Material.SmoothPlastic)
	for _, side in { -1, 1 } do
		block(m, "QueueV", Vector3.new(1.4, 0.08, 0.5), CFrame.new(side * 0.5, 1.35, 1.8) * CFrame.Angles(0, 0, side * 35 * DEG), "Secondaire")
	end
	cylinder(m, "Moyeu", Vector3.new(0.3, 0.3, 0.3), CFrame.new(0, 1, 2.2) * CFrame.Angles(0, 90 * DEG, 0), "Arme")
	block(m, "Helice", Vector3.new(1.3, 0.12, 0.06), CFrame.new(0, 1, 2.4), "Arme")
	ball(m, "Capteur", Vector3.new(0.45, 0.45, 0.45), CFrame.new(0, 0.62, -1.3), nil, DARK)
	block(m, "Insigne", Vector3.new(0.6, 0.04, 0.4), CFrame.new(2.2, 1.11, -0.2), "Drapeau")
	return finish(m, body)
end

-- Hélicoptère : cabine arrondie, poutre de queue, rotor principal en croix, patins
local function buildHelicoptere(): Model
	local m = Instance.new("Model")
	m.Name = "Helicoptere"
	local cabin = ball(m, "Cabine", Vector3.new(2.1, 1.9, 3.2), CFrame.new(0, 1.9, 0), "Principale", nil, Enum.Material.SmoothPlastic)
	ball(m, "Vitre", Vector3.new(1.6, 1.2, 1.4), CFrame.new(0, 2.1, -1.1), nil, GLASS, Enum.Material.Glass)
	cylinder(m, "Queue", Vector3.new(4.2, 0.45, 0.45), CFrame.new(0, 2.15, 3.3) * CFrame.Angles(0, 90 * DEG, 0), "Principale")
	wedge(m, "Derive", Vector3.new(0.15, 1.1, 0.9), CFrame.new(0, 2.75, 5.25) * CFrame.Angles(0, 180 * DEG, 0), "Secondaire")
	block(m, "RotorArriere", Vector3.new(0.08, 1.3, 0.14), CFrame.new(0.2, 2.6, 5.35), "Arme")
	cylinder(m, "Mat", Vector3.new(0.5, 0.3, 0.3), CFrame.new(0, 3.05, 0) * CFrame.Angles(0, 0, 90 * DEG), "Arme")
	for _, angle in { 45, -45 } do
		block(m, "Pale", Vector3.new(8, 0.08, 0.35), CFrame.new(0, 3.3, 0) * CFrame.Angles(0, angle * DEG, 0), "Arme")
	end
	for _, side in { -1, 1 } do
		block(m, "Patin", Vector3.new(0.18, 0.18, 3.6), CFrame.new(side * 0.9, 0.35, 0), nil, DARK)
		block(m, "Jambe", Vector3.new(0.12, 0.8, 0.12), CFrame.new(side * 0.9, 0.8, -0.8), nil, DARK)
		block(m, "Jambe", Vector3.new(0.12, 0.8, 0.12), CFrame.new(side * 0.9, 0.8, 0.8), nil, DARK)
	end
	block(m, "Insigne", Vector3.new(0.05, 0.5, 0.7), CFrame.new(1.02, 2.0, 0.6), "Drapeau")
	return finish(m, cabin)
end

-- Porte-avions : longue coque, pont d'envol sombre avec marquages, îlot à tribord, avions au pont
local function buildPorteAvions(): Model
	local m = Instance.new("Model")
	m.Name = "PorteAvions"
	local hull = block(m, "Coque", Vector3.new(4.2, 1.4, 14), CFrame.new(0, 0.9, 0), "Principale", nil, Enum.Material.Metal)
	wedge(m, "Etrave", Vector3.new(4.2, 1.4, 2.4), CFrame.new(0, 0.9, -8.2) * CFrame.Angles(0, 180 * DEG, 0), "Principale", nil, Enum.Material.Metal)
	block(m, "LigneFlottaison", Vector3.new(4.26, 0.2, 14.1), CFrame.new(0, 0.3, 0), "Secondaire")
	block(m, "Pont", Vector3.new(5.2, 0.2, 16.4), CFrame.new(0.3, 1.7, -0.9), nil, DECK, Enum.Material.Concrete)
	for i = -3, 3 do
		block(m, "Marquage", Vector3.new(0.18, 0.02, 1.1), CFrame.new(0.3, 1.81, i * 2.2 - 0.9), nil, WHITE)
	end
	block(m, "Ilot", Vector3.new(1.1, 2.2, 2.6), CFrame.new(2.2, 2.9, 1.6), "Secondaire")
	block(m, "Passerelle", Vector3.new(1.3, 0.6, 1.2), CFrame.new(2.2, 4.2, 1.2), "Principale")
	block(m, "Vitres", Vector3.new(1.32, 0.22, 0.05), CFrame.new(2.2, 4.25, 0.58), nil, GLASS, Enum.Material.Glass)
	cylinder(m, "Mat", Vector3.new(1.6, 0.14, 0.14), CFrame.new(2.2, 5.2, 1.6) * CFrame.Angles(0, 0, 90 * DEG), nil, DARK)
	block(m, "Pavillon", Vector3.new(0.06, 0.5, 0.8), CFrame.new(2.2, 5.7, 2.05), "Drapeau")
	-- deux petits avions garés sur le pont
	for _, z in { -5.5, -2.5 } do
		block(m, "AvionPont", Vector3.new(0.35, 0.3, 1.9), CFrame.new(-1.1, 1.95, z), "Secondaire")
		block(m, "AilePont", Vector3.new(1.8, 0.08, 0.6), CFrame.new(-1.1, 1.95, z + 0.1), "Secondaire")
	end
	return finish(m, hull)
end

-- Cargo commercial : coque, conteneurs colorés, château arrière (servira aux routes commerciales)
local function buildCargo(): Model
	local m = Instance.new("Model")
	m.Name = "Cargo"
	local hull = block(m, "Coque", Vector3.new(3.4, 1.5, 11), CFrame.new(0, 0.95, 0), "Principale", nil, Enum.Material.Metal)
	wedge(m, "Etrave", Vector3.new(3.4, 1.5, 2), CFrame.new(0, 0.95, -6.5) * CFrame.Angles(0, 180 * DEG, 0), "Principale", nil, Enum.Material.Metal)
	block(m, "LigneFlottaison", Vector3.new(3.46, 0.2, 11.1), CFrame.new(0, 0.3, 0), "Secondaire")
	for row = 0, 2 do
		for col = -1, 1, 2 do
			local color = CONTAINERS[(row * 2 + (col + 1) / 2) % #CONTAINERS + 1]
			block(m, "Conteneur", Vector3.new(1.45, 0.9, 2.3), CFrame.new(col * 0.8, 2.15, -3.6 + row * 2.5), nil, color)
		end
	end
	block(m, "Chateau", Vector3.new(2.8, 2.2, 2.2), CFrame.new(0, 2.8, 4.1), nil, WHITE)
	block(m, "Vitres", Vector3.new(2.82, 0.3, 0.05), CFrame.new(0, 3.5, 2.98), nil, GLASS, Enum.Material.Glass)
	cylinder(m, "Cheminee", Vector3.new(1.3, 0.6, 0.6), CFrame.new(0, 4.4, 4.6) * CFrame.Angles(0, 0, 90 * DEG), "Secondaire")
	block(m, "Pavillon", Vector3.new(0.06, 0.45, 0.7), CFrame.new(0, 5.2, 5.0), "Drapeau")
	return finish(m, hull)
end

-- Ajoute les modèles dans le dossier fourni (remplace ceux qui portent le même nom)
function AirNavalModels.populate(folder: Instance)
	for _, build in { buildDrone, buildHelicoptere, buildPorteAvions, buildCargo } do
		local model = build()
		local previous = folder:FindFirstChild(model.Name)
		if previous then
			previous:Destroy()
		end
		model.Parent = folder
	end
end

return AirNavalModels
