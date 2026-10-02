--!strict
-- Règles politiques : stabilité intérieure, opinion publique, révoltes, leader et coalitions.
-- (voir server/Politics/Stability et server/Politics/BalanceService)

local Politics = {
	startingStability = 100, -- en pourcentage
	-- couleurs d'affichage de la stabilité selon son niveau
	stabilityColors = {
		{ min = 60, color = Color3.fromRGB(120, 220, 130) },
		{ min = 30, color = Color3.fromRGB(240, 170, 70) },
		{ min = 0, color = Color3.fromRGB(235, 95, 85) },
	},

	-- Évolution de la stabilité (points ; « par cycle » = par cycle de production)
	stability = {
		recovery = 0.5, -- par cycle, en paix et sans pénurie (jusqu'à 100)
		-- (un pays compte plusieurs régions, façon Hearts of Iron : chacune pèse peu)
		regionLost = 4, -- une région perdue
		regionWon = 1, -- une région conquise (fierté nationale)
		unitLost = 0.4, -- par unité perdue au combat
		shortage = 1, -- par cycle et par ressource qui manque à ses armées
		warWearinessAfter = 300, -- secondes de guerre avant la lassitude...
		warWeariness = 0.3, -- ... puis, par cycle et par guerre qui dure
		maxWarWeariness = 1,
		freeConquests = 8, -- au-delà de ce nombre de régions conquises, le pays s'étend trop :
		overextension = 0.05, -- par cycle et par région conquise en trop
	},

	-- Opinion publique : effets de la stabilité (voir shared/StabilityRules)
	effects = {
		productionMin = 0.5, -- production x (0,5 + stabilité / 200) : 100 % -> x1, 0 % -> x0,5
		recruitAbove = 50, -- en dessous de 50 % de stabilité, recruter coûte plus cher...
		recruitMaxExtra = 0.5, -- ... jusqu'à +50 % de crédits à 0 %
	},

	-- Révoltes : sous ce seuil, chaque région conquise peut se soulever et revenir à son pays
	revolt = {
		below = 20,
		chance = 0.015, -- par cycle et par région conquise
		militia = 1, -- divisions de milice levées dans la région libérée
	},

	-- Gouvernement en exil et résistance (voir server/Session/ExileService)
	exile = {
		resistanceCost = 200, -- crédits pour financer la résistance dans une de ses régions perdues...
		resistanceGain = 20, -- ... qui gagne 20 points
		resistanceDecay = 1, -- points perdus à chaque cycle de production
		uprisingAt = 100, -- à 100 points, la région se soulève et revient à son pays
		uprisingMilitia = 2, -- divisions de milice levées dans la région libérée
		aiInterval = 60, -- les pays IA en exil financent la résistance toutes les 60 s
	},

	-- Leader et mécanismes de retour (voir BalanceService)
	balance = {
		interval = 30, -- secondes entre deux calculs de puissance
		regionWeight = 3, -- puissance = régions x 3 + troupes + divisions x 10 + crédits / 200
		divisionWeight = 10, -- une division à pleine force compte comme 10 troupes
		creditsDivisor = 200,
		leaderRatio = 1.5, -- le leader doit dépasser le deuxième d'au moins 50 %...
		leaderMinRegions = 10, -- ... posséder au moins 10 régions...
		leaderMinConquests = 5, -- ... dont au moins 5 conquises (les territoires de départ ne suffisent pas)
		coalitionBonus = 0.3, -- envie des IA de s'allier contre le leader (score d'alliance)
		aidPerLostRegion = 4, -- aide internationale : crédits par cycle et par région perdue...
		aidMax = 40, -- ... au plus
		underdogMilitia = 1.3, -- un pays qui a perdu des régions : ses miliciens se battent 30 % mieux
	},
}

return Politics
