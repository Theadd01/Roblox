--!strict
-- Ordres militaires des joueurs (SYSTEME_MILITAIRE.md, 6.4) : un seul RemoteEvent
-- Remotes.CommandeMilitaire. Le client envoie (requête, ordre, données) ; le serveur vérifie tout
-- (le joueur dirige-t-il ce pays ? ces divisions sont-elles à lui ? ...) puis répond
-- (« Resultat », requête, acceptée, message). Les modules militaires s'y inscrivent :
--   Commands.register(ordre, fonction(pays, données, joueur) -> (accepté, message))
-- Fréquence limitée : Config/Military.commands.perSecond ordres par seconde et par joueur.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Military = require(Config:WaitForChild("Military")) :: any
local Server = script.Parent.Parent
local CountryAssignment = require(Server:WaitForChild("Session"):WaitForChild("CountryAssignment"))
local PlayStyle = require(Server:WaitForChild("Session"):WaitForChild("PlayStyle"))
local RateLimiter = require(Server:WaitForChild("Util"):WaitForChild("RateLimiter"))
local Divisions = require(script.Parent:WaitForChild("Divisions"))

type Handler = (countryId: string, data: { [any]: any }, player: Player) -> (boolean, string?)

local Commands = {}

local handlers: { [string]: Handler } = {}
-- nom d'action pour PlayStyle (style de jeu du joueur, repris par l'IA s'il s'absente)
local styleNames: { [string]: string } = {}

-- Inscrit un ordre. styleName : action équivalente pour PlayStyle (« Recruter », « DeplacerArmee »...)
function Commands.register(order: string, handler: Handler, styleName: string?)
	handlers[order] = handler
	if styleName then
		styleNames[order] = styleName
	end
end

-- Divisions d'une liste d'identifiants envoyée par un client : toutes doivent exister et
-- appartenir au pays (sinon l'ordre est refusé en entier)
function Commands.ownedDivisions(countryId: string, ids: unknown): ({ Instance }?, string?)
	if typeof(ids) ~= "table" then
		return nil, "Aucune division choisie."
	end
	local list = {}
	local seen: { [string]: boolean } = {}
	for _, id in ids :: { any } do
		if typeof(id) ~= "string" or seen[id] then
			return nil, "Sélection invalide."
		end
		seen[id] = true
		local d = Divisions.get(id)
		if not d or d:GetAttribute("Proprietaire") ~= countryId then
			return nil, "Ces divisions ne t'appartiennent pas."
		end
		table.insert(list, d)
		if #list > Military.commands.maxIds then
			return nil, `Pas plus de {Military.commands.maxIds} divisions par ordre.`
		end
	end
	if #list == 0 then
		return nil, "Aucune division choisie."
	end
	return list, nil
end

-- Texte choisi par un joueur et montré aux autres (nom d'un général) : filtré par Roblox ; nil
-- s'il est refusé ou modifié par le filtre
function Commands.filterText(text: unknown, player: Player): string?
	if typeof(text) ~= "string" or #text == 0 or #text > 100 then
		return nil
	end
	local ok, result = pcall(function(): string
		local filtered = TextService:FilterStringAsync(text, player.UserId)
		return filtered:GetNonChatStringForBroadcastAsync()
	end)
	if not ok or result ~= text then
		return nil
	end
	return result
end

function Commands.init()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local event = Instance.new("RemoteEvent")
	event.Name = "CommandeMilitaire"
	event.Parent = remotes
	local limiter = RateLimiter.new(1 / Military.commands.perSecond)

	event.OnServerEvent:Connect(function(player: Player, requestId: unknown, order: unknown, data: unknown)
		if typeof(requestId) ~= "number" then
			return
		end
		local function reply(ok: boolean, message: string?)
			event:FireClient(player, "Resultat", requestId, ok, message)
		end
		if not limiter:allow(player) then
			reply(false, "Doucement, réessaie dans un instant.")
			return
		end
		local handler = if typeof(order) == "string" then handlers[order] else nil
		if not handler then
			reply(false, "Ordre inconnu.")
			return
		end
		if typeof(data) ~= "table" then
			reply(false, "Ordre incomplet.")
			return
		end
		local countryId = CountryAssignment.getCountryOf(player)
		if not countryId then
			reply(false, "Choisis d'abord un pays.")
			return
		end
		local ran, accepted, message = pcall(handler, countryId, data :: any, player)
		if not ran then
			warn(`[Militaire] ordre {order} : {accepted}`)
			reply(false, "Ordre impossible.")
			return
		end
		reply(accepted == true, message)
		if accepted == true then
			local styleName = styleNames[order :: string]
			if styleName then
				PlayStyle.recordAction(countryId, styleName, nil, (data :: any).region)
			end
		end
	end)

	-- Recruter { type, region } : une division à entraîner dans une de ses régions
	Commands.register("Recruter", function(countryId: string, data: { [any]: any }): (boolean, string?)
		return Divisions.recruit(countryId, data.type, data.region)
	end, "Recruter")
end

return Commands
