--!strict
-- Partie en cours côté client : les modules d'interface y rattachent leurs connexions, qui sont
-- coupées quand le joueur quitte son pays (exil, fin de partie). Ainsi une nouvelle partie ne
-- double pas les messages et les boucles de la précédente.

local GameSession = {}

local connections: { RBXScriptConnection } = {}
local token = 0

-- Garde une connexion jusqu'à la fin de la partie en cours ; la renvoie
function GameSession.track(connection: RBXScriptConnection): RBXScriptConnection
	table.insert(connections, connection)
	return connection
end

-- Numéro de la partie en cours (pour arrêter une boucle : while GameSession.alive(t) do ...)
function GameSession.token(): number
	return token
end

function GameSession.alive(t: number): boolean
	return t == token
end

-- Le joueur quitte son pays : on coupe tout ce qui était rattaché à la partie
function GameSession.stop()
	token += 1
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

return GameSession
