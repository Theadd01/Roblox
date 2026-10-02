--!strict
-- Modèles stratégiques low-poly construits uniquement avec des primitives Roblox.
-- L'avant des véhicules est orienté vers -Z. Toutes les pièces sont statiques afin
-- que les clients puissent cloner puis déplacer les modèles avec Model:PivotTo().

local StrategicModels = {}

type Tint = "Principale" | "Secondaire" | "Chenilles" | "Roues" | "Arme" | "Drapeau"

local DEG = math.pi / 180

local DARK = Color3.fromRGB(43, 47, 50)
local BLACK = Color3.fromRGB(20, 23, 25)
local METAL = Color3.fromRGB(92, 99, 103)
local LIGHT_METAL = Color3.fromRGB(155, 163, 166)
local CONCRETE = Color3.fromRGB(135, 137, 132)
local LIGHT_CONCRETE = Color3.fromRGB(184, 181, 169)
local GLASS = Color3.fromRGB(74, 139, 166)
local ROAD = Color3.fromRGB(57, 59, 61)
local WOOD = Color3.fromRGB(112, 78, 48)
local BRICK = Color3.fromRGB(146, 75, 59)
local ROOF = Color3.fromRGB(71, 76, 80)
local WHITE = Color3.fromRGB(225, 226, 220)
local YELLOW = Color3.fromRGB(238, 194, 55)
local RED = Color3.fromRGB(194, 54, 48)
local BLUE = Color3.fromRGB(48, 102, 153)
local GREEN = Color3.fromRGB(58, 105, 69)

local function configure(
	part: BasePart,
	name: string,
	size: Vector3,
	cf: CFrame,
	tint: Tint?,
	color: Color3?,
	material: Enum.Material?
): BasePart
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = true
	part.Material = material or Enum.Material.Plastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if tint ~= nil then
		part:SetAttribute("Teinte", tint)
	else
		part.Color = color or LIGHT_CONCRETE
	end
	return part
end

local function block(
	model: Model,
	name: string,
	size: Vector3,
	cf: CFrame,
	tint: Tint?,
	color: Color3?,
	material: Enum.Material?
): Part
	local part = configure(Instance.new("Part"), name, size, cf, tint, color, material) :: Part
	part.Shape = Enum.PartType.Block
	part.Parent = model
	return part
end

local function wedge(
	model: Model,
	name: string,
	size: Vector3,
	cf: CFrame,
	tint: Tint?,
	color: Color3?,
	material: Enum.Material?
): WedgePart
	local part = configure(Instance.new("WedgePart"), name, size, cf, tint, color, material) :: WedgePart
	part.Parent = model
	return part
end

local function cylinder(
	model: Model,
	name: string,
	size: Vector3,
	cf: CFrame,
	tint: Tint?,
	color: Color3?,
	material: Enum.Material?
): Part
	local part = configure(Instance.new("Part"), name, size, cf, tint, color, material) :: Part
	part.Shape = Enum.PartType.Cylinder
	part.Parent = model
	return part
end

local function ball(
	model: Model,
	name: string,
	size: Vector3,
	cf: CFrame,
	tint: Tint?,
	color: Color3?,
	material: Enum.Material?
): Part
	local part = configure(Instance.new("Part"), name, size, cf, tint, color, material) :: Part
	part.Shape = Enum.PartType.Ball
	part.Parent = model
	return part
end

-- Crée un cylindre entre deux points. L'axe longitudinal d'un Part Cylinder est X.
local function beam(
	model: Model,
	name: string,
	from: Vector3,
	to: Vector3,
	diameter: number,
	tint: Tint?,
	color: Color3?,
	material: Enum.Material?
): Part
	local delta = to - from
	local length = delta.Magnitude
	local midpoint = from + delta * 0.5
	local cf = CFrame.lookAt(midpoint, to) * CFrame.Angles(0, 90 * DEG, 0)
	return cylinder(model, name, Vector3.new(length, diameter, diameter), cf, tint, color, material)
end

local function finish(model: Model, primary: BasePart): Model
	model.PrimaryPart = primary
	model:SetAttribute("ModeleStrategique", true)
	model:SetAttribute("OrientationAvant", "-Z")
	return model
end

