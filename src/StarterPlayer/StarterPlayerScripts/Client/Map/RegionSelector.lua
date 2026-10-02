--!strict
-- Sélection des régions : surbrillance au survol (souris) et sélection au clic / toucher.
-- Mode « pays » (écran de choix du pays) : la sélection met en valeur toutes les régions du pays
-- de la région cliquée (un pays en compte plusieurs).

local UserInputService = game:GetService("UserInputService")

local CameraController = require(script.Parent:WaitForChild("CameraController"))

type SelectListener = (regionId: string?) -> ()

local RegionSelector = {}

local regionsFolder: Instance? = nil
local hoverHighlight: Highlight? = nil
local selectHighlight: Highlight? = nil
local selected: string? = nil
local onSelect: SelectListener? = nil
local enabled = true
local interceptor: ((Vector2) -> boolean)? = nil -- ex. clic sur un général : prioritaire sur la région
local countryOwner: ((regionId: string) -> string?)? = nil -- mode « pays » : propriétaire d'une région
local countryHighlights: { Highlight } = {} -- régions du pays sélectionné (mode « pays »)

local function newHighlight(name: string, fill: number, outline: Color3, parent: Instance): Highlight
	local h = Instance.new("Highlight")
	h.Name = name
	h.FillColor = Color3.new(1, 1, 1)
	h.FillTransparency = fill
	h.OutlineColor = outline
	h.OutlineTransparency = 0
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Enabled = false
	h.Parent = parent
	return h
end

local function clearCountry()
	for _, h in countryHighlights do
		h:Destroy()
	end
	table.clear(countryHighlights)
end

-- Région située sous une position à l'écran (ou nil)
local function regionAt(screenPos: Vector2): Model?
	if not regionsFolder then
		return nil
	end
	local ray = workspace.CurrentCamera:ScreenPointToRay(screenPos.X, screenPos.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { regionsFolder }
	local result = workspace:Raycast(ray.Origin, ray.Direction * 20000, params)
	if not result then
		return nil
	end
	local model = result.Instance:FindFirstAncestorOfClass("Model")
	if model and model:GetAttribute("RegionId") then
		return model
	end
	return nil
end

local function onMouseMove(input: InputObject, processed: boolean)
	if input.UserInputType ~= Enum.UserInputType.MouseMovement or not hoverHighlight or not enabled then
		return
	end
	local model = if processed then nil else regionAt(Vector2.new(input.Position.X, input.Position.Y))
	if model and model.Name ~= selected then
		hoverHighlight.Adornee = model
		hoverHighlight.Enabled = true
	else
		hoverHighlight.Enabled = false
	end
end

function RegionSelector.start(carte: Model, listener: SelectListener)
	regionsFolder = carte:WaitForChild("Regions")
	onSelect = listener
	hoverHighlight = newHighlight("Survol", 0.85, Color3.new(1, 1, 1), carte)
	selectHighlight = newHighlight("Selection", 0.65, Color3.fromRGB(255, 225, 110), carte)

	UserInputService.InputChanged:Connect(onMouseMove)
	CameraController.onTap(function(screenPos: Vector2)
		if not enabled then
			return
		end
		if interceptor and interceptor(screenPos) then
			return
		end
		local model = regionAt(screenPos)
		RegionSelector.select(if model then model.Name else nil)
	end)
end

-- Un clic passe d'abord par `fn` ; s'il renvoie vrai, aucune région n'est sélectionnée
function RegionSelector.setTapInterceptor(fn: (Vector2) -> boolean)
	interceptor = fn
end

-- Identifiant de la région sous une position de l'écran (nil : mer, ou rien)
function RegionSelector.regionAt(screenPos: Vector2): string?
	local model = regionAt(screenPos)
	return if model then model.Name else nil
end

-- Mode « pays » : getOwner donne le propriétaire d'une région ; nil revient à une seule région
function RegionSelector.setCountryMode(getOwner: ((regionId: string) -> string?)?)
	countryOwner = getOwner
	if not getOwner then
		clearCountry()
	end
end

-- Active ou coupe la sélection (coupée pendant l'écran titre)
function RegionSelector.setEnabled(value: boolean)
	enabled = value
	if not value and hoverHighlight then
		hoverHighlight.Enabled = false
	end
end

-- Sélectionne une région (nil = aucune)
function RegionSelector.select(regionId: string?)
	selected = regionId
	local model = if regionId and regionsFolder then regionsFolder:FindFirstChild(regionId) else nil
	if selectHighlight then
		selectHighlight.Adornee = model
		selectHighlight.Enabled = model ~= nil
	end
	-- mode « pays » : les autres régions du même pays brillent aussi (moins de 31 surbrillances en
	-- tout : le plus grand pays compte 25 régions)
	clearCountry()
	local getOwner = countryOwner
	if getOwner and model and regionsFolder and selectHighlight then
		local owner = getOwner(model.Name)
		for _, other in regionsFolder:GetChildren() do
			if other ~= model and owner and getOwner(other.Name) == owner then
				local h = selectHighlight:Clone()
				h.Name = "SelectionPays"
				h.Adornee = other
				h.Enabled = true
				h.Parent = selectHighlight.Parent
				table.insert(countryHighlights, h)
			end
		end
	end
	if hoverHighlight and model and hoverHighlight.Adornee == model then
		hoverHighlight.Enabled = false
	end
	if onSelect then
		onSelect(if model then regionId else nil)
	end
end

return RegionSelector
