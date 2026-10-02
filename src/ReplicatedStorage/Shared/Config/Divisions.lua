--!strict
-- Types de divisions (SYSTEME_MILITAIRE.md, section 3) : statistiques, coûts, entraînement,
-- consommation et modèle 3D. 1 division = 1 modèle visible sur la carte.
-- Statistiques :
--   org : organisation max (capacité à continuer le combat) ; force : toujours 100 (%)
--   soft / hard : attaque douce (contre cibles non blindées) / dure (contre cibles blindées)
--   defense / breakthrough : coups encaissés par tick en défendant / en attaquant avant de
--     subir les dégâts pleins (voir Config/Military.combat)
--   armor / piercing : blindage / perforation ; hardness : part blindée de la division (0 à 1)
--   width : place occupée sur le champ de bataille ; speed : studs par seconde sur la carte
--   upkeep : consommation par minute (nourriture, pétrole) ; fuel : la division a besoin de pétrole
--   manpower : hommes recrutés, en milliers, pris à la population de la région du camp militaire
--   terrainBonus : bonus d'attaque et de défense sur certains terrains (Config/Terrain)
--   riverBonus : part de la pénalité de franchissement de rivière ignorée

export type DivisionType = {
	id: string,
	name: string, -- « Infanterie »
	label: string, -- « division d'infanterie » (nom complet : « 3e division d'infanterie »)
	short: string, -- étiquette courte : « INF »
	icon: string,
	model: string, -- modèle dans ReplicatedStorage.Modeles
	org: number,
	soft: number,
	hard: number,
	defense: number,
	breakthrough: number,
	armor: number,
	piercing: number,
	hardness: number,
	width: number,
	speed: number,
	upkeep: { [string]: number },
	fuel: boolean,
	cost: { [string]: number },
	trainSeconds: number,
	manpower: number, -- hommes recrutés (milliers d'habitants)
	recruitable: boolean,
	terrainBonus: { [string]: number }?,
	riverBonus: number?,
	text: string, -- points forts / faibles
}

