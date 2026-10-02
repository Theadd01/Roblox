--!strict
-- Articles des noms de pays, de régions et de blocs, pour des phrases correctes en français :
-- « la France », « l'Espagne », « le Brésil », « les États-Unis », « Cuba » ;
-- « de la France », « du Brésil », « des États-Unis », « d'Israël » ; « au Brésil », « aux États-Unis ».
-- Règle générale : nom qui commence par une voyelle -> « l' », qui finit par « e » -> « la »,
-- sinon « le » ; pour un nom composé (« Rhénanie-du-Nord-Westphalie »), c'est le premier mot qui
-- compte. Les noms de capitales (« Berne », « Riyad ») et ceux qui contiennent déjà leur article
-- (« Le Caire », « La Mecque ») n'en prennent pas. Les exceptions sont listées ci-dessous.

local Countries = require(script.Parent:WaitForChild("Config"):WaitForChild("Countries")) :: any

local FrenchNames = {}

local PLURAL: { [string]: boolean } = {
	["États-Unis"] = true, ["Pays-Bas"] = true, ["Émirats arabes unis"] = true, ["Philippines"] = true,
	["Bahamas"] = true, ["Fidji"] = true, ["Bermudes"] = true, ["Îles Salomon"] = true,
	["Îles Malouines"] = true, ["Terres australes françaises"] = true, ["Comores"] = true, ["Maldives"] = true,
}

-- premier mot d'un nom au pluriel (« les Îles Canaries », « les Pouilles »)
local PLURAL_WORDS: { [string]: boolean } = {
	["Îles"] = true, Iles = true, Terres = true, Hauts = true, Zones = true, ["Frontières"] = true, Peuples = true,
	Petites = true, Visayas = true, Marches = true, Pouilles = true, Abruzzes = true, Asturies = true, Moluques = true,
	Lacs = true, Savanes = true, Grisons = true,
}

-- article déjà compris dans le nom
local BUILT_IN: { [string]: boolean } = { Le = true, La = true, Les = true }

local NO_ARTICLE: { [string]: boolean } = {
	Cuba = true, Chypre = true, Djibouti = true, ["Haïti"] = true, ["Israël"] = true, Madagascar = true,
	Malte = true, Oman = true, ["Taïwan"] = true, ["Trinité-et-Tobago"] = true, Singapour = true, Monaco = true,
}

local MASCULINE: { [string]: boolean } = {
	Mexique = true, Cambodge = true, Mozambique = true, Zimbabwe = true, Belize = true, Suriname = true,
}

-- premier mot d'un nom composé (« Royaume-Uni », « Pacte de l'Est ») qui décide du genre
local MASCULINE_WORDS: { [string]: boolean } = {
	Royaume = true, Pacte = true, Front = true, Cercle = true, Timor = true, Soudan = true,
	Centre = true, Territoire = true, Bade = true, District = true, Grand = true,
}
local FEMININE_WORDS: { [string]: boolean } = {
	["Corée"] = true, ["Macédoine"] = true, ["Guinée"] = true, RD = true, ["Rép."] = true, Nouvelle = true,
	Papouasie = true, ["Côte"] = true, Sierra = true, Bosnie = true, Ligue = true, Coalition = true, Concorde = true,
	["Région"] = true, Mer = true, Province = true, ["Fédération"] = true, ["Communauté"] = true,
}

-- Capitales : une ville ne prend pas d'article (« Berne »), sauf si c'est aussi le nom d'un pays
-- (« le Luxembourg »)
local CITIES: { [string]: boolean } = {}
do
	local countryNames: { [string]: boolean } = {}
	for _, country in Countries do
		countryNames[country.name] = true
	end
	for _, country in Countries do
		if not countryNames[country.capital.name] then
			CITIES[country.capital.name] = true
		end
	end
end

local VOWELS = "^[AEIOUYÂÉÈÊÎÏÔÛÜaeiouyâéèêîïôûü]"

local function startsWithVowel(name: string): boolean
	return name:match(VOWELS) ~= nil or name:sub(1, 2) == "É" or name:sub(1, 2) == "Î"
end

-- Article d'un nom : « le », « la », « l' », « les » ou rien
function FrenchNames.article(name: string): string
	local first = name:match("^[^%s%-]+") or name
	if PLURAL[name] or PLURAL_WORDS[first] then
		return "les "
	elseif NO_ARTICLE[name] or CITIES[name] or BUILT_IN[first] then
		return ""
	elseif startsWithVowel(name) then
		return "l'"
	elseif MASCULINE[name] or MASCULINE_WORDS[first] then
		return "le "
	elseif FEMININE_WORDS[first] then
		return "la "
	end
	-- le premier mot donne le genre (pour un nom d'un seul mot, c'est le nom lui-même)
	return if first:sub(-1) == "e" then "la " else "le "
end

-- Nom au pluriel (« les États-Unis ») : le verbe s'accorde
function FrenchNames.isPlural(name: string): boolean
	return PLURAL[name] == true
end

-- « la France », « l'Espagne », « les États-Unis », « Cuba »
function FrenchNames.the(name: string): string
	return FrenchNames.article(name) .. name
end

-- Même chose avec une majuscule, en début de phrase : « La France », « L'Espagne »
function FrenchNames.The(name: string): string
	local text = FrenchNames.the(name)
	local first = text:sub(1, 1)
	return if first:match("%l") then first:upper() .. text:sub(2) else text
end

-- « de la France », « du Brésil », « des États-Unis », « de l'Espagne », « d'Israël », « de Cuba »
function FrenchNames.of(name: string): string
	-- « Le Caire » -> « du Caire », « Les Cayes » -> « des Cayes »
	if name:sub(1, 3) == "Le " then
		return "du " .. name:sub(4)
	elseif name:sub(1, 4) == "Les " then
		return "des " .. name:sub(5)
	end
	local article = FrenchNames.article(name)
	if article == "le " then
		return "du " .. name
	elseif article == "les " then
		return "des " .. name
	elseif article == "" then
		return (if startsWithVowel(name) or name:sub(1, 1) == "H" then "d'" else "de ") .. name
	end
	return "de " .. article .. name
end

-- « à la France », « au Brésil », « aux États-Unis », « à l'Espagne », « à Cuba »
function FrenchNames.to(name: string): string
	if name:sub(1, 3) == "Le " then
		return "au " .. name:sub(4)
	elseif name:sub(1, 4) == "Les " then
		return "aux " .. name:sub(5)
	end
	local article = FrenchNames.article(name)
	if article == "le " then
		return "au " .. name
	elseif article == "les " then
		return "aux " .. name
	end
	return "à " .. article .. name
end

return FrenchNames
