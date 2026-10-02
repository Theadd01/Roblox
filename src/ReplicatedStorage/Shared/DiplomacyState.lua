--!strict
-- Lecture de l'état diplomatique publié par le serveur (ReplicatedStorage.EtatMonde.Diplomatie),
-- utilisable côté serveur comme côté client : blocs, guerres, trêves.
-- Seul server/Politics/DiplomacyService le modifie.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DiplomacyState = {}

export type Relation = "Allie" | "Guerre" | "Treve" | "Paix"

local function folder(name: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local diplomatie = state and state:FindFirstChild("Diplomatie")
	return diplomatie and diplomatie:FindFirstChild(name)
end

local function countryFolder(countryId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
end

-- Clé d'une paire de pays (ordre alphabétique) : « DEU_FRA »
function DiplomacyState.pairKey(a: string, b: string): string
	return if a < b then a .. "_" .. b else b .. "_" .. a
end

function DiplomacyState.blocOf(countryId: string): string?
	local country = countryFolder(countryId)
	local bloc = country and country:GetAttribute("Bloc")
	return if typeof(bloc) == "string" and bloc ~= "" then bloc else nil
end

function DiplomacyState.members(blocId: string): { string }
	local blocs = folder("Blocs")
	local bloc = blocs and blocs:FindFirstChild(blocId)
	local text = bloc and bloc:GetAttribute("Membres")
	local list = {}
	if typeof(text) == "string" then
		for id in text:gmatch("[^,]+") do
			table.insert(list, id)
		end
	end
	return list
end

-- Nom du bloc d'un pays (nil s'il n'en a pas)
function DiplomacyState.blocName(countryId: string): string?
	local blocId = DiplomacyState.blocOf(countryId)
	local blocs = folder("Blocs")
	local bloc = blocId and blocs and blocs:FindFirstChild(blocId)
	local name = bloc and bloc:GetAttribute("Nom")
	return if typeof(name) == "string" then name else nil
end

-- Alliés d'un pays : les autres membres de son bloc
function DiplomacyState.alliesOf(countryId: string): { string }
	local blocId = DiplomacyState.blocOf(countryId)
	local list = {}
	if blocId then
		for _, id in DiplomacyState.members(blocId) do
			if id ~= countryId then
				table.insert(list, id)
			end
		end
	end
	return list
end

function DiplomacyState.areAllies(a: string, b: string): boolean
	if a == b then
		return false
	end
	local bloc = DiplomacyState.blocOf(a)
	return bloc ~= nil and bloc == DiplomacyState.blocOf(b)
end

function DiplomacyState.atWar(a: string, b: string): boolean
	local wars = folder("Guerres")
	return wars ~= nil and a ~= b and wars:FindFirstChild(DiplomacyState.pairKey(a, b)) ~= nil
end

-- Depuis quand deux pays sont en guerre (heure serveur), nil s'ils ne le sont pas
function DiplomacyState.warSince(a: string, b: string): number?
	local wars = folder("Guerres")
	local war = wars and wars:FindFirstChild(DiplomacyState.pairKey(a, b))
	local since = war and war:GetAttribute("Depuis")
	return if typeof(since) == "number" then since else nil
end

-- Secondes de trêve restantes entre deux pays (0 : pas de trêve)
function DiplomacyState.truceLeft(a: string, b: string): number
	local truces = folder("Treves")
	local truce = if truces and a ~= b then truces:FindFirstChild(DiplomacyState.pairKey(a, b)) else nil
	local finish = truce and truce:GetAttribute("Fin")
	return if typeof(finish) == "number" then math.max(0, finish - workspace:GetServerTimeNow()) else 0
end

-- Pays en guerre contre `countryId`
function DiplomacyState.enemiesOf(countryId: string): { string }
	local list = {}
	local wars = folder("Guerres")
	for _, war in (if wars then wars:GetChildren() else {}) do
		local a, b = war:GetAttribute("A"), war:GetAttribute("B")
		if a == countryId and typeof(b) == "string" then
			table.insert(list, b)
		elseif b == countryId and typeof(a) == "string" then
			table.insert(list, a)
		end
	end
	table.sort(list)
	return list
end

-- Embargo entre deux pays (dans un sens ou dans l'autre) : aucun contrat possible entre eux
function DiplomacyState.hasEmbargo(a: string, b: string): boolean
	local embargos = folder("Embargos")
	return embargos ~= nil and (embargos:FindFirstChild(a .. ">" .. b) ~= nil or embargos:FindFirstChild(b .. ">" .. a) ~= nil)
end

-- Pays visés par un embargo de `countryId`, et pays qui visent `countryId`
function DiplomacyState.embargoes(countryId: string): ({ string }, { string })
	local by, against = {}, {}
	local embargos = folder("Embargos")
	for _, embargo in (if embargos then embargos:GetChildren() else {}) do
		local from, target = embargo:GetAttribute("De"), embargo:GetAttribute("Contre")
		if from == countryId and typeof(target) == "string" then
			table.insert(by, target)
		elseif target == countryId and typeof(from) == "string" then
			table.insert(against, from)
		end
	end
	table.sort(by)
	table.sort(against)
	return by, against
end

-- Réputation d'un pays (0 à 100 ; voir DilemmaService) : les IA s'y fient
function DiplomacyState.reputation(countryId: string): number
	local country = countryFolder(countryId)
	local value = country and country:GetAttribute("Reputation")
	return if typeof(value) == "number" then value else 50
end

-- Secondes de protection de départ restantes (pays qu'un joueur vient de prendre ; 0 : aucune)
function DiplomacyState.protectionLeft(countryId: string): number
	local country = countryFolder(countryId)
	local finish = country and country:GetAttribute("Protection")
	return if typeof(finish) == "number" then math.max(0, finish - workspace:GetServerTimeNow()) else 0
end

-- Relation entre deux pays
function DiplomacyState.relation(a: string, b: string): Relation
	if DiplomacyState.areAllies(a, b) then
		return "Allie"
	elseif DiplomacyState.atWar(a, b) then
		return "Guerre"
	elseif DiplomacyState.truceLeft(a, b) > 0 then
		return "Treve"
	end
	return "Paix"
end

-- Tous les blocs : { id, nom, membres }
function DiplomacyState.blocs(): { { id: string, name: string, members: { string } } }
	local list = {}
	local blocs = folder("Blocs")
	for _, bloc in (if blocs then blocs:GetChildren() else {}) do
		table.insert(list, { id = bloc.Name, name = tostring(bloc:GetAttribute("Nom")), members = DiplomacyState.members(bloc.Name) })
	end
	table.sort(list, function(x, y)
		return x.name < y.name
	end)
	return list
end

-- Dossier publié (Blocs, Guerres, Treves, Propositions, Embargos), pour s'abonner aux changements
function DiplomacyState.folder(name: string): Instance?
	return folder(name)
end

return DiplomacyState
