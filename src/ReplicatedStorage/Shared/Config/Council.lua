--!strict
-- Conseil mondial (voir server/Politics/CouncilService) : toutes les `interval` secondes, tous les
-- pays (joueurs et IA) votent une résolution tirée de la situation du monde. Un pays = une voix ;
-- la résolution passe si elle a plus de « pour » que de « contre ». Son effet est réel.

local Council = {
	firstSession = 900, -- premier Conseil à 15 minutes de jeu
	interval = 900, -- puis toutes les 15 minutes
	voteDuration = 90, -- secondes de vote
	resultDuration = 20, -- secondes pendant lesquelles le résultat reste affiché
	lobbyCost = 150, -- crédits pour convaincre un pays IA de changer son vote
	lobbyChance = 0.7, -- chance qu'il accepte (jamais s'il est allié de la cible, pour une sanction)

	-- Effets
	sanctionDuration = 600, -- sanctions : 10 minutes...
	sanctionFee = 0.25, -- ... 25 % de frais sur le marché, et aucun nouveau contrat
	ceasefireDuration = 300, -- cessez-le-feu : aucune nouvelle attaque pendant 5 minutes
	oilTax = 0.2, -- taxe sur le pétrole : son prix bondit de 20 %
	recognitionStability = 10, -- reconnaissance d'une conquête : +10 de stabilité (ou -10 si rejetée)
	humanitarianAid = 1500, -- aide humanitaire : crédits pour le pays le plus affaibli

	-- Résolutions possibles (tirées au hasard parmi celles qui ont du sens à ce moment)
	resolutions = {
		Sanctions = { title = "Sanctions contre {target}", text = "Pendant 10 minutes, {target} paie 25 % de frais sur le marché mondial et ne peut signer aucun contrat." },
		CessezLeFeu = { title = "Cessez-le-feu mondial", text = "Pendant 5 minutes, aucune nouvelle attaque dans le monde." },
		TaxePetrole = { title = "Taxe mondiale sur le pétrole", text = "Le prix du pétrole bondit de 20 % : bon pour les producteurs, mauvais pour les armées motorisées." },
		Reconnaissance = { title = "Reconnaissance de la conquête de {region}", text = "Si elle passe, {target} gagne +10 de stabilité ; sinon il perd 10 de stabilité." },
		AideHumanitaire = { title = "Aide humanitaire pour {target}", text = "{target}, très affaibli, reçoit 1 500 crédits de la communauté internationale." },
	},
}

return Council
