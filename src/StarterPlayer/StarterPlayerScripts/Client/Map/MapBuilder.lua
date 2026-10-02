--!strict
-- Construit la maquette 3D de la carte du monde : table, océan, pays, reliefs, villes, étiquettes.
-- Appelé par le client au lancement : la carte n'existe que chez le joueur (rien à répliquer).
-- Sert aussi à l'aperçu en mode édition dans Studio.
-- Chaque pays est découpé en régions (façon Hearts of Iron) :
--   - frontières épaisses entre deux pays, traits fins entre deux régions d'un même pays ; elles
--     suivent les conquêtes (paintRegion) ;
--   - noms des régions de près, noms des pays de loin (dossier NomsPays, voir Map/LabelLOD) ;
--   - maquettes de villes pour les capitales et les villes principales des territoires seulement.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local MapGeometry = require(Config:WaitForChild("MapGeometry")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local FlagCatalog = require(Config:WaitForChild("FlagCatalog")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any

local FONT_BOLD = Font.fromEnum(Enum.Font.BuilderSansBold)
local FONT_MEDIUM = Font.fromEnum(Enum.Font.BuilderSansMedium)
local MAX_PART = 2000 -- une pièce Roblox ne peut pas dépasser 2048 studs

local MapBuilder = {}

local buildCountryLabels: (carte: Model) -> ()

-- Pièce de base : ancrée, sans collision ni ombre.
-- Matériau Plastic (et non SmoothPlastic) : il ne renvoie pas de reflet du soleil vu d'en haut.
local function basePart(className: string): BasePart
	local p = Instance.new(className) :: BasePart
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Plastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

local WEDGE = basePart("WedgePart")
local CORNER = basePart("CornerWedgePart")
local BLOCK = basePart("Part")

local function newFolder(name: string, parent: Instance): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

-- Les couleurs de configuration restent identifiables, mais sont harmonisees pour
-- obtenir une carte politique moins criarde et plus proche d'une table d'etat-major.
local function strategicColor(color: Color3): Color3
	local hue, saturation, value = color:ToHSV()
	saturation = math.clamp(saturation * 0.72, 0.28, 0.58)
	value = math.clamp(value * 0.82 + 0.08, 0.5, 0.76)
	return Color3.fromHSV(hue, saturation, value)
end

local function shade(color: Color3, factor: number): Color3
	return Color3.new(
		math.clamp(color.R * factor, 0, 1),
		math.clamp(color.G * factor, 0, 1),
		math.clamp(color.B * factor, 0, 1)
	)
end

-- Pavé découpé en tuiles de moins de 2048 studs
local function tiledBlock(name: string, minX: number, maxX: number, minZ: number, maxZ: number, top: number, height: number, color: Color3, material: Enum.Material, parent: Instance, transparency: number?)
	local nx = math.ceil((maxX - minX) / MAX_PART)
	local nz = math.ceil((maxZ - minZ) / MAX_PART)
	local w, d = (maxX - minX) / nx, (maxZ - minZ) / nz
	for i = 0, nx - 1 do
		for j = 0, nz - 1 do
			local p = BLOCK:Clone()
			p.Name = name
			p.Size = Vector3.new(w, height, d)
			p.Position = Vector3.new(minX + w * (i + 0.5), top - height / 2, minZ + d * (j + 0.5))
			p.Color = color
			p.Material = material
			p.Transparency = transparency or 0
			if transparency then
				p.CanQuery = false
			end
			p.Parent = parent
		end
	end
end

-- Dessine un triangle horizontal épais avec deux WedgeParts
local function drawTriangle(a: Vector3, b: Vector3, c: Vector3, thickness: number, color: Color3, name: string, parent: Instance)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	-- le plus grand côté devient la base (bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b

	local normal = ac:Cross(ab)
	if normal.Magnitude < 1e-4 then
		return -- triangle plat, rien à dessiner
	end
	local right = normal.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	if height < 0.01 then
		return
	end

	local w1 = WEDGE:Clone()
	w1.Name = name
	w1.Size = Vector3.new(thickness, height, math.abs(ab:Dot(back)))
	w1.CFrame = CFrame.fromMatrix((a + b) / 2, right, up, back)
	w1.Color = color
	w1.Parent = parent

	local w2 = WEDGE:Clone()
	w2.Name = name
	w2.Size = Vector3.new(thickness, height, math.abs(ac:Dot(back)))
	w2.CFrame = CFrame.fromMatrix((a + c) / 2, -right, up, -back)
	w2.Color = color
	w2.Parent = parent
end

-- Remplit un contour de pays (plaque qui va de 0 à `top`)
local function fillPolygon(poly: any, top: number, color: Color3, name: string, parent: Instance)
	local pts, tris = poly.points, poly.triangles
	local y = top / 2
	for t = 1, #tris, 3 do
		local i1, i2, i3 = tris[t], tris[t + 1], tris[t + 2]
		local a = Vector3.new(pts[i1 * 2 - 1], y, pts[i1 * 2])
		local b = Vector3.new(pts[i2 * 2 - 1], y, pts[i2 * 2])
		local c = Vector3.new(pts[i3 * 2 - 1], y, pts[i3 * 2])
		drawTriangle(a, b, c, top, color, name, parent)
	end
end

-- Table en bois, océan et sol de la salle
local function buildTable(carte: Model)
	local folder = newFolder("Table", carte)
	local b = MapGeometry.bounds
	local m = MapSettings.tableMargin
	local minX, maxX, minZ, maxZ = b.minX - m, b.maxX + m, b.minZ - m, b.maxZ + m
	local ocean = MapSettings.oceanTop

	tiledBlock("Ocean", minX, maxX, minZ, maxZ, ocean, 4, MapSettings.oceanColor, Enum.Material.Plastic, folder)

	-- Bandes bathymetriques tres discretes : elles donnent du volume a la mer sans texture lourde.
	local function oceanBand(name: string, latA: number, latB: number, color: Color3, transparency: number)
		local _, zA = MapProjection.toXZ(0, latA)
		local _, zB = MapProjection.toXZ(0, latB)
		tiledBlock(name, minX, maxX, math.min(zA, zB), math.max(zA, zB), ocean + 0.07, 0.06, color, Enum.Material.Plastic, folder, transparency)
	end
	oceanBand("EauxTropicales", -23.5, 23.5, MapSettings.oceanTropicColor, 0.84)
	oceanBand("EauxFroidesNord", 55, MapGeometry.projection.maxLat, MapSettings.oceanColdColor, 0.88)
	oceanBand("EauxFroidesSud", MapGeometry.projection.minLat, -35, MapSettings.oceanColdColor, 0.9)

	-- cadre : dépasse de 1,5 stud au-dessus de l'eau
	local fw, top, h = MapSettings.frameWidth, ocean + 1.5, 8
	local wood, color = Enum.Material.Wood, MapSettings.frameColor
	tiledBlock("Cadre", minX - fw, maxX + fw, minZ - fw, minZ, top, h, color, wood, folder)
	tiledBlock("Cadre", minX - fw, maxX + fw, maxZ, maxZ + fw, top, h, color, wood, folder)
	tiledBlock("Cadre", minX - fw, minX, minZ, maxZ, top, h, color, wood, folder)
	tiledBlock("Cadre", maxX, maxX + fw, minZ, maxZ, top, h, color, wood, folder)

	-- Filet metallique interne, comme sur une table de commandement.
	local trim = 3.5
	local trimTop = top + 0.4
	tiledBlock("Liseret", minX - trim, maxX + trim, minZ - trim, minZ, trimTop, 0.45, MapSettings.frameTrimColor, Enum.Material.Metal, folder)
	tiledBlock("Liseret", minX - trim, maxX + trim, maxZ, maxZ + trim, trimTop, 0.45, MapSettings.frameTrimColor, Enum.Material.Metal, folder)
	tiledBlock("Liseret", minX - trim, minX, minZ, maxZ, trimTop, 0.45, MapSettings.frameTrimColor, Enum.Material.Metal, folder)
	tiledBlock("Liseret", maxX, maxX + trim, minZ, maxZ, trimTop, 0.45, MapSettings.frameTrimColor, Enum.Material.Metal, folder)

	-- sol sombre de la salle, visible au-delà du cadre
	local s = 3000
	tiledBlock("Sol", minX - s, maxX + s, minZ - s, maxZ + s, -40, 2, MapSettings.floorColor, Enum.Material.Plastic, folder)
	for _, part in folder:GetChildren() do
		if part:IsA("BasePart") and part.Name == "Sol" then
			part.CanQuery = false
		end
	end
end

-- Méridiens et parallèles tracés sur l'océan
local function buildGrid(carte: Model)
	local folder = newFolder("Quadrillage", carte)
	local y = MapSettings.oceanTop + 0.11
	local step = MapSettings.gridStep
	local majorStep = MapSettings.gridMajorStep
	local P = MapGeometry.projection

	local function segment(x1: number, z1: number, x2: number, z2: number, isMajor: boolean, isAxis: boolean)
		local p1, p2 = Vector3.new(x1, y, z1), Vector3.new(x2, y, z2)
		local len = (p2 - p1).Magnitude
		if len < 0.1 then
			return
		end
		local s = BLOCK:Clone()
		s.Name = if isAxis then "Axe" else if isMajor then "Majeure" else "Mineure"
		s.Size = Vector3.new(if isAxis then 1.25 else if isMajor then 0.8 else 0.42, 0.08, len)
		s.CFrame = CFrame.lookAt((p1 + p2) / 2, p2)
		s.Color = if isMajor or isAxis then MapSettings.gridMajorColor else MapSettings.gridColor
		s.Transparency = if isAxis then 0.43 else if isMajor then 0.6 else 0.8
		s.CanQuery = false
		s.Parent = folder
	end

	local function polyline(points: { { number } }, isMajor: boolean, isAxis: boolean)
		for i = 2, #points do
			segment(points[i - 1][1], points[i - 1][2], points[i][1], points[i][2], isMajor, isAxis)
		end
	end

	-- méridiens (lignes verticales) et parallèles (horizontales), échantillonnés tous les 10°
	for lon = -180, 180, step do
		local isMajor = lon % majorStep == 0
		local pts = {}
		for lat = P.minLat, P.maxLat, 10 do
			table.insert(pts, { MapProjection.toXZ(lon, lat) })
		end
		table.insert(pts, { MapProjection.toXZ(lon, P.maxLat) })
		polyline(pts, isMajor, lon == 0)
	end
	for lat = -45, 75, step do
		local isMajor = lat % majorStep == 0
		local pts = {}
		for lon = -180, 180, 10 do
			table.insert(pts, { MapProjection.toXZ(lon, lat) })
		end
		polyline(pts, isMajor, lat == 0)
	end
end

-- Étiquette flottante : nom de la région + pastille du propriétaire.
-- Les grands pays ont un nom plus gros, visible de plus loin.
-- Noms d'oceans et rose des vents : quelques reperes sobres suffisent a donner
-- une vraie identite cartographique sans ajouter de texture ou de decal.
local function buildCartography(carte: Model)
	local folder = newFolder("Cartographie", carte)
	local oceanY = MapSettings.oceanTop + 0.14

	local function oceanLabel(name: string, text: string, lon: number, lat: number, width: number)
		local anchor = BLOCK:Clone()
		anchor.Name = name
		anchor.Size = Vector3.one
		anchor.Position = MapProjection.toVector3(lon, lat, oceanY)
		anchor.Transparency = 1
		anchor.CanQuery = false

		local gui = Instance.new("BillboardGui")
		gui.Name = "NomOcean"
		gui.Adornee = anchor
		gui.Size = UDim2.fromOffset(width, 30)
		gui.AlwaysOnTop = false
		gui.LightInfluence = 0
		gui.MaxDistance = 2400

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.FontFace = FONT_BOLD
		label.Text = text
		label.TextColor3 = MapSettings.oceanLabelColor
		label.TextSize = 18
		label.TextTransparency = 0.42
		label.TextStrokeColor3 = Color3.fromRGB(8, 24, 35)
		label.TextStrokeTransparency = 0.72
		label.Parent = gui
		gui.Parent = anchor
		anchor.Parent = folder
	end

	oceanLabel("Atlantique", "O C E A N   A T L A N T I Q U E", -34, 18, 390)
	oceanLabel("PacifiqueOuest", "O C E A N   P A C I F I Q U E", 158, 5, 400)
	oceanLabel("PacifiqueEst", "O C E A N   P A C I F I Q U E", -145, 0, 400)
	oceanLabel("Indien", "O C E A N   I N D I E N", 78, -24, 310)
	oceanLabel("Arctique", "O C E A N   A R C T I Q U E", 5, 76, 330)

	local compass = BLOCK:Clone()
	compass.Name = "RoseDesVents"
	compass.Size = Vector3.new(82, 0.04, 82)
	compass.Position = MapProjection.toVector3(-158, -41, oceanY)
	compass.Transparency = 1
	compass.CanQuery = false

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(256, 256)
	gui.LightInfluence = 0

	local ring = Instance.new("Frame")
	ring.Name = "Anneau"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromOffset(176, 176)
	ring.BackgroundTransparency = 1
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = ring
	local ringStroke = Instance.new("UIStroke")
	ringStroke.Color = MapSettings.oceanLabelColor
	ringStroke.Transparency = 0.52
	ringStroke.Thickness = 3
	ringStroke.Parent = ring
	ring.Parent = gui

	for _, line in {
		{ UDim2.fromOffset(3, 152), UDim2.fromScale(0.5, 0.5) },
		{ UDim2.fromOffset(152, 3), UDim2.fromScale(0.5, 0.5) },
	} do
		local frame = Instance.new("Frame")
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = line[2]
		frame.Size = line[1]
		frame.BorderSizePixel = 0
		frame.BackgroundColor3 = MapSettings.oceanLabelColor
		frame.BackgroundTransparency = 0.5
		frame.Parent = gui
	end

	local needle = Instance.new("Frame")
	needle.Name = "AiguilleNord"
	needle.AnchorPoint = Vector2.new(0.5, 0.5)
	needle.Position = UDim2.fromScale(0.5, 0.5)
	needle.Size = UDim2.fromOffset(22, 22)
	needle.Rotation = 45
	needle.BorderSizePixel = 0
	needle.BackgroundColor3 = MapSettings.frameTrimColor
	needle.BackgroundTransparency = 0.1
	needle.Parent = gui

	local function cardinal(text: string, position: UDim2)
		local label = Instance.new("TextLabel")
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = position
		label.Size = UDim2.fromOffset(38, 38)
		label.BackgroundTransparency = 1
		label.FontFace = FONT_BOLD
		label.Text = text
		label.TextColor3 = MapSettings.oceanLabelColor
		label.TextSize = 25
		label.TextTransparency = 0.25
		label.Parent = gui
	end
	-- La face Top d'un SurfaceGui tourne l'axe UI d'un quart de tour sur la carte.
	cardinal("N", UDim2.fromScale(0.91, 0.5))
	cardinal("S", UDim2.fromScale(0.09, 0.5))
	cardinal("E", UDim2.fromScale(0.5, 0.91))
	cardinal("O", UDim2.fromScale(0.5, 0.09))

	gui.Parent = compass
	compass.Parent = folder
end

-- Étiquette : nom (plus gros pour une grande surface) et pastille (pays occupant, ou joueur qui
-- a déjà pris le pays sur l'écran de choix), masquée tant qu'elle n'a rien à dire.
-- maxDistance : distance de visibilité (sinon d'après la surface)
local function makeLabel(model: Instance, anchor: BasePart, regionName: string, area: number, maxDistance: number?): BillboardGui
	local L = MapSettings.labels
	local width = math.sqrt(area)
	local textSize = math.clamp(math.floor(L.sizeMin + width * L.sizePerStud), L.sizeMin, L.sizeMax)
	local nameWidth = math.max(100, (utf8.len(regionName) or #regionName) * textSize * 0.55 + 16)

	local gui = Instance.new("BillboardGui")
	gui.Name = "Etiquette"
	gui.Adornee = anchor
	gui.Size = UDim2.fromOffset(nameWidth, textSize + 28)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 2, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = maxDistance or math.max(L.distanceMin, width * L.distancePerStud)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = gui

	local name = Instance.new("TextLabel")
	name.Name = "Nom"
	name.LayoutOrder = 1
	name.BackgroundTransparency = 1
	name.Size = UDim2.new(1, 0, 0, textSize + 2)
	name.FontFace = FONT_BOLD
	name.TextSize = textSize
	name.TextColor3 = Color3.fromRGB(241, 242, 236)
	name.TextTransparency = 0.04
	name.Text = regionName
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(12, 16, 22)
	stroke.Thickness = 2
	stroke.Transparency = 0.14
	stroke.Parent = name
	name.Parent = gui

	local pill = Instance.new("Frame")
	pill.Name = "Proprietaire"
	pill.LayoutOrder = 2
	pill.AutomaticSize = Enum.AutomaticSize.X
	pill.Size = UDim2.fromOffset(0, 18)
	pill.BorderSizePixel = 0
	pill.BackgroundTransparency = 0.12
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = pill
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 7)
	padding.PaddingRight = UDim.new(0, 7)
	padding.Parent = pill
	local pillStroke = Instance.new("UIStroke")
	pillStroke.Color = Color3.new(1, 1, 1)
	pillStroke.Transparency = 0.62
	pillStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	pillStroke.Parent = pill

	local text = Instance.new("TextLabel")
	text.Name = "Texte"
	text.BackgroundTransparency = 1
	text.AutomaticSize = Enum.AutomaticSize.X
	text.Size = UDim2.fromScale(0, 1)
	text.FontFace = FONT_MEDIUM
	text.TextSize = 13
	text.TextColor3 = Color3.new(1, 1, 1)
	text.Parent = pill
	pill.Visible = false
	pill.Parent = gui

	gui.Parent = model
	return gui
end

-- Pays : régions jouables (colorées) et terres neutres
type BorderEdge = {
	x1: number,
	z1: number,
	x2: number,
	z2: number,
	top: number,
	sides: { string }, -- régions de part et d'autre (« » : terre neutre)
}
-- Frontière entre deux régions : ses segments, restylés quand l'une change de propriétaire
type BorderPair = { a: string, b: string, parts: { BasePart } }

local borderPairs: { [string]: BorderPair } = {}
local pairsOf: { [string]: { BorderPair } } = {} -- région -> ses frontières avec ses voisines
local paintedOwner: { [string]: string } = {} -- propriétaire affiché de chaque région

-- Épaisse entre deux pays, fine entre deux régions d'un même pays
local function styleBorder(pair: BorderPair)
	local a, b = paintedOwner[pair.a], paintedOwner[pair.b]
	local national = a == nil or a ~= b
	for _, part in pair.parts do
		part.Name = if national then "Frontiere" else "LimiteRegion"
		part.Size = Vector3.new(if national then 1.45 else 0.45, 0.12, part.Size.Z)
		part.Color = if national then MapSettings.borderColor else MapSettings.regionBorderColor
		part.Transparency = if national then 0.06 else 0.5
	end
end

local function borderPointKey(x: number, z: number): string
	return string.format("%.1f,%.1f", x, z)
end

local function registerBorder(edges: { [string]: BorderEdge }, poly: any, top: number, side: string)
	local points = poly.points
	for i = 1, #points, 2 do
		local j = if i + 2 <= #points then i + 2 else 1
		local x1, z1 = points[i], points[i + 1]
		local x2, z2 = points[j], points[j + 1]
		local length = math.sqrt((x2 - x1) ^ 2 + (z2 - z1) ^ 2)
		-- Les tres longs segments sont des raccords artificiels au meridien 180 degres.
		if length < 0.5 or length > 250 then
			continue
		end
		local a, b = borderPointKey(x1, z1), borderPointKey(x2, z2)
		local key = if a < b then a .. "|" .. b else b .. "|" .. a
		local existing = edges[key]
		if existing then
			table.insert(existing.sides, side)
			existing.top = math.max(existing.top, top)
		else
			edges[key] = { x1 = x1, z1 = z1, x2 = x2, z2 = z2, top = top, sides = { side } }
		end
	end
end

local function renderBorders(edges: { [string]: BorderEdge }, parent: Instance)
	for _, edge in edges do
		local dx, dz = edge.x2 - edge.x1, edge.z2 - edge.z1
		local length = math.sqrt(dx * dx + dz * dz)
		local internal = #edge.sides > 1
		-- Les frontieres politiques restent completes. Le littoral ignore seulement
		-- les micro-segments invisibles afin de preserver les performances mobiles.
		if not internal and length < 10 then
			continue
		end
		local y = edge.top + 0.1
		local p1 = Vector3.new(edge.x1, y, edge.z1)
		local p2 = Vector3.new(edge.x2, y, edge.z2)
		local line = BLOCK:Clone()
		line.Name = if internal then "Frontiere" else "Littoral"
		line.Size = Vector3.new(if internal then 1.45 else 0.95, 0.12, length)
		line.CFrame = CFrame.lookAt((p1 + p2) / 2, p2)
		line.Color = if internal then MapSettings.borderColor else MapSettings.coastColor
		line.Transparency = if internal then 0.06 else 0.3
		line.CanQuery = false
		line.Parent = parent
		-- entre deux régions jouables : le style suit leurs propriétaires
		local a, b = edge.sides[1], edge.sides[2]
		if internal and a ~= "" and b ~= "" and a ~= b then
			local key = if a < b then a .. "|" .. b else b .. "|" .. a
			local pair = borderPairs[key]
			if not pair then
				pair = { a = a, b = b, parts = {} }
				borderPairs[key] = pair
				pairsOf[a] = pairsOf[a] or {}
				table.insert(pairsOf[a], pair)
				pairsOf[b] = pairsOf[b] or {}
				table.insert(pairsOf[b], pair)
			end
			table.insert(pair.parts, line)
		end
	end
	for _, pair in borderPairs do
		styleBorder(pair)
	end
end

-- Noms des pays, vus de loin : posés sur la région la plus proche du centre du pays (pondéré par
-- la surface, territoires lointains exclus) ; taille et distance de visibilité d'après la surface
-- du pays. Masqués quand le pays a perdu sa capitale (attribut Vivant, voir paintRegion).
function buildCountryLabels(carte: Model)
	local folder = newFolder("NomsPays", carte)
	local top = MapSettings.regionTop
	for countryId, info in Countries do
		local sumX, sumZ, total = 0, 0, 0
		local shapes = {}
		for regionId, region in Regions do
			local shape = MapGeometry.countries[region.geometry]
			if shape and region.startOwner == countryId and (regionId:match("^(%u+)") == countryId) then
				sumX += shape.label[1] * shape.area
				sumZ += shape.label[2] * shape.area
				total += shape.area
				table.insert(shapes, shape)
			end
		end
		if total <= 0 then
			continue
		end
		local cx, cz = sumX / total, sumZ / total
		local best, bestDistance = shapes[1], math.huge
		for _, shape in shapes do
			local d = (shape.label[1] - cx) ^ 2 + (shape.label[2] - cz) ^ 2
			if d < bestDistance then
				best, bestDistance = shape, d
			end
		end
		local anchor = BLOCK:Clone()
		anchor.Name = countryId
		anchor.Size = Vector3.one
		anchor.Transparency = 1
		anchor.CanQuery = false
		anchor.Position = Vector3.new(best.label[1], top + 1, best.label[2])
		anchor.Parent = folder
		local gui = makeLabel(anchor, anchor, info.name, total)
		gui.Name = "NomPays"
		gui.Enabled = false -- affiché de loin seulement (Map/LabelLOD)
		gui:SetAttribute("Vivant", true)
	end
end

local function buildLands(carte: Model, owners: { [string]: string })
	table.clear(borderPairs)
	table.clear(pairsOf)
	table.clear(paintedOwner)
	local regionsFolder = newFolder("Regions", carte)
	local neutralFolder = newFolder("TerresNeutres", carte)
	local bordersFolder = newFolder("Frontieres", carte)
	local borderEdges: { [string]: BorderEdge } = {}

	local regionByGeometry: { [string]: string } = {}
	for id, region in Regions do
		regionByGeometry[region.geometry] = id
	end

	for key, country in MapGeometry.countries do
		local regionId = regionByGeometry[key]
		if regionId then
			local region = Regions[regionId]
			local top = MapSettings.regionTop + (country.raise or 0)
			local model = Instance.new("Model")
			model.Name = regionId
			model:SetAttribute("RegionId", regionId)
			for _, poly in country.polygons do
				fillPolygon(poly, top, Color3.new(1, 1, 1), "Plaque", model)
				registerBorder(borderEdges, poly, top, regionId)
			end
			local anchor = BLOCK:Clone()
			anchor.Name = "Ancre"
			anchor.Size = Vector3.one
			anchor.Transparency = 1
			anchor.CanQuery = false
			anchor.Position = Vector3.new(country.label[1], top + 1, country.label[2])
			anchor.Parent = model
			makeLabel(model, anchor, region.name, country.area, MapSettings.labels.regionDistance)
			model.Parent = regionsFolder
			MapBuilder.paintRegion(carte, regionId, owners[regionId] or region.startOwner)
		else
			for _, poly in country.polygons do
				fillPolygon(poly, MapSettings.neutralLandTop, MapSettings.neutralLandColor, "Terre", neutralFolder)
				registerBorder(borderEdges, poly, MapSettings.neutralLandTop, "")
			end
		end
	end
	renderBorders(borderEdges, bordersFolder)
	buildCountryLabels(carte)
end

-- Pic low-poly : pyramide faite de 4 CornerWedgeParts.
-- Le sommet d'une CornerWedgePart est dans son coin (+X, -Z) : chaque quart est tourné
-- pour que ce coin pointe vers le centre de la pyramide.
local QUARTERS = {
	{ 1, 1, math.rad(90) },
	{ -1, 1, 0 },
	{ 1, -1, math.pi },
	{ -1, -1, math.rad(-90) },
}

-- cf : centre de la base au sol
local function pyramid(cf: CFrame, halfWidth: number, height: number, color: Color3, material: Enum.Material, parent: Instance)
	for _, q in QUARTERS do
		local p = CORNER:Clone()
		p.Name = "Relief"
		p.Size = Vector3.new(halfWidth, height, halfWidth)
		p.CFrame = cf * CFrame.new(q[1] * halfWidth / 2, height / 2, q[2] * halfWidth / 2) * CFrame.Angles(0, q[3], 0)
		p.Color = color
		p.Material = material
		p.CastShadow = true
		p.CanQuery = false
		p.Parent = parent
	end
end

local function buildMountains(carte: Model)
	local folder = newFolder("Reliefs", carte)
	local rng = Random.new(1944)
	local base = 1.0
	local rock: Color3 = MapSettings.mountainColor
	local spacing = MapSettings.mountainSpacing

	for _, chain in MapSettings.mountains do
		local pts = {}
		for _, p in chain.points do
			local x, z = MapProjection.toXZ(p.lon, p.lat)
			table.insert(pts, Vector3.new(x, base, z))
		end
		local total = 0
		for i = 2, #pts do
			total += (pts[i] - pts[i - 1]).Magnitude
		end

		local walked = 0
		for i = 1, #pts - 1 do
			local p1, p2 = pts[i], pts[i + 1]
			local len = (p2 - p1).Magnitude
			local dir = (p2 - p1).Unit
			local count = math.max(1, math.floor(len / spacing))
			for k = 0, count - 1 do
				local t = (k + rng:NextNumber(0.2, 0.8)) / count
				local pos = p1:Lerp(p2, t)
				-- les sommets sont plus bas aux extrémités de la chaîne
				local progress = (walked + t * len) / total
				local taper = 0.55 + 0.45 * math.clamp(math.min(progress, 1 - progress) / 0.15, 0, 1)
				local h = chain.height * rng:NextNumber(0.55, 1) * taper
				local half = h * rng:NextNumber(0.9, 1.3) + 1.5
				local offset = dir:Cross(Vector3.yAxis) * rng:NextNumber(-4, 4)
				local cf = CFrame.new(pos + offset) * CFrame.Angles(0, rng:NextNumber(0, math.pi / 2), 0)
				local shade = rng:NextNumber(0.85, 1.1)
				local color = Color3.new(math.min(1, rock.R * shade), math.min(1, rock.G * shade), math.min(1, rock.B * shade))
				pyramid(cf, half, h, color, Enum.Material.Slate, folder)
				if h > MapSettings.snowHeight then
					-- neige au sommet : petite pyramide un peu plus large pour recouvrir la pointe
					local r = 0.33
					pyramid(cf * CFrame.new(0, h * (1 - r), 0), half * r * 1.05, h * r * 1.01, MapSettings.snowColor, Enum.Material.Snow, folder)
				end
			end
			walked += len
		end
	end
end

-- Villes : capitale (socle doré) ou ville principale d'un territoire (socle gris), avec leur nom de près
local function makeFlagFace(cloth: BasePart, face: Enum.NormalId, countryId: string)
	local surface = Instance.new("SurfaceGui")
	surface.Name = if face == Enum.NormalId.Front then "DrapeauAvant" else "DrapeauArriere"
	surface.Face = face
	surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surface.PixelsPerStud = 72
	surface.LightInfluence = 0

	local image = Instance.new("ImageLabel")
	image.Name = "Image"
	local country = Countries[countryId]
	local fallbackColor = if country then country.color else Color3.fromRGB(80, 84, 92)
	image.BackgroundColor3 = fallbackColor
	image.BorderSizePixel = 0
	image.Size = UDim2.fromScale(1, 1)
	FlagCatalog.apply(image, countryId)
	image.Parent = surface

	local code = Instance.new("TextLabel")
	code.Name = "CodeSecours"
	code.BackgroundTransparency = 1
	code.Size = UDim2.fromScale(1, 1)
	code.FontFace = FONT_BOLD
	code.Text = countryId
	code.TextColor3 = Color3.new(1, 1, 1)
	code.TextScaled = true
	code.TextStrokeColor3 = Color3.new(0, 0, 0)
	code.TextStrokeTransparency = 0.15
	code.ZIndex = 2
	code.Parent = surface
	local function refreshFallback()
		code.Visible = not image.IsLoaded
		image.BackgroundColor3 = if image.IsLoaded then Color3.fromRGB(235, 235, 232) else fallbackColor
	end
	image:GetPropertyChangedSignal("IsLoaded"):Connect(refreshFallback)
	refreshFallback()
	surface.Parent = cloth
end

-- Petit mat et drapeau national place a cote de chaque capitale.
-- Le tissu est une vraie piece 3D, lisible des deux cotes.
local function makeCapitalFlag(city: Model, center: Vector3, countryId: string)
	local pole = BLOCK:Clone()
	pole.Name = "MatDrapeau"
	pole.Size = Vector3.new(0.16, 4.2, 0.16)
	pole.Position = center + Vector3.new(2.5, 2.1, 0)
	pole.Color = Color3.fromRGB(92, 96, 104)
	pole.Material = Enum.Material.Metal
	pole.CastShadow = true
	pole.CanQuery = false
	pole.Parent = city

	local cloth = BLOCK:Clone()
	cloth.Name = "DrapeauNational"
	cloth.Size = Vector3.new(3.2, 2, 0.08)
	cloth.Position = center + Vector3.new(4.1, 3.05, 0)
	cloth.Color = Color3.fromRGB(235, 235, 232)
	cloth.CastShadow = true
	cloth.CanQuery = false
	makeFlagFace(cloth, Enum.NormalId.Front, countryId)
	makeFlagFace(cloth, Enum.NormalId.Back, countryId)
	cloth.Parent = city

	city:SetAttribute("CountryId", countryId)
end

local function buildCities(carte: Model)
	local folder = newFolder("Villes", carte)
	local rng = Random.new(7)
	local top = MapSettings.regionTop

	for _, region in Regions do
		local info = region.city
		-- les autres régions n'ont qu'un point de repère (là où stationnent les armées), pas de ville
		if not info or not (info.isCapital or info.isMain) then
			continue
		end
		local center = MapProjection.toVector3(info.lon, info.lat, top)
		local capital = info.isCapital == true
		local city = Instance.new("Model")
		city.Name = info.name

		local diameter = if capital then 6 else 3.8
		local disc = BLOCK:Clone() :: Part
		disc.Name = "Socle"
		disc.Shape = Enum.PartType.Cylinder
		disc.Size = Vector3.new(0.3, diameter, diameter)
		disc.CFrame = CFrame.new(center + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90))
		disc.Color = if capital then MapSettings.capitalBaseColor else MapSettings.townBaseColor
		disc.Material = if capital then Enum.Material.Metal else Enum.Material.Slate
		disc.CastShadow = false
		disc.CanQuery = false
		disc.Parent = city

		if capital then
			local halo = BLOCK:Clone() :: Part
			halo.Name = "HaloCapitale"
			halo.Shape = Enum.PartType.Cylinder
			halo.Size = Vector3.new(0.06, diameter + 2.2, diameter + 2.2)
			halo.CFrame = CFrame.new(center + Vector3.new(0, 0.04, 0)) * CFrame.Angles(0, 0, math.rad(90))
			halo.Color = MapSettings.capitalBaseColor
			halo.Material = Enum.Material.Neon
			halo.Transparency = 0.68
			halo.CanQuery = false
			halo.Parent = city

			local core = BLOCK:Clone() :: Part
			core.Name = "NoyauCapitale"
			core.Shape = Enum.PartType.Cylinder
			core.Size = Vector3.new(0.08, diameter - 1.2, diameter - 1.2)
			core.CFrame = CFrame.new(center + Vector3.new(0, 0.34, 0)) * CFrame.Angles(0, 0, math.rad(90))
			core.Color = MapSettings.capitalCoreColor
			core.Material = Enum.Material.SmoothPlastic
			core.CanQuery = false
			core.Parent = city

			for rotation = 0, 90, 90 do
				local road = BLOCK:Clone()
				road.Name = "Avenue"
				road.Size = Vector3.new(diameter - 1.5, 0.05, 0.3)
				road.CFrame = CFrame.new(center + Vector3.new(0, 0.4, 0)) * CFrame.Angles(0, math.rad(rotation), 0)
				road.Color = Color3.fromRGB(122, 126, 126)
				road.Material = Enum.Material.Concrete
				road.CanQuery = false
				road.Parent = city
			end
		end

		for _ = 1, if capital then 5 else 2 do
			local b = BLOCK:Clone()
			b.Name = "Immeuble"
			local h = rng:NextNumber(0.8, 2.8)
			local s = rng:NextNumber(0.6, 1.2)
			local angle = rng:NextNumber(0, math.pi * 2)
			local r = rng:NextNumber(0, diameter * 0.25)
			b.Size = Vector3.new(s, h, s)
			b.Position = center + Vector3.new(math.cos(angle) * r, 0.3 + h / 2, math.sin(angle) * r)
			b.Color = shade(MapSettings.cityColor, rng:NextNumber(0.82, 1.08))
			b.Material = Enum.Material.Concrete
			b.CastShadow = true
			b.CanQuery = false
			b.Parent = city

			local roof = BLOCK:Clone()
			roof.Name = "Toit"
			roof.Size = Vector3.new(s + 0.12, 0.12, s + 0.12)
			roof.Position = b.Position + Vector3.new(0, h / 2 + 0.06, 0)
			roof.Color = MapSettings.cityRoofColor
			roof.Material = Enum.Material.Metal
			roof.CastShadow = true
			roof.CanQuery = false
			roof.Parent = city
		end

		local gui = Instance.new("BillboardGui")
		gui.Name = "NomVille"
		gui.Adornee = disc
		gui.Size = UDim2.fromOffset(180, 22)
		gui.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
		gui.AlwaysOnTop = true
		gui.LightInfluence = 0
		gui.MaxDistance = MapSettings.labels.cityDistance
		local label = Instance.new("TextLabel")
		label.BackgroundColor3 = Color3.fromRGB(17, 22, 29)
		label.BackgroundTransparency = 0.24
		label.BorderSizePixel = 0
		label.Size = UDim2.fromScale(1, 1)
		label.FontFace = FONT_MEDIUM
		label.TextSize = 14
		label.TextColor3 = Color3.fromRGB(244, 242, 230)
		label.Text = if capital then "★ " .. info.name else info.name
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(5, 7, 10)
		stroke.Thickness = 1.3
		stroke.Transparency = 0.2
		stroke.Parent = label
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 5)
		corner.Parent = label
		label.Parent = gui
		gui.Parent = city

		if capital then
			makeCapitalFlag(city, center, region.startOwner)
		end

		city.Parent = folder
	end
end

-- Construit une nouvelle carte (non parentée). owners : propriétaire de chaque région.
function MapBuilder.build(owners: { [string]: string }?): Model
	local carte = Instance.new("Model")
	carte.Name = "Carte"
	buildTable(carte)
	buildGrid(carte)
	buildCartography(carte)
	buildLands(carte, owners or {})
	buildMountains(carte)
	buildCities(carte)
	return carte
end

local TAKEN_GREY = Color3.fromRGB(91, 96, 105)

-- Colore une région aux couleurs de son propriétaire et met à jour son étiquette.
-- takenBy : pseudo du joueur qui dirige déjà ce pays (écran de choix) -> région grisée.
-- dim : assombrissement (brouillard de guerre : région hors de vue), de 0 à 1
function MapBuilder.paintRegion(carte: Model, regionId: string, ownerId: string, takenBy: string?, dim: number?)
	local owner = Countries[ownerId]
	local regions = carte:FindFirstChild("Regions")
	local model = regions and regions:FindFirstChild(regionId)
	if not owner or not model then
		return
	end
	local ownerMapColor = strategicColor(owner.color)
	local color = if takenBy then ownerMapColor:Lerp(TAKEN_GREY, 0.78) else ownerMapColor
	if dim and dim > 0 then
		color = color:Lerp(Color3.new(0.04, 0.05, 0.08), dim)
	end
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and child.Name == "Plaque" then
			child.Color = color
		end
	end
	local region = Regions[regionId]
	local occupied = region ~= nil and region.startOwner ~= ownerId
	local label = model:FindFirstChild("Etiquette")
	local pill = label and label:FindFirstChild("Proprietaire")
	if pill and pill:IsA("Frame") then
		-- la couleur dit déjà à qui est la région : la pastille ne sert que pour une occupation
		pill.Visible = takenBy ~= nil or occupied
		pill.BackgroundColor3 = if takenBy then Color3.fromRGB(51, 55, 62) else shade(ownerMapColor, 0.78)
		local text = pill:FindFirstChild("Texte")
		if text and text:IsA("TextLabel") then
			text.Text = if takenBy then "Pris par " .. takenBy else owner.name
		end
	end
	-- frontières avec les voisines : épaisses si le propriétaire diffère
	if paintedOwner[regionId] ~= ownerId then
		paintedOwner[regionId] = ownerId
		for _, pair in pairsOf[regionId] or {} do
			styleBorder(pair)
		end
	end
	-- région de la capitale : le nom du pays n'apparaît que s'il la tient (et « Pris par » au choix)
	local names = carte:FindFirstChild("NomsPays")
	local countryAnchor = if Countries[regionId] and names then names:FindFirstChild(regionId) else nil
	local countryLabel = countryAnchor and countryAnchor:FindFirstChild("NomPays")
	if countryLabel then
		countryLabel:SetAttribute("Vivant", ownerId == regionId)
		local countryPill = countryLabel:FindFirstChild("Proprietaire")
		if countryPill and countryPill:IsA("Frame") then
			countryPill.Visible = takenBy ~= nil
			countryPill.BackgroundColor3 = Color3.fromRGB(51, 55, 62)
			local text = countryPill:FindFirstChild("Texte")
			if text and text:IsA("TextLabel") then
				text.Text = if takenBy then "Pris par " .. takenBy else ""
			end
		end
	end
end

return MapBuilder
