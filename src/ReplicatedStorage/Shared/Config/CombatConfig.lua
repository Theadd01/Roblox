--!strict
-- Combat terrestre (cahier des charges v2, section 2) : TOUS les chiffres d'équilibrage du combat
-- des divisions sont ici, pour équilibrer sans toucher à la logique (server/Military/Combat et
-- BattleManager). Un « soldat » = une division = un modèle sur la carte.
--
-- Le résultat est calculé par le serveur, dans UNE boucle par bataille (un tick toutes les
-- tickSeconds) ; les modèles ne font que l'animer. À chaque tick :
--   1. déploiement : chaque camp engage ses soldats peu à peu (ils « arrivent au front »), au plus
--      frontWidth en même temps ; les autres attendent en réserve et remplacent les tombés ;
--   2. ciblage : chaque soldat engagé reçoit une cible en rotation (le défenseur le moins visé
--      d'abord) ; si elle tombe, il en reçoit une nouvelle au tick suivant ; les troupes à
--      l'arrière (rear) ne sont visées que quand plus aucune troupe de première ligne ne combat ;
--   3. dégâts d'un soldat sur sa cible :
--        DPS x tick x (1 + bonus_recherche + bonus_général + expérience...) x facteur_terrain
--          x efficacité contre la cible (vsArmor / vsSoft) x avantage du nombre
--        divisés par la défense de la cible (défenseur : 1 + defenderBonus + retranchement
--        + fortifications + bonus du général...) ;
--   4. un soldat à 0 PV se replie dans une région amie voisine avec retreatHealth de ses PV, ou
--      meurt s'il n'en a aucune ; chaque soldat tombé fait baisser le moral (organisation) de son
--      camp : sous morale.routBelow, tout le camp se replie (il ne se bat pas jusqu'au dernier) ;
--   5. la région change de propriétaire dès qu'il ne reste plus aucun défenseur.

export type UnitStats = {
	health: number, -- PV au niveau 1 de la recherche
	dps: number, -- dégâts par seconde au niveau 1
	armored: boolean?, -- cible blindée
	rear: boolean?, -- tire depuis l'arrière : n'est visé qu'en dernier
	vsArmor: number?, -- multiplicateur des dégâts contre une cible blindée (1 par défaut)
	vsSoft: number?, -- multiplicateur des dégâts contre une cible non blindée (1 par défaut)
}

local CombatConfig = {
	tickSeconds = 0.5, -- un calcul de combat toutes les 0,5 s
	frontWidth = 20, -- soldats qui combattent en même temps, au plus, par camp
	defenderBonus = 0.15, -- le défenseur connaît le terrain : +15 % de défense
	retreatHealth = 0.25, -- un soldat à 0 PV se replie avec 25 % de ses PV (s'il a une région amie voisine)
	maxSeconds = 240, -- sécurité : au-delà, l'attaque s'arrête (le défenseur garde la région)

	-- Déploiement : un camp engage tous ses soldats en environ `window` secondes (au moins `minRate`
	-- soldats par seconde) ; `initial` soldats sont au contact dès le début. Un camp qui n'a plus
	-- personne en ligne engage tout de suite un soldat de sa réserve.
	-- Durées obtenues en plaine (tools/lune/simulate_combat.luau) : 1 contre 1, le soldat meurt en
	-- 3,5 s ; 10 contre 10 : environ 20 s (le défenseur tient) ; 20 contre 10 : environ 10 s
	-- (l'attaquant gagne) ; 40 contre 20 : environ 11 s.
	deployment = {
		initial = 1,
		window = 36,
		minRate = 0.3,
	},

	-- Avantage du nombre : un camp plus nombreux frappe plus fort (et l'autre moins fort),
	-- multiplicateur = (effectifs du camp / effectifs adverses) ^ exponent, borné à [1/max, max].
	-- Les effectifs comptent chaque soldat selon sa valeur (PV x DPS) et ses PV restants.
	numbers = {
		exponent = 0.5,
		max = 2,
	},

	-- Moral (organisation des divisions, 0 à OrgMax) : chaque soldat tombé en retire
	-- perCasualty / (soldats engagés par le camp) à tout son camp ; le combat en retire aussi un peu
	-- chaque seconde. Sous routBelow (part de l'organisation max, moyenne du camp), le camp se replie.
	morale = {
		perCasualty = 0.8,
		perSecond = 0.01,
		routBelow = 0.25,
	},

	-- Statistiques des types de divisions (Config/Divisions)
	units = {
		Infanterie = { health = 40, dps = 12, vsArmor = 0.5 },
		InfanterieMotorisee = { health = 50, dps = 13, vsArmor = 0.6 },
		Blindee = { health = 120, dps = 25, armored = true, vsSoft = 1.5 }, -- fort contre l'infanterie
		Mecanisee = { health = 90, dps = 20, armored = true, vsSoft = 1.2 },
		Artillerie = { health = 30, dps = 35, rear = true, vsArmor = 0.6 }, -- à l'arrière
		Montagne = { health = 45, dps = 12, vsArmor = 0.5 },
		AntiChar = { health = 45, dps = 10, vsArmor = 3, vsSoft = 0.8 },
		Milice = { health = 25, dps = 7, vsArmor = 0.4 },
	} :: { [string]: UnitStats },
	defaultUnit = "Infanterie",

	-- Attaque continue : après une victoire, les divisions qui avancent attaquent la région ennemie
	-- voisine suivante (la moins défendue) tant qu'elles sont au moins minDivisions et que leur
	-- organisation moyenne dépasse minOrganisation (part du max)
	continuous = {
		minDivisions = 1,
		minOrganisation = 0.35,
		delay = 1, -- secondes après l'arrivée dans la région prise
	},

	-- Animation (client) : tirs animés par camp et par tick au plus (les tireurs changent à chaque
	-- tick : tous finissent par tirer)
	animatedShotsPerSide = 8,
}

-- Statistiques d'un type de division (Infanterie par défaut)
function CombatConfig.stats(typeId: string?): UnitStats
	return CombatConfig.units[typeId or ""] or CombatConfig.units[CombatConfig.defaultUnit]
end

return CombatConfig
