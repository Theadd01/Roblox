--!strict
-- Dilemmes de dirigeant (voir server/Politics/DilemmaService) : régulièrement, le joueur reçoit
-- une carte avec deux choix et leurs conséquences. Tous fictifs.
-- condition : situation requise (voir DilemmaService.conditions) ; default : choix appliqué
-- si le joueur ne répond pas à temps.
-- Effets : credits, food, oil, mainResource (sa ressource principale), stability, reputation,
--          morale (moral de toutes ses armées), peace (propose la paix à tous ses ennemis)

local Dilemmas = {
	interval = { min = 180, max = 300 }, -- secondes entre deux cartes pour un même joueur
	firstDelay = 150, -- première carte après 2 min 30 de jeu
	answerTime = 60, -- secondes pour choisir
	startReputation = 50, -- réputation de départ (0 à 100)

	list = {
		{
			id = "GreveAcieries", condition = "hasFactory", default = 2,
			title = "Grève dans les aciéries",
			text = "Les ouvriers de tes usines cessent le travail et réclament de meilleurs salaires.",
			choices = {
				{ label = "Augmenter les salaires", effects = { credits = -300, stability = 3 } },
				{ label = "Réprimer la grève", effects = { stability = -8 } },
			},
		},
		{
			id = "AideAlimentaire", condition = "foodStock", default = 2,
			title = "Un pays voisin demande une aide alimentaire",
			text = "Une mauvaise récolte frappe un voisin : il te demande de partager tes réserves.",
			choices = {
				{ label = "Aider", effects = { food = -50, reputation = 10 } },
				{ label = "Refuser", effects = { reputation = -5 } },
			},
		},
		{
			id = "Gisement", condition = "always", default = 2,
			title = "Découverte d'un gisement",
			text = "Des géologues trouvent un riche gisement, mais la population locale craint pour sa vallée.",
			choices = {
				{ label = "Exploiter tout de suite", effects = { mainResource = 60, stability = -5 } },
				{ label = "Protéger la vallée", effects = { stability = 5 } },
			},
		},
		{
			id = "Veterans", condition = "hasArmy", default = 2,
			title = "Les vétérans réclament une pension",
			text = "Les soldats revenus du front demandent une reconnaissance de la nation.",
			choices = {
				{ label = "Payer la pension", effects = { credits = -250, morale = 10 } },
				{ label = "Refuser", effects = { morale = -10, stability = -3 } },
			},
		},
		{
			id = "CriseCarburant", condition = "oilLow", default = 2,
			title = "Crise du carburant",
			text = "Les réservoirs se vident : tes blindés risquent la panne sèche.",
			choices = {
				{ label = "Acheter en urgence", effects = { credits = -300, oil = 40 } },
				{ label = "Rationner", effects = { stability = -6 } },
			},
		},
		{
			id = "Corruption", condition = "always", default = 2,
			title = "Scandale de corruption",
			text = "Un ministre fictif aurait détourné des fonds publics. La presse s'empare de l'affaire.",
			choices = {
				{ label = "Enquête publique", effects = { credits = -150, stability = 5 } },
				{ label = "Étouffer l'affaire", effects = { reputation = -10, stability = -2 } },
			},
		},
		{
			id = "Investisseur", condition = "always", default = 2,
			title = "Un investisseur étranger frappe à la porte",
			text = "Un consortium propose d'investir chez toi, en échange de privilèges.",
			choices = {
				{ label = "Accepter l'investissement", effects = { credits = 500, reputation = -5 } },
				{ label = "Refuser", effects = { stability = 3 } },
			},
		},
		{
			id = "ManifestationPaix", condition = "atWar", default = 2,
			title = "Manifestation pour la paix",
			text = "Des milliers de personnes défilent dans la capitale pour réclamer la fin de la guerre.",
			choices = {
				{ label = "Promettre la paix", effects = { stability = 6, peace = true } },
				{ label = "Ignorer la foule", effects = { stability = -6, morale = 5 } },
			},
		},
		{
			id = "Recolte", condition = "farmer", default = 1,
			title = "Récolte record",
			text = "Les greniers débordent : que faire de ce surplus ?",
			choices = {
				{ label = "Exporter le surplus", effects = { credits = 300 } },
				{ label = "Constituer des réserves", effects = { food = 100, stability = 3 } },
			},
		},
		{
			id = "Espion", condition = "hasEnemy", default = 2,
			title = "Un espion capturé",
			text = "Tes services arrêtent un agent étranger près d'une base militaire.",
			choices = {
				{ label = "L'échanger discrètement", effects = { reputation = 10 } },
				{ label = "Le juger publiquement", effects = { stability = 5, reputation = -5 } },
			},
		},
	},
}

return Dilemmas
