--!strict
-- Atlas des 169 drapeaux utilises par WORLD FRONT.
-- Trois images partagees evitent de charger un decal different pour chaque pays.

local FlagCatalog = {}

export type Entry = {
	image: string,
	offset: Vector2,
	size: Vector2,
}

local ATLAS = {
	"rbxassetid://85781978877975",
	"rbxassetid://120348735414397",
	"rbxassetid://117664096622820",
}

local CODES = {
	"AFG", "AGO", "ALB", "ARE", "ARG", "ARM", "AUS", "AUT",
	"AZE", "BDI", "BEL", "BEN", "BFA", "BGD", "BGR", "BHS",
	"BIH", "BLR", "BLZ", "BOL", "BRA", "BRN", "BTN", "BWA",
	"CAF", "CAN", "CHE", "CHL", "CHN", "CIV", "CMR", "COD",
	"COG", "COL", "CRI", "CUB", "CYP", "CZE", "DEU", "DJI",
	"DNK", "DOM", "DZA", "ECU", "EGY", "ERI", "ESP", "EST",
	"ETH", "FIN", "FJI", "FRA", "GAB", "GBR", "GEO", "GHA",
	"GIN", "GMB", "GNB", "GNQ", "GRC", "GTM", "GUY", "HND",
	"HRV", "HTI", "HUN", "IDN", "IND", "IRL", "IRN", "IRQ",
	"ISL", "ISR", "ITA", "JAM", "JOR", "JPN", "KAZ", "KEN",
	"KGZ", "KHM", "KOR", "KOS", "KWT", "LAO", "LBN", "LBR",
	"LBY", "LKA", "LSO", "LTU", "LUX", "LVA", "MAR", "MDA",
	"MDG", "MEX", "MKD", "MLI", "MLT", "MMR", "MNE", "MNG",
	"MOZ", "MRT", "MWI", "MYS", "NAM", "NER", "NGA", "NIC",
	"NLD", "NOR", "NPL", "NZL", "OMN", "PAK", "PAN", "PER",
	"PHL", "PNG", "POL", "PRK", "PRT", "PRY", "PSE", "QAT",
	"ROU", "RUS", "RWA", "SAU", "SDN", "SEN", "SLB", "SLE",
	"SLV", "SOM", "SRB", "SSD", "SUR", "SVK", "SVN", "SWE",
	"SWZ", "SYR", "TCD", "TGO", "THA", "TJK", "TKM", "TLS",
	"TTO", "TUN", "TUR", "TWN", "TZA", "UGA", "UKR", "URY",
	"USA", "UZB", "VEN", "VNM", "VUT", "YEM", "ZAF", "ZMB",
	"ZWE",
}

local CELL_WIDTH = 128
local CELL_HEIGHT = 96
local COLUMNS = 8
local PER_ATLAS = 64
local entries: { [string]: Entry } = {}

for index, code in ipairs(CODES) do
	local zero = index - 1
	local page = math.floor(zero / PER_ATLAS) + 1
	local cell = zero % PER_ATLAS
	entries[code] = {
		image = ATLAS[page],
		offset = Vector2.new((cell % COLUMNS) * CELL_WIDTH, math.floor(cell / COLUMNS) * CELL_HEIGHT),
		size = Vector2.new(CELL_WIDTH, CELL_HEIGHT),
	}
end

function FlagCatalog.get(countryId: string): Entry?
	return entries[countryId]
end

function FlagCatalog.apply(label: ImageLabel, countryId: string): boolean
	local entry = entries[countryId]
	if not entry then
		label.Image = ""
		return false
	end
	label.Image = entry.image
	label.ImageRectOffset = entry.offset
	label.ImageRectSize = entry.size
	label.ImageColor3 = Color3.new(1, 1, 1)
	label.ImageTransparency = 0
	label.ScaleType = Enum.ScaleType.Fit
	return true
end

function FlagCatalog.count(): number
	return #CODES
end

return FlagCatalog
