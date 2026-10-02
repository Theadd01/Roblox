--!strict
-- FICHIER GÉNÉRÉ par tools/geo2luau.js : ne pas modifier à la main.
-- (modifier tools/data/pays-fr.js ou les paramètres du script, puis relancer : node tools/geo2luau.js)
-- Projection de Miller, limites de la carte ; rassemble les contours de Config/Geometry.

local Geometry = script.Parent:WaitForChild("Geometry")

local MapGeometry = {
	projection = { radius = 859.4367, offsetY = 384.0476, minLat = -56.5, maxLat = 84 },
	bounds = { minX = -2700, maxX = 2700, minZ = -1336.2, maxZ = 1336.2 },
	countries = {} :: { [string]: any }, -- contours par région (clé = Regions[id].geometry)
}

for _, zone in { "Ameriques", "Europe", "AfriqueMoyenOrient", "Asie", "Oceanie" } do
	local chunk = require(Geometry:WaitForChild(zone)) :: any
	for key, data in chunk do
		MapGeometry.countries[key] = data
	end
end

return MapGeometry
