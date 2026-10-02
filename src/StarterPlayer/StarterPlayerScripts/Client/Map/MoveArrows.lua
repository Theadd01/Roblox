--!strict
-- Flèches de déplacement : chaque force en route trace un trait jusqu'à sa destination, avec une
-- pointe et des pulsations lumineuses qui avancent (on voit d'un coup d'œil qui marche sur qui).
--   tes forces : à ta couleur ; forces qui marchent sur tes régions : rouge vif ;
--   alliés : à leur couleur ; les autres : à leur couleur, plus fines et plus transparentes.
-- Une armée envoyée loin (itinéraire de région en région) montre tout son chemin, étape par étape,
-- pour toi et tes alliés ; d'une force étrangère, on ne voit que l'étape en cours. Pendant une
-- bataille en chemin, la suite de la route reste affichée.
-- Purement visuel : le serveur ne connaît que le trajet (départ, destination, horaires, itinéraire).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Countries = require(Shared:WaitForChild("Config"):WaitForChild("Countries")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local ArmyState = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("ArmyState"))
local ArmyView = require(script.Parent:WaitForChild("ArmyView"))
local RegionView = require(script.Parent:WaitForChild("RegionView"))
local Fog = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("Fog"))

local HOSTILE = Color3.fromRGB(235, 70, 60)
local LIFT = Vector3.new(0, 0.8, 0) -- au-dessus du sol, sinon le trait se perd dans les plaques
local PULSES = 2 -- pulsations visibles le long d'un trait
local PULSE_SPEED = 0.6 -- tours par seconde
local SAMPLES = 18 -- points de la courbe de transparence (20 au plus pour un Beam)
local PULSE_INTERVAL = 1 / 20
local STYLE_INTERVAL = 1 -- secondes entre deux mises à jour des couleurs (guerres, alliances)

type Style = { color: Color3, width: number, base: number } -- base : transparence du trait
type Arrow = {
	from: Attachment, -- suit la force
	points: { Attachment }, -- étapes (la dernière est la base de la pointe)
	tip: Attachment,
	lines: { Beam },
	head: Beam,
	key: string, -- trajet dessiné (on redessine quand il change)
	base: number,
}

local MoveArrows = {}

local holder: BasePart? = nil
local arrows: { [Instance]: Arrow } = {}

local function myCountry(): string?
	local me = Players.LocalPlayer:GetAttribute("Pays")
	return if typeof(me) == "string" and me ~= "" then me else nil
end

