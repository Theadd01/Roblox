--!strict
-- Musique et sons du jeu. Musiques : bibliothèque APM Music (sous licence Roblox, utilisable dans
-- toutes les expériences) ; sons : bibliothèques officielles Roblox et Pro Sound Effects.
-- Pour changer un son, remplacer son identifiant ici (rbxassetid://...).

local Audio = {}

-- Volumes de départ (réglables par le joueur dans Paramètres, de 0 à 1)
Audio.defaultMusicVolume = 0.5
Audio.defaultEffectsVolume = 0.7
Audio.volumeStep = 0.1 -- pas des boutons − / +

-- Musique : une liste de pistes par ambiance, jouées au hasard et enchaînées en fondu
Audio.crossfade = 3 -- secondes de fondu entre deux pistes
Audio.musicBase = 0.6 -- volume de base des musiques (avant le réglage du joueur)
Audio.duckFactor = 0.3 -- pendant un jingle (victoire, défaite...), la musique baisse à 30 %
Audio.loadTimeout = 10 -- une piste qui ne se charge pas en 10 s est sautée
Audio.music = {
	-- écran titre et choix du pays
	Titre = {
		{ id = "rbxassetid://1836104037", name = "Determined Epic Theme" },
		{ id = "rbxassetid://1846105995", name = "Glory Path" },
	},
	-- aucune menace : gestion, commerce, diplomatie
	Paix = {
		{ id = "rbxassetid://9042589035", name = "Summer Dawn" },
		{ id = "rbxassetid://1835322111", name = "Hopeful Contemplation" },
		{ id = "rbxassetid://1842691547", name = "Evolving Expanse" },
		{ id = "rbxassetid://1838935780", name = "Media Report" },
	},
	-- en guerre sans combat, armée ennemie en approche, pays instable ou en exil
	Tension = {
		{ id = "rbxassetid://1835248722", name = "Stalking the Prey" },
		{ id = "rbxassetid://1836289781", name = "Unseen Danger" },
		{ id = "rbxassetid://9038865774", name = "Political Discussion" },
		{ id = "rbxassetid://1836391539", name = "Countdown" },
	},
	-- bataille en cours (ou toute récente) qui concerne le joueur
	Guerre = {
		{ id = "rbxassetid://1837240654", name = "On the Warpath" },
		{ id = "rbxassetid://1846877907", name = "Deadly Assault" },
		{ id = "rbxassetid://9048541013", name = "Battleground" },
		{ id = "rbxassetid://9040111018", name = "Large Scale Maneuvers" },
		{ id = "rbxassetid://1840528240", name = "March To Conquest" },
	},
}

-- Choix de l'ambiance (voir client/Audio/Mood)
Audio.mood = {
	checkInterval = 2, -- secondes entre deux vérifications
	battleLinger = 60, -- la musique de guerre continue 60 s après une bataille
	calmDelay = 30, -- il faut 30 s de calme pour revenir à une ambiance plus douce
	lowStability = 35, -- en dessous : ambiance « Tension »
	order = { Paix = 1, Tension = 2, Guerre = 3 },
}

-- Sons courts. volume : volume propre du son ; maxLength : coupé après N secondes (jingles longs)
export type Sound = { id: string, volume: number, maxLength: number? }
Audio.sounds = {
	-- interface
	Clic = { id = "rbxassetid://17208396156", volume = 0.35 }, -- Roblox GUI - Select
	Refus = { id = "rbxassetid://17208353912", volume = 0.5 }, -- Roblox GUI - Negative
	Notification = { id = "rbxassetid://17208372272", volume = 0.5 }, -- Roblox GUI - Notification Low
	Succes = { id = "rbxassetid://17208361335", volume = 0.5 }, -- Roblox GUI - Notification High
	Alerte = { id = "rbxassetid://1846902250", volume = 0.7, maxLength = 3 }, -- coup grave dramatique
	-- actions
	Vente = { id = "rbxassetid://9113728049", volume = 0.6 }, -- tiroir-caisse
	Achat = { id = "rbxassetid://17208380755", volume = 0.6 }, -- Roblox GUI - Purchase
	Recrutement = { id = "rbxassetid://17208323435", volume = 0.6 }, -- Roblox GUI - Equip
	General = { id = "rbxassetid://9113797306", volume = 0.5 }, -- clairon
	Construction = { id = "rbxassetid://9113445305", volume = 0.5 }, -- marteau sur l'enclume
	Ordre = { id = "rbxassetid://17208405682", volume = 0.5 }, -- Roblox GUI - Swipe
	Signature = { id = "rbxassetid://9114026047", volume = 0.6 }, -- coup de tampon
	Verdict = { id = "rbxassetid://9125574353", volume = 0.6 }, -- coups de marteau de juge
	-- grands moments (jingles : la musique baisse pendant qu'ils jouent)
	Guerre = { id = "rbxassetid://1846902399", volume = 0.7, maxLength = 6 }, -- déclaration de guerre
	Victoire = { id = "rbxassetid://1836473422", volume = 0.7, maxLength = 7 }, -- fanfare
	Defaite = { id = "rbxassetid://1846885853", volume = 0.7, maxLength = 6 }, -- jingle triste
	-- sons placés sur la carte (on les entend en zoomant sur la bataille)
	Explosion = { id = "rbxasset://sounds/impact_explosion_03.mp3", volume = 0.8 },
	Fusillade = { id = "rbxassetid://9114701396", volume = 0.6 }, -- mitrailleuses (en boucle pendant la bataille)
} :: { [string]: Sound }

-- Jingles : la musique baisse pendant qu'ils jouent
Audio.jingles = { Guerre = true, Victoire = true, Defaite = true }

-- Son par défaut des messages à l'écran (Toast), selon leur sorte
Audio.toastSounds = { info = "Notification", success = "Succes", danger = "Alerte" }

-- Son joué quand le serveur accepte une demande (nom du RemoteFunction -> son) ; refus : « Refus »
Audio.actionSounds = {
	Vendre = "Vente",
	Acheter = "Achat",
	Recruter = "Recrutement",
	NommerGeneral = "General",
	ConstruireUsine = "Construction",
	AmeliorerUsine = "Construction",
	DeplacerArmee = "Ordre",
	OrdreArmee = "Ordre",
	ProposerContrat = "Signature",
	RepondreContrat = "Signature",
	ChoisirDilemme = "Signature",
	VoterConseil = "Signature",
	ConvaincreConseil = "Achat",
	FinancerResistance = "Achat",
	InvestirProjet = "Construction",
	SaboterProjet = "Explosion",
	RevelerRegion = "Notification",
	SaboterUsine = "Explosion",
	Rechercher = "Signature",
	VolerTechnologie = "Notification",
}

-- Sons dans l'espace (batailles) : audibles de près, muets vue de loin
Audio.spatial = {
	minDistance = 80, -- volume plein en dessous
	maxDistance = 650, -- silence au-delà
	minInterval = 0.12, -- pas deux fois le même son en moins de 0,12 s (sauf boucle)
}

return Audio
