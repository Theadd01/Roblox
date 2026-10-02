--!strict
-- Style commun des interfaces : polices, couleurs, panneaux et boutons.

local TweenService = game:GetService("TweenService")
local IconCatalog = require(script.Parent:WaitForChild("IconCatalog"))

local UIStyle = {}

-- Icône vectorielle native, indépendante des polices/emoji du système.
function UIStyle.iconFrame(name: string, size: number?, color: Color3?): Frame
	return IconCatalog.create(name, size, color)
end

function UIStyle.mountIcon(parent: GuiObject, name: string, size: number?, color: Color3?): Frame
	local icon = IconCatalog.create(name, size, color)
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	IconCatalog.setZIndex(icon, parent.ZIndex + 1)
	icon.Parent = parent
	return icon
end

function UIStyle.setIconColor(icon: Instance, color: Color3)
	IconCatalog.setColor(icon, color)
end

UIStyle.FONT = Font.fromEnum(Enum.Font.BuilderSans)
UIStyle.FONT_MEDIUM = Font.fromEnum(Enum.Font.BuilderSansMedium)
UIStyle.FONT_BOLD = Font.fromEnum(Enum.Font.BuilderSansBold)
UIStyle.FONT_BLACK = Font.fromEnum(Enum.Font.BuilderSansExtraBold)

-- Palette unique de WORLD FRONT. Les surfaces restent sombres pour laisser la carte
-- dominer, avec des niveaux suffisamment distincts pour lire immédiatement la hiérarchie.
UIStyle.BACKDROP = Color3.fromRGB(7, 10, 15)
UIStyle.PANEL = Color3.fromRGB(15, 20, 28)
UIStyle.PANEL_ALT = Color3.fromRGB(23, 29, 40)
UIStyle.PANEL_RAISED = Color3.fromRGB(30, 37, 50)
UIStyle.BORDER = Color3.fromRGB(91, 104, 124)
UIStyle.BORDER_SOFT = Color3.fromRGB(57, 68, 84)
UIStyle.TEXT = Color3.fromRGB(242, 245, 249)
UIStyle.TEXT_DIM = Color3.fromRGB(164, 175, 191)
UIStyle.GREY_HEX = "#A4AFBF"
UIStyle.ACCENT = Color3.fromRGB(235, 190, 70)
UIStyle.ACCENT_SOFT = Color3.fromRGB(93, 74, 28)
UIStyle.SUCCESS = Color3.fromRGB(105, 205, 126)
UIStyle.WARNING = Color3.fromRGB(245, 157, 75)
UIStyle.INFO = Color3.fromRGB(111, 150, 181)
UIStyle.DANGER = Color3.fromRGB(230, 95, 85)

function UIStyle.corner(parent: Instance, radius: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = if radius then UDim.new(0, radius) else UDim.new(1, 0)
	c.Parent = parent
end

function UIStyle.stroke(parent: Instance, transparency: number?, color: Color3?, thickness: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Name = "Contour"
	s.Color = color or UIStyle.BORDER
	s.Transparency = transparency or 0.35
	s.Thickness = thickness or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

-- Relief très léger, commun à toutes les surfaces. Il ne change ni taille ni placement.
function UIStyle.gradient(parent: Instance, strength: number?): UIGradient
	local amount = math.clamp(strength or 0.08, 0, 0.25)
	local g = Instance.new("UIGradient")
	g.Name = "Profondeur"
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(1, Color3.new(1 - amount, 1 - amount * 0.78, 1 - amount * 0.55)),
	})
	g.Rotation = 90
	g.Parent = parent
	return g
end

function UIStyle.padding(parent: Instance, vertical: number, horizontal: number)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, vertical)
	p.PaddingBottom = UDim.new(0, vertical)
	p.PaddingLeft = UDim.new(0, horizontal)
	p.PaddingRight = UDim.new(0, horizontal)
	p.Parent = parent
end

function UIStyle.list(parent: Instance, gap: number, horizontal: boolean?): UIListLayout
	local l = Instance.new("UIListLayout")
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Padding = UDim.new(0, gap)
	l.FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical
	l.Parent = parent
	return l
