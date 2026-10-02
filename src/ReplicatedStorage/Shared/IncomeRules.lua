--!strict
-- Revenus passifs (Config/Economy.taxes et autoSell), partagés par le serveur (qui décide) et le
-- client (qui affiche) : montant des impôts, réglage de la vente automatique, réserve gardée.
-- Fonctions pures (tests/Income.spec.luau), sauf autoSellEnabled qui lit l'attribut du pays.

local Economy = require(script.Parent.Config.Economy)
local Population = require(script.Parent.Config.Population)

local IncomeRules = {}

-- Impôts d'un cycle (crédits, avec décimales) : habitants de ses propres régions et de ses régions
-- conquises (milliers) ; factor : effet de la stabilité (StabilityRules.productionFactor)
function IncomeRules.taxes(home: number, occupied: number, factor: number): number
	local people = math.max(0, home) + math.max(0, occupied) * Economy.taxes.occupiedFactor
	return people / 1000 * Population.taxPerMillion * math.max(0, factor)
end

-- L'achat automatique de nourriture est-il actif ? (réglage du joueur, sinon actif)
function IncomeRules.autoBuyEnabled(country: Instance): boolean
	return country:GetAttribute("AchatAutoNourriture") ~= false
end

-- Attribut du pays (EtatMonde.Pays.<pays>) qui garde le réglage de la vente automatique
function IncomeRules.autoSellAttribute(resourceId: string): string
	return "VenteAuto_" .. resourceId
end

-- La vente automatique est-elle active pour cette ressource ? (réglage du joueur, sinon réglage de départ)
function IncomeRules.autoSellEnabled(country: Instance, resourceId: string): boolean
	local value = country:GetAttribute(IncomeRules.autoSellAttribute(resourceId))
	if typeof(value) == "boolean" then
		return value
	end
	return Economy.autoSell.defaults[resourceId] == true
end

-- Stock gardé par la vente automatique : réserve de base + quelques cycles de consommation
-- (needPerCycle : ce que ses usines et ses divisions consomment par cycle)
function IncomeRules.reserve(resourceId: string, needPerCycle: number): number
	local A = Economy.autoSell
	return (A.reserve[resourceId] or A.defaultReserve) + math.ceil(A.needCycles * math.max(0, needPerCycle))
end

-- Quantité vendue automatiquement : ce qui dépasse la réserve (0 si trop peu)
function IncomeRules.surplus(stock: number, reserve: number, maxQuantity: number): number
	local amount = math.min(math.floor(stock - reserve), maxQuantity)
	return if amount >= Economy.autoSell.minQuantity then amount else 0
end

return IncomeRules
