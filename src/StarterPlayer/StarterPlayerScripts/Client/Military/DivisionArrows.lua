--!strict
-- Flèches de trajet des divisions (comme Map/MoveArrows pour les escadrilles et les flottes) :
--   tes divisions et celles de tes alliés : tout le chemin, étape par étape ;
--   divisions ennemies qui marchent sur une de tes régions : l'étape en cours, en rouge ;
--   les autres ne sont pas dessinées (lisibilité et performance).
-- Purement visuel : le serveur ne connaît que le trajet (départ, destination, horaires, itinéraire).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local Client = script.Parent.Parent
local MilitaryState = require(script.Parent:WaitForChild("MilitaryState"))
local UnitRenderer = require(script.Parent:WaitForChild("UnitRenderer"))
local RegionView = require(Client:WaitForChild("Map"):WaitForChild("RegionView"))
local Fog = require(Client:WaitForChild("State"):WaitForChild("Fog"))

local HOSTILE = Color3.fromRGB(235, 70, 60)
local LIFT = Vector3.new(0, 0.9, 0)
local SAMPLES = 12

type Arrow = {
	from: Attachment,
	points: { Attachment },
	tip: Attachment,
	lines: { Beam },
	head: Beam,
	key: string,
}

local DivisionArrows = {}

local holder: BasePart? = nil
local arrows: { [Instance]: Arrow } = {}

local function anchorOf(regionId: string): Vector3?
	local region = Regions[regionId]
	local city = region and region.city
	return if city then MapProjection.toVector3(city.lon, city.lat, MapSettings.regionTop) else nil
end

local function myCountry(): string?
	local me = Players.LocalPlayer:GetAttribute("Pays")
	return if typeof(me) == "string" and me ~= "" then me else nil
end

-- Étapes à dessiner et couleur (nil : rien à dessiner)
local function plan(d: Instance): ({ string }?, Color3?, number?)
	if not MilitaryState.isMoving(d) then
		return nil, nil, nil
	end
	local me = myCountry()
	local owner = d:GetAttribute("Proprietaire") :: string
	local destination = d:GetAttribute("Destination") :: string
	local country = Countries[owner]
	local color = if country then country.color else Color3.new(1, 1, 1)
	if me and (owner == me or DiplomacyState.areAllies(me, owner)) then
		local steps = { destination }
		local raw = d:GetAttribute("Itineraire")
		if typeof(raw) == "string" and raw ~= "" then
			for _, regionId in string.split(raw, ",") do
				table.insert(steps, regionId)
			end
		end
		return steps, color, if owner == me then 0.9 else 0.6
	end
	if me and RegionView.getOwner(destination) == me and Fog.isArmyVisible(d) then
		return { destination }, HOSTILE, 1
	end
	return nil, nil, nil
end

local function attachment(name: string, position: Vector3): Attachment
	local a = Instance.new("Attachment")
	a.Name = name
	a.Position = position
	a.Parent = holder
	return a
end

local function beam(a0: Attachment, a1: Attachment, color: Color3, width: number, transparency: number): Beam
	local b = Instance.new("Beam")
	b.Attachment0 = a0
	b.Attachment1 = a1
	b.FaceCamera = true
	b.Segments = SAMPLES
	b.LightEmission = 0.4
	b.LightInfluence = 0
	b.Color = ColorSequence.new(color)
	b.Width0 = width
	b.Width1 = width
	b.Transparency = NumberSequence.new(transparency)
	b.Parent = a0
	return b
end

local function remove(d: Instance)
	local arrow = arrows[d]
	if arrow then
		arrow.from:Destroy()
		for _, a in arrow.points do
			a:Destroy()
		end
		arrow.tip:Destroy()
		arrows[d] = nil
	end
end

local function refresh(d: Instance, removed: boolean)
	local steps, color, width = nil, nil, nil
	if not removed then
		steps, color, width = plan(d)
	end
	if not steps or not color or not width or not holder then
		remove(d)
		return
	end
	local key = `{d:GetAttribute("Depart")}|{table.concat(steps, ",")}|{color:ToHex()}`
	local existing = arrows[d]
	if existing and existing.key == key then
		return
	end
	remove(d)
	local start = UnitRenderer.positionOf(d)
	if not start then
		return
	end
	local positions = {}
	for _, regionId in steps do
		local p = anchorOf(regionId)
		if p then
			table.insert(positions, p + LIFT)
		end
	end
	if #positions == 0 then
		return
	end
	local tip = positions[#positions]
	local before = if #positions >= 2 then positions[#positions - 1] else start + LIFT
	local flat = Vector3.new(tip.X - before.X, 0, tip.Z - before.Z)
	local direction = if flat.Magnitude > 0.01 then flat.Unit else Vector3.zAxis
	local headLength = math.clamp(flat.Magnitude * 0.2, 1.5, 4)
	local from = attachment("Depart", start + LIFT)
	local points = {}
	for i = 1, #positions - 1 do
		table.insert(points, attachment("Etape" .. i, positions[i]))
	end
	table.insert(points, attachment("Pointe", tip - direction * headLength))
	local tipAttachment = attachment("Bout", tip)
	local lines = {}
	local previous = from
	for _, a in points do
		table.insert(lines, beam(previous, a, color, width, 0.3))
		previous = a
	end
	arrows[d] = {
		from = from,
		points = points,
		tip = tipAttachment,
		lines = lines,
		head = beam(points[#points], tipAttachment, color, width * 3, 0.15),
		key = key,
	}
	arrows[d].head.Width1 = 0.05
end

function DivisionArrows.start(carte: Model)
	local part = Instance.new("Part")
	part.Name = "SupportFlechesDivisions"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.CFrame = CFrame.identity
	part.Parent = carte
	holder = part

	MilitaryState.onChanged(refresh)
	for _, d in MilitaryState.list() do
		refresh(d, false)
	end
	Fog.onChanged(function()
		for _, d in MilitaryState.list() do
			refresh(d, false)
		end
	end)
	-- le départ du trait suit la division
	RunService.RenderStepped:Connect(function()
		for d, arrow in arrows do
			local position = UnitRenderer.positionOf(d)
			if position then
				arrow.from.Position = position + LIFT
			end
		end
	end)
end

return DivisionArrows
