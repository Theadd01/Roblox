--!strict
-- Déroulé d'une partie (60 à 90 minutes) : durée, phases, crise mondiale, classement final.
-- Voir server/Session/MatchService (horloge, phases, fin, nouvelle partie) et RankingService.

export type Phase = {
	id: string,
	start: number, -- secondes depuis le début de la partie
	icon: string,
	name: string,
	text: string,
	crisis: boolean?, -- une crise mondiale frappe le marché au début de la phase
	aiOffensives: number?, -- offensives IA simultanées permises (sinon Config/AI.maxOffensives)
}

local Match = {}

Match.duration = 75 * 60 -- secondes (entre 60 et 90 minutes)
Match.endScreenDuration = 60 -- secondes d'écran de fin (classement, bilan) avant la nouvelle partie
Match.warnings = { 600, 300, 60 } -- messages « fin de la partie dans 10 min, 5 min, 1 min »

Match.phases = {
	{
		id = "MiseEnPlace",
		start = 0,
		icon = "🗺️",
		name = "Mise en place",
		text = "Choisis ton pays et remplis ton premier objectif. Protection de départ : 5 minutes.",
	},
	{
		id = "Essor",
		start = 5 * 60,
		icon = "🏭",
		name = "Essor",
		text = "Construis ton économie : premières ventes, premières usines, premier général.",
	},
	{
		id = "Conflits",
		start = 15 * 60,
		icon = "⚔️",
		name = "Premiers conflits",
		text = "Le Conseil mondial se réunit. Alliances, premières guerres, premiers dilemmes.",
	},
	{
		id = "Crise",
		start = 35 * 60,
		icon = "🌋",
		name = "Crise mondiale",
		text = "Un choc frappe le marché mondial et les guerres s'ouvrent partout.",
		crisis = true,
	},
	{
		id = "Final",
		start = 50 * 60,
		icon = "🏁",
		name = "Course finale",
		text = "La course aux projets décisifs commence (onglet Industrie) : le premier à terminer un projet gagne un gros bonus. Grandes offensives !",
		aiOffensives = 4,
	},
} :: { Phase }

-- Crises possibles (une seule, tirée au début de la phase « Crise mondiale ») : choc sur un prix
Match.crises = {
	{ resource = "Petrole", factor = 1.4, title = "Un détroit est bloqué : le pétrole s'envole (+40 %)" },
	{ resource = "Puces", factor = 1.35, title = "Pénurie mondiale de puces : +35 %" },
	{ resource = "Nourriture", factor = 1.3, title = "Sécheresse historique : la nourriture flambe (+30 %)" },
	{ resource = "Gaz", factor = 1.4, title = "Un gazoduc géant est coupé : le gaz s'envole (+40 %)" },
	{ resource = "Acier", factor = 0.7, title = "Surproduction d'acier : les cours s'effondrent (−30 %)" },
}

-- Classement final : quatre domaines notés de 0 à 100 (100 = le meilleur pays du domaine),
-- puis pondérés pour le score total
Match.scoreWeights = { Territoire = 0.3, Economie = 0.25, Militaire = 0.25, Commerce = 0.2 }
Match.domains = {
	{ id = "Territoire", icon = "🗺️", name = "Territoire" },
	{ id = "Economie", icon = "💰", name = "Économie" },
	{ id = "Militaire", icon = "⚔️", name = "Puissance militaire" },
	{ id = "Commerce", icon = "📦", name = "Commerce" },
}
Match.contractValue = 150 -- un contrat signé compte comme 150 crédits de ventes (domaine Commerce)
Match.rankingSize = 10 -- pays affichés dans le classement (plus le rang de chaque joueur)

-- Difficulté de la partie (cahier des charges v2) : choisie dans Studio par l'attribut
-- « Difficulte » de Workspace (Facile, Normal ou Difficile), sinon `difficulty`.
--   researchSpeed : vitesse de recherche des pays IA (les joueurs : 1) ;
--   generalDefeat : un général dont toute l'armée est détruite est « Blesse » (hors combat un
--     moment, Config/Military.generals.woundedSeconds) ou « Mort » (il disparaît).
Match.difficulty = "Normal"
Match.difficulties = {
	Facile = { researchSpeed = 0.5, generalDefeat = "Blesse" },
	Normal = { researchSpeed = 0.75, generalDefeat = "Blesse" },
	Difficile = { researchSpeed = 1, generalDefeat = "Mort" },
}

return Match
