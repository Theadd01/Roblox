--!strict
-- Caméra de la carte : vue du dessus inclinée.
--   Souris : clic gauche + glisser pour se déplacer, molette pour zoomer vers le curseur.
--     En partie (setLeftDragPans(false)), le clic gauche glissé sert au rectangle de sélection des
--     divisions (Military/Selection) : on se déplace alors au clic droit ou au clic molette glissé.
--     Un clic droit sans glisser compte comme un « tap droit » (ordre aux divisions, voir onRightTap).
--   Tactile : un doigt pour se déplacer, deux doigts (pincer) pour zoomer.
--   Clavier (facultatif) : ZQSD / WASD / flèches pour se déplacer, E / R ou + / - pour zoomer.
-- Un appui relâché sans avoir glissé compte comme un « tap » (voir onTap).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local MapGeometry = require(Config:WaitForChild("MapGeometry")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any

local S = MapSettings.camera
local GROUND_Y = MapSettings.regionTop -- plan utilisé pour « attraper » la carte
local DRAG_THRESHOLD = 8 -- pixels à parcourir avant que l'appui devienne un glissement
local KEY_SPEED = 1.2 -- vitesse du clavier (en distances de caméra par seconde)

type TapListener = (screenPos: Vector2) -> ()

local CameraController = {}

local focus = Vector3.zero -- point visé (cible)
local distance: number = S.startDistance -- distance visée (cible)
local currentFocus = Vector3.zero -- valeurs lissées réellement affichées
local currentDistance: number = S.startDistance

local pressInput: InputObject? = nil
local pressPos: Vector2? = nil
local grabPoint: Vector3? = nil
local dragging = false
local touchCount = 0
local pinchStartDistance: number? = nil
local pinchAnchor: Vector3? = nil
local tapListeners: { TapListener } = {}
local rightTapListeners: { TapListener } = {}
local leftDragPans = true -- faux en partie : le clic gauche glissé dessine le rectangle de sélection
local wheelPassThrough: ((Vector2) -> boolean)? = nil -- interfaces que la molette traverse (étiquettes de la carte)
local inputEnabled = true -- faux pendant l'écran titre
local attract = false -- survol automatique du monde (fond de l'écran titre)
local attractTime = 0

local function pitchFor(d: number): number
	local t = math.clamp((d - S.minDistance) / (S.maxDistance - S.minDistance), 0, 1)
	return math.rad(S.pitchNear + (S.pitchFar - S.pitchNear) * t)
end

-- La caméra se place au sud du point visé et regarde vers le nord
local function cameraCFrame(f: Vector3, d: number): CFrame
	local pitch = pitchFor(d)
	local offset = Vector3.new(0, math.sin(pitch) * d, math.cos(pitch) * d)
	return CFrame.lookAt(f + offset, f)
end

local function clampFocus(f: Vector3): Vector3
	local b = MapGeometry.bounds
	return Vector3.new(math.clamp(f.X, b.minX, b.maxX), GROUND_Y, math.clamp(f.Z, b.minZ, b.maxZ))
end

local function applyNow()
	workspace.CurrentCamera.CFrame = cameraCFrame(currentFocus, currentDistance)
end

-- Point de la carte situé sous une position à l'écran
local function groundPoint(screenPos: Vector2): Vector3?
	local ray = workspace.CurrentCamera:ScreenPointToRay(screenPos.X, screenPos.Y)
	if math.abs(ray.Direction.Y) < 1e-4 then
		return nil
	end
	local t = (GROUND_Y - ray.Origin.Y) / ray.Direction.Y
	if t < 0 then
		return nil
	end
	return ray.Origin + ray.Direction * t
end

-- Zoom en gardant le point sous le curseur au même endroit
local function zoomTo(newDistance: number, anchor: Vector3?)
	newDistance = math.clamp(newDistance, S.minDistance, S.maxDistance)
	if anchor then
		focus = anchor + (focus - anchor) * (newDistance / distance)
	end
	distance = newDistance
	focus = clampFocus(focus)
end

local function endPress()
	pressInput = nil
	pressPos = nil
	grabPoint = nil
	dragging = false
end

local function onInputBegan(input: InputObject, processed: boolean)
	if processed or not inputEnabled then
		return
	end
	local kind = input.UserInputType
	local mouse = kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.MouseButton2
		or kind == Enum.UserInputType.MouseButton3
	if not mouse and kind ~= Enum.UserInputType.Touch then
		return
	end
	if mouse and pressInput and pressInput.UserInputType ~= kind then
		return -- un autre bouton est déjà enfoncé
	end
	if kind == Enum.UserInputType.Touch then
		touchCount += 1
		if touchCount > 1 then
			-- deuxième doigt : c'est un pincement, pas un glissement ni un tap
			endPress()
			return
		end
	end
	pressInput = input
	pressPos = Vector2.new(input.Position.X, input.Position.Y)
	grabPoint = groundPoint(pressPos :: Vector2)
	dragging = false
end

local function onInputChanged(input: InputObject, processed: boolean)
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		local through = processed and wheelPassThrough ~= nil and wheelPassThrough(pos)
		if (not processed or through) and inputEnabled then
			zoomTo(distance * (1 - S.zoomStep * input.Position.Z), groundPoint(pos))
		end
		return
	end

	local press = pressInput
	if not press or not pressPos then
		return
	end
	local pressKind = press.UserInputType
	local isMouseDrag = (pressKind == Enum.UserInputType.MouseButton1 or pressKind == Enum.UserInputType.MouseButton2
		or pressKind == Enum.UserInputType.MouseButton3) and input.UserInputType == Enum.UserInputType.MouseMovement
	local isTouchDrag = input == press
	if not (isMouseDrag or isTouchDrag) then
		return
	end

	local pos = Vector2.new(input.Position.X, input.Position.Y)
	if not dragging and (pos - (pressPos :: Vector2)).Magnitude > DRAG_THRESHOLD then
		dragging = true
	end
	-- en partie, le clic gauche glissé ne déplace pas la caméra (rectangle de sélection)
	local pans = pressKind ~= Enum.UserInputType.MouseButton1 or leftDragPans
	if dragging and grabPoint and pans then
		local p = groundPoint(pos)
		if p then
			-- on déplace la caméra pour que le point attrapé reste sous le doigt
			focus = clampFocus(focus + ((grabPoint :: Vector3) - p))
			currentFocus = focus
			applyNow()
		end
	end
end

local function onInputEnded(input: InputObject, _processed: boolean)
	if input.UserInputType == Enum.UserInputType.Touch then
		touchCount = math.max(0, touchCount - 1)
	end
	local press = pressInput
	if not press then
		return
	end
	-- souris : relâcher le même bouton ; tactile : le même doigt
	local isEnd = input == press
		or (press.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType == press.UserInputType)
	if not isEnd then
		return
	end
	local tapPos = pressPos
	local wasDrag = dragging
	local right = press.UserInputType == Enum.UserInputType.MouseButton2
	local middle = press.UserInputType == Enum.UserInputType.MouseButton3
	endPress()
	if not wasDrag and tapPos and not middle then
		for _, listener in (if right then rightTapListeners else tapListeners) do
			task.spawn(listener, tapPos)
		end
	end
end

local function onPinch(positions: { Vector2 }, scale: number, _velocity: number, state: Enum.UserInputState, processed: boolean)
	if not inputEnabled then
		return
	end
	if processed and state == Enum.UserInputState.Begin then
		return
	end
	if state == Enum.UserInputState.Begin then
		pinchStartDistance = distance
		pinchAnchor = if #positions >= 2 then groundPoint((positions[1] + positions[2]) / 2) else nil
	elseif state == Enum.UserInputState.Change and pinchStartDistance then
		zoomTo((pinchStartDistance :: number) / math.max(scale, 0.01), pinchAnchor)
	else
		pinchStartDistance = nil
		pinchAnchor = nil
	end
end

local function keyboardMove(dt: number)
	if not inputEnabled or UserInputService:GetFocusedTextBox() then
		return -- commandes coupées, ou le joueur écrit dans le chat
	end
	local function down(...: Enum.KeyCode): boolean
		for _, key in { ... } do
			if UserInputService:IsKeyDown(key) then
				return true
			end
		end
		return false
	end
	local K = Enum.KeyCode
	local move = Vector3.zero
	if down(K.W, K.Z, K.Up) then
		move -= Vector3.zAxis
	end
	if down(K.S, K.Down) then
		move += Vector3.zAxis
	end
	if down(K.D, K.Right) then
		move += Vector3.xAxis
	end
	if down(K.A, K.Q, K.Left) then
		move -= Vector3.xAxis
	end
	if move.Magnitude > 0 then
		focus = clampFocus(focus + move.Unit * distance * KEY_SPEED * dt)
	end
	if down(K.E, K.Equals, K.KeypadPlus) then
		zoomTo(distance * (1 - 1.5 * dt), nil)
	elseif down(K.R, K.Minus, K.KeypadMinus) then
		zoomTo(distance * (1 + 1.5 * dt), nil)
	end
end

local function onRenderStep(dt: number)
	local camera = workspace.CurrentCamera
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	keyboardMove(dt)
	if attract then
		-- lente dérive au-dessus du monde
		attractTime += dt
		local b = MapGeometry.bounds
		focus = clampFocus(Vector3.new(b.maxX * 0.6 * math.sin(attractTime * 0.035), 0, b.maxZ * 0.35 * math.sin(attractTime * 0.05 + 1)))
	end
	local alpha = 1 - math.exp(-S.smoothing * dt)
	currentDistance += (distance - currentDistance) * alpha
	if not dragging then
		currentFocus = currentFocus:Lerp(focus, alpha)
	end
	applyNow()
end

function CameraController.start()
	focus = clampFocus(MapProjection.toVector3(S.startFocus.lon, S.startFocus.lat, GROUND_Y))
	currentFocus = focus
	distance = S.startDistance
	currentDistance = distance

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputChanged:Connect(onInputChanged)
	UserInputService.InputEnded:Connect(onInputEnded)
	UserInputService.TouchPinch:Connect(onPinch)
	RunService:BindToRenderStep("CameraCarte", Enum.RenderPriority.Camera.Value + 1, onRenderStep)
end

-- Active ou coupe les commandes du joueur (souris, tactile, clavier)
function CameraController.setInputEnabled(enabled: boolean)
	inputEnabled = enabled
	if not enabled then
		endPress()
	end
end

-- Survol automatique du monde, utilisé en fond de l'écran titre
function CameraController.setAttract(enabled: boolean)
	attract = enabled
	if enabled then
		distance = S.attractDistance
	end
end

-- Centre la caméra (en douceur) sur une position, avec éventuellement une nouvelle distance
function CameraController.focusOn(position: Vector3, newDistance: number?)
	focus = clampFocus(position)
	if newDistance then
		distance = math.clamp(newDistance, S.minDistance, S.maxDistance)
	end
end

-- Appelé quand le joueur clique / touche l'écran sans glisser
-- La molette zoome aussi au-dessus des interfaces pour lesquelles `fn(position)` est vrai
-- (étiquettes posées sur la carte)
function CameraController.setWheelPassThrough(fn: (Vector2) -> boolean)
	wheelPassThrough = fn
end

-- Clic droit sans glisser (ordres aux divisions sélectionnées)
function CameraController.onRightTap(listener: TapListener)
	table.insert(rightTapListeners, listener)
end

-- En partie : faux, le clic gauche glissé sert au rectangle de sélection (et non à déplacer la caméra)
function CameraController.setLeftDragPans(enabled: boolean)
	leftDragPans = enabled
end

-- Un appui gauche en cours a-t-il glissé (rectangle de sélection, pas un clic) ?
function CameraController.isDragging(): boolean
	return dragging
end

function CameraController.onTap(listener: TapListener)
	table.insert(tapListeners, listener)
end

return CameraController