end

-- Panneau sombre arrondi à hauteur automatique.
-- Active = vrai : un clic sur le panneau ne traverse pas jusqu'à la carte.
function UIStyle.panel(name: string, width: UDim): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Active = true
	f.Size = UDim2.new(width, UDim.new(0, 0))
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.BackgroundColor3 = UIStyle.PANEL
	f.BackgroundTransparency = 0.025
	UIStyle.corner(f, 10)
	UIStyle.stroke(f, 0.28)
	UIStyle.gradient(f, 0.07)
	return f
end

-- Carte interne : utilisée pour grouper une information sans créer un nouveau panneau flottant.
function UIStyle.card(name: string, height: number?, color: Color3?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = UDim2.new(1, 0, 0, height or 0)
	f.AutomaticSize = if height then Enum.AutomaticSize.None else Enum.AutomaticSize.Y
	f.BackgroundColor3 = color or UIStyle.PANEL_ALT
	f.BackgroundTransparency = 0.14
	UIStyle.corner(f, 8)
	UIStyle.stroke(f, 0.58, UIStyle.BORDER_SOFT)
	return f
end

function UIStyle.divider(name: string?): Frame
	local line = Instance.new("Frame")
	line.Name = name or "Separateur"
	line.Size = UDim2.new(1, 0, 0, 1)
	line.BackgroundColor3 = UIStyle.BORDER_SOFT
	line.BackgroundTransparency = 0.35
	line.BorderSizePixel = 0
	return line
end

function UIStyle.styleScroll(frame: ScrollingFrame)
	frame.BorderSizePixel = 0
	frame.ScrollBarThickness = 5
	frame.ScrollBarImageColor3 = UIStyle.ACCENT
	frame.ScrollBarImageTransparency = 0.22
end

-- Texte (retour à la ligne automatique, hauteur automatique)
function UIStyle.text(name: string, text: string, size: number, font: Font?, color: Color3?): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.Size = UDim2.new(1, 0, 0, 0)
	t.AutomaticSize = Enum.AutomaticSize.Y
	t.FontFace = font or UIStyle.FONT
	t.TextSize = size
	t.TextColor3 = color or UIStyle.TEXT
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.TextWrapped = true
	t.RichText = true
	t.LineHeight = 1.06
	t.Text = text
	return t
end

-- Bouton arrondi. primary = bouton principal doré ; sinon bouton sombre.
function UIStyle.button(name: string, text: string, primary: boolean?): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.AutoButtonColor = false
	b.Size = UDim2.new(1, 0, 0, 50)
	b.FontFace = UIStyle.FONT_BOLD
	b.TextSize = 20
	b.Text = text
	local base = if primary then UIStyle.ACCENT else UIStyle.PANEL_ALT
	b.BackgroundColor3 = base
	b.BackgroundTransparency = if primary then 0 else 0.08
	b:SetAttribute("TransparenceBase", b.BackgroundTransparency)
	b:SetAttribute("Actif", true)
	b.TextColor3 = if primary then Color3.fromRGB(30, 26, 18) else UIStyle.TEXT
	UIStyle.corner(b, 8)
	local outline = UIStyle.stroke(b, if primary then 0.44 else 0.48, if primary then UIStyle.ACCENT else UIStyle.BORDER_SOFT)
	b:SetAttribute("ContourBase", if primary then 0.44 else 0.48)
	UIStyle.gradient(b, if primary then 0.08 else 0.055)
	b:SetAttribute("CouleurBase", base)
	local info = TweenInfo.new(0.12)
	local function baseColor(): Color3
		local c = b:GetAttribute("CouleurBase")
		return if typeof(c) == "Color3" then c else base
	end
	local function outlineBase(): number
		local value = b:GetAttribute("ContourBase")
		return if typeof(value) == "number" then value else 0.48
	end
	local function updateIconTint(hovered: boolean)
		local mountedIcon = b:FindFirstChild("Icone", true)
		if mountedIcon and mountedIcon:IsA("Frame") then
			local accented = b:GetAttribute("Selectionne") == true or b:GetAttribute("IconeAccent") == true
			IconCatalog.setColor(mountedIcon, if accented then UIStyle.ACCENT elseif hovered then UIStyle.TEXT else UIStyle.TEXT_DIM)
		end
	end
	b.MouseEnter:Connect(function()
		if UIStyle.isEnabled(b) then
			TweenService:Create(b, info, { BackgroundColor3 = baseColor():Lerp(Color3.new(1, 1, 1), 0.12) }):Play()
			TweenService:Create(outline, info, { Transparency = 0.12 }):Play()
			updateIconTint(true)
		end
	end)
	b.MouseLeave:Connect(function()
		TweenService:Create(b, info, { BackgroundColor3 = baseColor() }):Play()
		TweenService:Create(outline, info, { Transparency = outlineBase() }):Play()
		updateIconTint(false)
	end)
	b.MouseButton1Down:Connect(function()
		if UIStyle.isEnabled(b) then
			TweenService:Create(b, TweenInfo.new(0.06), { BackgroundColor3 = baseColor():Lerp(Color3.new(0, 0, 0), 0.12) }):Play()
		end
	end)
	b.MouseButton1Up:Connect(function()
		if UIStyle.isEnabled(b) then
			TweenService:Create(b, info, { BackgroundColor3 = baseColor():Lerp(Color3.new(1, 1, 1), 0.08) }):Play()
		end
	end)
	b:SetAttribute("Principal", primary == true)
	return b
end

-- Change la couleur d'un bouton (le survol revient ensuite à cette couleur)
function UIStyle.setButtonColor(b: TextButton, background: Color3, text: Color3, transparency: number)
	b:SetAttribute("CouleurBase", background)
	b:SetAttribute("TransparenceBase", transparency)
	b.BackgroundColor3 = background
	b.BackgroundTransparency = transparency
	b.TextColor3 = text
	local outline = b:FindFirstChild("Contour")
	if outline and outline:IsA("UIStroke") then
		local selected = background == UIStyle.ACCENT
		outline.Color = if selected then UIStyle.ACCENT else UIStyle.BORDER_SOFT
		outline.Transparency = if selected then 0.44 else 0.48
		b:SetAttribute("ContourBase", if selected then 0.44 else 0.48)
		b:SetAttribute("Principal", selected)
	end
end

-- Un onglet sélectionné reste une navigation sombre soulignée d'or ; le grand fond doré
-- est réservé aux actions principales (acheter, confirmer, lancer...).
function UIStyle.setButtonSelected(b: TextButton, selected: boolean)
	UIStyle.setButtonColor(
		b,
		if selected then UIStyle.PANEL_RAISED else UIStyle.PANEL_ALT,
		if selected then UIStyle.ACCENT else UIStyle.TEXT_DIM,
		if selected then 0.02 else 0.1
	)
	local outline = b:FindFirstChild("Contour")
	if outline and outline:IsA("UIStroke") then
		outline.Color = if selected then UIStyle.ACCENT else UIStyle.BORDER_SOFT
		outline.Transparency = if selected then 0.2 else 0.58
		b:SetAttribute("ContourBase", if selected then 0.2 else 0.58)
	end
	b:SetAttribute("Selectionne", selected)
end

-- Active / désactive un bouton (grisé quand désactivé).
-- Les actions des boutons doivent vérifier UIStyle.isEnabled avant d'agir.
function UIStyle.setButtonEnabled(b: TextButton, enabled: boolean)
	b:SetAttribute("Actif", enabled)
	b.Active = enabled
	b.Selectable = enabled
	b.Interactable = enabled
	b.TextTransparency = if enabled then 0 else 0.5
	local base = b:GetAttribute("TransparenceBase")
	b.BackgroundTransparency = if enabled and typeof(base) == "number" then base else 0.6
	local outline = b:FindFirstChild("Contour")
	if outline and outline:IsA("UIStroke") then
		local saved = b:GetAttribute("ContourBase")
		outline.Transparency = if enabled and typeof(saved) == "number" then saved else 0.8
	end
end

function UIStyle.isEnabled(b: TextButton): boolean
	return b:GetAttribute("Actif") ~= false
end

return UIStyle
