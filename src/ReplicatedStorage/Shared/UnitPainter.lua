--!strict
-- Colore un modèle d'unité aux couleurs d'un pays, d'après l'attribut « Teinte » de ses pièces.

local UnitStyles = require(script.Parent.Config.UnitStyles)

local UnitPainter = {}

local function shade(c: Color3, factor: number): Color3
	return Color3.new(math.min(1, c.R * factor), math.min(1, c.G * factor), math.min(1, c.B * factor))
end

-- Couleur d'une teinte pour un pays donné
function UnitPainter.colorFor(tint: string, countryColor: Color3): Color3?
	local fixed = UnitStyles.fixed[tint]
	if fixed then
		return fixed
	end
	local style = UnitStyles.tints[tint]
	if not style then
		return nil
	end
	return shade(UnitStyles.military:Lerp(countryColor, style.mix), style.shade)
end

function UnitPainter.paint(model: Instance, countryColor: Color3)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local tint = d:GetAttribute("Teinte")
			if typeof(tint) == "string" then
				local color = UnitPainter.colorFor(tint, countryColor)
				if color then
					d.Color = color
				end
			end
		end
	end
end

return UnitPainter
