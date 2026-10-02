--!strict
-- Petit son de clic sur chaque bouton de l'interface (bouton grisé : son de refus).
-- Les boutons sont repérés dès qu'ils apparaissent : les modules d'interface n'ont rien à faire.

local Players = game:GetService("Players")

local Sfx = require(script.Parent:WaitForChild("Sfx"))

local UISounds = {}

-- marqueur posé sur chaque bouton déjà équipé (un attribut : un bouton déplacé n'est pas équipé deux fois)
local MARK = "SonClic"

local function hook(gui: Instance)
	if not gui:IsA("GuiButton") or gui:GetAttribute(MARK) then
		return
	end
	gui:SetAttribute(MARK, true)
	local button = gui :: GuiButton
	button.Activated:Connect(function()
		-- « Actif » : attribut des boutons de UIStyle (faux = grisé)
		Sfx.play(if button:GetAttribute("Actif") == false then "Refus" else "Clic")
	end)
end

function UISounds.start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	for _, descendant in playerGui:GetDescendants() do
		hook(descendant)
	end
	playerGui.DescendantAdded:Connect(hook)
end

return UISounds
