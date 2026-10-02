--!strict
-- Population des pays (voir shared/PopulationRules et server/Economy/PopulationService).
-- Chaque région a ses habitants (en milliers) ; la population d'un pays est la somme de ses régions.
-- La population mange (nourriture), grandit quand elle mange à sa faim, paie les impôts et fournit
-- les soldats (Config/Divisions.manpower) ; elle fixe aussi le nombre de divisions possibles.
-- Tous les pays démarrent avec presque autant d'habitants : chacun garde sa chance.

local Population = {
	start = 10000, -- habitants de départ d'un pays, en milliers (10 millions)...
	spread = 0.1, -- ... nuancés selon sa population réelle (échelle logarithmique, `real`) :
	minFactor = 0.85, -- au moins 85 %...
	maxFactor = 1.2, -- ... et au plus 120 % de `start`
	capitalWeight = 2, -- la région de la capitale compte double (grandes villes)...
	territoryWeight = 0.25, -- ... un territoire lointain (Groenland, Guyane...) compte peu

	-- À chaque cycle de production
	foodPerMillion = 0.6, -- nourriture mangée par million d'habitants
	growth = 0.0005, -- croissance par cycle d'une population qui mange à sa faim (x stabilité)
	maxGrowth = 1.6, -- une région ne dépasse pas 1,6 fois sa population de départ
	famine = 0.004, -- perte par cycle quand la nourriture manque
	taxPerMillion = 4.5, -- impôts : crédits par million d'habitants (voir shared/IncomeRules)

	-- Armée
	divisionsPerMillion = 2, -- divisions qu'un pays peut avoir par million d'habitants
	minDivisions = 6,
	maxDivisions = 40,

	-- Population réelle approximative (millions) : sert seulement à nuancer la population de départ
	real = {
		AFG = 41, AGO = 36, ALB = 2.8, ARE = 9.5, ARG = 46, ARM = 2.8, AUS = 26, AUT = 9.1, AZE = 10.1, BDI = 13,
		BEL = 11.7, BEN = 13.7, BFA = 23, BGD = 172, BGR = 6.4, BHS = 0.41, BIH = 3.2, BLR = 9.2, BLZ = 0.41, BOL = 12.4,
		BRA = 216, BRN = 0.45, BTN = 0.78, BWA = 2.6, CAF = 5.7, CAN = 39, CHE = 8.8, CHL = 19.6, CHN = 1410, CIV = 28,
		CMR = 28, COD = 102, COG = 6.1, COL = 52, CRI = 5.2, CUB = 11.2, CYP = 1.3, CZE = 10.9, DEU = 84, DJI = 1.1,
		DNK = 5.9, DOM = 11.3, DZA = 45.6, ECU = 18, EGY = 112, ERI = 3.7, ESP = 48, EST = 1.4, ETH = 126, FIN = 5.6,
		FJI = 0.93, FRA = 68, GAB = 2.4, GBR = 67, GEO = 3.7, GHA = 34, GIN = 14, GMB = 2.8, GNB = 2.2, GNQ = 1.7,
		GRC = 10.4, GTM = 18, GUY = 0.81, HND = 10.6, HRV = 3.9, HTI = 11.7, HUN = 9.6, IDN = 278, IND = 1430, IRL = 5.2,
		IRN = 89, IRQ = 45, ISL = 0.39, ISR = 9.8, ITA = 59, JAM = 2.8, JOR = 11.3, JPN = 124, KAZ = 20, KEN = 55,
		KGZ = 7, KHM = 17, KOR = 52, KOS = 1.8, KWT = 4.3, LAO = 7.6, LBN = 5.4, LBR = 5.4, LBY = 6.9, LKA = 22,
		LSO = 2.3, LTU = 2.9, LUX = 0.66, LVA = 1.9, MAR = 37.8, MDA = 2.5, MDG = 30, MEX = 128, MKD = 1.8, MLI = 23,
		MLT = 0.54, MMR = 54, MNE = 0.62, MNG = 3.4, MOZ = 34, MRT = 4.9, MWI = 21, MYS = 34, NAM = 2.6, NER = 27,
		NGA = 224, NIC = 7, NLD = 17.9, NOR = 5.5, NPL = 30.9, NZL = 5.2, OMN = 4.6, PAK = 240, PAN = 4.5, PER = 34,
		PHL = 117, PNG = 10.3, POL = 37.6, PRK = 26, PRT = 10.4, PRY = 6.9, PSE = 5.4, QAT = 2.7, ROU = 19, RUS = 144,
		RWA = 14, SAU = 36.9, SDN = 48, SEN = 18, SLB = 0.74, SLE = 8.8, SLV = 6.4, SOM = 18, SRB = 6.6, SSD = 11,
		SUR = 0.62, SVK = 5.4, SVN = 2.1, SWE = 10.5, SWZ = 1.2, SYR = 23, TCD = 18, TGO = 9, THA = 72, TJK = 10,
		TKM = 6.5, TLS = 1.4, TTO = 1.5, TUN = 12.5, TUR = 85, TWN = 23.4, TZA = 67, UGA = 48, UKR = 37, URY = 3.4,
		USA = 335, UZB = 36, VEN = 28, VNM = 99, VUT = 0.33, YEM = 34, ZAF = 60, ZMB = 20.6, ZWE = 16,
	} :: { [string]: number },
}

return Population
