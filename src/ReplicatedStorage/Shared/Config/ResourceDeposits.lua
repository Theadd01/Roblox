--!strict
-- Spécialités des pays, inspirées de la géographie réelle (grands producteurs mondiaux).
-- Chiffre = importance du gisement pour le pays (1 à 10) : chaque pays produit la même valeur
-- (Config/Economy.national), partagée entre la nourriture (selon sa fertilité, listes plus bas)
-- et ses gisements les plus importants (voir shared/RegionResources).

local ResourceDeposits = {
	deposits = {
		Petrole = {
			USA = 10, SAU = 10, RUS = 9, IRQ = 7, CAN = 6, IRN = 6, ARE = 6, CHN = 5, BRA = 5, KWT = 5,
			VEN = 4, NOR = 3, MEX = 3, KAZ = 3, QAT = 3, NGA = 3, DZA = 2, LBY = 2, AGO = 2, OMN = 2,
			AZE = 2, GBR = 2, COL = 2, ECU = 1, EGY = 1, MYS = 1, IDN = 1, ARG = 1, IND = 1, GAB = 1,
			COG = 1, TKM = 1, SDN = 1, SSD = 1, TTO = 1, YEM = 1, SYR = 1, TCD = 1, GHA = 1, GNQ = 1,
			BRN = 1, VNM = 1, AUS = 1, DNK = 1, ROU = 1, TUN = 1, PER = 1, CMR = 1,
		},
		Gaz = {
			USA = 10, RUS = 10, IRN = 7, QAT = 6, CHN = 5, CAN = 5, AUS = 5, NOR = 5, SAU = 4, DZA = 3,
			TKM = 3, ARE = 2, MYS = 2, IDN = 2, EGY = 2, UZB = 2, NGA = 2, ARG = 2, AZE = 2, OMN = 2,
			NLD = 2, KAZ = 2, MEX = 1, GBR = 1, TTO = 1, IND = 1, PAK = 1, THA = 1, BOL = 1, BRN = 1,
			LBY = 1, UKR = 1, VEN = 1, ROU = 1, PER = 1, KWT = 1, IRQ = 1, MMR = 1, BGD = 1, ISR = 1,
		},
		Charbon = {
			CHN = 10, IND = 8, IDN = 6, AUS = 6, USA = 5, RUS = 5, ZAF = 4, KAZ = 3, POL = 3, DEU = 2,
			COL = 2, UKR = 2, MNG = 2, PRK = 2, TUR = 1, VNM = 1, CAN = 1, CZE = 1, SRB = 1, GRC = 1,
			BGR = 1, MOZ = 1, BWA = 1, ZWE = 1, PHL = 1, THA = 1, PAK = 1, UZB = 1, MEX = 1, BRA = 1,
			ROU = 1, BIH = 1, IRN = 1, NZL = 1, CHL = 1, GBR = 1, ESP = 1,
		},
		MineraiFer = {
			AUS = 10, BRA = 8, CHN = 5, IND = 5, RUS = 3, UKR = 3, ZAF = 2, CAN = 2, IRN = 2, SWE = 2,
			USA = 2, KAZ = 1, MRT = 1, CHL = 1, MEX = 1, PER = 1, VEN = 1, TUR = 1, MNG = 1, NOR = 1,
			LBR = 1, GIN = 1, SLE = 1, NCL = 1, VNM = 1, MYS = 1, PRK = 1, GAB = 1, EGY = 1, DZA = 1,
		},
		TerresRares = {
			CHN = 10, USA = 3, MMR = 3, AUS = 3, COD = 3, RUS = 2, VNM = 2, BRA = 2, IND = 2, GRL = 2,
			MDG = 1, THA = 1, KAZ = 1, ZAF = 1, TZA = 1, CAN = 1, MWI = 1, BDI = 1, RWA = 1, NAM = 1,
			CHL = 1, ARG = 1, BOL = 1, MNG = 1,
		},
	} :: { [string]: { [string]: number } },

	-- Greniers du monde : nourriture x Economy.fertileFactor
	fertile = {
		"USA", "CHN", "IND", "BRA", "ARG", "FRA", "UKR", "CAN", "IDN", "THA", "VNM", "DEU", "POL",
		"MEX", "TUR", "NGA", "PAK", "BGD", "EGY", "ITA", "ESP", "ROU", "HUN", "NLD", "DNK", "IRL",
		"NZL", "URY", "PRY", "MYS", "PHL", "MMR", "KHM", "GBR", "RUS", "KAZ", "AUS",
	},
	-- Déserts et régions polaires : nourriture x Economy.aridFactor
	arid = {
		"GRL", "SAU", "LBY", "MRT", "NER", "MLI", "TCD", "ARE", "QAT", "KWT", "OMN", "YEM", "JOR",
		"TKM", "MNG", "NAM", "BWA", "ATF", "DZA", "DJI", "ERI", "SOM", "ISL",
	},
}

return ResourceDeposits
