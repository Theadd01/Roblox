--!strict
-- Marché mondial : prix de base, et règles des prix dynamiques (offre et demande).
--   - Chaque achat fait monter le prix, chaque vente le fait baisser : acheter la
--     « profondeur » (liquidity) d'une ressource multiplie son prix par e (environ 2,7).
--   - Toutes les priceInterval secondes, le prix revient un peu vers son prix de base
--     (reversion) et bouge au hasard (volatility), puis il est ajouté à l'historique.

local Market = {
	basePrices = {
		Petrole = 12,
		Gaz = 8,
		Charbon = 5,
		MineraiFer = 6,
		Acier = 20,
		TerresRares = 25,
		Puces = 60,
		Nourriture = 3,
		Munitions = 15,
	} :: { [string]: number },

	-- Profondeur du marché (unités) : plus elle est grande, moins un échange fait bouger le prix
	liquidity = {
		Petrole = 500,
		Gaz = 600,
		Charbon = 800,
		MineraiFer = 800,
		Acier = 300,
		TerresRares = 200,
		Puces = 120,
		Nourriture = 1500,
		Munitions = 300,
	} :: { [string]: number },

	sellRatio = 0.9, -- la revente rapporte 90 % de la valeur (évite les allers-retours gratuits)
	quantities = { 1, 10, 100 }, -- choix proposés dans l'interface
	maxQuantity = 10000, -- quantité maximale par échange

	priceInterval = 10, -- secondes entre deux recalculs des prix
	reversion = 0.04, -- part de l'écart au prix de base rattrapée à chaque recalcul
	volatility = 0.012, -- ampleur des variations aléatoires à chaque recalcul
	minFactor = 0.25, -- le prix reste entre 25 %...
	maxFactor = 5, -- ... et 500 % du prix de base
	historyLength = 60, -- points gardés pour le graphique (60 x 10 s = 10 minutes)
	variationPoints = 6, -- variation affichée : par rapport à il y a 6 points (1 minute)
}

return Market
