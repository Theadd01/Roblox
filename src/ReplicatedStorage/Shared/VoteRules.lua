--!strict
-- Règles des votes (cahier des charges v2, section 1 ; Config/Council) : fonctions PURES, partagées
-- par le serveur (qui décide) et le client (qui affiche), testées dans Tests/Votes.spec.
--   VoteRules.affinity : affinité d'un pays IA envers celui qui propose (-100 à 100) ;
--   VoteRules.paymentValue : valeur en crédits d'une offre (crédits + ressources au prix du marché) ;
--   VoteRules.chance : probabilité qu'un pays IA vote « oui » ;
--   VoteRules.tally : décompte et résultat (majorité simple, abstentions exclues).

local Council = require(script.Parent:WaitForChild("Config"):WaitForChild("Council")) :: any

export type AffinityInput = {
	relation: string, -- "Allie" | "Guerre" | "Treve" | "Paix" (DiplomacyState.relation)
	reputation: number, -- réputation de celui qui propose (0 à 100)
	commonEnemy: boolean, -- ils combattent un même ennemi
}

export type ChanceInput = {
	affinity: number, -- -100 à 100
	payment: number, -- valeur de l'offre en crédits
	winning: number, -- régions gagnées moins régions perdues dans ses guerres (positif : il gagne)
	war: boolean, -- vote sur la guerre (trêve, paix, cessez-le-feu) : le malus compte en entier
	interest: number?, -- intérêt du pays pour la résolution (-1 à 1, ajouté à la probabilité)
}

local VoteRules = {}

function VoteRules.affinity(input: AffinityInput): number
	local A = Council.affinity
	local value = 0
	if input.relation == "Allie" then
		value += A.ally
	elseif input.relation == "Guerre" then
		value += A.war
	elseif input.relation == "Treve" then
		value += A.truce
	end
	value += (input.reputation - 50) * A.reputationWeight
	if input.commonEnemy then
		value += A.commonEnemy
	end
	return math.clamp(value, -100, 100)
end

-- Valeur d'une offre : crédits, plus les ressources au prix donné par priceOf (nil : ignorée)
function VoteRules.paymentValue(offer: { [string]: number }, currency: string, priceOf: (resourceId: string) -> number?): number
	local value = 0
	for resourceId, amount in offer do
		if amount > 0 then
			if resourceId == currency then
				value += amount
			else
				value += amount * (priceOf(resourceId) or 0)
			end
		end
	end
	return value
end

-- Bonus de probabilité apporté par une offre (rendements décroissants)
function VoteRules.paymentBonus(value: number): number
	local P = Council.chance.payment
	return P.maxBonus * (1 - math.exp(-math.max(0, value) / P.scale))
end

-- Malus de probabilité : le pays est en train de gagner sa guerre
function VoteRules.winningMalus(winning: number, war: boolean): number
	local W = Council.chance.winning
	local malus = W.malus * math.clamp(winning / W.scale, 0, 1)
	return if war then malus else malus * 0.5
end

-- Probabilité qu'un pays IA vote « oui »
function VoteRules.chance(input: ChanceInput): number
	local C = Council.chance
	local p = C.base + input.affinity / 100 * C.affinityWeight
	p += VoteRules.paymentBonus(input.payment)
	p -= VoteRules.winningMalus(input.winning, input.war)
	p += input.interest or 0
	return math.clamp(p, C.minChance, C.maxChance)
end

-- Décompte : votes = pays -> "Pour" | "Contre" | "Abstention" ; adopté à la majorité simple
function VoteRules.tally(votes: { [string]: string }): (number, number, number, boolean)
	local yes, no, abstain = 0, 0, 0
	for _, vote in votes do
		if vote == "Pour" then
			yes += 1
		elseif vote == "Contre" then
			no += 1
		else
			abstain += 1
		end
	end
	return yes, no, abstain, yes > no
end

return VoteRules
