--!strict
-- Fabrique les modèles 3D des unités au lancement du serveur (aucun modèle de la Toolbox) :
--   Soldat : personnage R15 avec uniforme, casque, gilet, sac et fusil
--   Char   : char d'assaut low-poly en pièces Roblox
-- Chaque pièce porte un attribut « Teinte » : UnitPainter la colore selon le pays.
-- Les modèles sont rangés dans ReplicatedStorage.Modeles ; les clients les copient.

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local unitsFolder = script.Parent or ServerScriptService:WaitForChild("Server"):WaitForChild("Units")
local StrategicModels = require(unitsFolder:WaitForChild("StrategicModels"))
local AirNavalModels = require(unitsFolder:WaitForChild("AirNavalModels"))

local UnitModels = {}

local function tag(part: BasePart, tint: string)
	part:SetAttribute("Teinte", tint)
end

local function newPart(name: string, size: Vector3, tint: string, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Shape = shape or Enum.PartType.Block
	p.Material = Enum.Material.Plastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanTouch = false
	tag(p, tint)
	return p
end

-- Équipement fixé sur une partie du corps (position relative à cette partie)
local function attach(part: BasePart, body: BasePart, offset: CFrame, parent: Instance)
	part.CFrame = body.CFrame * offset
	part.Massless = true
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = body
	weld.Part1 = part
	weld.Parent = part
	part.Parent = parent
end

local BODY_TINTS = {
	Head = "Peau",
	LeftHand = "Peau",
	RightHand = "Peau",
	UpperTorso = "Uniforme",
	LeftUpperArm = "Uniforme",
	RightUpperArm = "Uniforme",
	LeftLowerArm = "Uniforme",
	RightLowerArm = "Uniforme",
	LowerTorso = "Pantalon",
	LeftUpperLeg = "Pantalon",
	RightUpperLeg = "Pantalon",
	LeftLowerLeg = "Pantalon",
	RightLowerLeg = "Pantalon",
	LeftFoot = "Bottes",
	RightFoot = "Bottes",
}

local function buildSoldier(): Model
	local rig = Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	rig.Name = "Soldat"

	-- aucun script dans les modèles ; les couleurs sont gérées par les attributs
	for _, d in rig:GetDescendants() do
		if d:IsA("LuaSourceContainer") or d:IsA("BodyColors") then
			d:Destroy()
		end
	end

	for _, d in rig:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanTouch = false
			local tint = BODY_TINTS[d.Name]
			if tint then
				tag(d, tint)
			end
		end
	end

	local root = rig:FindFirstChild("HumanoidRootPart") :: BasePart
	root.Anchored = true
	root.Transparency = 1
	local head = rig:FindFirstChild("Head") :: BasePart
	local torso = rig:FindFirstChild("UpperTorso") :: BasePart
	local leftArm = rig:FindFirstChild("LeftUpperArm") :: BasePart
	local gear = Instance.new("Folder")
	gear.Name = "Equipement"
	gear.Parent = rig

	-- visage
	local face = Instance.new("Decal")
	face.Name = "face"
	face.Texture = "rbxasset://textures/face.png"
	face.Face = Enum.NormalId.Front
	face.Parent = head

	-- casque : demi-sphère aplatie sur le haut de la tête
	attach(newPart("Casque", Vector3.new(1.34, 0.95, 1.34), "Casque", Enum.PartType.Ball), head, CFrame.new(0, 0.3, 0.03), gear)
	-- gilet et poches
	attach(newPart("Gilet", Vector3.new(2.02, 1.05, 1.22), "Gilet"), torso, CFrame.new(0, -0.18, 0), gear)
	for _, x in { -0.45, 0.45 } do
		attach(newPart("Poche", Vector3.new(0.45, 0.35, 0.14), "Gilet"), torso, CFrame.new(x, -0.35, -0.66), gear)
	end
	-- sac à dos (le dos est du côté +Z)
	attach(newPart("Sac", Vector3.new(1.25, 1.1, 0.55), "Sac"), torso, CFrame.new(0, 0, 0.78), gear)
	-- fusil porté en bandoulière, en travers du dos
	attach(
		newPart("Fusil", Vector3.new(2.4, 0.22, 0.2), "Arme"),
		torso,
		CFrame.new(0, 0.05, 1.12) * CFrame.Angles(0, 0, math.rad(40)),
		gear
	)
	-- écusson aux couleurs du pays sur l'épaule
	attach(newPart("Ecusson", Vector3.new(0.06, 0.35, 0.55), "Drapeau"), leftArm, CFrame.new(-0.52, 0.25, 0), gear)

	local humanoid = rig:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	pcall(function()
		-- modèle d'affichage : inutile de calculer la physique du personnage
		humanoid.EvaluateStateMachine = false
	end)

	rig.PrimaryPart = root
	return rig
end

-- Général : officier R15 avec casquette, épaulettes dorées et drapeau du pays à la main.
-- C'est lui qui représente toute son armée sur la carte.
local function buildGeneral(): Model
	local rig = Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	rig.Name = "General"
	for _, d in rig:GetDescendants() do
		if d:IsA("LuaSourceContainer") or d:IsA("BodyColors") then
			d:Destroy()
		end
	end
	for _, d in rig:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanTouch = false
			local tint = BODY_TINTS[d.Name]
			if tint then
				tag(d, tint)
			end
		end
	end

	local root = rig:FindFirstChild("HumanoidRootPart") :: BasePart
	root.Anchored = true
	root.Transparency = 1
	local head = rig:FindFirstChild("Head") :: BasePart
	local torso = rig:FindFirstChild("UpperTorso") :: BasePart
	local hand = rig:FindFirstChild("RightHand") :: BasePart
	local gear = Instance.new("Folder")
	gear.Name = "Equipement"
	gear.Parent = rig

	local face = Instance.new("Decal")
	face.Name = "face"
	face.Texture = "rbxasset://textures/face.png"
	face.Face = Enum.NormalId.Front
	face.Parent = head

	-- casquette d'officier : calotte, visière et insigne doré
	attach(newPart("Casquette", Vector3.new(0.42, 1.36, 1.36), "Casque", Enum.PartType.Cylinder), head, CFrame.new(0, 0.62, 0) * CFrame.Angles(0, 0, math.rad(90)), gear)
	attach(newPart("Visiere", Vector3.new(1.0, 0.08, 0.45), "Bottes"), head, CFrame.new(0, 0.44, -0.66), gear)
	attach(newPart("Insigne", Vector3.new(0.26, 0.22, 0.05), "Galons"), head, CFrame.new(0, 0.64, -0.7), gear)
	-- épaulettes
	for _, x in { -0.78, 0.78 } do
		attach(newPart("Epaulette", Vector3.new(0.6, 0.12, 0.9), "Galons"), torso, CFrame.new(x, 0.86, 0), gear)
	end
	-- drapeau tenu dans la main droite
	attach(newPart("Hampe", Vector3.new(0.12, 5.4, 0.12), "Hampe"), hand, CFrame.new(0, 1.7, 0), gear)
	attach(newPart("Drapeau", Vector3.new(0.05, 1.1, 1.7), "Drapeau"), hand, CFrame.new(0, 3.8, 0.9), gear)

	local humanoid = rig:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	pcall(function()
		humanoid.EvaluateStateMachine = false
	end)

	rig.PrimaryPart = root
	return rig
end

-- Char low-poly (l'avant est du côté -Z, comme pour les personnages)
local function buildTank(): Model
	local model = Instance.new("Model")
	model.Name = "Char"

	local function add(name: string, size: Vector3, tint: string, cf: CFrame, class: string?, shape: Enum.PartType?): BasePart
		local p: BasePart
		if class == "Wedge" then
			local w = Instance.new("WedgePart")
			w.Name = name
			w.Size = size
			w.Material = Enum.Material.Plastic
			w.CanCollide = false
			w.CanTouch = false
			tag(w, tint)
			p = w
		else
			p = newPart(name, size, tint, shape)
		end
		p.Anchored = true
		p.CFrame = cf
		p.Parent = model
		return p
	end

	local hull = add("Coque", Vector3.new(3.4, 1.0, 5.6), "Principale", CFrame.new(0, 1.15, 0))
	add("Glacis", Vector3.new(3.4, 1.0, 1.2), "Principale", CFrame.new(0, 1.15, -3.4), "Wedge")
	add("Arriere", Vector3.new(2.2, 0.5, 0.6), "Secondaire", CFrame.new(0, 1.4, 3.1))

	for _, side in { -1, 1 } do
		add("Chenille", Vector3.new(0.9, 1.1, 6.6), "Chenilles", CFrame.new(side * 2.15, 0.55, -0.3))
		add("GardeBoue", Vector3.new(1.0, 0.12, 6.8), "Secondaire", CFrame.new(side * 2.15, 1.16, -0.3))
		for i = -2, 2 do
			add("Roue", Vector3.new(0.3, 0.8, 0.8), "Roues", CFrame.new(side * 2.62, 0.45, i * 1.3 - 0.3), nil, Enum.PartType.Cylinder)
		end
		add("Bandeau", Vector3.new(0.05, 0.35, 1.2), "Drapeau", CFrame.new(side * 1.23, 2.2, 0.5))
	end

	add("Tourelle", Vector3.new(2.4, 0.9, 2.8), "Principale", CFrame.new(0, 2.1, 0.3))
	add("MasqueTourelle", Vector3.new(2.4, 0.9, 0.8), "Principale", CFrame.new(0, 2.1, -1.5), "Wedge")
	add("Canon", Vector3.new(3.6, 0.32, 0.32), "Secondaire", CFrame.new(0, 2.15, -3.3) * CFrame.Angles(0, math.rad(90), 0), nil, Enum.PartType.Cylinder)
	add("FreinDeBouche", Vector3.new(0.5, 0.4, 0.5), "Secondaire", CFrame.new(0, 2.15, -5.2))
	add("Trappe", Vector3.new(0.15, 0.9, 0.9), "Secondaire", CFrame.new(0.5, 2.6, 0.8) * CFrame.Angles(0, 0, math.rad(90)), nil, Enum.PartType.Cylinder)
	add("Antenne", Vector3.new(0.08, 2.2, 0.08), "Arme", CFrame.new(-0.8, 3.65, 1.3))

	model.PrimaryPart = hull
	return model
end

-- Construit les modèles dans un dossier « Modeles » placé sous `parent`
function UnitModels.build(parent: Instance): Folder
	local old = parent:FindFirstChild("Modeles")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "Modeles"
	buildSoldier().Parent = folder
	buildGeneral().Parent = folder
	buildTank().Parent = folder
	StrategicModels.populate(folder)
	AirNavalModels.populate(folder) -- drone, hélicoptère, porte-avions, cargo
	folder.Parent = parent
	return folder
end

return UnitModels
