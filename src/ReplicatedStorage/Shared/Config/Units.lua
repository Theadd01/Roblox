--!strict
-- Forces militaires. Trois sortes de forces, chacune représentée sur la carte par son chef :
--   Terre : une armée et son général (officier au drapeau)
--   Air   : une escadrille et son avion de tête
--   Mer   : une flotte et son navire amiral
-- Les troupes sont comptées par type dans chaque force.

export type UnitType = {
	id: string,
	kind: string, -- "Terre" | "Air" | "Mer"
	name: string,
	icon: string,
	cost: { [string]: number },
	upkeep: { [string]: number }, -- entretien : consommé à chaque cycle de production
	model: string, -- modèle 3D dans ReplicatedStorage.Modeles
}

export type Kind = {
	id: string,
	name: string, -- nom de la force (« Armée », « Escadrille », « Flotte »)
	leaderTitle: string, -- préfixe du nom du chef
	createLabel: string, -- texte du bouton de création
	icon: string,
	leaderModel: string,
	order: { string }, -- types de troupes, dans l'ordre d'affichage
	lossOrder: { string }, -- les moins chers tombent d'abord
	cost: { [string]: number }, -- nommer le chef
	capacity: { number }, -- troupes maximum selon le niveau
	maxPerCountry: number,
	speed: number, -- studs par seconde sur la carte
	minTime: number,
	maxTime: number,
	range: number?, -- portée d'un déplacement (air et mer)
	coastal: boolean?, -- ne se crée et ne va que dans les régions côtières
	altitude: number?, -- hauteur de vol (air)
}

local Units = {
	kindOrder = { "Terre", "Air", "Mer" },
	kinds = {
		Terre = {
			id = "Terre",
			name = "Armée",
			leaderTitle = "Général",
			createLabel = "Nommer un général",
			icon = "🎖️",
			leaderModel = "General",
			order = { "Infanterie", "Blindes", "Artillerie" },
			lossOrder = { "Infanterie", "Artillerie", "Blindes" },
			cost = { Credits = 200 },
			capacity = { 10, 15, 20, 25, 30 },
			maxPerCountry = 5,
			speed = 6,
			minTime = 10,
			maxTime = 60,
		},
		Air = {
			id = "Air",
			name = "Escadrille",
			leaderTitle = "Escadrille",
			createLabel = "Former une escadrille",
			icon = "✈️",
			leaderModel = "Avion",
			order = { "Chasseur", "Bombardier", "Drone", "Helicoptere" },
			lossOrder = { "Drone", "Helicoptere", "Chasseur", "Bombardier" },
			cost = { Credits = 250 },
			capacity = { 8, 10, 12, 14, 16 },
			maxPerCountry = 3,
			speed = 20,
			minTime = 6,
			maxTime = 40,
			range = 400,
			altitude = 14,
		},
		Mer = {
			id = "Mer",
			name = "Flotte",
			leaderTitle = "Amiral",
			createLabel = "Nommer un amiral",
			icon = "⚓",
			leaderModel = "Navire",
			order = { "Destroyer", "PorteAvions", "SousMarin" },
			lossOrder = { "SousMarin", "Destroyer", "PorteAvions" },
			cost = { Credits = 300 },
			capacity = { 6, 8, 10, 12, 14 },
			maxPerCountry = 3,
			speed = 9,
			minTime = 10,
			maxTime = 80,
			range = 600,
			coastal = true,
		},
	} :: { [string]: Kind },

	types = {
		-- Terre
		Infanterie = { id = "Infanterie", kind = "Terre", name = "Infanterie", icon = "⚔️", cost = { Credits = 40, Nourriture = 15 }, upkeep = { Nourriture = 1 }, model = "Soldat" },
		Blindes = { id = "Blindes", kind = "Terre", name = "Blindés", icon = "🛡️", cost = { Credits = 120, Acier = 10, Petrole = 5 }, upkeep = { Petrole = 1 }, model = "Char" },
		Artillerie = { id = "Artillerie", kind = "Terre", name = "Artillerie", icon = "💥", cost = { Credits = 90, Acier = 6 }, upkeep = { Nourriture = 1 }, model = "Artillerie" },
		-- Air (les puces s'achètent au marché)
		Chasseur = { id = "Chasseur", kind = "Air", name = "Chasseur", icon = "✈️", cost = { Credits = 150, Acier = 8, Puces = 2, Petrole = 6 }, upkeep = { Petrole = 1 }, model = "Avion" },
		Bombardier = { id = "Bombardier", kind = "Air", name = "Bombardier", icon = "💣", cost = { Credits = 220, Acier = 12, Puces = 3, Petrole = 10 }, upkeep = { Petrole = 2 }, model = "Bombardier" },
		Drone = { id = "Drone", kind = "Air", name = "Drone", icon = "🛸", cost = { Credits = 80, Acier = 3, Puces = 1 }, upkeep = {}, model = "Drone" },
		Helicoptere = { id = "Helicoptere", kind = "Air", name = "Hélicoptère", icon = "🚁", cost = { Credits = 120, Acier = 6, Puces = 1, Petrole = 5 }, upkeep = { Petrole = 1 }, model = "Helicoptere" },
		-- Mer
		Destroyer = { id = "Destroyer", kind = "Mer", name = "Destroyer", icon = "🚢", cost = { Credits = 200, Acier = 20, Petrole = 8 }, upkeep = { Petrole = 1 }, model = "Navire" },
		PorteAvions = { id = "PorteAvions", kind = "Mer", name = "Porte-avions", icon = "🛳️", cost = { Credits = 500, Acier = 50, Puces = 5, Petrole = 20 }, upkeep = { Petrole = 2 }, model = "PorteAvions" },
		SousMarin = { id = "SousMarin", kind = "Mer", name = "Sous-marin", icon = "🐋", cost = { Credits = 250, Acier = 18, Puces = 2, Petrole = 6 }, upkeep = { Petrole = 1 }, model = "SousMarin" },
	} :: { [string]: UnitType },

	-- noms de code fictifs (aucun militaire réel)
	names = {
		"Faucon", "Orion", "Lynx", "Condor", "Granit", "Mistral", "Sirius", "Cobalt", "Albatros", "Typhon",
		"Onyx", "Borée", "Jaguar", "Véga", "Tempête", "Castor", "Rigel", "Hermine", "Basalte", "Zéphyr",
		"Panthère", "Altaïr", "Sirocco", "Titan", "Corbeau", "Saphir", "Volcan", "Pollux", "Éclair", "Atlas",
	},

	-- Escorte visible autour du chef selon la taille de la force
	escort = {
		{ maxUnits = 2, followers = 0 },
		{ maxUnits = 5, followers = 1 },
		{ maxUnits = 10, followers = 2 },
		{ maxUnits = math.huge, followers = 3 },
	},
}

-- Sorte de force d'une armée (les plus anciennes, sans attribut, sont des armées de terre)
function Units.kindOf(army: Instance): string
	local kind = army:GetAttribute("Genre")
	return if typeof(kind) == "string" and Units.kinds[kind] then kind else "Terre"
end

return Units
