--!strict
-- Missions quotidiennes : chaque jour (UTC), Missions.perDay missions tirées dans la liste,
-- les mêmes pour tous les joueurs. Elles comptent les actions du joueur, quelle que soit la
-- partie ou le serveur, et donnent de l'expérience de compte (celle du passe de saison).
-- counter : compteur suivi par server/Session/DailyMissions.

export type Mission = {
	id: string,
	text: string, -- {target} : objectif chiffré
	counter: string,
	target: number,
	xp: number,
}

local Missions = {}

Missions.perDay = 3
Missions.saveInterval = 60 -- secondes entre deux sauvegardes d'un joueur dont les missions ont avancé

Missions.pool = {
	{ id = "Ventes", text = "Vends {target} ressources (marché ou contrats)", counter = "sold", target = 150, xp = 150 },
	{ id = "Recettes", text = "Gagne {target} crédits en vendant", counter = "saleCredits", target = 2500, xp = 150 },
	{ id = "Victoires", text = "Gagne {target} batailles", counter = "battlesWon", target = 3, xp = 200 },
	{ id = "Conquetes", text = "Conquiers {target} régions", counter = "conquests", target = 4, xp = 200 }, -- les pays comptent plusieurs régions
	{ id = "Contrats", text = "Signe {target} contrats commerciaux", counter = "contracts", target = 2, xp = 150 },
	{ id = "Usines", text = "Construis {target} bâtiments", counter = "factories", target = 2, xp = 120 },
	{ id = "Recrues", text = "Recrute {target} unités", counter = "recruits", target = 20, xp = 120 },
	{ id = "Conseil", text = "Vote {target} fois au Conseil mondial", counter = "votes", target = 2, xp = 100 },
	{ id = "Objectifs", text = "Termine {target} objectifs nationaux", counter = "objectives", target = 3, xp = 150 },
	{ id = "Temps", text = "Dirige un pays pendant {target} minutes", counter = "minutes", target = 30, xp = 100 },
	{ id = "Classement", text = "Termine une partie dans les 10 premiers", counter = "top10", target = 1, xp = 250 },
	{ id = "Projet", text = "Termine {target} étapes d'un projet décisif", counter = "projectStages", target = 2, xp = 150 },
} :: { Mission }

return Missions
