--!strict
-- Sélection des divisions (SYSTEME_MILITAIRE.md, 6.1 à 6.4), côté joueur :
--   PC : clic gauche (une division), Shift + clic (ajouter / retirer), clic gauche maintenu et
--     glissé (rectangle de sélection), double-clic (toutes ses divisions de la région), Échap ou
--     clic dans le vide (plus de sélection), Ctrl + 1…9 (enregistrer un groupe), 1…9 (le rappeler) ;
--   mobile : appui court ; bouton « Sélection multiple » du panneau (les appuis ajoutent ou retirent) ;
--   de loin : toucher l'étiquette d'une région sélectionne ses divisions ;
--   retour visuel : cercle lumineux au sol sous chaque division sélectionnée (le panneau en bas de
--     l'écran est dans SelectionPanel).
-- Seules ses propres divisions se sélectionnent ; le serveur revérifie tout à chaque ordre.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local MilitaryState = require(script.Parent:WaitForChild("MilitaryState"))
local UnitRenderer = require(script.Parent:WaitForChild("UnitRenderer"))

local DRAG_THRESHOLD = 8 -- pixels avant qu'un clic devienne un rectangle (comme la caméra)
local DOUBLE_CLICK = 0.35 -- secondes entre les deux clics d'un double-clic
local CIRCLE_COLOR = Color3.fromRGB(255, 220, 90)

type Listener = (selected: { Instance }) -> ()

export type Options = {
	myCountry: () -> string?, -- pays dirigé (nil hors partie)
	enabled: () -> boolean, -- faux hors partie (écran titre, choix du pays)
}

local Selection = {}

local options: Options? = nil
local selected: { Instance } = {}
local listeners: { Listener } = {}
local multi = false -- mode « sélection multiple » (mobile)
local groups: { [number]: { string } } = {}
local lastClickId = ""
local lastClickTime = 0
local dragStart: Vector2? = nil
local rectangle: Frame? = nil
local circles: { [Instance]: BasePart } = {}
local circleFolder: Folder? = nil

local function mine(d: Instance): boolean
	local o = options
	return o ~= nil and d.Parent ~= nil and d:GetAttribute("Proprietaire") == o.myCountry()
end

local function notify()
	for _, listener in listeners do
		task.spawn(listener, table.clone(selected))
	end
end

local function removeCircle(d: Instance)
	local circle = circles[d]
	if circle then
		circle:Destroy()
		circles[d] = nil
	end
end

-- Divisions sélectionnées (encore existantes et à soi)
function Selection.get(): { Instance }
	local list = {}
	for _, d in selected do
		if mine(d) then
			table.insert(list, d)
		end
	end
	return list
end

function Selection.ids(): { string }
	local ids = {}
	for _, d in Selection.get() do
		table.insert(ids, d.Name)
	end
	return ids
end

function Selection.set(list: { Instance })
	for d in circles do
		if not table.find(list, d) then
			removeCircle(d)
		end
	end
	selected = {}
	for _, d in list do
		if mine(d) and not table.find(selected, d) then
			table.insert(selected, d)
		end
	end
	notify()
end

function Selection.clear()
	if #selected == 0 then
		return
	end
	Selection.set({})
end

function Selection.toggle(d: Instance)
	local list = table.clone(selected)
	local i = table.find(list, d)
	if i then
		table.remove(list, i)
	else
		table.insert(list, d)
	end
	Selection.set(list)
end

function Selection.remove(d: Instance)
	local list = table.clone(selected)
	local i = table.find(list, d)
	if i then
		table.remove(list, i)
		Selection.set(list)
	end
end

-- Toutes ses divisions d'une région
function Selection.selectRegion(regionId: string, add: boolean?)
	local list = if add then table.clone(selected) else {}
	for _, d in MilitaryState.inRegion(regionId) do
		if mine(d) and not table.find(list, d) then
			table.insert(list, d)
		end
	end
	Selection.set(list)
end

function Selection.isMulti(): boolean
	return multi
end

function Selection.setMulti(value: boolean)
	multi = value
	notify()
end

function Selection.onChanged(listener: Listener): () -> ()
	table.insert(listeners, listener)
	return function()
		local i = table.find(listeners, listener)
		if i then
			table.remove(listeners, i)
		end
	end
end

local function shiftDown(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

-- Clic ou appui sur la carte (appelé avant la sélection des régions) : vrai s'il est utilisé ici.
-- Un clic sur une de ses divisions la sélectionne ; un clic ailleurs vide la sélection (et laisse
-- la région s'ouvrir), sauf en sélection multiple.
function Selection.handleTap(screenPos: Vector2): boolean
	local o = options
	if not o or not o.enabled() then
		return false
	end
	local id = UnitRenderer.hitTest(screenPos)
	local d = if id then MilitaryState.get(id) else nil
	if d and mine(d) then
		local now = os.clock()
		if id == lastClickId and now - lastClickTime < DOUBLE_CLICK then
			-- double-clic : toute la région
			Selection.selectRegion(d:GetAttribute("Region") :: string, shiftDown() or multi)
			lastClickId = ""
		else
			lastClickId = id :: string
			lastClickTime = now
			if shiftDown() or multi then
				Selection.toggle(d)
			else
				Selection.set({ d })
			end
		end
		return true
	end
	-- sur mobile, toucher une région avec une sélection prépare un ordre (OrderInput)
	local touch = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
	if #selected > 0 and not multi and not touch then
		Selection.clear()
	end
	return false
end

-- Rectangle de sélection (PC) : ses divisions dont la position à l'écran est dans le rectangle
local function selectInRectangle(a: Vector2, b: Vector2, add: boolean)
	local o = options
	if not o then
		return
	end
	local minX, maxX = math.min(a.X, b.X), math.max(a.X, b.X)
	local minY, maxY = math.min(a.Y, b.Y), math.max(a.Y, b.Y)
	local camera = workspace.CurrentCamera
	local list = if add then table.clone(selected) else {}
	for _, d in MilitaryState.ofCountry(o.myCountry() or "") do
		local position = UnitRenderer.positionOf(d)
		if position then
			local screen, visible = camera:WorldToScreenPoint(position)
			if visible and screen.X >= minX and screen.X <= maxX and screen.Y >= minY and screen.Y <= maxY
				and not table.find(list, d) then
				table.insert(list, d)
			end
		end
	end
	Selection.set(list)
end

local function buildRectangle()
	local gui = Instance.new("ScreenGui")
	gui.Name = "RectangleSelection"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 3
	local frame = Instance.new("Frame")
	frame.Name = "Rectangle"
	frame.BackgroundColor3 = CIRCLE_COLOR
	frame.BackgroundTransparency = 0.85
	frame.BorderSizePixel = 0
	frame.Visible = false
	local stroke = Instance.new("UIStroke")
	stroke.Color = CIRCLE_COLOR
	stroke.Thickness = 1.5
	stroke.Parent = frame
	frame.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	rectangle = frame
end

local function updateRectangle(a: Vector2, b: Vector2)
	local frame = rectangle
	if not frame then
		return
	end
	frame.Position = UDim2.fromOffset(math.min(a.X, b.X), math.min(a.Y, b.Y))
	frame.Size = UDim2.fromOffset(math.abs(a.X - b.X), math.abs(a.Y - b.Y))
	frame.Visible = true
end

-- Cercles lumineux au sol sous les divisions sélectionnées (seulement si leur modèle est affiché)
local function updateCircles()
	for d in circles do
		if not table.find(selected, d) then
			removeCircle(d)
		end
	end
	for _, d in selected do
		local model = UnitRenderer.modelOf(d)
		local circle = circles[d]
		if not model then
			if circle then
				circle.Transparency = 1
			end
			continue
		end
		if not circle then
			local part = Instance.new("Part")
			part.Name = "CercleSelection"
			part.Shape = Enum.PartType.Cylinder
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			part.Material = Enum.Material.Neon
			part.Color = CIRCLE_COLOR
			part.Size = Vector3.new(0.1, 3.4, 3.4)
			part.Parent = circleFolder
			circles[d] = part
			circle = part
		end
		local box, size = model:GetBoundingBox()
		local c = circle :: BasePart
		c.Transparency = 0.35
		c.CFrame = CFrame.new(box.Position.X, box.Position.Y - size.Y / 2 + 0.06, box.Position.Z) * CFrame.Angles(0, 0, math.rad(90))
	end
end

function Selection.start(opts: Options)
	options = opts
	local folder = Instance.new("Folder")
	folder.Name = "CerclesSelection"
	folder.Parent = workspace
	circleFolder = folder
	buildRectangle()

	-- rectangle au clic gauche maintenu (PC)
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not opts.enabled() then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 and not processed then
			dragStart = Vector2.new(input.Position.X, input.Position.Y)
		elseif input.UserInputType == Enum.UserInputType.Keyboard and not processed and not UserInputService:GetFocusedTextBox() then
			local key = input.KeyCode
			if key == Enum.KeyCode.Escape then
				Selection.clear()
				return
			end
			local digit = key.Value - Enum.KeyCode.Zero.Value
			if digit >= 1 and digit <= 9 then
				local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
				if ctrl then
					groups[digit] = Selection.ids() -- Ctrl + chiffre : enregistrer le groupe
				elseif groups[digit] then
					local list = {}
					for _, id in groups[digit] do
						local d = MilitaryState.get(id)
						if d then
							table.insert(list, d)
						end
					end
					Selection.set(list)
				end
			end
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		local start = dragStart
		if start and input.UserInputType == Enum.UserInputType.MouseMovement then
			local pos = Vector2.new(input.Position.X, input.Position.Y)
			if (pos - start).Magnitude > DRAG_THRESHOLD then
				updateRectangle(start, pos)
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		local start = dragStart
		dragStart = nil
		local frame = rectangle
		if start and frame and frame.Visible then
			frame.Visible = false
			selectInRectangle(start, Vector2.new(input.Position.X, input.Position.Y), shiftDown())
		end
	end)

	-- une division sélectionnée disparaît : elle quitte la sélection
	MilitaryState.onChanged(function(d: Instance, removed: boolean)
		if removed and table.find(selected, d) then
			Selection.remove(d)
		end
	end)
	-- toucher l'étiquette d'une région (vue de loin) : ses divisions
	UnitRenderer.onLabelClicked(function(regionId: string)
		if opts.enabled() then
			Selection.selectRegion(regionId, shiftDown() or multi)
		end
	end)
	RunService.RenderStepped:Connect(updateCircles)
end

return Selection