local Divisions = {
	order = { "Infanterie", "InfanterieMotorisee", "Blindee", "Mecanisee", "Artillerie", "Montagne", "AntiChar" },
	types = {
		Infanterie = {
			id = "Infanterie", name = "Infanterie", label = "division d'infanterie", short = "INF", icon = "⚔️", model = "Soldat",
			org = 60, soft = 6, hard = 1, defense = 8, breakthrough = 2, armor = 0, piercing = 2, hardness = 0, width = 1,
			speed = 4, upkeep = { Nourriture = 2 }, fuel = false,
			cost = { Credits = 120, Nourriture = 20 }, trainSeconds = 30, manpower = 50, recruitable = true,
			text = "Bonne organisation, pas chère, bonne en défense. Faible percée, faible contre les blindés.",
		},
		InfanterieMotorisee = {
			id = "InfanterieMotorisee", name = "Infanterie motorisée", label = "division motorisée", short = "MOT", icon = "🚚", model = "Camion",
			org = 50, soft = 6, hard = 1, defense = 7, breakthrough = 4, armor = 1, piercing = 3, hardness = 0.1, width = 1,
			speed = 8, upkeep = { Nourriture = 2, Petrole = 1 }, fuel = true,
			cost = { Credits = 200, Acier = 6, Petrole = 6 }, trainSeconds = 40, manpower = 50, recruitable = true,
			text = "Rapide : exploite les percées. Consomme du pétrole.",
		},
		Blindee = {
			id = "Blindee", name = "Blindée", label = "division blindée", short = "BLI", icon = "🛡️", model = "Char",
			org = 30, soft = 10, hard = 4, defense = 4, breakthrough = 12, armor = 10, piercing = 8, hardness = 0.8, width = 2,
			speed = 7, upkeep = { Nourriture = 1, Petrole = 2.5 }, fuel = true,
			cost = { Credits = 350, Acier = 18, Petrole = 10, Puces = 2 }, trainSeconds = 60, manpower = 30, recruitable = true,
			terrainBonus = { Montagne = -0.5, Foret = -0.25, Marais = -0.25, Ville = -0.2 },
			text = "Grosse attaque, grosse percée, blindage. Chère, gourmande en pétrole, mauvaise en montagne et en forêt.",
		},
		Mecanisee = {
			id = "Mecanisee", name = "Mécanisée", label = "division mécanisée", short = "MÉC", icon = "🚜", model = "VehiculeBlinde",
			org = 50, soft = 7, hard = 3, defense = 10, breakthrough = 8, armor = 5, piercing = 6, hardness = 0.6, width = 2,
			speed = 7.5, upkeep = { Nourriture = 2, Petrole = 1.5 }, fuel = true,
			cost = { Credits = 380, Acier = 14, Petrole = 8, Puces = 4 }, trainSeconds = 60, manpower = 40, recruitable = true,
			terrainBonus = { Montagne = -0.25 },
			text = "Polyvalente, bonne défense. Très chère (acier et puces).",
		},
		Artillerie = {
			id = "Artillerie", name = "Artillerie", label = "division d'artillerie", short = "ART", icon = "💥", model = "Artillerie",
			org = 20, soft = 14, hard = 2, defense = 2, breakthrough = 2, armor = 0, piercing = 4, hardness = 0, width = 1,
			speed = 3.5, upkeep = { Nourriture = 1.5 }, fuel = false,
			cost = { Credits = 180, Acier = 10 }, trainSeconds = 40, manpower = 30, recruitable = true,
			text = "Énorme attaque contre l'infanterie. Très faible en défense seule.",
		},
		Montagne = {
			id = "Montagne", name = "Montagne", label = "division de montagne", short = "MON", icon = "🏔️", model = "Soldat",
			org = 55, soft = 6, hard = 1, defense = 9, breakthrough = 3, armor = 0, piercing = 2, hardness = 0, width = 1,
			speed = 4.5, upkeep = { Nourriture = 2.5 }, fuel = false,
			cost = { Credits = 220, Nourriture = 20, Acier = 4 }, trainSeconds = 45, manpower = 50, recruitable = true,
			terrainBonus = { Montagne = 0.25, Collines = 0.2, Foret = 0.1 }, riverBonus = 0.5,
			text = "Bonus en montagne, collines et franchissement de rivière. Chère.",
		},
		AntiChar = {
			id = "AntiChar", name = "Anti-char", label = "division antichar", short = "AC", icon = "🎯", model = "Antiaerien",
			org = 40, soft = 2, hard = 12, defense = 6, breakthrough = 2, armor = 0, piercing = 14, hardness = 0.1, width = 1,
			speed = 3.5, upkeep = { Nourriture = 1.5 }, fuel = false,
			cost = { Credits = 200, Acier = 12 }, trainSeconds = 40, manpower = 30, recruitable = true,
			text = "Perce le blindage des chars. Faible contre l'infanterie.",
		},
		-- levée par une révolte ou par la résistance (pas de recrutement)
		Milice = {
			id = "Milice", name = "Milice", label = "milice", short = "MIL", icon = "✊", model = "Soldat",
			org = 30, soft = 3, hard = 0.5, defense = 5, breakthrough = 1, armor = 0, piercing = 1, hardness = 0, width = 1,
			speed = 3.5, upkeep = { Nourriture = 1 }, fuel = false,
			cost = { Credits = 0 }, trainSeconds = 0, manpower = 0, recruitable = false,
			text = "Combattants levés par une révolte. Faibles.",
		},
	} :: { [string]: DivisionType },
}

-- Nom complet : « 1re division d'infanterie », « 3e division blindée »
function Divisions.fullName(typeId: string, number: number): string
	local t = Divisions.types[typeId]
	return `{number}{if number == 1 then "re" else "e"} {if t then t.label else "division"}`
end

return Divisions
