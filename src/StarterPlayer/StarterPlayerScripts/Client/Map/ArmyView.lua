--!strict
-- Forces sur la carte, chacune représentée par son chef (principe du « système de généraux ») :
--   Terre : général R15 au drapeau, au nord de la ville, escorte de 0 à 3 soldats
--   Air   : avion de tête qui tourne au-dessus de la ville, ailiers en V (0 à 3)
--   Mer   : navire amiral au mouillage devant le port, escorteurs (0 à 3)
-- Le serveur ne donne que la position logique (région, trajet en cours) : le client anime.
-- Brouillard de guerre : les forces étrangères hors de vue sont retirées de la carte (State/Fog).
-- Niveaux de détail : de loin, l'escorte disparaît et les animations s'arrêtent ; une force hors de
-- l'écran n'est pas animée.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Units = require(Config:WaitForChild("Units")) :: any
local UnitStyles = require(Config:WaitForChild("UnitStyles")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any
local UnitPainter = require(Shared:WaitForChild("UnitPainter")) :: any
local ArmyState = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("ArmyState"))
local Fog = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("Fog"))
local MilitaryMath = require(Shared:WaitForChild("MilitaryMath")) :: any
local GeneralTraits = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GeneralTraits")) :: any

local FONT = Font.fromEnum(Enum.Font.BuilderSansBold)
local FONT_MEDIUM = Font.fromEnum(Enum.Font.BuilderSansMedium)
local FACE_CAMERA = math.rad(180) -- la caméra est au sud et regarde le nord
local SEA_LEVEL = MapSettings.oceanTop

