--!strict
-- Divisions sur la carte (SYSTEME_MILITAIRE.md, 7.1) : 1 division = 1 modèle 3D, rangées en
-- formation dans leur région, face à l'ennemi le plus proche (10 au plus par région, la limite de
-- stationnement). Les troupes de l'armée d'un général ne sont pas affichées : le général les
-- représente (GeneralRenderer, une seule unité avec un compteur).
--   de près : les modèles, avec au-dessus de chacun ses barres d'organisation (verte) et de force
--     (orange) et l'icône de son type ; ils marchent ou roulent d'une région à l'autre (barre bleue
--     de progression) ; en bataille, ils font face à l'ennemi (blindés devant en attaque, derrière
--     en défense) ; une division détruite s'enfonce et disparaît dans un nuage de fumée ;
--   de loin, ou trop loin de la caméra : une seule étiquette par région (« 7 div. » et les icônes) ;
--   brouillard de guerre : seules les divisions visibles (State/Fog) sont affichées ;
--   performance : modèles seulement près de la caméra, animations seulement tout près.
-- Purement visuel : le serveur ne donne que la position logique (région, trajet en cours).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local UnitStyles = require(Config:WaitForChild("UnitStyles")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any
local UnitPainter = require(Shared:WaitForChild("UnitPainter")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local Client = script.Parent.Parent
local MilitaryState = require(script.Parent:WaitForChild("MilitaryState"))
local Fog = require(Client:WaitForChild("State"):WaitForChild("Fog"))
local RegionView = require(Client:WaitForChild("Map"):WaitForChild("RegionView"))

local MODEL_DISTANCE = 420 -- au-delà de cette distance de la caméra : étiquette de région, pas de modèles
local ANIM_DISTANCE = 160 -- au-delà, les modèles ne s'animent pas
local BAR_DISTANCE = 170 -- barres de moral (organisation) et de PV visibles jusqu'à cette distance
local FAR_HEIGHT = 300 -- caméra plus haute : seulement les étiquettes de région
local LABEL_DISTANCE = 1400 -- étiquettes de région visibles jusqu'à cette distance...
local LABEL_MAX_HEIGHT = 1100 -- ... et seulement sous cette hauteur de caméra (tout en haut : la carte seule)
local REFRESH = 0.3 -- secondes entre deux choix des régions à afficher
local SPACING = 2.8 -- écart entre deux modèles d'une formation (studs)
local PER_ROW = 5 -- modèles par rangée
local CAPITAL_OFFSET = 6 -- dans la région d'une capitale, la formation se tient devant la ville
local TARGET_SIZE = { soldier = 2.4, vehicle = 3.2 } -- plus grande dimension d'un modèle (studs)
local FACE_SOUTH = math.rad(180) -- vers la caméra (elle est au sud et regarde le nord)
local MAX_DYING = 12 -- divisions détruites animées en même temps, au plus
local FONT = Font.fromEnum(Enum.Font.BuilderSansBold)

type View = {
	division: Instance,
	model: Model,
	lift: number,
	bars: BillboardGui,
	idle: AnimationTrack?,
	walk: AnimationTrack?,
	walking: boolean,
	rest: CFrame, -- place dans la formation (au sol)
	color: Color3,
}
type RegionState = {
	shown: boolean, -- modèles affichés (sinon étiquette)
	label: BillboardGui?,
	anchor: BasePart?,
}

local UnitRenderer = {}

local container: Folder? = nil
local templates: Instance? = nil
local views: { [Instance]: View } = {}
local regions: { [string]: RegionState } = {}
local dirty: { [string]: boolean } = {} -- régions dont la formation est à refaire
local labelListeners: { (regionId: string) -> () } = {}
-- les étiquettes de région se touchent : leurs BillboardGui doivent être dans l'interface du joueur
local labelFolder: Folder? = nil
local labelsEnabled = false -- étiquettes seulement en partie (sur l'écran de choix, elles cacheraient la carte)
local scales: { [string]: number } = {} -- échelle de chaque modèle source

local function anchorOf(regionId: string): Vector3?
	local region = Regions[regionId]
	local city = region and region.city
	if not city then
		return nil
	end
	return MapProjection.toVector3(city.lon, city.lat, MapSettings.regionTop)
end

-- Échelle d'un modèle source pour que sa plus grande dimension vaille TARGET_SIZE
local function scaleFor(template: Model): number
	local cached = scales[template.Name]
	if cached then
		return cached
	end
	local _, size = template:GetBoundingBox()
	local soldier = template:FindFirstChildOfClass("Humanoid") ~= nil
	local target = if soldier then TARGET_SIZE.soldier else TARGET_SIZE.vehicle
	local scale = target / math.max(size.X, size.Y, size.Z, 0.1)
	scales[template.Name] = scale
	return scale
end

local function liftOf(model: Model): number
	local box, size = model:GetBoundingBox()
	return model:GetPivot().Position.Y - (box.Position.Y - size.Y / 2)
end

local function loadTrack(model: Model, id: string): AnimationTrack?
	local animator = model:FindFirstChildWhichIsA("Animator", true)
	if not animator then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = id
	local ok, track = pcall(function()
		return (animator :: Animator):LoadAnimation(animation)
	end)
	if ok and track then
		track.Looped = true
		return track
	end
	return nil
end

-- Barres d'organisation et de force au-dessus d'un modèle
local function makeBars(model: Model, icon: string): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "Barres"
	gui.Adornee = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	gui.Size = UDim2.fromOffset(46, 15)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 1.6, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = BAR_DISTANCE
	local iconLabel = Instance.new("TextLabel")
	iconLabel.Name = "Icone"
	iconLabel.BackgroundTransparency = 1
	iconLabel.Size = UDim2.fromOffset(14, 15)
	iconLabel.FontFace = FONT
	iconLabel.TextSize = 11
	iconLabel.Text = icon
	iconLabel.TextColor3 = Color3.new(1, 1, 1)
	iconLabel.Parent = gui
	for i, name in { "Org", "Force" } do
		local back = Instance.new("Frame")
		back.Name = name
		back.Position = UDim2.fromOffset(15, if i == 1 then 3 else 9)
		back.Size = UDim2.fromOffset(30, 4)
		back.BackgroundColor3 = Color3.fromRGB(20, 22, 26)
		back.BorderSizePixel = 0
		local fill = Instance.new("Frame")
		fill.Name = "Remplissage"
		fill.Size = UDim2.fromScale(1, 1)
		fill.BorderSizePixel = 0
		fill.BackgroundColor3 = if i == 1 then Color3.fromRGB(110, 210, 110) else Color3.fromRGB(240, 160, 60)
		fill.Parent = back
		back.Parent = gui
	end
	-- progression du trajet en cours (bleue), seulement quand la division est en route
	local trip = Instance.new("Frame")
	trip.Name = "Trajet"
	trip.Position = UDim2.fromOffset(0, -5)
	trip.Size = UDim2.fromOffset(45, 3)
	trip.BackgroundColor3 = Color3.fromRGB(20, 22, 26)
	trip.BorderSizePixel = 0
	trip.Visible = false
	local tripFill = Instance.new("Frame")
	tripFill.Name = "Remplissage"
	tripFill.Size = UDim2.fromScale(0, 1)
	tripFill.BorderSizePixel = 0
	tripFill.BackgroundColor3 = Color3.fromRGB(110, 170, 255)
	tripFill.Parent = trip
	trip.Parent = gui
	gui.Size = UDim2.fromOffset(46, 20)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 1.7, 0)
	for _, child in gui:GetChildren() do
		if child:IsA("GuiObject") then
			child.Position += UDim2.fromOffset(0, 5)
		end
	end
	gui.Parent = model
	return gui
end

local function refreshBars(view: View)
	local d = view.division
	local org = (d:GetAttribute("Org") :: number?) or 0
	local orgMax = math.max((d:GetAttribute("OrgMax") :: number?) or 1, 1)
	local force = (d:GetAttribute("Force") :: number?) or 0
	local orgFill = (view.bars:FindFirstChild("Org") :: Frame):FindFirstChild("Remplissage") :: Frame
	local forceFill = (view.bars:FindFirstChild("Force") :: Frame):FindFirstChild("Remplissage") :: Frame
	orgFill.Size = UDim2.fromScale(math.clamp(org / orgMax, 0, 1), 1)
	forceFill.Size = UDim2.fromScale(math.clamp(force / 100, 0, 1), 1)
	local training = MilitaryState.isTraining(d)
	local icon = view.bars:FindFirstChild("Icone") :: TextLabel
	icon.Text = if training then "⏳" else MilitaryState.typeOf(d).icon
end

-- Modèle en entraînement : à moitié transparent
local function setGhost(model: Model, ghost: boolean)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.LocalTransparencyModifier = if ghost then 0.55 else 0
		end
	end
end

local dying = 0 -- modèles en train de disparaître (animation limitée en nombre)

-- Division détruite, près de la caméra : le modèle s'enfonce et s'efface dans un nuage de fumée
local function dieAnimation(model: Model)
	dying += 1
	local box, size = model:GetBoundingBox()
	local smoke = Instance.new("Part")
	smoke.Name = "Fumee"
	smoke.Shape = Enum.PartType.Ball
	smoke.Anchored = true
	smoke.CanCollide = false
	smoke.CanQuery = false
	smoke.CanTouch = false
	smoke.CastShadow = false
	smoke.Color = Color3.fromRGB(110, 110, 110)
	smoke.Transparency = 0.3
	smoke.Size = Vector3.one * math.max(size.X, size.Z)
	smoke.Position = box.Position
	smoke.Parent = container
	TweenService:Create(smoke, TweenInfo.new(1.2), { Size = smoke.Size * 2.2, Transparency = 1, Position = box.Position + Vector3.new(0, 1.5, 0) }):Play()
	local bars = model:FindFirstChild("Barres")
	if bars then
		bars:Destroy()
	end
	local start = model:GetPivot()
	local elapsed = 0
	local connection: RBXScriptConnection? = nil
	connection = RunService.RenderStepped:Connect(function(dt: number)
		elapsed += dt
		local t = math.clamp(elapsed / 0.9, 0, 1)
		if model.Parent then
			model:PivotTo(start * CFrame.new(0, -size.Y * 0.8 * t, 0) * CFrame.Angles(0, 0, math.rad(25) * t))
			for _, part in model:GetDescendants() do
				if part:IsA("BasePart") then
					part.LocalTransparencyModifier = t
				end
			end
		end
		if t >= 1 then
			(connection :: RBXScriptConnection):Disconnect()
			model:Destroy()
			smoke:Destroy()
			dying -= 1
		end
	end)
end

local function removeView(d: Instance, destroyed: boolean?)
	local view = views[d]
	if view then
		views[d] = nil
		local near = (view.model:GetPivot().Position - workspace.CurrentCamera.CFrame.Position).Magnitude < ANIM_DISTANCE
		if destroyed and near and dying < MAX_DYING then
			dieAnimation(view.model)
		else
			view.model:Destroy()
		end
	end
end

local function ensureView(d: Instance): View?
	local existing = views[d]
	if existing then
		return existing
	end
	if not container or not templates then
		return nil
	end
	local t = MilitaryState.typeOf(d)
	local template = templates:FindFirstChild(t.model)
	if not template or not template:IsA("Model") then
		return nil
	end
	local model = template:Clone()
	local owner = Countries[d:GetAttribute("Proprietaire") :: string]
	local color = if owner then owner.color else Color3.fromRGB(150, 150, 150)
	UnitPainter.paint(model, color)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			-- soldat : seule la racine est ancrée, pour que la marche s'anime
			part.Anchored = humanoid == nil or part == model.PrimaryPart
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = true -- cliquable (sélection)
			part.CastShadow = false
		end
	end
	model:ScaleTo(scaleFor(template))
	model:SetAttribute("DivisionId", d.Name)
	model.Name = d.Name
	model.Parent = container
	local view: View = {
		division = d,
		model = model,
		lift = liftOf(model),
		bars = makeBars(model, t.icon),
		idle = if humanoid then loadTrack(model, UnitStyles.idleAnimation) else nil,
		walk = if humanoid then loadTrack(model, UnitStyles.walkAnimation) else nil,
		walking = false,
		rest = CFrame.identity,
		color = color,
	}
	refreshBars(view)
	setGhost(model, MilitaryState.isTraining(d))
	views[d] = view
	return view
end

-- Direction vers la région ennemie voisine la plus proche (lacet), sinon vers la caméra
local function facingFor(regionId: string, owner: string?): number
	local here = anchorOf(regionId)
	local region = Regions[regionId]
	if not here or not region or not owner then
		return FACE_SOUTH
	end
	local best: Vector3? = nil
	local bestDistance = math.huge
	for _, link in region.neighbors do
		local other = RegionView.getOwner(link.region)
		if not link.bySea and other and other ~= owner and DiplomacyState.atWar(owner, other) then
			local there = anchorOf(link.region)
			if there and (there - here).Magnitude < bestDistance then
				best, bestDistance = there, (there - here).Magnitude
			end
		end
	end
	if not best then
		return FACE_SOUTH
	end
	local dir = best - here
	return math.atan2(-dir.X, -dir.Z) -- les modèles regardent vers -Z
end

local function battleFolder(id: unknown): Instance?
	if typeof(id) ~= "string" then
		return nil
	end
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local battles = state and state:FindFirstChild("Batailles")
	return battles and battles:FindFirstChild(id)
end

-- Région attaquée par une division (nil : elle n'attaque pas)
local function attackTarget(d: Instance): string?
	local battle = battleFolder(d:GetAttribute("Bataille"))
	local target = battle and battle:GetAttribute("Region")
	return if typeof(target) == "string" and target ~= d:GetAttribute("Region") then target else nil
end

local function yawToward(from: Vector3, to: Vector3): number
	local dir = to - from
	return math.atan2(-dir.X, -dir.Z) -- les modèles regardent vers -Z
end

-- Places des divisions d'une région : rangées face à l'ennemi. Pendant une bataille, face à la
-- région attaquée (ou aux attaquants) ; les blindés devant en attaque, derrière en défense.
local function layout(regionId: string, list: { Instance })
	local here = anchorOf(regionId)
	if not here then
		return
	end
	local owner = if #list > 0 then list[1]:GetAttribute("Proprietaire") :: string else nil
	local yaw = facingFor(regionId, owner)
	local attacking = false
	for _, d in list do
		local target = attackTarget(d)
		local there = target and anchorOf(target)
		if there then
			yaw = yawToward(here, there)
			attacking = true
			break
		end
	end
	if not attacking then
		-- région attaquée : face à la première direction d'attaque
		local defended = list[1] and battleFolder(list[1]:GetAttribute("Bataille"))
		local directions = defended and defended:GetAttribute("Directions")
		local from = if typeof(directions) == "string" and directions ~= "" then anchorOf(string.split(directions, ",")[1]) else nil
		if from then
			yaw = yawToward(here, from)
		end
	end
	local function armored(d: Instance): boolean
		return MilitaryState.typeOf(d).hardness >= 0.5
	end
	list = table.clone(list)
	table.sort(list, function(a: Instance, b: Instance): boolean
		local ha, hb = armored(a), armored(b)
		if ha ~= hb then
			return if attacking then ha else hb -- le premier rang est devant
		end
		return (tonumber(a.Name:match("%d+")) or 0) < (tonumber(b.Name:match("%d+")) or 0)
	end)
	local frame = CFrame.new(here) * CFrame.Angles(0, yaw, 0)
	if Regions[regionId].city and Regions[regionId].city.isCapital then
		frame *= CFrame.new(0, 0, -CAPITAL_OFFSET) -- devant la ville
	end
	local count = #list
	local rows = math.ceil(count / PER_ROW)
	for i, d in list do
		local row = (i - 1) // PER_ROW
		local inRow = math.min(PER_ROW, count - row * PER_ROW)
		local col = (i - 1) % PER_ROW
		local x = (col - (inRow - 1) / 2) * SPACING
		local z = (row - (rows - 1) / 2) * SPACING
		local view = views[d]
		if view then
			view.rest = frame * CFrame.new(x, 0, z)
		end
	end
end

local function pose(view: View, cf: CFrame)
	view.model:PivotTo(cf + Vector3.new(0, view.lift, 0))
end

-- Position d'une division en route : de sa place vers la région d'arrivée
local function travelPose(view: View): (CFrame?, boolean)
	local d = view.division
	if not MilitaryState.isMoving(d) then
		return view.rest, false
	end
	local destination = anchorOf(d:GetAttribute("Destination") :: string)
	if not destination then
		return view.rest, false
	end
	local start, finish = d:GetAttribute("Depart") :: number, d:GetAttribute("Arrivee") :: number
	local t = math.clamp((workspace:GetServerTimeNow() - start) / math.max(finish - start, 0.001), 0, 1)
	local from = view.rest.Position
	local to = destination + (from - (anchorOf(d:GetAttribute("Region") :: string) or from))
	local p = from:Lerp(to, t)
	local dir = to - from
	local yaw = if dir.Magnitude > 0.01 then math.atan2(-dir.X, -dir.Z) else 0
	return CFrame.new(p) * CFrame.Angles(0, yaw, 0), true
end

local function setWalking(view: View, walking: boolean, animate: boolean)
	local playing = walking and animate
	if view.walking == playing then
		return
	end
	view.walking = playing
	if view.walk then
		if playing then
			view.walk:Play(0.2)
		else
			view.walk:Stop(0.2)
		end
	end
end

-- Étiquette d'une région vue de loin : « ● 7 div. ⚔️5 🛡️2 »
local function labelText(list: { Instance }): string
	local counts: { [string]: number } = {}
	local order = {}
	for _, d in list do
		local t = MilitaryState.typeOf(d)
		if not counts[t.icon] then
			table.insert(order, t.icon)
		end
		counts[t.icon] = (counts[t.icon] or 0) + 1
	end
	local parts = {}
	for _, icon in order do
		table.insert(parts, `{icon}{counts[icon]}`)
	end
	local owner = Countries[list[1]:GetAttribute("Proprietaire") :: string]
	local hex = if owner then owner.color:ToHex() else "FFFFFF"
	return `<font color="#{hex}">●</font> {#list} div.  {table.concat(parts, " ")}`
end

local function ensureLabel(regionId: string, state: RegionState): BillboardGui?
	if state.label then
		return state.label
	end
	local here = anchorOf(regionId)
	if not here or not container then
		return nil
	end
	local anchor = Instance.new("Part")
	anchor.Name = "Pile_" .. regionId
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.Position = here + Vector3.new(0, 3, 0)
	anchor.Parent = container
	local gui = Instance.new("BillboardGui")
	gui.Name = "PileDivisions"
	gui.Adornee = anchor
	gui.Size = UDim2.fromOffset(150, 22)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = LABEL_DISTANCE
	gui.Active = true -- l'étiquette se touche : elle sélectionne les divisions de la région
	local text = Instance.new("TextButton")
	text.AutoButtonColor = false
	text.Name = "Texte"
	text.BackgroundColor3 = Color3.fromRGB(16, 20, 26)
	text.BackgroundTransparency = 0.25
	text.AutomaticSize = Enum.AutomaticSize.X
	text.AnchorPoint = Vector2.new(0.5, 0.5)
	text.Position = UDim2.fromScale(0.5, 0.5)
	text.Size = UDim2.fromOffset(0, 20)
	text.FontFace = FONT
	text.TextSize = 13
	text.RichText = true
	text.TextColor3 = Color3.new(1, 1, 1)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = text
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 6)
	padding.PaddingRight = UDim.new(0, 6)
	padding.Parent = text
	text.Parent = gui
	text.Activated:Connect(function()
		for _, listener in labelListeners do
			task.spawn(listener, regionId)
		end
	end)
	gui.Parent = labelFolder
	state.anchor = anchor
	state.label = gui
	return gui
end

local function removeLabel(state: RegionState)
	if state.label then
		state.label:Destroy()
	end
	if state.anchor then
		state.anchor:Destroy()
	end
	state.anchor = nil
	state.label = nil
end

-- Choisit, pour chaque région, modèles ou étiquette (selon la caméra et le brouillard)
local function refresh()
	local camera = workspace.CurrentCamera
	local cameraPosition = camera.CFrame.Position
	local far = cameraPosition.Y > FAR_HEIGHT
	local seen: { [string]: boolean } = {}
	for _, regionId in MilitaryState.regions() do
		local here = anchorOf(regionId)
		if not here then
			continue
		end
		seen[regionId] = true
		local state = regions[regionId]
		if not state then
			state = { shown = false }
			regions[regionId] = state
		end
		local list = {}
		for _, d in MilitaryState.inRegion(regionId) do
			if Fog.isArmyVisible(d) then
				table.insert(list, d)
			end
		end
		local distance = (here - cameraPosition).Magnitude
		local showModels = #list > 0 and not far and distance < MODEL_DISTANCE
		if showModels then
			removeLabel(state)
			local changed = not state.shown or dirty[regionId]
			for _, d in list do
				if not views[d] then
					ensureView(d)
					changed = true
				end
			end
			-- divisions qui ne sont plus visibles ici
			for d, view in views do
				if view.division:GetAttribute("Region") == regionId and not table.find(list, d) then
					removeView(d)
					changed = true
				end
			end
			if changed then
				layout(regionId, list)
				for _, d in list do
					local view = views[d]
					if view and not MilitaryState.isMoving(d) then
						pose(view, view.rest)
					end
				end
			end
			state.shown = true
		else
			if state.shown then
				for _, d in MilitaryState.allInRegion(regionId) do
					removeView(d)
				end
				state.shown = false
			end
			if labelsEnabled and #list > 0 and distance < LABEL_DISTANCE and cameraPosition.Y < LABEL_MAX_HEIGHT then
				local gui = ensureLabel(regionId, state)
				if gui then
					(gui:FindFirstChild("Texte") :: TextButton).Text = labelText(list)
				end
			else
				removeLabel(state)
			end
		end
		dirty[regionId] = nil
	end
	-- régions vidées
	for regionId, state in regions do
		if not seen[regionId] then
			removeLabel(state)
			regions[regionId] = nil
		end
	end
	-- modèles orphelins (division disparue ou région quittée)
	for d, view in views do
		local regionId = d:GetAttribute("Region")
		if not d.Parent or typeof(regionId) ~= "string" or not (regions[regionId] and regions[regionId].shown) then
			removeView(d)
		end
	end
end

function UnitRenderer.start(carte: Model)
	local folder = Instance.new("Folder")
	folder.Name = "Divisions"
	folder.Parent = carte
	container = folder
	local labels = Instance.new("Folder")
	labels.Name = "EtiquettesDivisions"
	labels.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	labelFolder = labels
	templates = ReplicatedStorage:WaitForChild("Modeles", 30)

	MilitaryState.onRegionChanged(function(regionId: string)
		dirty[regionId] = true
	end)
	MilitaryState.onChanged(function(d: Instance, removed: boolean)
		if removed then
			-- détruite en partie (pas au changement de partie) : petite animation
			removeView(d, MatchState.isRunning())
			return
		end
		local view = views[d]
		if view then
			refreshBars(view)
			setGhost(view.model, MilitaryState.isTraining(d))
		end
	end)
	Fog.onChanged(function()
		for regionId in regions do
			dirty[regionId] = true
		end
	end)

	local clock = 0
	RunService.RenderStepped:Connect(function(dt: number)
		clock += dt
		if clock >= REFRESH then
			clock = 0
			refresh()
		end
		local camera = workspace.CurrentCamera
		local cameraPosition = camera.CFrame.Position
		local now = workspace:GetServerTimeNow()
		for d, view in views do
			local cf, moving = travelPose(view)
			local near = (view.rest.Position - cameraPosition).Magnitude < ANIM_DISTANCE
			setWalking(view, moving, near)
			-- barre de progression du trajet
			local trip = view.bars:FindFirstChild("Trajet") :: Frame?
			if trip then
				trip.Visible = moving
				if moving then
					local start, finish = (d:GetAttribute("Depart") :: number?) or now, (d:GetAttribute("Arrivee") :: number?) or now
					local t = math.clamp((now - start) / math.max(finish - start, 0.001), 0, 1);
					(trip:FindFirstChild("Remplissage") :: Frame).Size = UDim2.fromScale(t, 1)
				end
			end
			if moving and cf then
				local _, onScreen = camera:WorldToViewportPoint(cf.Position)
				if onScreen then
					pose(view, cf)
				end
			end
			if view.idle then
				local shouldIdle = near and not view.walking
				if shouldIdle and not view.idle.IsPlaying then
					view.idle:Play(0.2)
				elseif not shouldIdle and view.idle.IsPlaying then
					view.idle:Stop(0.2)
				end
			end
		end
	end)
end

-- Division dont le modèle est sous une position de l'écran (ou nil)
function UnitRenderer.hitTest(screenPos: Vector2): string?
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
		local id = node:GetAttribute("DivisionId")
		if typeof(id) == "string" then
			return id
		end
		node = node.Parent
	end
	return nil
end

-- Étiquettes de région (vue de loin) : seulement en partie
function UnitRenderer.setLabelsEnabled(enabled: boolean)
	labelsEnabled = enabled
end

-- listener(région) : le joueur a touché l'étiquette d'une région (vue de loin)
function UnitRenderer.onLabelClicked(listener: (regionId: string) -> ())
	table.insert(labelListeners, listener)
end

-- Modèle d'une division (nil s'il n'est pas affiché)
function UnitRenderer.modelOf(d: Instance): Model?
	local view = views[d]
	return if view then view.model else nil
end

-- Position d'une division sur la carte (même sans modèle affiché)
function UnitRenderer.positionOf(d: Instance): Vector3?
	local view = views[d]
	if view then
		return view.model:GetPivot().Position
	end
	local regionId = d:GetAttribute("Region")
	return if typeof(regionId) == "string" then anchorOf(regionId) else nil
end

return UnitRenderer
