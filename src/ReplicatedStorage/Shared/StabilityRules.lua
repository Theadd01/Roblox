--!strict
-- Effets de la stabilité (opinion publique), partagés par le serveur (qui décide) et le client
-- (qui affiche) : production, coût du recrutement, humeur de la population.

local Politics = require(script.Parent.Config.Politics)

local StabilityRules = {}

-- Multiplicateur de la production des régions (0,5 à 1)
function StabilityRules.productionFactor(stability: number): number
	local E = Politics.effects
	return E.productionMin + (1 - E.productionMin) * math.clamp(stability, 0, 100) / 100
end

-- Multiplicateur du coût en crédits d'un recrutement (1 à 1,5)
function StabilityRules.recruitFactor(stability: number): number
	local E = Politics.effects
	if stability >= E.recruitAbove then
		return 1
	end
	return 1 + E.recruitMaxExtra * (E.recruitAbove - math.max(0, stability)) / E.recruitAbove
end

-- Coût réel d'une recrue : les crédits sont multipliés, les ressources ne changent pas
function StabilityRules.recruitCost(cost: { [string]: number }, stability: number, currency: string): { [string]: number }
	local factor = StabilityRules.recruitFactor(stability)
	local result = table.clone(cost)
	if result[currency] then
		result[currency] = math.ceil(result[currency] * factor)
	end
	return result
end

-- Humeur de la population, pour l'affichage
function StabilityRules.opinion(stability: number): string
	if stability >= 60 then
		return "😊 favorable"
	elseif stability >= 30 then
		return "😐 partagée"
	end
	return "😠 hostile"
end

return StabilityRules
