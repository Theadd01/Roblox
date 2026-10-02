--!strict
-- Succès du compte : chacun se débloque une fois pour toutes et donne un titre que le joueur peut
-- afficher (à côté de son pseudo : choix du pays, classement, joueurs de la partie).
-- Aucun avantage en jeu. Voir server/Session/Achievements (détection) et AccountService (sauvegarde).

export type Achievement = {
	id: string,
	icon: string,
	name: string,
	text: string, -- comment l'obtenir
	title: string, -- titre débloqué
}

local Achievements = {}

Achievements.list = {
	{ id = "PremierContrat", icon = "📦", name = "Premier contrat commercial", text = "Signer un contrat avec un autre pays.", title = "Négociant" },
	{ id = "PremiereConquete", icon = "🚩", name = "Première conquête", text = "Prendre une région à un autre pays.", title = "Conquérant" },
	{ id = "Batisseur", icon = "🏭", name = "Bâtisseur", text = "Construire 5 usines dans une même partie.", title = "Bâtisseur" },
	{ id = "ChefDeGuerre", icon = "⚔️", name = "Chef de guerre", text = "Gagner 10 batailles dans une même partie.", title = "Chef de guerre" },
	{ id = "Magnat", icon = "💰", name = "Magnat", text = "Avoir 10 000 crédits en même temps.", title = "Magnat" },
	{ id = "Diplomate", icon = "🤝", name = "Diplomate", text = "Faire partie d'un bloc d'au moins 3 pays.", title = "Diplomate" },
	{ id = "Visionnaire", icon = "🚀", name = "Visionnaire", text = "Remporter un projet décisif.", title = "Visionnaire" },
	{ id = "Liberateur", icon = "✊", name = "Libérateur", text = "Libérer une de tes régions grâce à la résistance.", title = "Libérateur" },
	{ id = "Podium", icon = "🥉", name = "Podium", text = "Finir une partie parmi les 3 premiers.", title = "Stratège" },
	{ id = "Vainqueur", icon = "🏆", name = "Vainqueur", text = "Finir une partie à la 1re place.", title = "Maître du monde" },
	{ id = "SansPerte", icon = "🛡️", name = "Victoire sans perdre une région", text = "Finir 1er sans avoir perdu une seule région.", title = "Invaincu" },
	{ id = "Fidele", icon = "🎖️", name = "Fidèle", text = "Jouer 10 parties jusqu'au classement final.", title = "Vétéran" },
} :: { Achievement }

-- Seuils
Achievements.factories = 5
Achievements.battles = 10
Achievements.credits = 10000
Achievements.blocSize = 3
Achievements.games = 10

-- Recherche par identifiant
function Achievements.get(id: string): Achievement?
	for _, a in Achievements.list do
		if a.id == id then
			return a
		end
	end
	return nil
end

return Achievements
