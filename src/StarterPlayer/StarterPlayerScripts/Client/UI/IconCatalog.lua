--!strict
-- Icônes stratégiques dessinées avec des primitives Roblox.
-- Aucun asset externe ni emoji de plateforme : le rendu reste monochrome,
-- net et cohérent sur ordinateur, tablette et téléphone.

local IconCatalog = {}

local PART_ATTRIBUTE = "WorldFrontIconPart"
local DEFAULT_COLOR = Color3.fromRGB(230, 234, 240)

local function mark(instance: Instance)
	instance:SetAttribute(PART_ATTRIBUTE, true)
end

local function rounded(instance: GuiObject, radius: number?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(radius or 1, 0)
	corner.Parent = instance
end

local function part(
	parent: Instance,
	name: string,
	x: number,
	y: number,
	width: number,
	height: number,
	color: Color3,
	rotation: number?,
	radius: number?
): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(x, y)
	frame.Size = UDim2.fromScale(width, height)
	frame.Rotation = rotation or 0
	frame.BackgroundColor3 = color
	frame.BorderSizePixel = 0
	if radius then
		rounded(frame, radius)
	end
	mark(frame)
	frame.Parent = parent
	return frame
end

local function line(
	parent: Instance,
	name: string,
	ax: number,
	ay: number,
	bx: number,
	by: number,
	thickness: number,
	color: Color3
): Frame
	local dx, dy = bx - ax, by - ay
	local length = math.sqrt(dx * dx + dy * dy)
	local angle = math.deg(math.atan2(dy, dx))
	return part(parent, name, (ax + bx) / 2, (ay + by) / 2, length, thickness, color, angle, 1)
end

local function circle(parent: Instance, name: string, x: number, y: number, diameter: number, color: Color3): Frame
	return part(parent, name, x, y, diameter, diameter, color, 0, 1)
end

local function outline(
	parent: Instance,
	name: string,
	x: number,
	y: number,
	width: number,
	height: number,
	color: Color3,
	radius: number?
): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(x, y)
	frame.Size = UDim2.fromScale(width, height)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	if radius then
		rounded(frame, radius)
	end
	local stroke = Instance.new("UIStroke")
	stroke.Name = "Trait"
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize
	-- ScaledSize est relatif au Frame qui porte le trait. On compense sa
	-- taille pour garder un contour égal à 5,5 % de la racine de l'icône.
	stroke.Thickness = 0.055 / math.min(width, height)
	stroke.Color = color
	mark(stroke)
	stroke.Parent = frame
	frame.Parent = parent
	return frame
end

local function drawMap(root: Frame, color: Color3)
	for index, points in {
		{ 0.12, 0.27, 0.35, 0.18 },
		{ 0.35, 0.18, 0.65, 0.29 },
		{ 0.65, 0.29, 0.88, 0.20 },
		{ 0.12, 0.27, 0.12, 0.77 },
		{ 0.12, 0.77, 0.35, 0.68 },
		{ 0.35, 0.68, 0.65, 0.79 },
		{ 0.65, 0.79, 0.88, 0.70 },
		{ 0.88, 0.20, 0.88, 0.70 },
		{ 0.35, 0.18, 0.35, 0.68 },
		{ 0.65, 0.29, 0.65, 0.79 },
	} do
		line(root, "Carte" .. index, points[1], points[2], points[3], points[4], 0.055, color)
	end
	line(root, "Itineraire", 0.24, 0.50, 0.74, 0.55, 0.045, color)
	circle(root, "Depart", 0.24, 0.50, 0.13, color)
	circle(root, "Arrivee", 0.74, 0.55, 0.13, color)
end

local function drawIndustry(root: Frame, color: Color3)
	outline(root, "Batiment", 0.50, 0.65, 0.72, 0.40, color, 0.08)
	part(root, "Cheminee", 0.75, 0.31, 0.14, 0.30, color, 0, 0.12)
	line(root, "Toit1", 0.15, 0.49, 0.31, 0.34, 0.07, color)
	line(root, "Toit2", 0.31, 0.34, 0.31, 0.49, 0.07, color)
	line(root, "Toit3", 0.31, 0.49, 0.47, 0.34, 0.07, color)
	line(root, "Toit4", 0.47, 0.34, 0.47, 0.49, 0.07, color)
	for index, x in { 0.30, 0.50, 0.70 } do
		part(root, "Fenetre" .. index, x, 0.66, 0.10, 0.13, color, 0, 0.16)
	end
end

local function drawBuildings(root: Frame, color: Color3)
	outline(root, "BlocGauche", 0.27, 0.62, 0.24, 0.40, color, 0.08)
	outline(root, "Tour", 0.52, 0.52, 0.26, 0.62, color, 0.08)
	outline(root, "BlocDroit", 0.77, 0.66, 0.20, 0.32, color, 0.08)
	for index, point in { { 0.27, 0.56 }, { 0.27, 0.69 }, { 0.52, 0.38 }, { 0.52, 0.52 }, { 0.52, 0.66 }, { 0.77, 0.66 } } do
		part(root, "Fenetre" .. index, point[1], point[2], 0.07, 0.07, color, 0, 0.18)
	end
	line(root, "Sol", 0.10, 0.84, 0.90, 0.84, 0.06, color)
end

local function drawResearch(root: Frame, color: Color3)
	line(root, "ColGauche", 0.42, 0.15, 0.42, 0.42, 0.06, color)
	line(root, "ColDroite", 0.58, 0.15, 0.58, 0.42, 0.06, color)
	line(root, "Bouchon", 0.36, 0.15, 0.64, 0.15, 0.06, color)
	line(root, "FlancGauche", 0.42, 0.40, 0.22, 0.78, 0.06, color)
	line(root, "FlancDroit", 0.58, 0.40, 0.78, 0.78, 0.06, color)
	line(root, "Fond", 0.22, 0.78, 0.78, 0.78, 0.06, color)
	line(root, "Liquide", 0.31, 0.62, 0.69, 0.62, 0.045, color)
	circle(root, "Bulle1", 0.43, 0.69, 0.08, color)
	circle(root, "Bulle2", 0.58, 0.54, 0.06, color)
end

local function drawMarket(root: Frame, color: Color3)
	line(root, "AxeY", 0.18, 0.18, 0.18, 0.82, 0.055, color)
	line(root, "AxeX", 0.18, 0.82, 0.86, 0.82, 0.055, color)
	local points = {
		{ 0.27, 0.69, 0.43, 0.56 },
		{ 0.43, 0.56, 0.57, 0.63 },
		{ 0.57, 0.63, 0.80, 0.31 },
	}
	for index, segment in points do
		line(root, "Courbe" .. index, segment[1], segment[2], segment[3], segment[4], 0.075, color)
	end
	for index, point in { { 0.27, 0.69 }, { 0.43, 0.56 }, { 0.57, 0.63 }, { 0.80, 0.31 } } do
		circle(root, "Point" .. index, point[1], point[2], 0.12, color)
	end
end

local function drawArmy(root: Frame, color: Color3)
	local points = {
		{ 0.20, 0.22, 0.80, 0.22 },
		{ 0.80, 0.22, 0.74, 0.65 },
		{ 0.74, 0.65, 0.50, 0.84 },
		{ 0.50, 0.84, 0.26, 0.65 },
		{ 0.26, 0.65, 0.20, 0.22 },
	}
	for index, segment in points do
		line(root, "Bouclier" .. index, segment[1], segment[2], segment[3], segment[4], 0.065, color)
	end
	line(root, "InsigneVertical", 0.50, 0.36, 0.50, 0.67, 0.07, color)
	line(root, "InsigneHorizontal", 0.36, 0.50, 0.64, 0.50, 0.07, color)
end

local function drawDiplomacy(root: Frame, color: Color3)
	outline(root, "AnneauGauche", 0.38, 0.50, 0.46, 0.46, color, 1)
	outline(root, "AnneauDroit", 0.62, 0.50, 0.46, 0.46, color, 1)
	line(root, "LienHaut", 0.43, 0.37, 0.57, 0.37, 0.055, color)
	line(root, "LienBas", 0.43, 0.63, 0.57, 0.63, 0.055, color)
end

local function drawProfile(root: Frame, color: Color3)
	outline(root, "Tete", 0.50, 0.31, 0.28, 0.28, color, 1)
	line(root, "EpauleGauche1", 0.18, 0.79, 0.27, 0.62, 0.065, color)
	line(root, "EpauleGauche2", 0.27, 0.62, 0.40, 0.56, 0.065, color)
	line(root, "EpauleDroite1", 0.60, 0.56, 0.73, 0.62, 0.065, color)
	line(root, "EpauleDroite2", 0.73, 0.62, 0.82, 0.79, 0.065, color)
	line(root, "Base", 0.18, 0.79, 0.82, 0.79, 0.065, color)
end

local function drawSocial(root: Frame, color: Color3)
	outline(root, "TeteGauche", 0.34, 0.31, 0.23, 0.23, color, 1)
	outline(root, "TeteDroite", 0.66, 0.31, 0.23, 0.23, color, 1)
	line(root, "GroupeGauche1", 0.09, 0.76, 0.19, 0.58, 0.06, color)
	line(root, "GroupeGauche2", 0.19, 0.58, 0.40, 0.54, 0.06, color)
	line(root, "GroupeDroit1", 0.60, 0.54, 0.81, 0.58, 0.06, color)
	line(root, "GroupeDroit2", 0.81, 0.58, 0.91, 0.76, 0.06, color)
	line(root, "Base", 0.09, 0.76, 0.91, 0.76, 0.06, color)
end

local function drawMissions(root: Frame, color: Color3)
	outline(root, "Dossier", 0.50, 0.55, 0.68, 0.72, color, 0.14)
	part(root, "Attache", 0.50, 0.19, 0.28, 0.11, color, 0, 0.35)
	for index, y in { 0.39, 0.56, 0.72 } do
		part(root, "Case" .. index, 0.31, y, 0.10, 0.10, color, 0, 0.18)
		line(root, "Ligne" .. index, 0.43, y, 0.71, y, 0.055, color)
	end
end

local function drawSettings(root: Frame, color: Color3)
	outline(root, "Couronne", 0.50, 0.50, 0.45, 0.45, color, 1)
	outline(root, "Centre", 0.50, 0.50, 0.16, 0.16, color, 1)
	for index = 0, 7 do
		local angle = math.rad(index * 45)
		local ax = 0.50 + math.cos(angle) * 0.29
		local ay = 0.50 + math.sin(angle) * 0.29
		local bx = 0.50 + math.cos(angle) * 0.44
		local by = 0.50 + math.sin(angle) * 0.44
		line(root, "Dent" .. index, ax, ay, bx, by, 0.085, color)
	end
end

local function drawPass(root: Frame, color: Color3)
	outline(root, "Billet", 0.50, 0.50, 0.76, 0.58, color, 0.16)
	line(root, "Separation", 0.62, 0.25, 0.62, 0.75, 0.045, color)
	line(root, "Etoile1", 0.28, 0.50, 0.48, 0.50, 0.06, color)
	line(root, "Etoile2", 0.38, 0.40, 0.38, 0.60, 0.06, color)
	circle(root, "Niveau", 0.75, 0.50, 0.10, color)
end

local function drawUnknown(root: Frame, color: Color3)
	line(root, "HautGauche", 0.50, 0.14, 0.84, 0.50, 0.07, color)
	line(root, "BasDroite", 0.84, 0.50, 0.50, 0.86, 0.07, color)
	line(root, "BasGauche", 0.50, 0.86, 0.16, 0.50, 0.07, color)
	line(root, "HautDroite", 0.16, 0.50, 0.50, 0.14, 0.07, color)
end

function IconCatalog.create(name: string, size: number?, color: Color3?): Frame
	local root = Instance.new("Frame")
	root.Name = "Icone"
	root.Size = UDim2.fromOffset(size or 24, size or 24)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root:SetAttribute("IconName", name)
	local tint = color or DEFAULT_COLOR
	if name == "Map" then
		drawMap(root, tint)
	elseif name == "Industry" then
		drawIndustry(root, tint)
	elseif name == "Buildings" then
		drawBuildings(root, tint)
	elseif name == "Research" then
		drawResearch(root, tint)
	elseif name == "Market" then
		drawMarket(root, tint)
	elseif name == "Army" then
		drawArmy(root, tint)
	elseif name == "Diplomacy" then
		drawDiplomacy(root, tint)
	elseif name == "Profile" then
		drawProfile(root, tint)
	elseif name == "Social" then
		drawSocial(root, tint)
	elseif name == "Missions" then
		drawMissions(root, tint)
	elseif name == "Settings" then
		drawSettings(root, tint)
	elseif name == "Pass" then
		drawPass(root, tint)
	else
		drawUnknown(root, tint)
	end
	return root
end

function IconCatalog.setColor(root: Instance, color: Color3)
	for _, child in root:GetDescendants() do
		if child:GetAttribute(PART_ATTRIBUTE) == true then
			if child:IsA("GuiObject") then
				child.BackgroundColor3 = color
			elseif child:IsA("UIStroke") then
				child.Color = color
			end
		end
	end
end

function IconCatalog.setZIndex(root: GuiObject, zIndex: number)
	root.ZIndex = zIndex
	for _, child in root:GetDescendants() do
		if child:IsA("GuiObject") then
			child.ZIndex = zIndex
		end
	end
end

return IconCatalog