local function newModel(name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	return model
end

local function addWheels(model: Model, zPositions: { number }, halfWidth: number, radius: number)
	for _, side in { -1, 1 } do
		for _, z in zPositions do
			cylinder(
				model,
				"Roue",
				Vector3.new(0.34, radius * 2, radius * 2),
				CFrame.new(side * halfWidth, radius, z),
				"Roues",
				nil,
				Enum.Material.SmoothPlastic
			)
		end
	end
end

local function buildArtillerie(): Model
	local model = newModel("Artillerie")
	local chassis = block(model, "Affut", Vector3.new(1.5, 0.32, 2.8), CFrame.new(0, 0.72, 0.2), "Principale", nil, nil)
	block(model, "Essieu", Vector3.new(3.1, 0.22, 0.24), CFrame.new(0, 0.68, 0.45), "Secondaire", nil, Enum.Material.Metal)
	addWheels(model, { 0.45 }, 1.62, 0.72)
	wedge(model, "BouclierGauche", Vector3.new(1.45, 1.7, 0.22), CFrame.new(-0.78, 1.55, -0.62), "Principale", nil, nil)
	wedge(model, "BouclierDroit", Vector3.new(1.45, 1.7, 0.22), CFrame.new(0.78, 1.55, -0.62), "Principale", nil, nil)
	block(model, "Culasse", Vector3.new(0.72, 0.65, 1.1), CFrame.new(0, 1.55, -0.35), "Secondaire", nil, Enum.Material.Metal)
	beam(model, "Canon", Vector3.new(0, 1.62, -0.55), Vector3.new(0, 1.92, -4.55), 0.34, "Arme", nil, Enum.Material.Metal)
	beam(model, "FreinDeBouche", Vector3.new(0, 1.89, -4.25), Vector3.new(0, 1.96, -4.85), 0.54, "Arme", nil, Enum.Material.Metal)
	for _, x in { -0.52, 0.52 } do
		beam(model, "Fleche", Vector3.new(x, 0.53, 0.65), Vector3.new(x * 1.5, 0.18, 3.8), 0.2, "Secondaire", nil, Enum.Material.Metal)
		block(model, "Beche", Vector3.new(0.75, 0.18, 0.55), CFrame.new(x * 1.5, 0.19, 3.85), "Secondaire", nil, Enum.Material.Metal)
	end
	block(model, "Marquage", Vector3.new(0.55, 0.3, 0.04), CFrame.new(1.05, 1.65, -0.75), "Drapeau", nil, nil)
	return finish(model, chassis)
end

local function buildAvion(): Model
	local model = newModel("Avion")
	local fuselage = cylinder(
		model,
		"Fuselage",
		Vector3.new(7.2, 1.08, 1.08),
		CFrame.new(0, 1.32, 0) * CFrame.Angles(0, 90 * DEG, 0),
		"Principale",
		nil,
		Enum.Material.SmoothPlastic
	)
	ball(model, "Nez", Vector3.new(1.1, 1.1, 1.8), CFrame.new(0, 1.32, -3.9), "Secondaire", nil, nil)
	ball(model, "Verriere", Vector3.new(0.9, 0.62, 1.55), CFrame.new(0, 1.88, -1.1), nil, GLASS, Enum.Material.Glass)
	block(model, "Aile", Vector3.new(7.8, 0.18, 2.4), CFrame.new(0, 1.34, 0.25), "Principale", nil, Enum.Material.SmoothPlastic)
	for _, side in { -1, 1 } do
		wedge(
			model,
			"BoutAile",
			Vector3.new(1.25, 0.18, 2.4),
			CFrame.new(side * 4.45, 1.34, 0.25) * CFrame.Angles(0, side * 180 * DEG, 0),
			"Secondaire",
			nil,
			Enum.Material.SmoothPlastic
		)
		cylinder(
			model,
			"Reacteur",
			Vector3.new(2.25, 0.68, 0.68),
			CFrame.new(side * 1.9, 1.05, 0.35) * CFrame.Angles(0, 90 * DEG, 0),
			"Secondaire",
			nil,
			Enum.Material.Metal
		)
	end
	block(model, "Empennage", Vector3.new(3.4, 0.13, 1.35), CFrame.new(0, 1.42, 2.95), "Secondaire", nil, nil)
	wedge(model, "Derive", Vector3.new(0.18, 1.65, 1.55), CFrame.new(0, 2.08, 2.85) * CFrame.Angles(0, 180 * DEG, 0), "Principale", nil, nil)
	block(model, "Insigne", Vector3.new(0.8, 0.05, 0.52), CFrame.new(2.4, 1.46, 0.15), "Drapeau", nil, nil)
	return finish(model, fuselage)
end

local function buildNavire(): Model
	local model = newModel("Navire")
	local hull = block(model, "Coque", Vector3.new(3.2, 1.05, 9.4), CFrame.new(0, 0.92, 0.7), "Principale", nil, Enum.Material.Metal)
	wedge(model, "Etrave", Vector3.new(3.2, 1.55, 2.5), CFrame.new(0, 1.15, -5.25) * CFrame.Angles(0, 180 * DEG, 0), "Principale", nil, Enum.Material.Metal)
	block(model, "LigneFlottaison", Vector3.new(3.26, 0.18, 9.5), CFrame.new(0, 0.42, 0.75), "Secondaire", nil, nil)
	block(model, "Pont", Vector3.new(2.85, 0.18, 8.4), CFrame.new(0, 1.52, 0.2), nil, WOOD, Enum.Material.Wood)
	block(model, "Superstructure", Vector3.new(2.05, 1.35, 2.55), CFrame.new(0, 2.22, 0.85), "Secondaire", nil, nil)
	block(model, "Passerelle", Vector3.new(2.45, 0.72, 1.2), CFrame.new(0, 3.05, -0.15), "Principale", nil, nil)
	block(model, "Vitres", Vector3.new(2.48, 0.28, 0.05), CFrame.new(0, 3.12, -0.78), nil, GLASS, Enum.Material.Glass)
	cylinder(model, "Cheminee", Vector3.new(1.45, 0.68, 0.68), CFrame.new(0, 3.25, 1.95) * CFrame.Angles(0, 0, 90 * DEG), nil, DARK, Enum.Material.Metal)
	beam(model, "Mat", Vector3.new(0, 3.15, 0.85), Vector3.new(0, 5.25, 0.85), 0.12, nil, METAL, Enum.Material.Metal)
	block(model, "Pavillon", Vector3.new(0.08, 0.55, 0.9), CFrame.new(0, 4.85, 1.28), "Drapeau", nil, nil)
	for _, z in { -3.2, 3.6 } do
		cylinder(model, "Tourelle", Vector3.new(0.45, 1.15, 1.15), CFrame.new(0, 1.95, z) * CFrame.Angles(0, 0, 90 * DEG), "Principale", nil, Enum.Material.Metal)
		beam(model, "Canon", Vector3.new(0, 2.05, z - 0.25), Vector3.new(0, 2.2, z - 1.75), 0.18, "Arme", nil, Enum.Material.Metal)
	end
	return finish(model, hull)
end

local function buildCamion(): Model
	local model = newModel("Camion")
	local chassis = block(model, "Chassis", Vector3.new(2.35, 0.32, 5.4), CFrame.new(0, 0.82, 0), "Secondaire", nil, Enum.Material.Metal)
	addWheels(model, { -1.65, 1.6 }, 1.32, 0.58)
	block(model, "Cabine", Vector3.new(2.2, 1.65, 1.6), CFrame.new(0, 1.72, -1.65), "Principale", nil, nil)
	wedge(model, "Capot", Vector3.new(2.2, 0.78, 1.0), CFrame.new(0, 1.3, -2.95) * CFrame.Angles(0, 180 * DEG, 0), "Principale", nil, nil)
	block(model, "PareBrise", Vector3.new(1.65, 0.55, 0.05), CFrame.new(0, 1.95, -2.47), nil, GLASS, Enum.Material.Glass)
	block(model, "Caisse", Vector3.new(2.25, 1.45, 2.7), CFrame.new(0, 1.65, 1.3), "Secondaire", nil, nil)
	block(model, "Bache", Vector3.new(2.32, 0.22, 2.78), CFrame.new(0, 2.48, 1.3), "Principale", nil, nil)
	block(model, "PareChocs", Vector3.new(2.45, 0.25, 0.25), CFrame.new(0, 0.75, -3.45), nil, METAL, Enum.Material.Metal)
	for _, x in { -0.72, 0.72 } do
		ball(model, "Phare", Vector3.new(0.24, 0.24, 0.15), CFrame.new(x, 1.12, -3.47), nil, YELLOW, Enum.Material.Neon)
	end
	block(model, "Marquage", Vector3.new(0.04, 0.45, 0.75), CFrame.new(1.13, 1.8, -1.65), "Drapeau", nil, nil)
	return finish(model, chassis)
end

local function buildVehiculeBlinde(): Model
	local model = newModel("VehiculeBlinde")
	local hull = block(model, "Coque", Vector3.new(3.0, 1.25, 5.5), CFrame.new(0, 1.18, 0.15), "Principale", nil, Enum.Material.Metal)
	wedge(model, "BlindageAvant", Vector3.new(3.0, 1.25, 1.15), CFrame.new(0, 1.18, -3.18) * CFrame.Angles(0, 180 * DEG, 0), "Principale", nil, Enum.Material.Metal)
	addWheels(model, { -1.75, 0, 1.75 }, 1.7, 0.61)
	for _, side in { -1, 1 } do
		block(model, "GardeBoue", Vector3.new(0.32, 0.18, 5.75), CFrame.new(side * 1.66, 1.18, 0.12), "Secondaire", nil, Enum.Material.Metal)
	end
	cylinder(model, "Tourelle", Vector3.new(0.55, 1.55, 1.55), CFrame.new(0, 2.18, -0.3) * CFrame.Angles(0, 0, 90 * DEG), "Secondaire", nil, Enum.Material.Metal)
	beam(model, "Mitrailleuse", Vector3.new(0, 2.35, -0.85), Vector3.new(0, 2.45, -2.55), 0.17, "Arme", nil, Enum.Material.Metal)
	block(model, "Trappe", Vector3.new(0.72, 0.16, 0.9), CFrame.new(0.45, 2.58, 0.2), "Secondaire", nil, nil)
	block(model, "Marquage", Vector3.new(0.05, 0.42, 0.72), CFrame.new(1.53, 1.65, 0.9), "Drapeau", nil, nil)
	return finish(model, hull)
end

local function buildAntiaerien(): Model
	local model = newModel("Antiaerien")
	local chassis = block(model, "Chassis", Vector3.new(2.75, 0.55, 4.7), CFrame.new(0, 0.78, 0.25), "Principale", nil, Enum.Material.Metal)
	addWheels(model, { -1.3, 1.35 }, 1.55, 0.58)
	cylinder(model, "Plateforme", Vector3.new(0.42, 2.4, 2.4), CFrame.new(0, 1.28, 0.2) * CFrame.Angles(0, 0, 90 * DEG), "Secondaire", nil, Enum.Material.Metal)
	block(model, "Siege", Vector3.new(0.75, 0.95, 0.65), CFrame.new(0, 1.95, 1.0), "Principale", nil, nil)
	block(model, "Bouclier", Vector3.new(2.15, 1.35, 0.18), CFrame.new(0, 2.05, -0.45), "Principale", nil, Enum.Material.Metal)
	for _, x in { -0.48, 0.48 } do
		beam(model, "CanonAA", Vector3.new(x, 2.15, -0.35), Vector3.new(x, 3.45, -3.25), 0.2, "Arme", nil, Enum.Material.Metal)
		beam(model, "FreinDeBouche", Vector3.new(x, 3.25, -2.8), Vector3.new(x, 3.58, -3.55), 0.32, "Arme", nil, Enum.Material.Metal)
	end
	block(model, "Marquage", Vector3.new(0.72, 0.36, 0.04), CFrame.new(0.75, 2.2, -0.55), "Drapeau", nil, nil)
	return finish(model, chassis)
end

local function buildBombardier(): Model
	local model = newModel("Bombardier")
	local fuselage = cylinder(
		model,
		"Fuselage",
		Vector3.new(10.8, 1.4, 1.4),
		CFrame.new(0, 1.65, 0) * CFrame.Angles(0, 90 * DEG, 0),
		"Principale",
		nil,
		Enum.Material.Metal
	)
	ball(model, "NezVitre", Vector3.new(1.38, 1.38, 2.0), CFrame.new(0, 1.65, -5.55), nil, GLASS, Enum.Material.Glass)
	block(model, "Aile", Vector3.new(11.8, 0.28, 3.4), CFrame.new(0, 1.62, 0.2), "Principale", nil, Enum.Material.Metal)
	for _, side in { -1, 1 } do
		wedge(
			model,
			"BoutAile",
			Vector3.new(2.1, 0.28, 3.4),
			CFrame.new(side * 6.92, 1.62, 0.2) * CFrame.Angles(0, side * 180 * DEG, 0),
			"Secondaire",
			nil,
			Enum.Material.Metal
		)
		for _, xOffset in { 2.1, 4.45 } do
			local x = side * xOffset
			cylinder(
				model,
				"Moteur",
				Vector3.new(2.05, 0.85, 0.85),
				CFrame.new(x, 1.42, -0.15) * CFrame.Angles(0, 90 * DEG, 0),
				"Secondaire",
				nil,
				Enum.Material.Metal
			)
			beam(model, "Helice", Vector3.new(x, 0.76, -1.22), Vector3.new(x, 2.1, -1.22), 0.08, "Arme", nil, Enum.Material.Metal)
		end
	end
	block(model, "Empennage", Vector3.new(4.9, 0.18, 1.7), CFrame.new(0, 1.72, 4.55), "Secondaire", nil, nil)
	wedge(model, "Derive", Vector3.new(0.22, 2.15, 1.9), CFrame.new(0, 2.45, 4.5) * CFrame.Angles(0, 180 * DEG, 0), "Principale", nil, nil)
	ball(model, "Tourelle", Vector3.new(1.0, 0.55, 1.0), CFrame.new(0, 2.45, 0.7), "Secondaire", nil, Enum.Material.Metal)
	block(model, "Insigne", Vector3.new(1.0, 0.06, 0.75), CFrame.new(3.5, 1.79, 0.1), "Drapeau", nil, nil)
	return finish(model, fuselage)
end

local function buildSousMarin(): Model
	local model = newModel("SousMarin")
	local hull = cylinder(
		model,
		"Coque",
		Vector3.new(9.5, 2.15, 2.15),
		CFrame.new(0, 1.45, 0) * CFrame.Angles(0, 90 * DEG, 0),
		"Principale",
		nil,
		Enum.Material.Metal
	)
	ball(model, "Proue", Vector3.new(2.1, 2.1, 2.25), CFrame.new(0, 1.45, -5.05), "Principale", nil, Enum.Material.Metal)
	ball(model, "Poupe", Vector3.new(1.75, 1.75, 1.9), CFrame.new(0, 1.45, 5.0), "Secondaire", nil, Enum.Material.Metal)
	wedge(model, "Kiosque", Vector3.new(1.35, 1.55, 2.1), CFrame.new(0, 2.68, 0.4) * CFrame.Angles(0, 180 * DEG, 0), "Secondaire", nil, Enum.Material.Metal)
	beam(model, "Periscope", Vector3.new(-0.2, 3.0, 0.25), Vector3.new(-0.2, 4.25, 0.25), 0.12, "Arme", nil, Enum.Material.Metal)
	beam(model, "PeriscopeCoude", Vector3.new(-0.2, 4.25, 0.25), Vector3.new(-0.2, 4.25, -0.25), 0.12, "Arme", nil, Enum.Material.Metal)
	block(model, "Gouvernail", Vector3.new(0.18, 2.15, 1.4), CFrame.new(0, 2.08, 5.25), "Secondaire", nil, Enum.Material.Metal)
	block(model, "PlongeeAvant", Vector3.new(4.0, 0.16, 0.8), CFrame.new(0, 1.55, -3.4), "Secondaire", nil, Enum.Material.Metal)
	block(model, "PlongeeArriere", Vector3.new(3.3, 0.16, 0.9), CFrame.new(0, 1.55, 4.45), "Secondaire", nil, Enum.Material.Metal)
	block(model, "Marquage", Vector3.new(0.05, 0.5, 0.8), CFrame.new(0.7, 3.0, -0.05), "Drapeau", nil, nil)
	return finish(model, hull)
end

local function addBuilding(model: Model, name: string, position: Vector3, size: Vector3, color: Color3, roofTint: Tint?)
	block(model, name, size, CFrame.new(position), nil, color, Enum.Material.Concrete)
	block(
		model,
		name .. "Toit",
		Vector3.new(size.X + 0.18, 0.18, size.Z + 0.18),
		CFrame.new(position + Vector3.new(0, size.Y * 0.5 + 0.1, 0)),
		roofTint,
		ROOF,
		Enum.Material.Metal
	)
	local windowRows = math.max(1, math.floor(size.Y / 1.2))
	for row = 1, math.min(windowRows, 4) do
		local y = position.Y - size.Y * 0.5 + 0.5 + (row - 1) * 0.9
		block(model, "Fenetre", Vector3.new(math.max(0.45, size.X * 0.45), 0.27, 0.04), CFrame.new(position.X, y, position.Z - size.Z * 0.5 - 0.025), nil, GLASS, Enum.Material.Glass)
	end
end

local function buildVille(): Model
	local model = newModel("Ville")
	local base = block(model, "Socle", Vector3.new(12, 0.25, 12), CFrame.new(0, 0.12, 0), nil, ROAD, Enum.Material.Concrete)
	block(model, "RueNordSud", Vector3.new(2.0, 0.05, 11.7), CFrame.new(0, 0.27, 0), nil, DARK, Enum.Material.Concrete)
	block(model, "RueEstOuest", Vector3.new(11.7, 0.05, 2.0), CFrame.new(0, 0.28, 0), nil, DARK, Enum.Material.Concrete)
	addBuilding(model, "Mairie", Vector3.new(-3.15, 2.3, -3.1), Vector3.new(3.2, 4.1, 2.8), LIGHT_CONCRETE, "Principale")
	addBuilding(model, "Immeuble", Vector3.new(3.25, 3.25, -3.25), Vector3.new(2.6, 6.0, 2.6), CONCRETE, "Secondaire")
	addBuilding(model, "Habitation", Vector3.new(-3.45, 1.65, 3.35), Vector3.new(2.7, 2.8, 2.8), BRICK, "Principale")
	addBuilding(model, "Bureaux", Vector3.new(3.3, 2.25, 3.25), Vector3.new(3.0, 4.0, 2.7), Color3.fromRGB(117, 126, 129), "Secondaire")
	cylinder(model, "Monument", Vector3.new(2.25, 0.38, 0.38), CFrame.new(0, 1.4, 0) * CFrame.Angles(0, 0, 90 * DEG), nil, LIGHT_CONCRETE, Enum.Material.Concrete)
	block(model, "DrapeauMairie", Vector3.new(0.06, 0.7, 1.05), CFrame.new(-3.15, 5.15, -3.1), "Drapeau", nil, nil)
	return finish(model, base)
end

local function buildPort(): Model
	local model = newModel("Port")
	local quay = block(model, "Quai", Vector3.new(13.5, 0.5, 7.5), CFrame.new(0, 0.25, 1.0), nil, CONCRETE, Enum.Material.Concrete)
	block(model, "Bassin", Vector3.new(13.5, 0.12, 3.7), CFrame.new(0, 0.05, -4.65), nil, BLUE, Enum.Material.SmoothPlastic)
	block(model, "JeteeGauche", Vector3.new(2.0, 0.32, 4.5), CFrame.new(-4.8, 0.25, -3.25), nil, CONCRETE, Enum.Material.Concrete)
	block(model, "JeteeDroite", Vector3.new(2.0, 0.32, 4.5), CFrame.new(4.8, 0.25, -3.25), nil, CONCRETE, Enum.Material.Concrete)
	block(model, "Entrepot", Vector3.new(5.3, 2.4, 2.8), CFrame.new(-3.0, 1.7, 2.5), "Secondaire", nil, Enum.Material.Metal)
	wedge(model, "ToitEntrepot", Vector3.new(5.5, 1.0, 3.0), CFrame.new(-3.0, 3.35, 2.5), "Principale", nil, Enum.Material.Metal)
	for _, x in { 2.1, 4.1 } do
		beam(model, "MontantGrue", Vector3.new(x, 0.5, 1.8), Vector3.new(x, 4.8, 1.8), 0.22, nil, YELLOW, Enum.Material.Metal)
		beam(model, "FlecheGrue", Vector3.new(x, 4.65, 1.8), Vector3.new(x, 4.65, -2.3), 0.22, nil, YELLOW, Enum.Material.Metal)
		beam(model, "Cable", Vector3.new(x, 4.65, -1.75), Vector3.new(x, 1.2, -1.75), 0.07, nil, BLACK, Enum.Material.Metal)
	end
	for row = 0, 1 do
		for col = 0, 2 do
			local colors = { RED, BLUE, GREEN }
			block(model, "Conteneur", Vector3.new(1.65, 0.75, 0.85), CFrame.new(1.8 + col * 1.7, 0.88 + row * 0.78, 3.0), nil, colors[col + 1], Enum.Material.Metal)
		end
	end
	block(model, "PavillonPort", Vector3.new(0.06, 0.65, 1.0), CFrame.new(-5.5, 3.8, 1.0), "Drapeau", nil, nil)
	beam(model, "MatPort", Vector3.new(-5.5, 0.5, 1.0), Vector3.new(-5.5, 4.5, 1.0), 0.1, nil, METAL, Enum.Material.Metal)
	return finish(model, quay)
end

local function buildBaseAerienne(): Model
	local model = newModel("BaseAerienne")
	local runway = block(model, "Piste", Vector3.new(6.2, 0.22, 16), CFrame.new(2.8, 0.12, 0), nil, ROAD, Enum.Material.Concrete)
	for z = -6, 6, 2 do
		block(model, "MarquagePiste", Vector3.new(0.22, 0.04, 1.1), CFrame.new(2.8, 0.25, z), nil, WHITE, Enum.Material.SmoothPlastic)
	end
	block(model, "Tarmac", Vector3.new(7.2, 0.2, 8.0), CFrame.new(-4.0, 0.11, 2.8), nil, CONCRETE, Enum.Material.Concrete)
	block(model, "Hangar", Vector3.new(5.2, 2.7, 4.3), CFrame.new(-4.2, 1.55, 3.7), "Secondaire", nil, Enum.Material.Metal)
	wedge(model, "ToitHangar", Vector3.new(5.45, 1.4, 4.55), CFrame.new(-4.2, 3.55, 3.7), "Principale", nil, Enum.Material.Metal)
	block(model, "PorteHangar", Vector3.new(4.15, 2.1, 0.08), CFrame.new(-4.2, 1.4, 1.52), nil, DARK, Enum.Material.Metal)
	block(model, "TourControle", Vector3.new(1.65, 4.4, 1.65), CFrame.new(-5.5, 2.3, -3.7), "Principale", nil, Enum.Material.Concrete)
	block(model, "CabineControle", Vector3.new(2.35, 1.0, 2.35), CFrame.new(-5.5, 4.75, -3.7), nil, GLASS, Enum.Material.Glass)
	block(model, "ToitControle", Vector3.new(2.6, 0.16, 2.6), CFrame.new(-5.5, 5.35, -3.7), "Secondaire", nil, Enum.Material.Metal)
	beam(model, "Mat", Vector3.new(-3.8, 0.25, -4.2), Vector3.new(-3.8, 3.6, -4.2), 0.09, nil, METAL, Enum.Material.Metal)
	block(model, "Drapeau", Vector3.new(0.05, 0.75, 1.15), CFrame.new(-3.8, 3.2, -3.63), "Drapeau", nil, nil)
	return finish(model, runway)
end

local function buildDepotRavitaillement(): Model
	local model = newModel("DepotRavitaillement")
	local base = block(model, "Dalle", Vector3.new(10.5, 0.25, 9.0), CFrame.new(0, 0.12, 0), nil, CONCRETE, Enum.Material.Concrete)
	block(model, "Entrepot", Vector3.new(5.2, 2.7, 3.9), CFrame.new(-2.2, 1.62, 1.65), "Secondaire", nil, Enum.Material.Metal)
	wedge(model, "Toit", Vector3.new(5.45, 1.15, 4.15), CFrame.new(-2.2, 3.52, 1.65), "Principale", nil, Enum.Material.Metal)
	block(model, "Porte", Vector3.new(2.2, 2.0, 0.08), CFrame.new(-2.2, 1.28, -0.34), nil, DARK, Enum.Material.Metal)
	for _, x in { 2.1, 3.75 } do
		cylinder(model, "Reservoir", Vector3.new(2.8, 1.35, 1.35), CFrame.new(x, 1.52, 1.8) * CFrame.Angles(0, 0, 90 * DEG), nil, LIGHT_METAL, Enum.Material.Metal)
		cylinder(model, "Couvercle", Vector3.new(0.15, 1.42, 1.42), CFrame.new(x, 2.96, 1.8) * CFrame.Angles(0, 0, 90 * DEG), "Secondaire", nil, Enum.Material.Metal)
	end
	for row = 0, 1 do
		for col = 0, 2 do
			block(model, "Caisse", Vector3.new(0.95, 0.75, 0.95), CFrame.new(1.8 + col, 0.62 + row * 0.77, -2.25), nil, WOOD, Enum.Material.Wood)
		end
	end
	beam(model, "Canalisation", Vector3.new(2.1, 0.55, 1.8), Vector3.new(2.1, 0.55, -0.9), 0.18, nil, METAL, Enum.Material.Metal)
	block(model, "Marquage", Vector3.new(0.05, 0.55, 0.85), CFrame.new(-4.82, 1.2, 1.6), "Drapeau", nil, nil)
	return finish(model, base)
end

local function buildFortification(): Model
	local model = newModel("Fortification")
	local base = block(model, "Terrain", Vector3.new(9.5, 0.35, 8.5), CFrame.new(0, 0.18, 0), nil, Color3.fromRGB(89, 91, 70), Enum.Material.Concrete)
	block(model, "Bunker", Vector3.new(5.7, 1.8, 3.8), CFrame.new(0, 1.25, 0.35), nil, CONCRETE, Enum.Material.Concrete)
	wedge(model, "GlacisBunker", Vector3.new(5.7, 1.8, 1.6), CFrame.new(0, 1.25, -2.3) * CFrame.Angles(0, 180 * DEG, 0), nil, CONCRETE, Enum.Material.Concrete)
	block(model, "ToitBunker", Vector3.new(6.2, 0.5, 4.4), CFrame.new(0, 2.4, 0.15), "Principale", nil, Enum.Material.Concrete)
	block(model, "Embrasure", Vector3.new(2.8, 0.38, 0.12), CFrame.new(0, 1.52, -3.12), nil, BLACK, Enum.Material.Metal)
	beam(model, "Canon", Vector3.new(0, 1.53, -2.8), Vector3.new(0, 1.58, -4.35), 0.18, "Arme", nil, Enum.Material.Metal)
	for _, x in { -3.7, 3.7 } do
		block(model, "Mur", Vector3.new(1.1, 1.4, 5.8), CFrame.new(x, 0.9, 0.25), nil, LIGHT_CONCRETE, Enum.Material.Concrete)
	end
	for _, z in { -3.35, 3.35 } do
		block(model, "Barriere", Vector3.new(8.2, 0.55, 0.5), CFrame.new(0, 0.52, z), "Secondaire", nil, Enum.Material.Concrete)
	end
	block(model, "Fanion", Vector3.new(0.05, 0.65, 1.0), CFrame.new(0, 4.1, 0.3), "Drapeau", nil, nil)
	beam(model, "Mat", Vector3.new(0, 2.6, 0.3), Vector3.new(0, 4.8, 0.3), 0.08, nil, METAL, Enum.Material.Metal)
	return finish(model, base)
end

local function buildRadar(): Model
	local model = newModel("Radar")
	local base = cylinder(model, "Socle", Vector3.new(0.65, 4.8, 4.8), CFrame.new(0, 0.34, 0) * CFrame.Angles(0, 0, 90 * DEG), nil, CONCRETE, Enum.Material.Concrete)
	block(model, "Cabine", Vector3.new(3.6, 2.0, 3.2), CFrame.new(0, 1.65, 0), "Principale", nil, Enum.Material.Metal)
	block(model, "Porte", Vector3.new(0.85, 1.45, 0.06), CFrame.new(-0.8, 1.45, -1.63), nil, DARK, Enum.Material.Metal)
	beam(model, "MatRadar", Vector3.new(0, 2.65, 0), Vector3.new(0, 6.1, 0), 0.25, "Secondaire", nil, Enum.Material.Metal)
	block(model, "Traverse", Vector3.new(3.7, 0.18, 0.18), CFrame.new(0, 5.0, 0), "Secondaire", nil, Enum.Material.Metal)
	for _, side in { -1, 1 } do
		beam(model, "Hauban", Vector3.new(side * 1.65, 4.95, 0), Vector3.new(0, 2.75, 0), 0.09, nil, METAL, Enum.Material.Metal)
	end
	-- Disque vertical légèrement incliné pour évoquer une antenne parabolique.
	cylinder(
		model,
		"Antenne",
		Vector3.new(0.22, 4.0, 4.0),
		CFrame.new(0, 6.25, 0) * CFrame.Angles(0, 18 * DEG, 0),
		"Secondaire",
		nil,
		Enum.Material.Metal
	)
	beam(model, "Capteur", Vector3.new(0, 6.25, -0.1), Vector3.new(0, 6.25, -1.25), 0.11, "Arme", nil, Enum.Material.Metal)
	ball(model, "Recepteur", Vector3.new(0.35, 0.35, 0.35), CFrame.new(0, 6.25, -1.27), "Arme", nil, Enum.Material.Metal)
	block(model, "Marquage", Vector3.new(0.65, 0.04, 0.65), CFrame.new(1.1, 2.68, 0.8), "Drapeau", nil, nil)
	return finish(model, base)
end

local function buildGare(): Model
	local model = newModel("Gare")
	local platform = block(model, "Quai", Vector3.new(7.2, 0.45, 14), CFrame.new(-2.5, 0.23, 0), nil, CONCRETE, Enum.Material.Concrete)
	block(model, "Ballast", Vector3.new(4.0, 0.18, 14.5), CFrame.new(3.4, 0.1, 0), nil, Color3.fromRGB(83, 79, 73), Enum.Material.Concrete)
	for _, x in { 2.65, 4.15 } do
		block(model, "Rail", Vector3.new(0.16, 0.16, 14.5), CFrame.new(x, 0.28, 0), nil, METAL, Enum.Material.Metal)
	end
	for z = -6.5, 6.5, 1.0 do
		block(model, "Traverse", Vector3.new(3.0, 0.12, 0.24), CFrame.new(3.4, 0.17, z), nil, WOOD, Enum.Material.Wood)
	end
	block(model, "Batiment", Vector3.new(4.7, 2.8, 7.2), CFrame.new(-3.3, 1.68, 1.2), "Secondaire", nil, Enum.Material.Brick)
	wedge(model, "Toit", Vector3.new(5.05, 1.35, 7.55), CFrame.new(-3.3, 3.75, 1.2), "Principale", nil, Enum.Material.Metal)
	block(model, "Porte", Vector3.new(1.0, 1.9, 0.08), CFrame.new(-3.3, 1.25, -2.44), nil, DARK, Enum.Material.Wood)
	for _, x in { -4.65, -1.95 } do
		block(model, "Fenetre", Vector3.new(0.85, 0.65, 0.06), CFrame.new(x, 2.05, -2.45), nil, GLASS, Enum.Material.Glass)
	end
	block(model, "Auvent", Vector3.new(3.8, 0.18, 9.2), CFrame.new(0.25, 2.45, 0.5), "Secondaire", nil, Enum.Material.Metal)
	for z = -3.2, 4.2, 2.45 do
		beam(model, "Poteau", Vector3.new(0.65, 0.45, z), Vector3.new(0.65, 2.45, z), 0.12, nil, METAL, Enum.Material.Metal)
	end
	block(model, "Enseigne", Vector3.new(2.4, 0.55, 0.08), CFrame.new(-3.3, 2.85, -2.48), "Drapeau", nil, nil)
	return finish(model, platform)
end

local function buildPont(): Model
	local model = newModel("Pont")
	local deck = block(model, "Tablier", Vector3.new(6.2, 0.58, 16), CFrame.new(0, 3.4, 0), nil, CONCRETE, Enum.Material.Concrete)
	block(model, "Route", Vector3.new(4.8, 0.12, 15.8), CFrame.new(0, 3.76, 0), nil, ROAD, Enum.Material.Concrete)
	for z = -6.5, 6.5, 2.2 do
		block(model, "LigneCentrale", Vector3.new(0.14, 0.04, 1.0), CFrame.new(0, 3.84, z), nil, WHITE, Enum.Material.SmoothPlastic)
	end
	for _, side in { -1, 1 } do
		block(model, "GardeCorps", Vector3.new(0.18, 0.85, 16), CFrame.new(side * 3.0, 4.05, 0), "Secondaire", nil, Enum.Material.Metal)
		for _, z in { -6.8, -3.4, 0, 3.4, 6.8 } do
			beam(model, "Montant", Vector3.new(side * 3.0, 3.7, z), Vector3.new(side * 3.0, 6.2, z), 0.18, "Principale", nil, Enum.Material.Metal)
		end
		beam(model, "Cable", Vector3.new(side * 3.0, 6.2, -6.8), Vector3.new(side * 3.0, 6.2, 6.8), 0.12, "Secondaire", nil, Enum.Material.Metal)
	end
	for _, z in { -5.0, 0, 5.0 } do
		for _, x in { -2.25, 2.25 } do
			block(model, "Pile", Vector3.new(0.85, 3.15, 1.15), CFrame.new(x, 1.58, z), nil, LIGHT_CONCRETE, Enum.Material.Concrete)
		end
	end
	block(model, "Marquage", Vector3.new(0.06, 0.7, 1.1), CFrame.new(-3.13, 5.15, -5.8), "Drapeau", nil, nil)
	return finish(model, deck)
end

local function buildUsine(): Model
	local model = newModel("Usine")
	local base = block(model, "Dalle", Vector3.new(12.5, 0.28, 11), CFrame.new(0, 0.14, 0), nil, CONCRETE, Enum.Material.Concrete)
	block(model, "AtelierPrincipal", Vector3.new(7.0, 3.4, 5.7), CFrame.new(-1.8, 1.85, 1.1), "Secondaire", nil, Enum.Material.Metal)
	for _, x in { -4.25, -1.8, 0.65 } do
		wedge(model, "ToitDente", Vector3.new(2.55, 1.25, 5.95), CFrame.new(x, 4.15, 1.1), "Principale", nil, Enum.Material.Metal)
	end
	block(model, "Annexe", Vector3.new(3.7, 2.5, 3.7), CFrame.new(4.0, 1.4, 2.1), "Secondaire", nil, Enum.Material.Brick)
	block(model, "ToitAnnexe", Vector3.new(3.95, 0.22, 3.95), CFrame.new(4.0, 2.78, 2.1), "Principale", nil, Enum.Material.Metal)
	block(model, "PorteIndustrielle", Vector3.new(2.45, 2.45, 0.08), CFrame.new(-1.8, 1.5, -1.78), nil, DARK, Enum.Material.Metal)
	for _, x in { 2.4, 4.45 } do
		cylinder(model, "Cheminee", Vector3.new(5.8, 0.82, 0.82), CFrame.new(x, 3.15, -2.7) * CFrame.Angles(0, 0, 90 * DEG), nil, BRICK, Enum.Material.Brick)
		cylinder(model, "Couronne", Vector3.new(0.25, 1.0, 1.0), CFrame.new(x, 6.15, -2.7) * CFrame.Angles(0, 0, 90 * DEG), "Secondaire", nil, Enum.Material.Metal)
	end
	for _, x in { -4.5, -2.7, -0.9 } do
		block(model, "Fenetre", Vector3.new(1.0, 0.65, 0.05), CFrame.new(x, 2.35, -1.79), nil, GLASS, Enum.Material.Glass)
	end
	beam(model, "Canalisation", Vector3.new(1.0, 0.75, 4.2), Vector3.new(5.4, 0.75, 4.2), 0.28, nil, LIGHT_METAL, Enum.Material.Metal)
	block(model, "Enseigne", Vector3.new(0.06, 0.7, 1.1), CFrame.new(-5.32, 2.1, -0.2), "Drapeau", nil, nil)
	return finish(model, base)
end

local BUILDERS: { () -> Model } = {
	buildArtillerie,
	buildAvion,
	buildNavire,
	buildCamion,
	buildVehiculeBlinde,
	buildAntiaerien,
	buildBombardier,
	buildSousMarin,
	buildVille,
	buildPort,
	buildBaseAerienne,
	buildDepotRavitaillement,
	buildFortification,
	buildRadar,
	buildGare,
	buildPont,
	buildUsine,
}

-- Ajoute (ou remplace) tous les modèles stratégiques dans le dossier fourni.
function StrategicModels.populate(folder: Instance)
	for _, build in BUILDERS do
		local model = build()
		local previous = folder:FindFirstChild(model.Name)
		if previous ~= nil then
			previous:Destroy()
		end
		model.Parent = folder
	end
end

return StrategicModels
