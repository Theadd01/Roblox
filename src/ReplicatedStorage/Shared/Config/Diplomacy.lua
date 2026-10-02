--!strict
-- Diplomatie (voir server/Politics/DiplomacyService) : blocs d'alliance, guerres, trêves, propositions.
-- Un bloc réunit des pays alliés : ses membres se défendent et combattent ensemble
-- (une guerre contre l'un d'eux est une guerre contre tout le bloc).

local Diplomacy = {
	maxBlocSize = 5, -- pays au plus dans un bloc
	truceDuration = 180, -- secondes de trêve après la paix : pas d'attaque entre les deux camps
	proposalDuration = 60, -- une proposition sans réponse expire au bout de 60 s
	proposalCooldown = 30, -- secondes avant de pouvoir refaire la même proposition au même pays
	answerDelay = { min = 2, max = 5 }, -- l'IA répond après quelques secondes
	resultDelay = 6, -- secondes pendant lesquelles la réponse reste visible

	-- Noms fictifs des blocs (aucune alliance réelle)
	blocNames = {
		"Alliance Atlantique", "Pacte de l'Est", "Ligue du Sud", "Union Boréale", "Entente Pacifique",
		"Concorde des Savanes", "Front des Cordillères", "Coalition des Oasis", "Cercle Arctique",
		"Axe des Détroits", "Ligue des Steppes", "Union des Deux Mers", "Pacte Austral",
		"Entente des Îles", "Alliance du Soleil Levant", "Ligue des Fleuves", "Pacte des Volcans",
		"Union des Plaines", "Entente des Caps", "Alliance des Hauts Plateaux",
	},
}

return Diplomacy
