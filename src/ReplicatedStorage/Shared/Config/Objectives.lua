--!strict
-- Objectifs nationaux (voir server/Session/ObjectivesService) : chaque pays suit une chaîne
-- d'objectifs tirée de sa géographie (sa ressource principale, ses voisins, sa taille),
-- avec une récompense à chaque étape. Les premiers se font en moins de 2 minutes.
-- kind : ce qui est mesuré
--   sold (unités vendues de sa ressource principale), factories (bâtiments construits), factoryLevels,
--   troops (troupes dans ses armées), contracts (contrats signés), bloc (être dans un bloc),
--   credits (crédits en stock), conquer (prendre une région voisine précise),
--   hold (ne perdre aucune région pendant `target` secondes), exportRank (rang mondial des ventes)
-- Textes : {target}, {resource} (« 🛢️ Pétrole »), {of} (« du pétrole »), {region} (« la Moldavie »)

local Objectives = {
	checkInterval = 2, -- secondes entre deux vérifications

	-- chaîne commune ; « conquer » est remplacé par « hold » pour les petits pays
	chain = {
		{ kind = "sold", target = 30, text = "Vends {target} {resource} au marché ou par contrat", reward = { Credits = 300 } },
		{ kind = "factories", target = 1, text = "Construis un bâtiment", reward = { Credits = 400 } },
		{ kind = "troops", target = 6, text = "Lève une armée de {target} troupes", reward = { Credits = 300, Nourriture = 60 } },
		{ kind = "contracts", target = 1, text = "Signe un contrat commercial avec un autre pays", reward = { Credits = 500 } },
		{ kind = "factoryLevels", target = 3, text = "Atteins {target} niveaux de bâtiments", reward = { Acier = 30, Credits = 300 } },
		{ kind = "bloc", target = 1, text = "Rejoins ou fonde un bloc d'alliance", reward = { Credits = 600 } },
		{ kind = "conquer", target = 1, text = "Prends {region}", reward = { Credits = 1000 } },
		{ kind = "exportRank", target = 3, text = "Deviens un des {target} premiers exportateurs mondiaux {of}", reward = { Credits = 1500 } },
	},
	hold = { kind = "hold", target = 600, text = "Défends ton territoire : ne perds aucune région pendant 10 minutes", reward = { Credits = 1000 } },
	soldCycles = 6, -- la première vente demande environ 6 cycles de production...
	soldMin = 10, -- ... au moins 10 unités (et au plus le but du modèle)
	smallArea = 3000, -- en dessous (surface de départ), un pays reçoit « hold » à la place de « conquer »
}

return Objectives
