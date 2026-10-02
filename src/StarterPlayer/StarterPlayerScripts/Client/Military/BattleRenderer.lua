--!strict
-- Batailles terrestres sur la carte (SYSTEME_MILITAIRE.md, 7.3), côté client, purement visuel :
--   icône ronde entre la région attaquée et ses attaquants : verte (on gagne), jaune (indécis) ou
--   rouge (on perd) quand le joueur est concerné, grise sinon ; sous l'icône, une barre partagée
--   entre l'organisation des deux camps ; toucher l'icône ouvre le panneau (BattlePanel) ;
--   à chaque tick (Config/CombatConfig.tickSeconds), près de la caméra : tirs (éclair au bout du
--   canon, traçante vers l'ennemi) de chaque soldat engagé vers SA cible (attribut Cible, calculé
--   par le serveur) ; les tireurs animés changent à chaque tick, tous finissent par tirer ; l'armée
--   d'un général tire depuis le modèle du général ; petites explosions stylisées dans la région
--   attaquée, fusillade audible de près (pas de sang) ;
--   messages : région attaquée, victoire, défaite.
-- Le serveur décide de tout (EtatMonde.Batailles, Genre « Terre ») ; ici on ne fait qu'afficher.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local UnitPainter = require(Shared:WaitForChild("UnitPainter")) :: any
local Client = script.Parent.Parent
local CombatConfig = require(Config:WaitForChild("CombatConfig")) :: any
local MilitaryState = require(script.Parent:WaitForChild("MilitaryState"))
local UnitRenderer = require(script.Parent:WaitForChild("UnitRenderer"))
local GeneralRenderer = require(script.Parent:WaitForChild("GeneralRenderer"))
local BattlePanel = require(script.Parent:WaitForChild("BattlePanel"))
local Fog = require(Client:WaitForChild("State"):WaitForChild("Fog"))
local UI = Client:WaitForChild("UI")
local Toast = require(UI:WaitForChild("Toast"))
local Sfx = require(Client:WaitForChild("Audio"):WaitForChild("Sfx"))

local ICON_SIZE = 40
local ICON_LIFT = 3 -- studs au-dessus de la carte
local TOWARD_ATTACKERS = 0.4 -- l'icône est à 40 % du chemin entre la région attaquée et ses attaquants
local EFFECT_DISTANCE = 220 -- au-delà de cette distance de la caméra : pas de tirs ni de son
local EXPLOSIONS_PER_TICK = 3
local COLORS = {
	good = Color3.fromRGB(80, 200, 110),
	unsure = Color3.fromRGB(235, 190, 70),
	bad = Color3.fromRGB(225, 80, 70),
	neutral = Color3.fromRGB(150, 160, 175),
}
local HEAVY = { Artillerie = true, Blindee = true, Mecanisee = true } -- leurs tirs explosent à l'arrivée

type Track = {
	folder: Instance,
	anchor: Part,
	gui: BillboardGui,
	button: TextButton,
	fill: Frame,
	back: Frame,
	stopSound: (() -> ())?,
	ended: boolean,
	planes: { [string]: Model }, -- avions de soutien au-dessus de la bataille, par camp
	rotation: number, -- premier tireur animé au prochain tick
}

-- Un soldat engagé dont un modèle est affiché
type Shooter = { id: string, model: Model, heavy: boolean, target: string? }

local BattleRenderer = {}

local container: Folder? = nil -- pièces des icônes et des effets (dans la carte)
local iconFolder: Folder? = nil -- icônes (dans l'interface du joueur, pour qu'elles se touchent)
local tracks: { [Instance]: Track } = {}

local function anchorOf(regionId: unknown): Vector3?
	local region = if typeof(regionId) == "string" then Regions[regionId] else nil
	local city = region and region.city
	return if city then MapProjection.toVector3(city.lon, city.lat, MapSettings.regionTop) else nil
end

local function myCountry(): string?
	local me = Players.LocalPlayer:GetAttribute("Pays")
	return if typeof(me) == "string" and me ~= "" then me else nil
end

local function countryName(id: unknown): string
	local country = if typeof(id) == "string" then Countries[id] else nil
	return if country then country.name else "?"
end

