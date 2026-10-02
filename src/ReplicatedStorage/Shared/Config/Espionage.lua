--!strict
-- Brouillard de guerre et espionnage (voir shared/FogRules, server/Politics/EspionageService).
-- Un pays voit ses régions et celles de ses alliés, leurs voisines, et les régions où se trouvent
-- ou vont ses forces (et leurs voisines). Ailleurs, les armées ennemies sont cachées.
-- Ses espions peuvent révéler une région un moment, ou saboter une usine étrangère visible.

local Espionage = {}

Espionage.fogDim = 0.45 -- assombrissement des régions hors de vue sur la carte (0 = aucun)

-- Révéler une région : on y voit tout pendant `duration` secondes
Espionage.reveal = {
	cost = { Credits = 150 },
	duration = 180,
}

-- Saboter une usine (dans une région visible, d'un pays qui n'est pas un allié)
Espionage.sabotage = {
	cost = { Credits = 300 },
	duration = 120, -- secondes d'arrêt de l'usine
	success = 0.7, -- chance de réussite
	caught = 0.4, -- chance que les espions soient démasqués (réussite ou non)
	caughtReputation = -5, -- réputation perdue par le pays démasqué
	cooldown = 60, -- secondes entre deux sabotages du même pays contre le même pays
}

return Espionage
