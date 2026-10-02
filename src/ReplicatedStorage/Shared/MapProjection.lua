--!strict
-- Conversion longitude / latitude -> position sur la carte (studs).
-- Projection cylindrique de Miller : doit rester identique à celle de
-- tools/geo2luau.js (les paramètres viennent de MapGeometry).

local MapGeometry = require(script.Parent.Config.MapGeometry)

local P = MapGeometry.projection
local RAD = math.pi / 180

local MapProjection = {}

-- Renvoie X (est) et Z (sud) sur la carte
function MapProjection.toXZ(lon: number, lat: number): (number, number)
	local l = math.clamp(lat, P.minLat, P.maxLat)
	local x = P.radius * lon * RAD
	local y = P.radius * 1.25 * math.log(math.tan(math.pi / 4 + 0.4 * l * RAD))
	return x, -(y - P.offsetY)
end

function MapProjection.toVector3(lon: number, lat: number, height: number): Vector3
	local x, z = MapProjection.toXZ(lon, lat)
	return Vector3.new(x, height, z)
end

-- Vrai si le point (X, Z) est dans le rectangle de la carte
function MapProjection.isInside(x: number, z: number): boolean
	local b = MapGeometry.bounds
	return x >= b.minX and x <= b.maxX and z >= b.minZ and z <= b.maxZ
end

return MapProjection