-- Emplacements de repos selon la sorte de force (décalages autour du point d'ancrage). Les régions
-- sont petites (un pays en compte plusieurs) : les armées restent près du centre de la leur.
local SLOTS = {
	Terre = { Vector3.new(0, 0, -4), Vector3.new(6, 0, -7), Vector3.new(-6, 0, -7), Vector3.new(0, 0, -10), Vector3.new(10, 0, -12), Vector3.new(-10, 0, -12) },
	Air = { Vector3.new(0, 0, -4), Vector3.new(12, 0, -8), Vector3.new(-12, 0, -8) },
	Mer = { Vector3.new(0, 0, 0), Vector3.new(11, 0, 6), Vector3.new(-11, 0, 6) },
}
-- Suiveurs : derrière le chef (le modèle regarde vers -Z, donc +Z = derrière lui)
local FOLLOWERS = {
	Terre = { CFrame.new(-2.8, 0, 3.2), CFrame.new(2.8, 0, 3.2), CFrame.new(0, 0, 5.8) },
	Air = { CFrame.new(-5, -0.5, 5), CFrame.new(5, -0.5, 5), CFrame.new(0, -1, 10) },
	Mer = { CFrame.new(-7, 0, 9), CFrame.new(7, 0, 9), CFrame.new(0, 0, 16) },
}
local FOLLOWER_SCALE = { Terre = 1, Air = 0.7, Mer = 0.7 }
local ORBIT_RADIUS = 6
local LOD_DISTANCE = 650 -- au-delà, la force est simplifiée (chef seul, sans animation)
local LOD_INTERVAL = 0.3 -- secondes entre deux vérifications des distances

type View = {
	kind: string,
	group: Model,
	leader: Model,
	followers: { Model },
	lift: number, -- hauteur du pivot au-dessus du point le plus bas du modèle
	label: BillboardGui,
	idle: AnimationTrack?,
	walk: AnimationTrack?,
	walking: boolean,
	phase: number, -- décalage des animations (orbite, tangage)
	far: boolean, -- vue de loin : simplifiée
}

local ArmyView = {}

local container: Folder? = nil
local templates: Instance? = nil
local views: { [Instance]: View } = {}
local highlight: Highlight? = nil

-- Point d'ancrage d'une région pour une sorte de force (au sol, en mer ou en vol)
local function anchor(regionId: string, kind: string): Vector3?
	local region = Regions[regionId]
	if not region then
		return nil
	end
	local lonLat = if kind == "Mer" then region.port or region.city else region.city
	if not lonLat then
		return nil
	end
	local ground = MapProjection.toVector3(lonLat.lon, lonLat.lat, MapSettings.regionTop)
	if kind == "Mer" then
		return Vector3.new(ground.X, SEA_LEVEL, ground.Z)
	elseif kind == "Air" then
		return ground + Vector3.new(0, Units.kinds.Air.altitude, 0)
	end
	return ground
end

-- Rang d'une force parmi celles de même sorte à l'arrêt dans sa région
local function slotOf(army: Instance, kind: string): Vector3
	local list = {}
	for _, other in ArmyState.restingIn(army:GetAttribute("Region") :: string) do
		if ArmyState.kind(other) == kind then
			table.insert(list, other)
		end
	end
	local index = table.find(list, army) or 1
	local slots = SLOTS[kind]
	return slots[(index - 1) % #slots + 1]
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

local function prepare(model: Model, color: Color3?)
	if color then
		UnitPainter.paint(model, color)
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanQuery = true -- cliquable (certains modèles sont créés non cliquables)
		end
	end
end

local function makeLabel(leader: Model, kind: string): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "Etiquette"
	gui.Adornee = leader.PrimaryPart
	gui.Size = UDim2.fromOffset(230, 58)
	gui.StudsOffsetWorldSpace = Vector3.new(0, if kind == "Terre" then 4.8 else 4, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 1200
	for i, name in { "Nom", "Troupes" } do
		local label = Instance.new("TextLabel")
		label.Name = name
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromOffset(0, (i - 1) * 21)
		label.Size = UDim2.new(1, 0, 0, 21)
		label.FontFace = if i == 1 then FONT else FONT_MEDIUM
		label.TextSize = if i == 1 then 15 else 14
		label.TextColor3 = Color3.new(1, 1, 1)
		label.RichText = true
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1.5
		stroke.Parent = label
		label.Parent = gui
	end
	-- barre de moral et icônes d'état (ravitaillement, ordre)
	local status = Instance.new("Frame")
	status.Name = "Statut"
	status.BackgroundTransparency = 1
	status.Position = UDim2.fromOffset(0, 44)
	status.Size = UDim2.new(1, 0, 0, 12)
	local bar = Instance.new("Frame")
	bar.Name = "Moral"
	bar.AnchorPoint = Vector2.new(0.5, 0.5)
	bar.Position = UDim2.new(0.5, -14, 0.5, 0)
	bar.Size = UDim2.fromOffset(90, 6)
	bar.BackgroundColor3 = Color3.fromRGB(25, 25, 28)
	bar.BorderSizePixel = 0
	local fill = Instance.new("Frame")
	fill.Name = "Remplissage"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BorderSizePixel = 0
	fill.Parent = bar
	bar.Parent = status
	local icons = Instance.new("TextLabel")
	icons.Name = "Icones"
	icons.BackgroundTransparency = 1
	icons.AnchorPoint = Vector2.new(0, 0.5)
	icons.Position = UDim2.new(0.5, 36, 0.5, 0)
	icons.Size = UDim2.fromOffset(60, 14)
	icons.FontFace = FONT_MEDIUM
	icons.TextSize = 12
	icons.TextXAlignment = Enum.TextXAlignment.Left
	icons.TextColor3 = Color3.new(1, 1, 1)
	icons.Parent = status
	status.Parent = gui
	gui.Parent = leader
	return gui
end

local function setFollowers(view: View, army: Instance)
	local _, total = ArmyState.troops(army)
	local wanted = 0
	for _, rule in Units.escort do
		if total <= rule.maxUnits then
			wanted = rule.followers
			break
		end
	end
	local templateName = if view.kind == "Terre" then "Soldat" else Units.kinds[view.kind].leaderModel
	local template = templates and templates:FindFirstChild(templateName)
	local owner = Countries[army:GetAttribute("Proprietaire") :: string]
	while #view.followers < wanted and template do
		local f = (template :: Model):Clone()
		prepare(f, if owner then owner.color else nil)
		if FOLLOWER_SCALE[view.kind] ~= 1 then
			f:ScaleTo(FOLLOWER_SCALE[view.kind])
		end
		f.Parent = if view.far then nil else view.group -- de loin, l'escorte reste cachée
		table.insert(view.followers, f)
	end
	while #view.followers > wanted do
		(table.remove(view.followers) :: Model):Destroy()
	end
end

-- Place le chef (et ses suiveurs) en `point`, tourné de `yaw`
local function pose(view: View, point: Vector3, yaw: number)
	local height = if view.kind == "Air" then 0 else view.lift
	if view.kind == "Mer" then
		height = view.lift - 0.4 -- la coque s'enfonce un peu sous la ligne de flottaison
	end
	local cf = CFrame.new(point + Vector3.new(0, height, 0)) * CFrame.Angles(0, yaw, 0)
	view.leader:PivotTo(cf)
	local offsets = FOLLOWERS[view.kind]
	for i, follower in view.followers do
		follower:PivotTo(cf * offsets[i])
	end
end

-- Position et orientation d'une force (trajet en cours, ou repos animé)
local function placement(army: Instance, view: View?): (Vector3?, number, boolean)
	local kind = ArmyState.kind(army)
	local phase = if view then view.phase else 0
	if not ArmyState.isMoving(army) then
		local base = anchor(army:GetAttribute("Region") :: string, kind)
		if not base then
			return nil, FACE_CAMERA, false
		end
		local rest = base + slotOf(army, kind)
		local t = os.clock()
		if kind == "Air" then
			-- l'escadrille tourne en rond au-dessus de sa région
			local angle = t * 0.45 + phase
			local p = rest + Vector3.new(math.cos(angle) * ORBIT_RADIUS, math.sin(t * 1.3 + phase) * 0.4, math.sin(angle) * ORBIT_RADIUS)
			local tangent = Vector3.new(-math.sin(angle), 0, math.cos(angle))
			return p, math.atan2(-tangent.X, -tangent.Z), false
		elseif kind == "Mer" then
			return rest + Vector3.new(0, math.sin(t * 0.9 + phase) * 0.08, 0), FACE_CAMERA + math.sin(t * 0.3 + phase) * 0.05, false
		end
		return rest, FACE_CAMERA, false
	end
	local travelKind = if kind == "Terre" and army:GetAttribute("ParMer") then "Terre" else kind
	local from = anchor(army:GetAttribute("Region") :: string, travelKind)
	local to = anchor(army:GetAttribute("Destination") :: string, travelKind)
	if not from or not to then
		return nil, FACE_CAMERA, false
	end
	local slot = SLOTS[kind][1]
	from += slot
	to += slot
	local start, finish = army:GetAttribute("Depart") :: number, army:GetAttribute("Arrivee") :: number
	local t = math.clamp((workspace:GetServerTimeNow() - start) / math.max(finish - start, 0.001), 0, 1)
	local direction = to - from
	local yaw = math.atan2(-direction.X, -direction.Z) -- les modèles regardent vers -Z
	return from:Lerp(to, t), yaw, true
end

local function refreshLabel(view: View, army: Instance)
	local owner = Countries[army:GetAttribute("Proprietaire") :: string]
	local color = if owner then "#" .. owner.color:ToHex() else "#FFFFFF"
	local nameLabel = view.label:FindFirstChild("Nom") :: TextLabel
	local troopsLabel = view.label:FindFirstChild("Troupes") :: TextLabel
	local traits = GeneralTraits.icons(army)
	nameLabel.Text = `<font color="{color}">●</font> {Units.kinds[view.kind].icon} {army:GetAttribute("Nom")}{if traits ~= "" then " " .. traits else ""}`
	local _, total = ArmyState.troops(army)
	local text = `{ArmyState.troopText(army)} · {total}/{ArmyState.capacity(army)}`
	if ArmyState.isMoving(army) then
		-- destination finale de l'itinéraire (et nombre d'étapes restantes)
		local steps = ArmyState.itinerary(army)
		local final = Regions[if #steps > 0 then steps[#steps] else army:GetAttribute("Destination") :: string]
		text ..= `  {if army:GetAttribute("ParMer") then "⛴️" else "→"} {final and final.name or "?"}{if #steps > 0 then ` ({#steps + 1} étapes)` else ""}`
	end
	troopsLabel.Text = text

	local morale = MilitaryMath.morale(army)
	local status = view.label:FindFirstChild("Statut") :: Frame
	local fill = (status:FindFirstChild("Moral") :: Frame):FindFirstChild("Remplissage") :: Frame
	fill.Size = UDim2.fromScale(morale / 100, 1)
	fill.BackgroundColor3 = if morale >= 60 then Color3.fromRGB(120, 220, 130) elseif morale >= 30 then Color3.fromRGB(240, 170, 70) else Color3.fromRGB(235, 95, 85)
	local icons = {}
	if not MilitaryMath.isSupplied(army) then
		table.insert(icons, "⚠️")
	end
	local posture = army:GetAttribute("Posture")
	if posture == "Defendre" then
		table.insert(icons, "🛡️")
	elseif posture == "Tenir" then
		table.insert(icons, "📌")
	end
	(status:FindFirstChild("Icones") :: TextLabel).Text = table.concat(icons, " ")
end

-- Brouillard : la force n'est sur la carte que si on la voit (ses animations reprennent ensuite)
local function applyVisibility(army: Instance, view: View)
	local parent = if Fog.isArmyVisible(army) then container else nil
	if view.group.Parent ~= parent then
		view.group.Parent = parent
		if parent then
			view.walking = not view.walking -- force la reprise de l'animation au prochain update
		end
	end
end

local function update(army: Instance)
	local view = views[army]
	if not view then
		return
	end
	applyVisibility(army, view)
	if not view.group.Parent then
		return
	end
	setFollowers(view, army)
	refreshLabel(view, army)
	local point, yaw, moving = placement(army, view)
	if point then
		pose(view, point, yaw)
	end
	if view.kind == "Terre" and moving ~= view.walking then
		view.walking = moving
		if moving then
			if view.idle then
				view.idle:Stop(0.2)
			end
			if view.walk then
				view.walk:Play(0.2)
			end
		else
			if view.walk then
				view.walk:Stop(0.2)
			end
			if view.idle then
				view.idle:Play(0.2)
			end
		end
	end
end

local function ensure(army: Instance)
	if views[army] or not container or not templates then
		return
	end
	local kind = ArmyState.kind(army)
	local template = templates:FindFirstChild(Units.kinds[kind].leaderModel)
	if not template then
		return
	end
	local group = Instance.new("Model")
	group.Name = army.Name
	group:SetAttribute("ArmyId", army.Name)
	local leader = (template :: Model):Clone()
	local owner = Countries[army:GetAttribute("Proprietaire") :: string]
	prepare(leader, if owner then owner.color else nil)
	leader.Parent = group
	group.Parent = container

	local view: View = {
		kind = kind,
		group = group,
		leader = leader,
		followers = {},
		lift = liftOf(leader),
		label = makeLabel(leader, kind),
		idle = if kind == "Terre" then loadTrack(leader, UnitStyles.idleAnimation) else nil,
		walk = if kind == "Terre" then loadTrack(leader, UnitStyles.walkAnimation) else nil,
		walking = false,
		phase = (tonumber(army.Name:match("%d+")) or 0) * 1.7,
		far = false,
	}
	if view.idle then
		view.idle:Play()
	end
	views[army] = view
end

-- Force sous une position de l'écran (ou nil)
function ArmyView.hitTest(screenPos: Vector2): string?
	if not container then
		return nil
	end
	local ray = workspace.CurrentCamera:ScreenPointToRay(screenPos.X, screenPos.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { container }
	local result = workspace:Raycast(ray.Origin, ray.Direction * 20000, params)
	if not result then
		return nil
	end
	local model: Instance? = result.Instance
	while model and model ~= container do
		local id = model:GetAttribute("ArmyId")
		if typeof(id) == "string" then
			return id
		end
		model = model.Parent
	end
	return nil
end

-- Position d'une force sur la carte (au sol, en vol ou en mer), sans l'animation de repos
function ArmyView.positionOf(armyId: string): Vector3?
	local army = ArmyState.get(armyId)
	if not army then
		return nil
	end
	local kind = ArmyState.kind(army)
	if not ArmyState.isMoving(army) then
		local base = anchor(army:GetAttribute("Region") :: string, kind)
		return if base then base + slotOf(army, kind) else nil
	end
	local point = placement(army, views[army])
	return point
end

-- Point d'arrivée d'une force en route (nil si elle est à l'arrêt)
function ArmyView.destinationOf(armyId: string): Vector3?
	local army = ArmyState.get(armyId)
	if not army or not ArmyState.isMoving(army) then
		return nil
	end
	local kind = ArmyState.kind(army)
	local to = anchor(army:GetAttribute("Destination") :: string, kind)
	return if to then to + SLOTS[kind][1] else nil
end

-- Point où se tient une force de cette sorte dans une région (étapes des flèches de trajet)
function ArmyView.pointOf(regionId: string, kind: string): Vector3?
	local base = anchor(regionId, kind)
	return if base then base + SLOTS[kind][1] else nil
end

-- Met une force en surbrillance (nil = aucune)
function ArmyView.setSelected(armyId: string?)
	if not highlight then
		return
	end
	local army = if armyId then ArmyState.get(armyId) else nil
	local view = army and views[army]
	highlight.Adornee = if view then view.group else nil
	highlight.Enabled = view ~= nil
end

function ArmyView.start(carte: Model)
	local folder = Instance.new("Folder")
	folder.Name = "Armees"
	folder.Parent = carte
	container = folder
	local h = Instance.new("Highlight")
	h.Name = "ArmeeChoisie"
	h.FillTransparency = 1
	h.OutlineColor = Color3.fromRGB(255, 225, 110)
	h.Enabled = false
	h.Parent = carte
	highlight = h

	templates = ReplicatedStorage:WaitForChild("Modeles", 30)

	ArmyState.onChanged(function(army: Instance, removed: boolean)
		if removed then
			local view = views[army]
			if view then
				view.group:Destroy()
				views[army] = nil
			end
			return
		end
		ensure(army)
		-- les forces d'une même région se répartissent les emplacements
		for other in views do
			if other == army or other:GetAttribute("Region") == army:GetAttribute("Region") then
				update(other)
			end
		end
	end)
	for _, army in ArmyState.list() do
		ensure(army)
		update(army)
	end

	-- brouillard : ce qu'on voit change
	Fog.onChanged(function()
		for army in views do
			update(army)
		end
	end)

	-- trajets en cours, orbites des escadrilles, tangage des flottes
	-- niveaux de détail : de loin, chef seul et animations figées
	local function applyLOD(view: View, far: boolean)
		if view.far == far then
			return
		end
		view.far = far
		for _, follower in view.followers do
			follower.Parent = if far then nil else view.group
		end
		for _, track in { view.idle, view.walk } do
			if track then
				track:AdjustSpeed(if far then 0 else 1)
			end
		end
	end
	local lodClock = 0
	RunService.RenderStepped:Connect(function(dt: number)
		local camera = workspace.CurrentCamera
		local cameraPosition = camera.CFrame.Position
		lodClock += dt
		local checkLOD = lodClock >= LOD_INTERVAL
		if checkLOD then
			lodClock = 0
		end
		for army, view in views do
			if not view.group.Parent then
				continue
			end
			local position = view.leader:GetPivot().Position
			if checkLOD then
				applyLOD(view, (cameraPosition - position).Magnitude > LOD_DISTANCE)
			end
			if ArmyState.isMoving(army) or view.kind ~= "Terre" then
				-- hors de l'écran : la force n'est pas déplacée (elle le sera en revenant à l'écran)
				local point, yaw = placement(army, view)
				if point then
					local _, onScreen = camera:WorldToViewportPoint(point)
					if onScreen then
						pose(view, point, yaw)
					end
				end
			end
		end
	end)
end

return ArmyView
