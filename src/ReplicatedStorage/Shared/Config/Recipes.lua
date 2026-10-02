--!strict
-- Chaînes de production : ce qu'une usine consomme et produit pour UN lot (voir Config/Factories).

local Recipes: { [string]: { inputs: { [string]: number }, outputs: { [string]: number } } } = {
	Acier = {
		inputs = { MineraiFer = 2, Charbon = 1 },
		outputs = { Acier = 1 },
	},
	Puces = {
		inputs = { TerresRares = 1, Gaz = 1 },
		outputs = { Puces = 1 },
	},
}

return Recipes
