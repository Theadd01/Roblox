--!strict
-- Terrain des régions (SYSTEME_MILITAIRE.md, sections 5.3 et 5.5) : largeur de bataille,
-- malus de l'attaquant, vitesse, capacité de ravitaillement ; franchissement de rivière.
-- Le terrain de chaque région et les rivières entre régions voisines sont générés dans
-- Config/RegionTerrain (tools/terrain.js).

export type TerrainType = {
	id: string,
	name: string,
	icon: string,
	width: number, -- largeur de bataille de base...
	widthPerDirection: number, -- ... et en plus par direction d'attaque supplémentaire
	attack: number, -- modificateur d'attaque de l'attaquant (-0,5 = -50 %)
	speed: number, -- vitesse des divisions qui y entrent (x)
	supply: number, -- capacité de ravitaillement : divisions entretenues sans attrition
}

local Terrain = {
	order = { "Plaine", "Desert", "Ville", "Foret", "Collines", "Montagne", "Marais" },
	types = {
		Plaine = { id = "Plaine", name = "Plaine", icon = "🌾", width = 6, widthPerDirection = 3, attack = 0, speed = 1, supply = 6 },
		Desert = { id = "Desert", name = "Désert", icon = "🏜️", width = 6, widthPerDirection = 3, attack = 0, speed = 0.9, supply = 2 },
		Ville = { id = "Ville", name = "Ville", icon = "🏙️", width = 6, widthPerDirection = 3, attack = -0.3, speed = 0.9, supply = 8 },
		Foret = { id = "Foret", name = "Forêt", icon = "🌲", width = 5, widthPerDirection = 2, attack = -0.25, speed = 0.8, supply = 4 },
		Collines = { id = "Collines", name = "Collines", icon = "⛰️", width = 5, widthPerDirection = 2, attack = -0.25, speed = 0.8, supply = 4 },
		Montagne = { id = "Montagne", name = "Montagne", icon = "🏔️", width = 4, widthPerDirection = 2, attack = -0.5, speed = 0.6, supply = 3 },
		Marais = { id = "Marais", name = "Marais", icon = "🌿", width = 4, widthPerDirection = 2, attack = -0.4, speed = 0.5, supply = 3 },
	} :: { [string]: TerrainType },
	default = "Plaine",

	-- Franchissement de rivière (attaque à travers une rivière qui sépare les deux régions)
	rivers = {
		Riviere = { name = "Rivière", attack = -0.3 },
		Fleuve = { name = "Grand fleuve", attack = -0.5 },
	},
}

return Terrain
