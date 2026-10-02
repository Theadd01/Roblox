--!strict
-- Petit graphique en ligne pour l'historique des prix, dessiné avec des cadres pivotés.
-- Ligne verte si le prix a monté sur la période, rouge s'il a baissé ;
-- trait gris pointillé = prix de base.

local UIStyle = require(script.Parent:WaitForChild("UIStyle"))

local UP = Color3.fromRGB(120, 220, 130)
local DOWN = Color3.fromRGB(235, 95, 85)
local AXIS_WIDTH = 46 -- place à gauche pour les valeurs min / max

export type Chart = {
	frame: Frame,
	set: (values: { number }, baseline: number?) -> (),
}

local PriceChart = {}

local function formatPrice(x: number): string
	return (string.format("%.1f", x):gsub("%.", ","))
end

local function segment(parent: Instance, a: Vector2, b: Vector2, color: Color3, thickness: number, transparency: number)
	local delta = b - a
	local line = Instance.new("Frame")
	line.AnchorPoint = Vector2.new(0.5, 0.5)
	line.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
	line.Size = UDim2.fromOffset(delta.Magnitude + 1, thickness)
	line.Rotation = math.deg(math.atan2(delta.Y, delta.X))
	line.BackgroundColor3 = color
	line.BackgroundTransparency = transparency
	line.BorderSizePixel = 0
	line.Parent = parent
end

function PriceChart.create(parent: Instance, order: number): Chart
	local frame = Instance.new("Frame")
	frame.Name = "Graphique"
	frame.LayoutOrder = order
	frame.Size = UDim2.new(1, 0, 0, 150)
	frame.BackgroundColor3 = UIStyle.PANEL_ALT
	frame.BackgroundTransparency = 0.5
	UIStyle.corner(frame, 8)
	UIStyle.stroke(frame, 0.65, UIStyle.BORDER_SOFT)

	local maxLabel = UIStyle.text("Max", "", 12, UIStyle.FONT, UIStyle.TEXT_DIM)
	maxLabel.AutomaticSize = Enum.AutomaticSize.None
	maxLabel.Position = UDim2.fromOffset(6, 6)
	maxLabel.Size = UDim2.fromOffset(AXIS_WIDTH - 8, 14)
	maxLabel.Parent = frame
	local minLabel = UIStyle.text("Min", "", 12, UIStyle.FONT, UIStyle.TEXT_DIM)
	minLabel.AutomaticSize = Enum.AutomaticSize.None
	minLabel.AnchorPoint = Vector2.new(0, 1)
	minLabel.Position = UDim2.new(0, 6, 1, -6)
	minLabel.Size = UDim2.fromOffset(AXIS_WIDTH - 8, 14)
	minLabel.Parent = frame

	local plot = Instance.new("Frame")
	plot.Name = "Trace"
	plot.BackgroundTransparency = 1
	plot.Position = UDim2.fromOffset(AXIS_WIDTH, 10)
	plot.Size = UDim2.new(1, -(AXIS_WIDTH + 10), 1, -20)
	plot.ClipsDescendants = true
	plot.Parent = frame
	frame.Parent = parent

	local values: { number } = {}
	local baseline: number? = nil

	local function render()
		for _, child in plot:GetChildren() do
			child:Destroy()
		end
		local size = plot.AbsoluteSize
		local n = #values
		if n < 2 or size.X < 10 or size.Y < 10 then
			return
		end
		local low, high = math.huge, -math.huge
		for _, v in values do
			low, high = math.min(low, v), math.max(high, v)
		end
		if baseline then
			low, high = math.min(low, baseline), math.max(high, baseline)
		end
		local pad = math.max((high - low) * 0.08, 0.05)
		low, high = low - pad, high + pad
		local function point(i: number, v: number): Vector2
			return Vector2.new((i - 1) / (n - 1) * size.X, (1 - (v - low) / (high - low)) * size.Y)
		end

		if baseline then
			-- prix de base en pointillés
			local y = point(1, baseline).Y
			local x = 0
			while x < size.X do
				segment(plot, Vector2.new(x, y), Vector2.new(math.min(x + 6, size.X), y), UIStyle.TEXT_DIM, 1, 0.5)
				x += 12
			end
		end
		local color = if values[n] >= values[1] then UP else DOWN
		for i = 2, n do
			segment(plot, point(i - 1, values[i - 1]), point(i, values[i]), color, 2, 0)
		end
		local last = point(n, values[n])
		local dot = Instance.new("Frame")
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.fromOffset(last.X, last.Y)
		dot.Size = UDim2.fromOffset(7, 7)
		dot.BackgroundColor3 = color
		dot.BorderSizePixel = 0
		UIStyle.corner(dot)
		dot.Parent = plot

		maxLabel.Text = formatPrice(high - pad)
		minLabel.Text = formatPrice(low + pad)
	end

	plot:GetPropertyChangedSignal("AbsoluteSize"):Connect(render)
	return {
		frame = frame,
		set = function(newValues: { number }, newBaseline: number?)
			values = newValues
			baseline = newBaseline
			render()
		end,
	}
end

return PriceChart
