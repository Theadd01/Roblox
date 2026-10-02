--!strict
-- Info-bulles (voir client/UI/Tooltips) : texte affiché au survol d'un bouton ou d'une ressource.
-- Recherche dans l'ordre : « Parent.Nom » (exact), puis « Nom » (exact), puis un préfixe
-- (« Recruter_ » -> fonction du reste du nom). Les ressources et les troupes ont un texte
-- construit à partir de leur configuration.

local Tooltips = {
	delay = 0.35, -- secondes de survol avant d'afficher la bulle
	holdDelay = 0.5, -- appui long sur écran tactile
	maxWidth = 290,

	byPath = {
		["Barre.Carte"] = "Carte : ferme les menus. Clique sur une région pour voir sa fiche.",
		["Barre.Industrie"] = "Industrie : tes stocks, ta production, tes bâtiments et les projets décisifs.",
		["Barre.Batiments"] = "Bâtiments : ta population et, région par région, tes champs de blé, mines, puits, usines et camps militaires (2 par région, 4 dans la capitale).",
		["Barre.Recherche"] = "Recherche : l'arbre technologique (drones, radars, missiles, blindés modernes, économie).",
		["Barre.Marche"] = "Marché : la Bourse mondiale (acheter, vendre, spéculer) et les contrats avec d'autres pays.",
		["Barre.Armee"] = "Armée : nommer un chef, recruter, déplacer tes forces et leur donner des ordres.",
		["Barre.Diplomatie"] = "Diplomatie : ton pays, ton bloc, tes guerres, tes voisins et le Conseil mondial.",
		["Boutons.Credits"] = "Crédits : qui a fait le jeu, d'où viennent la carte, les musiques et les sons.",
	},

	byName = {
		Population = "Population : tes habitants. Ils mangent à chaque cycle, paient les impôts et deviennent soldats. Bien nourris, ils grandissent ; en famine, ils diminuent. Plus d'habitants = plus de divisions possibles.",
		Partie = "Temps restant avant la fin de la partie, et phase en cours. À la fin : classement mondial (territoire, économie, armée, commerce).",
		Missions = "Missions du jour : trois défis, les mêmes pour tous, qui donnent de l'expérience de compte.",
		Profil = "Profil : tes succès, ton titre affiché et tes parties.",
		Amis = "Jouer entre amis : inviter des amis, s'allier avec eux, discuter en privé avec un autre dirigeant.",
		Parametres = "Paramètres : volume de la musique et des effets, messages à l'écran, taille de l'interface.",
		Stabilite = "Stabilité : baisse avec les pertes, les pénuries, les guerres longues et les conquêtes trop nombreuses. Basse, elle réduit ta production et renchérit tes recrues.",
		Credits = "Crédits : la monnaie du jeu. Tu en gagnes tout seul à chaque cycle (impôts de tes régions, vente automatique de tes surplus : onglet Marché), et avec tes objectifs.",
		Acheter = "Acheter au prix du marché : chaque achat fait monter le prix.",
		Vendre = "Vendre au prix du marché (90 % de la valeur) : chaque vente fait baisser le prix.",
		Posture_Normal = "Normal : la force se replie seule si son moral s'effondre.",
		Posture_Defendre = "Défendre : +25 % de puissance quand la force défend sa région.",
		Posture_Tenir = "Tenir : la force ne se replie jamais, même démoralisée.",
		Replier = "Se replier vers une région amie.",
		QuitterBloc = "Quitter ton bloc. Pendant une guerre, c'est une trahison dont les IA se souviendront.",
		Proposer = "Envoyer la proposition de contrat à ce pays.",
		Embargo = "Interdire (ou autoriser à nouveau) tout contrat avec ce pays.",
		AutrePays = "Laisser ton pays en exil et diriger un pays libre.",
		Vote_Pour = "Voter pour la résolution.",
		Vote_Contre = "Voter contre la résolution.",
		Vote_Abstention = "Ne pas prendre parti.",
		Retour = "Revenir à la liste de tes forces.",
		Q1 = "Échanger 1 unité à la fois.",
		Q10 = "Échanger 10 unités à la fois.",
		Q100 = "Échanger 100 unités à la fois.",
	},

	byPrefix = {
		Nommer_ = "Nommer un chef : une nouvelle force, vide, dans ta dernière région cliquée.",
		Aller_ = "Envoyer la force vers cette région. Chez un pays étranger, c'est une attaque (et une déclaration de guerre).",
		Guerre_ = "Déclarer la guerre à ce pays (deux touches pour confirmer). Son bloc entre en guerre avec lui.",
		Alliance_ = "Proposer une alliance : vous formerez ou rejoindrez un bloc qui se défend ensemble.",
		Paix_ = "Proposer la paix : la guerre s'arrête et une trêve de 3 minutes commence.",
		Financer_ = "Financer la résistance : à 100 points, la région se soulève et te revient.",
		Payer_ = "Payer ce pays pour qu'il vote comme toi au Conseil mondial.",
		Accepter_ = "Accepter la proposition.",
		Refuser_ = "Refuser la proposition.",
		Construire_ = "Construire ce bâtiment dans la région : le chantier dure quelques secondes. Le prix monte avec le nombre de bâtiments de ton pays.",
		VenteAuto_ = "Vente automatique de cette ressource : à chaque cycle, ce qui dépasse la réserve est vendu au prix du marché.",
	},
}

return Tooltips
