--!strict
-- Apparence des unités (soldats, véhicules) : couleurs dérivées de la couleur du pays.
-- Chaque pièce d'un modèle porte un attribut « Teinte » qui dit comment la colorer.

local UnitStyles = {
	-- Teinte militaire de base (kaki) mélangée à la couleur du pays
	military = Color3.fromRGB(78, 84, 58),

	-- Pour chaque teinte : part de couleur du pays (mix) et assombrissement (shade)
	tints = {
		Uniforme = { mix = 0.45, shade = 1.0 },
		Pantalon = { mix = 0.45, shade = 0.78 },
		Gilet = { mix = 0.25, shade = 0.72 },
		Casque = { mix = 0.35, shade = 0.85 },
		Sac = { mix = 0.15, shade = 0.9 },
		Principale = { mix = 0.5, shade = 1.0 }, -- coque et tourelle des véhicules
		Secondaire = { mix = 0.5, shade = 0.78 }, -- canon, détails
		Drapeau = { mix = 1, shade = 1.0 }, -- couleur pure du pays
	},

	-- Teintes fixes, identiques pour tous les pays
	fixed = {
		Peau = Color3.fromRGB(206, 152, 115),
		Bottes = Color3.fromRGB(35, 32, 30),
		Arme = Color3.fromRGB(40, 40, 42),
		Chenilles = Color3.fromRGB(45, 45, 48),
		Roues = Color3.fromRGB(72, 72, 75),
		Galons = Color3.fromRGB(232, 190, 72), -- épaulettes et insigne des généraux
		Hampe = Color3.fromRGB(110, 80, 52), -- mât du drapeau
	},

	-- Animation de marche des généraux en déplacement (animation R15 par défaut de Roblox)
	walkAnimation = "rbxassetid://507777826",

	-- Animation d'attente des soldats (animation R15 par défaut de Roblox)
	idleAnimation = "rbxassetid://507766388",
}

return UnitStyles
