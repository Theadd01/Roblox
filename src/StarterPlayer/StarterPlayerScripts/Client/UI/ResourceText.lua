--!strict
-- Mise en forme des ressources pour l'interface : « 🛢️ +10   🌾 +3 », « 1 250 ».

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Resources = require(Shared:WaitForChild("Config"):WaitForChild("Resources")) :: any
local RegionResources = require(Shared:WaitForChild("RegionResources")) :: any

local ResourceText = {}

-- 1250000 -> « 1 250 000 » (espace insécable entre les milliers) ; 1.5 -> « 1,5 » (production
-- au dixième près, sous 100)
function ResourceText.number(n: number): string
	local tenths = math.floor(math.abs(n) * 10 + 0.5) / 10
	if tenths < 100 and tenths % 1 ~= 0 then
		return (if n < 0 then "-" else "") .. (string.format("%.1f", tenths):gsub("%.", ","))
	end
	local digits = tostring(math.floor(math.abs(n)))
	-- on groupe par 3 en partant de la droite (chaîne ASCII : l'inversion est sans risque)
	local grouped = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	grouped = grouped:gsub("^,", ""):gsub(",", "\u{00A0}")
	return (if n < 0 then "-" else "") .. grouped
end

-- Production (ressource -> quantité) : « 🛢️ +10   🌾 +3 », de la plus forte à la plus faible
function ResourceText.production(production: { [string]: number }): string
	local parts = {}
	for _, id in RegionResources.sorted(production) do
		table.insert(parts, `{Resources.list[id].icon} +{production[id]}`)
	end
	return if #parts > 0 then table.concat(parts, "   ") else "rien"
end

-- Coût : « 400 💰 + 20 🔩 » (crédits d'abord, puis ressources dans l'ordre habituel)
function ResourceText.cost(costs: { [string]: number }): string
	local parts = {}
	local currency = Resources.currency
	if costs[currency.id] then
		table.insert(parts, `{ResourceText.number(costs[currency.id])} {currency.icon}`)
	end
	for _, id in Resources.order do
		if costs[id] then
			table.insert(parts, `{ResourceText.number(costs[id])} {Resources.list[id].icon}`)
		end
	end
	return table.concat(parts, " + ")
end

-- Principales ressources, avec leur nom : « 🛢️ Pétrole, 🔥 Gaz, 🌾 Nourriture »
function ResourceText.main(production: { [string]: number }, limit: number): string
	local parts = {}
	for i, id in RegionResources.sorted(production) do
		if i > limit then
			break
		end
		local r = Resources.list[id]
		table.insert(parts, `{r.icon} {r.name}`)
	end
	return if #parts > 0 then table.concat(parts, ", ") else "aucune"
end

return ResourceText
