--!strict
-- Place libre à l'écran pour les panneaux militaires (sélection, fiche du général, bataille), du
-- téléphone à l'ordinateur : entre la barre du haut (attribut BasBarreHaut publié par TopBar) et le
-- bandeau d'actualités / la barre d'onglets en bas ; échelle des panneaux comme le reste de
-- l'interface (UIScaler : plus petite sur téléphone, réglage « Taille de l'interface »).
-- Les panneaux latéraux (fiche du général, bataille) publient leur rectangle : le panneau de
-- sélection se place à côté. Tous contournent les boutons flottants dessinés au-dessus d'eux.
-- Les panneaux s'abonnent avec onChanged pour se replacer quand l'écran ou les barres bougent.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")

local Client = script.Parent.Parent
local UIScaler = require(Client:WaitForChild("UI"):WaitForChild("UIScaler"))

local MARGIN = 8 -- entre deux panneaux
local EDGE = 12 -- au bord de l'écran
local CHECK = 0.5 -- secondes entre deux vérifications (barres qui changent de taille)
local SIDE_MIN_HEIGHT = 220 -- place libre plus basse (téléphone) : les panneaux latéraux descendent jusqu'en bas

-- Boutons flottants d'autres modules, dessinés au-dessus des panneaux militaires : à contourner
local FLOATING = { { "Commerce", "OuvrirCommerce" } }

local ScreenSpace = {}

local listeners: { () -> () } = {}
local lastSignature = ""
local panels: { [string]: Rect } = {} -- panneaux latéraux ouverts (rectangle à l'écran)

local function playerGui(): Instance?
	return Players.LocalPlayer:FindFirstChild("PlayerGui")
end

-- Rectangle à l'écran d'un objet d'interface visible (nil s'il est caché)
local function visibleRect(path: { string }): Rect?
	local node: Instance? = playerGui()
	for _, name in path do
		node = node and node:FindFirstChild(name)
	end
	if node and node:IsA("GuiObject") and node.Visible and node.AbsoluteSize.X > 0 then
		local gui = node:FindFirstAncestorOfClass("ScreenGui")
		if gui and gui.Enabled then
			return Rect.new(node.AbsolutePosition, node.AbsolutePosition + node.AbsoluteSize)
		end
	end
	return nil
end

local function notify()
	for _, listener in listeners do
		task.defer(listener)
	end
end

-- Hauteur de l'écran (coordonnées de l'interface, sous la barre de Roblox)
local function screenHeight(): number
	return workspace.CurrentCamera.ViewportSize.Y - GuiService:GetGuiInset().Y
end

-- Haut de la place libre (sous la barre du haut)
function ScreenSpace.top(): number
	local bottom = Players.LocalPlayer:GetAttribute("BasBarreHaut")
	return (if typeof(bottom) == "number" then bottom else 60) + MARGIN
end

-- Bas de la place libre (au-dessus du bandeau d'actualités et de la barre d'onglets)
function ScreenSpace.bottom(): number
	local limit = screenHeight()
	for _, path in { { "Actualites", "Bandeau" }, { "Onglets", "Barre" } } do
		local r = visibleRect(path)
		if r and r.Min.Y > limit * 0.5 then
			limit = math.min(limit, r.Min.Y)
		end
	end
	return limit - MARGIN
end

-- Bas des panneaux latéraux (fiche du général, bataille) : sur un petit écran (téléphone), ils
-- descendent par-dessus le bandeau et les onglets, le temps d'être ouverts
function ScreenSpace.sideBottom(): number
	local bottom = ScreenSpace.bottom()
	if bottom - ScreenSpace.top() >= SIDE_MIN_HEIGHT then
		return bottom
	end
	return screenHeight() - MARGIN
end

-- Haut de la place libre pour un panneau qui occupe les colonnes x0 à x1 (sous les boutons flottants)
function ScreenSpace.topAt(x0: number, x1: number): number
	local top = ScreenSpace.top()
	for _, path in FLOATING do
		local r = visibleRect(path)
		if r and r.Min.X < x1 and r.Max.X > x0 then
			top = math.max(top, r.Max.Y + MARGIN)
		end
	end
	return top
end

-- Colonnes libres (x0, x1) pour un panneau du bas qui occupe les lignes y0 à y1 : sans les panneaux
-- latéraux ouverts ni les boutons flottants (de chaque obstacle, on garde le côté le plus large)
function ScreenSpace.band(y0: number, y1: number): (number, number)
	local x0, x1 = EDGE, ScreenSpace.width() - EDGE
	local obstacles: { Rect } = {}
	for _, rect in panels do
		table.insert(obstacles, rect)
	end
	for _, path in FLOATING do
		local r = visibleRect(path)
		if r then
			table.insert(obstacles, r)
		end
	end
	for _, r in obstacles do
		if r.Min.Y < y1 and r.Max.Y + MARGIN > y0 and r.Min.X < x1 and r.Max.X > x0 then
			if r.Min.X - x0 >= x1 - r.Max.X then
				x1 = r.Min.X - MARGIN
			else
				x0 = r.Max.X + MARGIN
			end
		end
	end
	return x0, x1
end

-- Un panneau latéral s'ouvre, bouge ou se ferme (rect nil) : les panneaux du bas se replacent
function ScreenSpace.setPanel(name: string, rect: Rect?)
	local old = panels[name]
	if old == rect or (old and rect and old.Min == rect.Min and old.Max == rect.Max) then
		return
	end
	panels[name] = rect
	notify()
end

-- Largeur de l'écran (coordonnées de l'interface)
function ScreenSpace.width(): number
	return workspace.CurrentCamera.ViewportSize.X
end

-- Échelle des panneaux (la même que le reste de l'interface)
function ScreenSpace.scale(): number
	local ok, factor = pcall(UIScaler.factor)
	return if ok and typeof(factor) == "number" then factor else 1
end

-- Ajoute (ou met à jour) l'échelle d'un panneau
function ScreenSpace.applyScale(frame: GuiObject)
	local s = frame:FindFirstChild("EchelleMilitaire") :: UIScale?
	if not s then
		local created = Instance.new("UIScale")
		created.Name = "EchelleMilitaire"
		created.Parent = frame
		s = created
	end
	(s :: UIScale).Scale = ScreenSpace.scale()
end

-- listener() : l'écran, les barres ou les panneaux latéraux ont changé, le panneau se replace
function ScreenSpace.onChanged(listener: () -> ())
	table.insert(listeners, listener)
	task.defer(listener)
end

function ScreenSpace.start()
	local clock = CHECK
	RunService.RenderStepped:Connect(function(dt: number)
		clock += dt
		if clock < CHECK then
			return
		end
		clock = 0
		local viewport = workspace.CurrentCamera.ViewportSize
		local signature = `{viewport.X}x{viewport.Y}|{ScreenSpace.top()}|{ScreenSpace.bottom()}|{ScreenSpace.scale()}`
		for _, path in FLOATING do
			signature ..= `|{visibleRect(path) or "-"}`
		end
		if signature ~= lastSignature then
			lastSignature = signature
			notify()
		end
	end)
end

return ScreenSpace
