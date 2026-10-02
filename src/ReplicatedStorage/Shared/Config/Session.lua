--!strict
-- Sessions des joueurs : relais joueur ↔ IA (voir server/Session/PlayerRelay).

local Session = {
	afkTimeout = 300, -- secondes sans rien toucher : l'IA prend le relais (le pays reste réservé au joueur)
	pingInterval = 20, -- le client signale son activité au plus toutes les 20 s
	checkInterval = 10, -- le serveur vérifie les absences toutes les 10 s
	protectionDuration = 300, -- protection de départ : 5 minutes sans pouvoir être attaqué

	-- Style de jeu : points gagnés par une personnalité à chaque action validée du joueur.
	-- Quand l'IA reprend son pays, elle prend la personnalité qui a le plus de points.
	style = {
		trade = { Commercant = 1 }, -- acheter ou vendre
		factory = { Industriel = 4 }, -- construire ou agrandir une usine
		recruit = { Defensif = 0.5 }, -- nommer un chef ou recruter
		defend = { Defensif = 1 }, -- ordre « Défendre » ou « Tenir », force déplacée chez soi
		attack = { Agressif = 6 }, -- attaquer un pays en paix
		opportunistAttack = { Opportuniste = 6, Agressif = 2 }, -- attaquer un pays en guerre ou affaibli
	} :: { [string]: { [string]: number } },
	styleMinimum = 6, -- en dessous, l'IA garde la personnalité du pays
}

return Session
