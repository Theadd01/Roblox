--!strict
-- Point d'entrée autonome de la boutique, séparé du client de jeu principal.

local CommerceState = require(script.Parent:WaitForChild("State"):WaitForChild("CommerceState"))
local CommerceScreen = require(script.Parent:WaitForChild("UI"):WaitForChild("CommerceScreen"))

local ready = false
for _attempt = 1, 3 do
	if CommerceState.start() then
		ready = true
		break
	end
	task.wait(2)
end

if ready then
	CommerceScreen.create()
else
	warn("[Commerce] Interface non démarrée après trois tentatives : profil indisponible.")
end
