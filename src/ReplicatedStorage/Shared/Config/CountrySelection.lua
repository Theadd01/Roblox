--!strict
-- Règles de l'écran de choix du pays (version basique).
-- La difficulté dépend de la taille du pays sur la carte (surface en studs²) :
-- les petits pays sont plus difficiles.

local CountrySelection = {
	easyArea = 15000, -- au-dessus : Facile (France, Turquie, Brésil...)
	mediumArea = 3000, -- au-dessus : Moyen (Allemagne, Italie, Japon...) ; en dessous : Difficile

	-- « Recommandé pour débuter » : un pays libre, facile, ni gigantesque
	recommendedMinArea = 15000,
	recommendedMaxArea = 40000,

	-- Points forts et points faibles affichés dans la fiche (production par cycle)
	traits = {
		strengths = {
			{ resource = "Petrole", min = 5, text = "beaucoup de pétrole" },
			{ resource = "Gaz", min = 5, text = "beaucoup de gaz" },
			{ resource = "Nourriture", min = 10, text = "grenier à blé" },
			{ resource = "TerresRares", min = 2, text = "terres rares" },
		},
		weaknesses = {
			{ resource = "Petrole", max = 0, text = "pas de pétrole" },
			{ resource = "Nourriture", max = 2, text = "peu de nourriture" },
		},
		steel = "industrie (fer et charbon)",
		noSteel = "ni fer ni charbon",
		large = "grand territoire",
		small = "petit pays",
		noPort = "pas d'accès à la mer",
	},

	difficultyColors = {
		Facile = Color3.fromRGB(110, 200, 120),
		Moyen = Color3.fromRGB(235, 190, 70),
		Difficile = Color3.fromRGB(230, 95, 85),
	},
}

return CountrySelection
