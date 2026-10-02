--!strict
-- Catalogue centralisé. Les identifiants restent à 0 tant que les produits n'ont
-- pas été créés dans le Creator Dashboard : aucun achat réel ne peut alors s'ouvrir.

export type Offer = {
	id: number,
	name: string,
	description: string,
	suggestedPrice: number,
	kind: string,
	medals: number?,
	unlocks: { string }?,
}

export type Cosmetic = {
	id: string,
	name: string,
	description: string,
	category: string,
	price: number,
}

local Monetization = {}

Monetization.profileStoreName = "WorldFront_PlayerProfile_v1"
Monetization.autosaveSeconds = 90
Monetization.freeBookmarkSlots = 2

Monetization.gamePasses = {
	CommandOffice = {
		id = 0,
		name = "Bureau du Commandant",
		description = "6 repères stratégiques au lieu de 2 et récupération automatique des récompenses.",
		suggestedPrice = 149,
		kind = "GamePass",
	},
	Cartographer = {
		id = 0,
		name = "Cartographe",
		description = "Thèmes de carte, marqueurs et présentations visuelles supplémentaires.",
		suggestedPrice = 99,
		kind = "GamePass",
	},
	Herald = {
		id = 0,
		name = "Héraut",
		description = "Titres, cadres de drapeau et styles de notifications exclusifs.",
		suggestedPrice = 79,
		kind = "GamePass",
	},
} :: { [string]: Offer }

Monetization.products = {
	PremiumBattlePass = {
		id = 0,
		name = "Passe Mobilisation Premium",
		description = "Débloque rétroactivement la piste Premium de la Saison 0.",
		suggestedPrice = 299,
		kind = "PremiumSeason",
	},
	SupportSmall = {
		id = 0,
		name = "Soutien — Éclaireur",
		description = "Soutiens le développement et reçois 50 Médailles cosmétiques.",
		suggestedPrice = 25,
		kind = "Support",
		medals = 50,
		unlocks = { "BADGE_SUPPORTER" },
	},
	SupportMedium = {
		id = 0,
		name = "Soutien — Officier",
		description = "Soutiens le développement et reçois 250 Médailles cosmétiques.",
		suggestedPrice = 100,
		kind = "Support",
		medals = 250,
		unlocks = { "BADGE_SUPPORTER" },
	},
	SupportLarge = {
		id = 0,
		name = "Soutien — État-major",
		description = "Soutiens le développement et reçois 800 Médailles cosmétiques.",
		suggestedPrice = 500,
		kind = "Support",
		medals = 800,
		unlocks = { "BADGE_SUPPORTER", "TITLE_BENEFACTOR" },
	},
} :: { [string]: Offer }

Monetization.cosmetics = {
	{
		id = "TITLE_PLANNER",
		name = "Titre « Planificateur »",
		description = "Affiché dans ton espace de commandement.",
		category = "Title",
		price = 150,
	},
	{
		id = "TITLE_CARTOGRAPHER",
		name = "Titre « Cartographe »",
		description = "Pour les stratèges qui connaissent chaque frontière.",
		category = "Title",
		price = 200,
	},
	{
		id = "TITLE_QUARTERMASTER",
		name = "Titre « Intendant »",
		description = "Une distinction purement cosmétique dédiée à la logistique.",
		category = "Title",
		price = 250,
	},
	{
		id = "TITLE_VETERAN",
		name = "Titre « Vétéran »",
		description = "Un titre de profil sans bonus de combat.",
		category = "Title",
		price = 400,
	},
} :: { Cosmetic }

function Monetization.gamePassById(id: number): (string?, Offer?)
	for key, offer in Monetization.gamePasses do
		if offer.id > 0 and offer.id == id then
			return key, offer
		end
	end
	return nil, nil
end

function Monetization.productById(id: number): (string?, Offer?)
	for key, offer in Monetization.products do
		if offer.id > 0 and offer.id == id then
			return key, offer
		end
	end
	return nil, nil
end

function Monetization.cosmeticById(id: string): Cosmetic?
	for _, cosmetic in Monetization.cosmetics do
		if cosmetic.id == id then
			return cosmetic
		end
	end
	return nil
end

return Monetization
