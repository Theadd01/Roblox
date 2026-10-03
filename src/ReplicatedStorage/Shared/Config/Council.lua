--!strict
-- Conseil mondial et votes (cahier des charges v2, section 1 ; voir server/Politics/CouncilService).
-- SEUL UN JOUEUR lance un vote : une résolution, un événement mondial, une trêve ou la paix. Les
-- IA ne proposent jamais rien ; elles votent. Les pays concernés votent (tous les pays pour une
-- résolution ou un événement ; les deux camps en guerre pour une trêve ou la paix) ; celui qui
-- propose vote « pour ». Un pays = une voix ; ça passe à la majorité simple (plus de « pour » que
-- de « contre », les abstentions ne comptent pas). Le détail des votes est montré aux joueurs.
--
-- Vote d'un pays IA : probabilité de « oui » =
--   base + affinité envers celui qui propose (-100 à 100) x affinityWeight / 100
--   + bonus du paiement offert : payment.maxBonus x (1 - e^(-valeur / payment.scale))
--   - malus s'il est en train de gagner sa guerre (winning.malus, complet à winning.scale régions)
--   + son intérêt pour la résolution (sanctions contre un allié, pétrole...)
-- bornée à [minChance, maxChance]. Celui qui propose paie l'offre (par pays IA) seulement aux pays
-- IA qui votent « oui » (le reste lui est rendu à la fin du vote).

local Council = {
	voteDuration = 30, -- secondes de vote
	resultDuration = 20, -- secondes pendant lesquelles le résultat reste affiché
	proposalCooldown = 45, -- secondes entre deux propositions d'un même joueur
	aiDelay = { min = 1, max = 6 }, -- les pays IA votent après quelques secondes
	lobbyCost = 150, -- crédits pour convaincre un pays IA de changer son vote
	lobbyChance = 0.7, -- chance qu'il accepte (jamais s'il est allié de la cible, pour une sanction)

	-- Probabilité de « oui » d'un pays IA
	chance = {
		base = 0.5,
		affinityWeight = 0.4,
		minChance = 0.03,
		maxChance = 0.97,
		payment = { maxBonus = 0.45, scale = 400 }, -- 400 crédits offerts : +28 % ; 1 000 : +41 %
		winning = { malus = 0.3, scale = 3 }, -- 3 régions gagnées de plus que perdues : -30 %
	},
	-- Affinité d'un pays IA envers celui qui propose (-100 à 100)
	affinity = {
		ally = 60,
		war = -40,
		truce = -15,
		reputationWeight = 0.6, -- (réputation - 50) x 0,6
		commonEnemy = 25,
	},
	paymentSteps = { 0, 100, 250, 500, 1000 }, -- offres proposées (crédits par pays IA qui vote oui)

	-- Effets
	truceDuration = 240, -- trêve : aucune attaque entre les deux camps pendant 4 min, puis la guerre reprend
	sanctionDuration = 600, -- sanctions : 10 minutes...
	sanctionFee = 0.25, -- ... 25 % de frais sur le marché, et aucun nouveau contrat
	ceasefireDuration = 300, -- cessez-le-feu : aucune nouvelle attaque pendant 5 minutes
	oilTax = 0.2, -- taxe sur le pétrole : son prix bondit de 20 %
	recognitionStability = 10, -- reconnaissance d'une conquête : +10 de stabilité (ou -10 si rejetée)
	humanitarianAid = 1500, -- aide humanitaire : crédits pour le pays choisi

	-- Ce qu'un joueur peut proposer. target : il faut choisir un pays ("pays", "ennemi") ou une
	-- région conquise ("conquete") ; war : vote des deux camps en guerre, et le malus « il gagne sa
	-- guerre » compte en entier (à moitié pour les autres votes)
	order = { "Treve", "Paix", "CessezLeFeu", "Sanctions", "AideHumanitaire", "Reconnaissance", "TaxePetrole", "Evenement" },
	resolutions = {
		Treve = { icon = "🕊️", name = "Trêve", target = "ennemi", war = true, title = "Trêve entre {initiator} et {target}", text = "Aucune attaque entre les deux camps pendant 4 minutes ; ensuite, la guerre reprend." },
		Paix = { icon = "🤝", name = "Paix", target = "ennemi", war = true, title = "Paix entre {initiator} et {target}", text = "La guerre entre les deux camps s'arrête, suivie d'une trêve de 3 minutes." },
		CessezLeFeu = { icon = "🏳️", name = "Cessez-le-feu mondial", war = true, title = "Cessez-le-feu mondial", text = "Pendant 5 minutes, aucune nouvelle attaque dans le monde." },
		Sanctions = { icon = "⛔", name = "Sanctions", target = "pays", title = "Sanctions contre {target}", text = "Pendant 10 minutes, {target} paie 25 % de frais sur le marché mondial et ne peut signer aucun contrat." },
		AideHumanitaire = { icon = "❤️", name = "Aide humanitaire", target = "pays", title = "Aide humanitaire pour {target}", text = "{target} reçoit 1 500 crédits de la communauté internationale." },
		Reconnaissance = { icon = "📜", name = "Reconnaissance d'une conquête", target = "conquete", title = "Reconnaissance de la conquête de {region}", text = "Si elle passe, {target} gagne +10 de stabilité ; sinon il perd 10 de stabilité." },
		TaxePetrole = { icon = "🛢️", name = "Taxe mondiale sur le pétrole", title = "Taxe mondiale sur le pétrole", text = "Le prix du pétrole bondit de 20 % : bon pour les producteurs, mauvais pour les armées motorisées." },
		Evenement = { icon = "🌐", name = "Événement mondial", target = "evenement", title = "{event}", text = "{eventText}" },
	},
}

return Council
