--!strict
-- Règles générales de l'économie.

local Economy = {
	-- Production automatique : toutes les X secondes, chaque région produit pour son propriétaire
	productionInterval = 10,

	-- Stocks de départ de chaque pays (joueur ou IA)
	startingCredits = 1000,
	startingStocks = {
		Nourriture = 50,
	} :: { [string]: number },

	-- Production de base des pays (voir shared/RegionResources) : la MÊME valeur pour tous les
	-- pays, pour que chacun ait sa chance, répartie selon leurs spécialités (Config/ResourceDeposits) :
	-- la France produit surtout du blé, l'Iran du pétrole et du gaz et le minimum de blé...
	-- L'industrie (acier, puces) vient des bâtiments (Config/Factories).
	national = {
		value = 60, -- valeur produite par cycle, en crédits au prix de base du marché (Config/Market)
		foodWeight = { fertile = 8, normal = 4, arid = 1 } :: { [string]: number }, -- poids de la nourriture face aux gisements (1 à 10)
		foodMin = 2, -- nourriture produite au moins par chaque pays, en plus
		maxSpecialties = 3, -- gisements gardés au plus (les plus importants du pays)
		minSpecialtyShare = 0.2, -- un gisement plus faible que 20 % du principal n'est pas gardé
	},
	occupiedProduction = 0.5, -- une région conquise produit moitié moins pour son occupant

	-- Répartition entre un pays et ses territoires (Danemark / Groenland...) : nourriture d'un
	-- territoire = racine de sa surface / foodAreaDivisor, bornée entre foodMin et foodMax,
	-- multipliée par sa fertilité (voir ResourceDeposits)
	foodAreaDivisor = 20,
	foodMin = 1,
	foodMax = 8,
	fertileFactor = 1.6,
	aridFactor = 0.35,

	-- Revenus passifs : de l'argent à chaque cycle de production, sans passer par le marché.
	-- Impôts (tous les pays) : payés par les habitants (Config/Population.taxPerMillion) ; ceux
	-- d'une région conquise paient moitié moins (population hostile) ; le tout suit la stabilité.
	taxes = {
		occupiedFactor = 0.5,
	},
	-- Vente automatique (pays des joueurs ; l'IA vend déjà ses surplus elle-même) : à chaque cycle,
	-- ce qui dépasse la réserve est vendu au prix du marché. Activée au départ pour les ressources
	-- de `defaults` ; le joueur l'active ou la coupe ressource par ressource (onglet Marché).
	autoSell = {
		reserve = { Nourriture = 100, Petrole = 50, Acier = 50, Puces = 10, Munitions = 30 } :: { [string]: number },
		defaultReserve = 40, -- réserve des autres ressources
		needCycles = 6, -- réserve en plus : 6 cycles (1 minute) de ce que consomment ses usines et ses divisions
		minQuantity = 1, -- pas de vente plus petite
		-- achat automatique (tous les pays) : stock visé = 3 cycles de ce que consomment habitants,
		-- divisions et usines ; pas sous 100 crédits, pas au-dessus de 2 fois le prix de base
		buyCycles = 3,
		creditFloor = 100,
		maxBuyPrice = 2,
		defaults = { Petrole = true, Gaz = true, Charbon = true, MineraiFer = true, TerresRares = true, Nourriture = true } :: { [string]: boolean },
	},
}

return Economy
