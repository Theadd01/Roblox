--!strict
-- Commerce entre pays (voir server/Economy/ContractService) : contrats, routes, frais, embargos.
-- Un contrat livre une ressource à chaque cycle de production (Economy.productionInterval),
-- à prix fixe, pendant un nombre de livraisons choisi.

local Trade = {
	-- choix proposés dans l'interface (et seuls acceptés par le serveur)
	quantities = { 5, 10, 20, 50 }, -- unités par livraison
	deliveries = { 6, 12, 30 }, -- nombre de livraisons (une par cycle)
	priceFactors = { 0.9, 1, 1.1, 1.2 }, -- prix unitaire = prix du marché x facteur

	proposalDuration = 60, -- une proposition sans réponse expire au bout de 60 s
	maxContracts = 6, -- contrats (proposés ou actifs) au plus par pays
	maxFailures = 2, -- livraisons manquées de suite (stock ou crédits insuffisants) avant rupture
	resultDelay = 20, -- secondes pendant lesquelles un contrat terminé reste affiché

	-- frais de transport (part de la valeur livrée, payée par l'acheteur)
	seaFee = 0.05, -- voie maritime
	warFee = 0.15, -- en plus, si l'un des deux pays est en guerre
	marketWarFee = 0.1, -- marché mondial : un pays en guerre paie 10 % de plus et reçoit 10 % de moins

	-- IA : contrats proposés aux joueurs (surtout les commerçants)
	aiProposalInterval = 180, -- secondes entre deux propositions d'un même pays IA
	aiPlayerInterval = 90, -- secondes entre deux propositions de l'IA à un même joueur
	aiDeliveries = 12,
}

return Trade