-- Tout le chemin est-il visible pour ce joueur (sa force, ou celle d'un allié) ?
local function showsWholePath(army: Instance): boolean
	local me = myCountry()
	local owner = army:GetAttribute("Proprietaire")
	return me ~= nil and typeof(owner) == "string" and (owner == me or DiplomacyState.areAllies(me, owner))
end

-- Régions à relier, dans l'ordre (vide : rien à dessiner)
local function stepsOf(army: Instance): { string }
	local steps = {}
	if ArmyState.isMoving(army) then
		table.insert(steps, army:GetAttribute("Destination") :: string)
	end
	if showsWholePath(army) then
		for _, regionId in ArmyState.itinerary(army) do
			table.insert(steps, regionId)
		end
	end
	return steps
end

local function styleOf(army: Instance): Style
	local me = myCountry()
	local owner = army:GetAttribute("Proprietaire")
	local country = Countries[owner]
	local color = if country then country.color else Color3.new(1, 1, 1)
	if not me then
		return { color = color, width = 0.7, base = 0.45 } -- écran titre, choix du pays
	end
	if owner == me then
		return { color = color, width = 1.1, base = 0.1 }
	end
	local allied = typeof(owner) == "string" and DiplomacyState.areAllies(me, owner)
	local destination = army:GetAttribute("Destination")
	if not allied and typeof(destination) == "string" and RegionView.getOwner(destination) == me then
		return { color = HOSTILE, width = 1.2, base = 0.05 }
	end
	if allied then
		return { color = color, width = 0.9, base = 0.25 }
	end
	return { color = color, width = 0.6, base = 0.5 }
end

local function attachment(name: string, position: Vector3): Attachment
	local a = Instance.new("Attachment")
	a.Name = name
	a.Position = position -- le support est à l'origine du monde
	a.Parent = holder
	return a
end

local function beam(name: string, a0: Attachment, a1: Attachment): Beam
	local b = Instance.new("Beam")
	b.Name = name
	b.Attachment0 = a0
	b.Attachment1 = a1
	b.FaceCamera = true
	b.Segments = SAMPLES
	b.LightEmission = 0.5
	b.LightInfluence = 0
	b.Parent = a0
	return b
end

local function applyStyle(arrow: Arrow, style: Style)
	local color = ColorSequence.new(style.color)
	for i, line in arrow.lines do
		line.Color = color
		-- les étapes suivantes sont un peu plus fines : on lit le sens de la marche
		local width = style.width * (if i == 1 then 1 else 0.8)
		line.Width0 = width * 0.8
		line.Width1 = width
	end
	arrow.head.Color = color
	arrow.head.Width0 = style.width * 3.2
	arrow.head.Width1 = 0.05
	arrow.head.Transparency = NumberSequence.new(style.base * 0.6)
	arrow.base = style.base
end

local function remove(army: Instance)
	local arrow = arrows[army]
	if arrow then
		arrow.from:Destroy()
		for _, a in arrow.points do
			a:Destroy()
		end
		arrow.tip:Destroy()
		arrows[army] = nil
	end
end

local function keyOf(army: Instance, steps: { string }): string
	return `{army:GetAttribute("Depart")}|{table.concat(steps, ",")}`
end

local function create(army: Instance, steps: { string })
	local start = ArmyView.positionOf(army.Name)
	if not start or not holder or #steps == 0 then
		return
	end
	local kind = ArmyState.kind(army)
	local positions = {}
	for _, regionId in steps do
		local p = ArmyView.pointOf(regionId, kind)
		if p then
			table.insert(positions, p + LIFT)
		end
	end
	if #positions == 0 then
		return
	end
	-- la pointe se pose sur la dernière étape ; le trait s'arrête à sa base
	local tip = positions[#positions]
	local before = if #positions >= 2 then positions[#positions - 1] else start + LIFT
	local flat = Vector3.new(tip.X - before.X, 0, tip.Z - before.Z)
	local direction = if flat.Magnitude > 0.01 then flat.Unit else Vector3.zAxis
	local headLength = math.clamp(flat.Magnitude * 0.25, 2.5, 6)
	local from = attachment("Depart", start + LIFT)
	local points = {}
	for i = 1, #positions - 1 do
		table.insert(points, attachment("Etape" .. i, positions[i]))
	end
	table.insert(points, attachment("Pointe", tip - direction * headLength))
	local tipAttachment = attachment("Bout", tip)
	local lines = {}
	local previous = from
	for i, a in points do
		table.insert(lines, beam("Trait" .. i, previous, a))
		previous = a
	end
	local arrow: Arrow = {
		from = from,
		points = points,
		tip = tipAttachment,
		lines = lines,
		head = beam("Pointe", points[#points], tipAttachment),
		key = keyOf(army, steps),
		base = 0.5,
	}
	applyStyle(arrow, styleOf(army))
	arrows[army] = arrow
end

local function refresh(army: Instance, removed: boolean)
	local steps = if removed then {} else stepsOf(army)
	if #steps == 0 or not Fog.isArmyVisible(army) then
		remove(army)
		return
	end
	-- nouvel ordre (autre destination, nouveau départ, autre itinéraire) : on redessine
	local arrow = arrows[army]
	if arrow and arrow.key ~= keyOf(army, steps) then
		remove(army)
		arrow = nil
	end
	if not arrow then
		create(army, steps)
	end
end

-- Transparence le long d'un trait : plus pâle vers le départ, avec des pulsations qui avancent
local function pulseSequence(base: number, phase: number): NumberSequence
	local points = {}
	for i = 0, SAMPLES - 1 do
		local t = i / (SAMPLES - 1)
		local ramp = base + (1 - base) * 0.6 * (1 - t)
		local wave = math.max(0, math.cos(2 * math.pi * (PULSES * t - phase)))
		table.insert(points, NumberSequenceKeypoint.new(t, math.clamp(ramp * (1 - 0.75 * wave * wave), 0, 1)))
	end
	return NumberSequence.new(points)
end

function MoveArrows.start(carte: Model)
	local part = Instance.new("Part")
	part.Name = "SupportFleches"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.CFrame = CFrame.identity
	part.Parent = carte
	holder = part

	ArmyState.onChanged(refresh)
	local function refreshAll()
		for _, army in ArmyState.list() do
			refresh(army, false)
		end
	end
	refreshAll()
	Fog.onChanged(refreshAll) -- brouillard : ce qu'on voit change

	local pulseClock, styleClock = 0, 0
	RunService.RenderStepped:Connect(function(dt: number)
		-- le départ du trait suit la force en route
		for army, arrow in arrows do
			local position = ArmyView.positionOf(army.Name)
			if position then
				arrow.from.Position = position + LIFT
			end
		end
		styleClock += dt
		if styleClock >= STYLE_INTERVAL then
			styleClock = 0
			for army, arrow in arrows do
				applyStyle(arrow, styleOf(army))
			end
		end
		pulseClock += dt
		if pulseClock >= PULSE_INTERVAL then
			pulseClock = 0
			-- une seule courbe par transparence de base (toutes les flèches pulsent ensemble)
			local phase = (os.clock() * PULSE_SPEED) % 1
			local cache: { [number]: NumberSequence } = {}
			for _, arrow in arrows do
				local sequence = cache[arrow.base]
				if not sequence then
					sequence = pulseSequence(arrow.base, phase)
					cache[arrow.base] = sequence
				end
				for _, line in arrow.lines do
					line.Transparency = sequence
				end
			end
		end
	end)
end

return MoveArrows
