--!strict
-- Ressources échangeables (voir CLAUDE.md, « Marché mondial »).
-- base = produite directement par les régions ; sinon fabriquée en usine (étape 4).

local Types = require(script.Parent.Parent.Types)

local list: { [string]: Types.Resource } = {
	Petrole = { id = "Petrole", name = "Pétrole", icon = "Pt", base = true, use = "Carburant des blindés, avions, navires" },
	Gaz = { id = "Gaz", name = "Gaz", icon = "Gz", base = true, use = "Énergie des usines" },
	Charbon = { id = "Charbon", name = "Charbon", icon = "Ch", base = true, use = "Production d'acier et d'énergie" },
	MineraiFer = { id = "MineraiFer", name = "Minerai de fer", icon = "Fe", base = true, use = "Production d'acier" },
	Acier = { id = "Acier", name = "Acier", icon = "Ac", base = false, use = "Blindés, navires, usines, artillerie" },
	TerresRares = { id = "TerresRares", name = "Terres rares", icon = "TR", base = true, use = "Production de puces" },
	Puces = { id = "Puces", name = "Puces", icon = "PC", base = false, use = "Avions, drones, missiles, radars" },
	Nourriture = { id = "Nourriture", name = "Nourriture", icon = "No", base = true, use = "Entretien des troupes et stabilité" },
	Munitions = { id = "Munitions", name = "Munitions", icon = "Mu", base = false, use = "Consommées en combat" },
}

local Resources = {
	-- ordre d'affichage
	order = { "Petrole", "Gaz", "Charbon", "MineraiFer", "Acier", "TerresRares", "Puces", "Nourriture", "Munitions" },
	list = list,
	-- monnaie unique du jeu
	currency = { id = "Credits", name = "Crédits", icon = "Cr" },
}

return Resources