-- Camp du joueur dans cette bataille : "Attaquant", "Defenseur" ou nil (il n'y est pas)
local function sideOf(folder: Instance): string?
	local me = myCountry()
	if not me then
		return nil
	end
	local attacker, defender = folder:GetAttribute("Attaquant"), folder:GetAttribute("Defenseur")
	if me == attacker or (typeof(attacker) == "string" and DiplomacyState.areAllies(me, attacker)) then
		return "Attaquant"
	elseif me == defender or (typeof(defender) == "string" and DiplomacyState.areAllies(me, defender)) then
		return "Defenseur"
	end
	return nil
end

-- Position de l'icône : entre la région attaquée et la moyenne des régions d'où l'on attaque
local function iconPosition(folder: Instance): Vector3?
	local target = anchorOf(folder:GetAttribute("Region"))
	if not target then
		return nil
	end
	local directions = folder:GetAttribute("Directions")
	local sum, n = Vector3.zero, 0
	if typeof(directions) == "string" then
		for _, regionId in string.split(directions, ",") do
			local p = anchorOf(regionId)
			if p then
				sum += p
				n += 1
			end
		end
	end
	local p = if n > 0 then target:Lerp(sum / n, TOWARD_ATTACKERS) else target
	return p + Vector3.new(0, ICON_LIFT, 0)
end

local function refreshIcon(track: Track)
	local folder = track.folder
	local position = iconPosition(folder)
	if position then
		track.anchor.Position = position
	end
	local side = sideOf(folder)
	local prevision = folder:GetAttribute("Prevision")
	local state = folder:GetAttribute("Etat")
	local color = COLORS.neutral
	if state == "Victoire" or state == "Repli" then
		-- résultat : bon ou mauvais pour le joueur
		local attackerWon = state == "Victoire"
		color = if side == nil then COLORS.neutral elseif (side == "Attaquant") == attackerWon then COLORS.good else COLORS.bad
		track.button.Text = if attackerWon then "🏆" else "🛡️"
	else
		if side ~= nil then
			if prevision == "Indecis" or prevision == nil then
				color = COLORS.unsure
			elseif prevision == side then
				color = COLORS.good
			else
				color = COLORS.bad
			end
		end
		track.button.Text = "⚔️"
	end
	track.button.BackgroundColor3 = color
	-- barre : part de l'organisation de l'attaquant dans celle des deux camps
	local a = (folder:GetAttribute("OrgAttaque") :: number?) or 1
	local d = (folder:GetAttribute("OrgDefense") :: number?) or 1
	track.fill.Size = UDim2.fromScale(if a + d > 0 then a / (a + d) else 0.5, 1)
	local attacker = Countries[folder:GetAttribute("Attaquant") :: string]
	local defender = Countries[folder:GetAttribute("Defenseur") :: string]
	track.fill.BackgroundColor3 = if attacker then attacker.color else COLORS.neutral
	track.back.BackgroundColor3 = if defender then defender.color else COLORS.neutral
end

-- ---- Effets (tirs et explosions), seulement près de la caméra -------------------------------

local function effectPart(name: string, shape: Enum.PartType, size: Vector3, color: Color3, cf: CFrame): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = size
	p.CFrame = cf
	p.Parent = container
	return p
end

local function fadeOut(part: BasePart, duration: number, goalSize: Vector3?)
	local goal: { [string]: any } = { Transparency = 1 }
	if goalSize then
		goal.Size = goalSize
	end
	local tween = TweenService:Create(part, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
	tween:Play()
	task.delay(duration + 0.05, function()
		part:Destroy()
	end)
end

-- Bout du canon (ou du fusil) d'un modèle : devant lui, un peu au-dessus du sol
local function muzzleOf(model: Model): Vector3
	local box, size = model:GetBoundingBox()
	return box.Position + box.LookVector * (size.Z * 0.5) + Vector3.new(0, size.Y * 0.15, 0)
end

local function centerOf(model: Model): Vector3
	return (model:GetBoundingBox()).Position
end

local function shot(from: Model, to: Model, heavy: boolean, explode: boolean)
	if not from.Parent or not to.Parent then
		return
	end
	local a = muzzleOf(from)
	local b = centerOf(to) + Vector3.new((math.random() - 0.5) * 0.8, 0, (math.random() - 0.5) * 0.8)
	-- éclair au bout du canon
	local flash = effectPart("Eclair", Enum.PartType.Ball, Vector3.one * (if heavy then 0.7 else 0.35), Color3.fromRGB(255, 220, 120), CFrame.new(a))
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 200, 110)
	light.Range = if heavy then 8 else 5
	light.Brightness = 2
	light.Parent = flash
	fadeOut(flash, 0.12)
	-- traçante
	local length = (b - a).Magnitude
	if length > 0.1 then
		local tracer = effectPart("Tracante", Enum.PartType.Block, Vector3.new(0.06, 0.06, length), Color3.fromRGB(255, 235, 160), CFrame.lookAt((a + b) / 2, b))
		fadeOut(tracer, 0.1)
	end
	if explode then
		-- petite explosion stylisée et un nuage de fumée (pas de sang)
		local boom = effectPart("Explosion", Enum.PartType.Ball, Vector3.one * 0.4, Color3.fromRGB(255, 150, 60), CFrame.new(b))
		fadeOut(boom, 0.3, Vector3.one * 2.4)
		local smoke = effectPart("Fumee", Enum.PartType.Ball, Vector3.one * 1.2, Color3.fromRGB(120, 120, 120), CFrame.new(b + Vector3.new(0, 0.6, 0)))
		smoke.Material = Enum.Material.SmoothPlastic
		smoke.Transparency = 0.35
		fadeOut(smoke, 0.9, Vector3.one * 3.2)
		Sfx.playAt("Explosion", b)
	end
end

-- Modèle d'une division : le sien, ou celui de son général (l'armée d'un général n'a qu'un modèle)
local function modelFor(d: Instance): Model?
	local model = UnitRenderer.modelOf(d)
	if model then
		return model
	end
	if MilitaryState.isAbsorbed(d) then
		return GeneralRenderer.modelOf(d:GetAttribute("Armee") :: string)
	end
	return nil
end

-- Soldats engagés de la bataille dont un modèle est affiché, par camp (dans un ordre stable), et
-- par identifiant
local function engagedModels(folder: Instance): ({ Shooter }, { Shooter }, { [string]: Shooter })
	local regionId = folder:GetAttribute("Region")
	local attackers, defenders = {}, {}
	local byId: { [string]: Shooter } = {}
	for _, d in MilitaryState.list() do
		if d:GetAttribute("Bataille") == folder.Name and d:GetAttribute("EnLigne") == true then
			local model = modelFor(d)
			if model then
				local target = d:GetAttribute("Cible")
				local entry: Shooter = {
					id = d.Name,
					model = model,
					heavy = HEAVY[d:GetAttribute("Type") :: string] == true,
					target = if typeof(target) == "string" then target else nil,
				}
				byId[d.Name] = entry
				table.insert(if d:GetAttribute("Region") == regionId then defenders else attackers, entry)
			end
		end
	end
	local function byName(a: Shooter, b: Shooter): boolean
		return a.id < b.id
	end
	table.sort(attackers, byName)
	table.sort(defenders, byName)
	return attackers, defenders, byId
end

local function near(track: Track): boolean
	local camera = workspace.CurrentCamera
	return (track.anchor.Position - camera.CFrame.Position).Magnitude < EFFECT_DISTANCE
end

-- Un tick : tirs croisés étalés sur la durée du tick
local function volley(track: Track)
	if not near(track) then
		if track.stopSound then
			track.stopSound()
			track.stopSound = nil
		end
		return
	end
	if not track.stopSound then
		track.stopSound = Sfx.loop("Fusillade", track.anchor.Position)
	end
	local attackers, defenders, byId = engagedModels(track.folder)
	if #attackers == 0 or #defenders == 0 then
		return
	end
	local explosions = 0
	local perSide = CombatConfig.animatedShotsPerSide
	local function fire(shooters: { Shooter }, targets: { Shooter })
		for k = 1, math.min(perSide, #shooters) do
			-- les tireurs animés tournent d'un tick à l'autre : tous tirent tour à tour
			local shooter = shooters[(track.rotation + k - 1) % #shooters + 1]
			-- sa cible calculée par le serveur ; sinon (cible sans modèle) un ennemi au hasard
			local target = (shooter.target and byId[shooter.target]) or targets[math.random(#targets)]
			if target.model == shooter.model then
				continue
			end
			local explode = shooter.heavy and explosions < EXPLOSIONS_PER_TICK
			if explode then
				explosions += 1
			end
			task.delay(math.random() * CombatConfig.tickSeconds, shot, shooter.model, target.model, shooter.heavy, explode)
		end
	end
	fire(attackers, defenders)
	fire(defenders, attackers)
	track.rotation += perSide
end

-- ---- Suivi des batailles -------------------------------------------------------------------

local function message(folder: Instance)
	if not MatchState.isRunning() then
		return -- nouvelle partie : pas de message
	end
	local me = myCountry()
	local regionName = Regions[folder:GetAttribute("Region") :: string].name
	local state = folder:GetAttribute("Etat")
	if me == folder:GetAttribute("Attaquant") then
		if state == "Victoire" then
			Toast.show(`🏆 Victoire ! <b>{regionName}</b> est à toi.`, "success", "Victoire")
		elseif state == "Repli" then
			Toast.show(`↩️ L'attaque sur <b>{regionName}</b> a échoué : tes divisions restent sur place.`, "info")
		end
	elseif me == folder:GetAttribute("Defenseur") then
		if state == "Victoire" then
			Toast.show(`🚩 Tu as perdu <b>{regionName}</b>.`, "danger", "Defaite")
		elseif state == "Repli" then
			Toast.show(`🛡️ <b>{regionName}</b> a repoussé l'attaque !`, "success", "Victoire")
		end
	end
end

-- ---- Avions de soutien (AirSupport) : ils tournent au-dessus des batailles proches de la caméra --

local PLANE_RADIUS = 9
local PLANE_HEIGHT = 11
local PLANE_SPEED = 0.7 -- tours de cercle (radians par seconde)
local planeTemplate: Model? = nil

local function removePlanes(track: Track)
	for side, plane in track.planes do
		plane:Destroy()
		track.planes[side] = nil
	end
end

-- Camps qui ont des avions au-dessus de la bataille : supériorité aérienne ou appui au sol
local function airSides(folder: Instance): { [string]: boolean }
	local sides: { [string]: boolean } = {}
	local superiority = folder:GetAttribute("Superiorite")
	if folder:GetAttribute("AppuiAttaque") == true or superiority == "Attaquant" then
		sides.Attaquant = true
	end
	if folder:GetAttribute("AppuiDefense") == true or superiority == "Defenseur" then
		sides.Defenseur = true
	end
	return sides
end

local function updatePlanes(track: Track, dt: number)
	local template = planeTemplate
	if not template or track.ended or not near(track) then
		removePlanes(track)
		return
	end
	local sides = airSides(track.folder)
	for side, plane in track.planes do
		if not sides[side] then
			plane:Destroy()
			track.planes[side] = nil
		end
	end
	local center = track.anchor.Position
	local clock = os.clock()
	for side in sides do
		local plane = track.planes[side]
		if not plane then
			local model = template:Clone()
			local country = Countries[track.folder:GetAttribute(if side == "Attaquant" then "Attaquant" else "Defenseur") :: string]
			UnitPainter.paint(model, if country then country.color else Color3.fromRGB(150, 150, 150))
			for _, part in model:GetDescendants() do
				if part:IsA("BasePart") then
					part.Anchored = true
					part.CanCollide = false
					part.CanQuery = false
					part.CanTouch = false
					part.CastShadow = false
				end
			end
			local _, size = model:GetBoundingBox()
			model:ScaleTo(2.6 / math.max(size.X, size.Y, size.Z, 0.1))
			model.Parent = container
			track.planes[side] = model
			plane = model
		end
		-- en cercle, chaque camp à l'opposé de l'autre
		local angle = clock * PLANE_SPEED + (if side == "Attaquant" then 0 else math.pi)
		local position = center + Vector3.new(math.cos(angle) * PLANE_RADIUS, PLANE_HEIGHT, math.sin(angle) * PLANE_RADIUS)
		local ahead = center + Vector3.new(math.cos(angle + 0.1) * PLANE_RADIUS, PLANE_HEIGHT, math.sin(angle + 0.1) * PLANE_RADIUS)
		local flying = plane :: Model
		flying:PivotTo(CFrame.lookAt(position, ahead))
	end
end

local function untrack(folder: Instance)
	local track = tracks[folder]
	if track then
		removePlanes(track)
		if track.stopSound then
			track.stopSound()
		end
		track.gui:Destroy()
		track.anchor:Destroy()
		tracks[folder] = nil
	end
end

local function track(folder: Instance, fresh: boolean)
	if tracks[folder] or not container or not iconFolder or folder:GetAttribute("Genre") ~= "Terre" then
		return
	end
	-- brouillard de guerre : une bataille hors de vue ne s'affiche pas (sauf celles du joueur)
	local regionId = folder:GetAttribute("Region")
	if typeof(regionId) ~= "string" or not Regions[regionId] then
		return
	end
	if not Fog.isRegionVisible(regionId) and sideOf(folder) == nil then
		return
	end
	local anchor = Instance.new("Part")
	anchor.Name = folder.Name
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.2
	anchor.Position = iconPosition(folder) or Vector3.zero
	anchor.Parent = container
	local gui = Instance.new("BillboardGui")
	gui.Name = folder.Name
	gui.Adornee = anchor
	gui.Size = UDim2.fromOffset(ICON_SIZE + 8, ICON_SIZE + 12)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 2500
	gui.Active = true
	local button = Instance.new("TextButton")
	button.Name = "Icone"
	button.AutoButtonColor = true
	button.AnchorPoint = Vector2.new(0.5, 0)
	button.Position = UDim2.new(0.5, 0, 0, 0)
	button.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
	button.FontFace = Font.fromEnum(Enum.Font.BuilderSansBold)
	button.TextSize = 20
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Text = "⚔️"
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = button
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Thickness = 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = button
	button.Parent = gui
	local back = Instance.new("Frame")
	back.Name = "Barre"
	back.AnchorPoint = Vector2.new(0.5, 1)
	back.Position = UDim2.new(0.5, 0, 1, 0)
	back.Size = UDim2.fromOffset(ICON_SIZE + 4, 6)
	back.BorderSizePixel = 0
	local fill = Instance.new("Frame")
	fill.Name = "Attaque"
	fill.Size = UDim2.fromScale(0.5, 1)
	fill.BorderSizePixel = 0
	fill.Parent = back
	back.Parent = gui
	gui.Parent = iconFolder
	local t: Track = {
		folder = folder,
		anchor = anchor,
		gui = gui,
		button = button,
		fill = fill,
		back = back,
		stopSound = nil,
		ended = false,
		planes = {},
		rotation = 0,
	}
	tracks[folder] = t
	button.Activated:Connect(function()
		BattlePanel.open(folder)
	end)
	refreshIcon(t)
	-- une de ses régions vient d'être attaquée
	local me = myCountry()
	if fresh and me and me == folder:GetAttribute("Defenseur") and MatchState.isRunning() then
		Toast.show(`⚔️ <b>{Regions[regionId].name}</b> est attaquée par {FrenchNames.the(countryName(folder:GetAttribute("Attaquant")))} !`, "danger")
	end
	folder.AttributeChanged:Connect(function(attribute: string)
		if not tracks[folder] then
			return
		end
		refreshIcon(t)
		if attribute == "Tick" then
			volley(t)
		elseif attribute == "Etat" and folder:GetAttribute("Etat") ~= "EnCours" and not t.ended then
			t.ended = true
			if t.stopSound then
				t.stopSound()
				t.stopSound = nil
			end
			message(folder)
		end
	end)
end

function BattleRenderer.start(carte: Model)
	local folder = Instance.new("Folder")
	folder.Name = "BataillesTerre"
	folder.Parent = carte
	task.spawn(function()
		local modeles = ReplicatedStorage:WaitForChild("Modeles", 30)
		local avion = modeles and modeles:FindFirstChild("Avion")
		planeTemplate = if avion and avion:IsA("Model") then avion else nil
	end)
	RunService.RenderStepped:Connect(function(dt: number)
		for _, track in tracks do
			updatePlanes(track, dt)
		end
	end)
	container = folder
	local icons = Instance.new("Folder")
	icons.Name = "IconesBatailles"
	icons.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	iconFolder = icons

	local batailles = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Batailles")
	for _, battle in batailles:GetChildren() do
		task.spawn(track, battle, false)
	end
	batailles.ChildAdded:Connect(function(battle: Instance)
		task.wait() -- laisse arriver les attributs de la bataille
		track(battle, true)
	end)
	batailles.ChildRemoved:Connect(untrack)
	-- le brouillard se lève sur une région : ses batailles apparaissent
	Fog.onChanged(function()
		for _, battle in batailles:GetChildren() do
			track(battle, false)
		end
	end)
end

return BattleRenderer
