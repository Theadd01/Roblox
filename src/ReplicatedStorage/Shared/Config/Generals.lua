--!strict
-- Traits des chefs (généraux, chefs d'escadrille, amiraux), tous fictifs.
-- Un chef reçoit un trait quand il est nommé, un second en atteignant secondTraitLevel et un troisième
-- à thirdTraitLevel (généraux de divisions, SYSTEME_MILITAIRE.md 4.1 : 1 à 3 traits).
-- Un trait se renforce avec le niveau du chef : bonus = base + perLevel x (niveau - 1).
-- effect : ce que le trait modifie (voir shared/GeneralTraits) :
--   attack (puissance en attaque), defense (puissance en défendant sa région),
--   Blindes / Artillerie (puissance d'un type de troupe), upkeep (entretien en moins),
--   morale (organisation perdue au combat en moins), speed (durée des trajets en moins),
--   experience (expérience gagnée en plus), rough (attaque et défense en montagne, collines, forêt
--   et marais), encirclement (attaque contre un ennemi coupé de son ravitaillement),
--   planning (bonus de planification plus fort)

export type Trait = {
	id: string,
	name: string,
	icon: string,
	effect: string,
	base: number,
	perLevel: number,
	kinds: { string }, -- sortes de forces qui peuvent l'avoir
	text: string, -- description, avec {n} pour le pourcentage
}

local ALL = { "Terre", "Air", "Mer" }

local Generals = {
	secondTraitLevel = 3,
	thirdTraitLevel = 5,
	order = { "DefenseurTenace", "FoudreDeGuerre", "ExpertBlindes", "MaitreArtilleur", "Logisticien", "Meneur", "Stratege", "Veteran", "Montagnard", "MaitreEncerclement", "Planificateur" },
	traits = {
		DefenseurTenace = { id = "DefenseurTenace", name = "Défenseur tenace", icon = "🛡️", effect = "defense", base = 0.15, perLevel = 0.05, kinds = ALL, text = "+{n} % en défense" },
		FoudreDeGuerre = { id = "FoudreDeGuerre", name = "Offensif", icon = "⚡", effect = "attack", base = 0.1, perLevel = 0.04, kinds = ALL, text = "+{n} % en attaque" },
		ExpertBlindes = { id = "ExpertBlindes", name = "Expert blindés", icon = "🚜", effect = "Blindes", base = 0.2, perLevel = 0.05, kinds = { "Terre" }, text = "+{n} % de puissance pour les blindés" },
		MaitreArtilleur = { id = "MaitreArtilleur", name = "Maître artilleur", icon = "💥", effect = "Artillerie", base = 0.2, perLevel = 0.05, kinds = { "Terre" }, text = "+{n} % de puissance pour l'artillerie" },
		Logisticien = { id = "Logisticien", name = "Logisticien", icon = "📦", effect = "upkeep", base = 0.2, perLevel = 0.05, kinds = ALL, text = "-{n} % d'entretien" },
		Meneur = { id = "Meneur", name = "Meneur d'hommes", icon = "🎖️", effect = "morale", base = 0.25, perLevel = 0.05, kinds = ALL, text = "-{n} % d'organisation perdue au combat" },
		Stratege = { id = "Stratege", name = "Stratège", icon = "🧭", effect = "speed", base = 0.15, perLevel = 0.03, kinds = ALL, text = "-{n} % de temps de trajet" },
		Veteran = { id = "Veteran", name = "Vétéran", icon = "⭐", effect = "experience", base = 0.5, perLevel = 0.1, kinds = ALL, text = "+{n} % d'expérience gagnée" },
		Montagnard = { id = "Montagnard", name = "Montagnard", icon = "🏔️", effect = "rough", base = 0.15, perLevel = 0.05, kinds = { "Terre" }, text = "+{n} % en montagne, collines, forêt et marais" },
		MaitreEncerclement = { id = "MaitreEncerclement", name = "Maître de l'encerclement", icon = "🔗", effect = "encirclement", base = 0.2, perLevel = 0.05, kinds = { "Terre" }, text = "+{n} % d'attaque contre un ennemi coupé de son ravitaillement" },
		Planificateur = { id = "Planificateur", name = "Planificateur", icon = "🗺️", effect = "planning", base = 0.25, perLevel = 0.05, kinds = { "Terre" }, text = "+{n} % de bonus de planification" },
	} :: { [string]: Trait },
	maxBonus = 0.6, -- aucun bonus ne dépasse 60 %
}

return Generals
