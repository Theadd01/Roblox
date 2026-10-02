--!strict
-- Réglages visuels de la carte du monde : hauteurs, couleurs, reliefs, étiquettes, caméra, lumière.

local Types = require(script.Parent.Parent.Types)

local function range(name: string, height: number, points: { { number } }): Types.MountainRange
	local list = {}
	for _, p in points do
		table.insert(list, { lon = p[1], lat = p[2] })
	end
	return { name = name, height = height, points = list }
end

local MapSettings = {
	-- Hauteurs (studs) : l'océan est à 0, les régions jouables sont légèrement surélevées
	oceanTop = 0,
	neutralLandTop = 1.2,
	regionTop = 2.0,
	tableMargin = 60, -- bande d'océan autour de la carte
	frameWidth = 40, -- cadre en bois de la table

	-- Couleurs
	oceanColor = Color3.fromRGB(18, 48, 73),
	oceanTropicColor = Color3.fromRGB(25, 84, 96),
	oceanColdColor = Color3.fromRGB(48, 79, 103),
	oceanLabelColor = Color3.fromRGB(132, 180, 194),
	neutralLandColor = Color3.fromRGB(143, 139, 119),
	gridColor = Color3.fromRGB(87, 137, 154),
	gridMajorColor = Color3.fromRGB(148, 184, 188),
	borderColor = Color3.fromRGB(24, 29, 36), -- frontière entre deux pays
	regionBorderColor = Color3.fromRGB(34, 40, 50), -- limite entre deux régions d'un même pays (trait fin)
	coastColor = Color3.fromRGB(92, 139, 158),
	frameColor = Color3.fromRGB(58, 42, 32),
	frameTrimColor = Color3.fromRGB(188, 151, 72),
	floorColor = Color3.fromRGB(12, 15, 20),
	mountainColor = Color3.fromRGB(101, 94, 82),
	snowColor = Color3.fromRGB(222, 229, 232),
	cityColor = Color3.fromRGB(213, 205, 185),
	cityRoofColor = Color3.fromRGB(56, 61, 66),
	capitalBaseColor = Color3.fromRGB(225, 179, 62),
	capitalCoreColor = Color3.fromRGB(35, 40, 47),
	townBaseColor = Color3.fromRGB(153, 158, 162),

	-- Quadrillage façon carte d'état-major (degrés)
	gridStep = 15,
	gridMajorStep = 30,

	-- Reliefs : distance entre deux sommets, hauteur à partir de laquelle il y a de la neige
	mountainSpacing = 10,
	snowHeight = 9,

	-- Étiquettes : noms des régions de près, noms des pays de loin (plus le pays est grand, plus son
	-- nom est gros et visible de loin)
	labels = {
		sizeMin = 13,
		sizeMax = 28,
		sizePerStud = 1 / 30, -- taille du texte ajoutée par stud de « largeur » du pays
		distancePerStud = 7, -- distance de visibilité par stud de « largeur » du pays
		distanceMin = 160,
		cityDistance = 220, -- les noms de villes n'apparaissent que de près
		regionDistance = 520, -- distance de visibilité des noms de régions
		countryHeight = 430, -- caméra plus haute que ça : noms des pays au lieu de ceux des régions
	},

	-- Caméra (distances en studs, angles en degrés)
	camera = {
		minDistance = 40,
		maxDistance = 2400,
		startDistance = 700,
		startFocus = { lon = 15, lat = 45 },
		attractDistance = 1300, -- survol automatique derrière l'écran titre
		pitchNear = 48, -- inclinaison quand on est proche
		pitchFar = 80, -- presque vu du dessus quand on est loin
		zoomStep = 0.15, -- part de la distance gagnée par cran de molette
		smoothing = 12, -- vitesse de lissage (plus grand = plus rapide)
	},

	-- Lumière : pas de brume (la carte doit rester lisible de très loin)
	-- et pas de reflets du ciel qui délavent les couleurs.
	-- Soleil de midi, au sud : la caméra regarde vers le nord, le reflet du soleil
	-- tombe donc derrière elle et ne blanchit pas la carte.
	lighting = {
		atmosphereDensity = 0,
		environmentSpecularScale = 0,
		environmentDiffuseScale = 0.35,
		ambient = Color3.fromRGB(91, 99, 111),
		outdoorAmbient = Color3.fromRGB(126, 133, 143),
		bloomIntensity = 0.08,
		bloomSize = 18,
		bloomThreshold = 1.35,
		brightness = 2.15,
		exposureCompensation = -0.12,
		clockTime = 12,
		geographicLatitude = 45,
		colorContrast = 0.08,
		colorSaturation = -0.08,
		colorBrightness = -0.01,
		colorTint = Color3.fromRGB(244, 247, 250),
	},

	-- Chaînes de montagnes (lon, lat) et hauteur max des sommets
	mountains = {
		range("Rocheuses", 11, {
			{ -128, 60 }, { -124, 56 }, { -120, 53 }, { -116, 50 }, { -113, 47 }, { -111, 44.5 },
			{ -108, 42 }, { -106, 39.5 }, { -106, 37 }, { -106, 34 },
		}),
		range("Chaîne d'Alaska", 10, {
			{ -154, 60 }, { -151, 62.8 }, { -147, 63.4 }, { -142, 62 }, { -138, 60.5 }, { -133, 58.5 },
		}),
		range("Chaîne Brooks", 6, { { -162, 68.3 }, { -155, 68 }, { -148, 68.3 }, { -142, 69 } }),
		range("Cascades et Sierra Nevada", 8, {
			{ -121.5, 48.5 }, { -121.8, 45.5 }, { -122, 42 }, { -120.5, 39 }, { -118.5, 36.5 },
		}),
		range("Sierra Madre occidentale", 7, { { -109, 30 }, { -107, 27 }, { -105, 24 }, { -103.5, 21.5 } }),
		range("Sierra Madre orientale", 6, { { -101, 26.5 }, { -99.5, 24 }, { -98, 21 }, { -97, 19 } }),
		range("Appalaches", 5, {
			{ -85, 34 }, { -82, 36.5 }, { -79, 38.5 }, { -76.5, 40.5 }, { -74, 42.5 }, { -71.5, 44.3 }, { -69, 46 },
		}),
		range("Andes", 13, {
			{ -75, 10 }, { -76, 6 }, { -77, 2 }, { -78.5, -1 }, { -79, -4 }, { -77, -9 }, { -74, -13 },
			{ -70.5, -16 }, { -68.5, -19 }, { -67.5, -23 }, { -68.5, -27 }, { -70, -31 }, { -70.2, -34 },
			{ -71, -38 }, { -71.5, -42 }, { -72.5, -46 }, { -73, -50 }, { -71, -53.5 },
		}),
		range("Alpes", 10, {
			{ 5.9, 44.2 }, { 6.8, 45.0 }, { 7.3, 45.9 }, { 8.5, 46.3 }, { 10.2, 46.5 }, { 11.8, 46.8 },
			{ 13.2, 47.1 }, { 14.8, 47.4 },
		}),
		range("Pyrénées", 7, { { -1.6, 43.0 }, { 0.8, 42.65 }, { 2.9, 42.45 } }),
		range("Cordillère cantabrique", 5, { { -7.2, 42.9 }, { -4.3, 43.1 }, { -3.0, 43.05 } }),
		range("Alpes scandinaves", 7, { { 6.8, 59.3 }, { 8.6, 61.6 }, { 12.8, 64.2 }, { 16.8, 67.7 }, { 21.5, 69.4 } }),
		range("Carpates", 6, { { 18.8, 49.4 }, { 22.3, 49.0 }, { 25.0, 47.5 }, { 25.8, 45.8 }, { 23.0, 45.4 }, { 22.2, 45.1 } }),
		range("Apennins", 5, { { 8.8, 44.4 }, { 12.0, 43.6 }, { 14.2, 41.9 }, { 16.0, 39.8 } }),
		range("Alpes dinariques", 5, { { 14.8, 45.6 }, { 17.8, 43.5 }, { 20.4, 42.1 } }),
		range("Oural", 5, { { 59, 67.5 }, { 60, 64 }, { 59.5, 60 }, { 59, 56 }, { 58.5, 53 }, { 58, 51 } }),
		range("Caucase", 9, { { 37.8, 44.4 }, { 40.2, 43.5 }, { 42.5, 42.9 }, { 44.8, 42.5 }, { 46.6, 41.6 }, { 48.5, 41.2 } }),
		range("Atlas", 8, { { -9, 30.8 }, { -6.5, 31.5 }, { -4, 32.5 }, { -1, 33.3 }, { 2, 34.3 }, { 5, 35.2 }, { 8, 36.2 } }),
		range("Taurus", 7, { { 29.3, 36.9 }, { 33.2, 36.9 }, { 36.8, 38.0 }, { 38.8, 38.3 } }),
		range("Monts Pontiques", 6, { { 31.8, 41.0 }, { 36.5, 40.8 }, { 41.2, 40.8 } }),
		range("Zagros", 8, { { 44, 37.5 }, { 46, 35 }, { 48, 33 }, { 50.5, 30.5 }, { 53, 28.5 }, { 56, 27.5 } }),
		range("Elbourz", 8, { { 48.5, 37.5 }, { 51, 36.3 }, { 54, 36.6 }, { 57, 37.3 } }),
		range("Hedjaz", 6, { { 36.5, 28.5 }, { 38, 25.5 }, { 40, 21.5 }, { 42.5, 17.5 }, { 44, 14 } }),
		range("Hindou Kouch", 11, { { 66, 34.5 }, { 68.5, 35.3 }, { 71, 36.2 }, { 73, 36.6 } }),
		range("Pamir", 11, { { 72.5, 38.8 }, { 74.5, 38.2 } }),
		range("Karakoram", 15, { { 74.5, 36.2 }, { 77, 35.5 } }),
		range("Himalaya", 16, {
			{ 73.5, 35 }, { 76, 34 }, { 78.5, 32 }, { 81, 30 }, { 84, 28.5 }, { 87, 27.9 }, { 90, 28 },
			{ 93, 28.3 }, { 95.5, 29 },
		}),
		range("Kunlun", 10, { { 76, 36.5 }, { 80, 35.8 }, { 85, 35.8 }, { 90, 36 }, { 95, 35.5 }, { 99, 35 } }),
		range("Tian Shan", 10, {
			{ 69.5, 41.5 }, { 72.5, 41.2 }, { 75.5, 41.5 }, { 79, 42 }, { 82.5, 42.8 }, { 86, 43.2 }, { 89, 43.3 },
		}),
		range("Altaï", 8, { { 84, 50.5 }, { 87, 49.5 }, { 89.5, 48.5 }, { 92, 47.5 }, { 96, 46 } }),
		range("Saïan", 7, { { 91, 53 }, { 95, 52.5 }, { 99, 52 }, { 102, 51.5 } }),
		range("Monts de Verkhoïansk", 6, { { 128, 72 }, { 128.5, 68 }, { 133, 65 }, { 137, 62.5 } }),
		range("Grand Khingan", 5, { { 120, 51.5 }, { 121, 48 }, { 119.5, 45 }, { 118, 43 } }),
		range("Alpes japonaises", 6, {
			{ 131, 33.5 }, { 134, 34.8 }, { 136.8, 35.8 }, { 138.5, 36.8 }, { 140.2, 38.5 }, { 140.8, 40.5 },
		}),
		range("Hauts plateaux éthiopiens", 8, { { 37, 14 }, { 38.5, 12 }, { 39.5, 10 }, { 39, 8 }, { 38, 6.5 } }),
		range("Kilimandjaro", 8, { { 37.2, -2.5 }, { 37.4, -3.1 } }),
		range("Drakensberg", 6, { { 27.5, -31.5 }, { 28.5, -30 }, { 29.5, -29 }, { 30, -27.5 } }),
		range("Cordillère australienne", 5, {
			{ 145.5, -16 }, { 146.5, -19 }, { 148, -22 }, { 150.5, -26 }, { 151.5, -29 }, { 150.5, -32 },
			{ 149, -35.5 }, { 146.5, -37.3 },
		}),
		range("Alpes du Sud", 7, { { 167.5, -45.5 }, { 169, -44 }, { 171, -43 }, { 172.5, -42 } }),
	},
}

return MapSettings
