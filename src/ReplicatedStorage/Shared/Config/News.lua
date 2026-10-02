--!strict
-- Journal télévisé mondial (voir server/News/NewsService) : flashs d'info tirés des vraies
-- actions des pays (guerres, paix, alliances, conquêtes, révoltes, flambées des prix...).

local News = {
	keep = 30, -- flashs gardés (les plus récents)
	marketSwing = 0.15, -- variation d'un prix en une minute qui fait la une (15 %)
	marketCooldown = 180, -- secondes avant une nouvelle une sur la même ressource
	tickerSpeed = 80, -- vitesse du bandeau défilant (pixels par seconde)
	tickerCount = 5, -- flashs qui défilent dans le bandeau

	-- « le prix du pétrole... »
	resources = {
		Petrole = "du pétrole",
		Gaz = "du gaz",
		Charbon = "du charbon",
		MineraiFer = "du minerai de fer",
		Acier = "de l'acier",
		TerresRares = "des terres rares",
		Puces = "des puces",
		Nourriture = "de la nourriture",
		Munitions = "des munitions",
	} :: { [string]: string },
}

return News
