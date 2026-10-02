--!strict
-- Attribution des pays aux joueurs. Le serveur valide chaque demande.
-- État publié dans ReplicatedStorage.EtatMonde.Pays.<code> :
--   Joueur    = UserId du joueur qui dirige le pays (0 = libre, géré par l'IA)
--   JoueurNom = pseudo affiché
--   Absent    = vrai quand son joueur est inactif : l'IA dirige le pays (voir PlayerRelay)
-- Le client demande un pays avec Remotes.ChoisirPays:InvokeServer(code).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Countries = require(Config:WaitForChild("Countries")) :: any
local MatchState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MatchState")) :: any

local REQUEST_COOLDOWN = 0.5 -- secondes minimum entre deux demandes d'un même joueur

local CountryAssignment = {}

local lastRequest: { [Player]: number } = {}
local assignedListeners: { (player: Player, countryId: string) -> () } = {}
local releasedListeners: { (player: Player, countryId: string) -> () } = {}

local function countryFolder(countryId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
end

function CountryAssignment.getCountryOf(player: Player): string?
	local countryId = player:GetAttribute("Pays")
	return if typeof(countryId) == "string" and countryId ~= "" then countryId else nil
end

-- Le pays est-il dirigé par l'IA en ce moment ? (pas de joueur, ou son joueur est absent)
function CountryAssignment.isAIControlled(countryId: string): boolean
	local folder = countryFolder(countryId)
	return folder ~= nil and (folder:GetAttribute("Joueur") == 0 or folder:GetAttribute("Absent") == true)
end

-- listener(joueur, pays) : un joueur vient de prendre un pays
function CountryAssignment.onAssigned(listener: (player: Player, countryId: string) -> ())
	table.insert(assignedListeners, listener)
end

-- listener(joueur, pays) : un joueur vient de quitter son pays (il est parti)
function CountryAssignment.onReleased(listener: (player: Player, countryId: string) -> ())
	table.insert(releasedListeners, listener)
end

-- Le pays redevient libre : l'IA le reprendra (étape 14)
local function release(player: Player)
	local countryId = CountryAssignment.getCountryOf(player)
	if not countryId then
		return
	end
	local folder = countryFolder(countryId)
	if folder and folder:GetAttribute("Joueur") == player.UserId then
		folder:SetAttribute("Joueur", 0)
		folder:SetAttribute("JoueurNom", "")
		folder:SetAttribute("Absent", nil)
	end
	player:SetAttribute("Pays", nil)
	for _, listener in releasedListeners do
		task.spawn(listener, player, countryId)
	end
end

local function choose(player: Player, countryId: unknown): (boolean, string?)
	local now = os.clock()
	local last = lastRequest[player]
	if last and now - last < REQUEST_COOLDOWN then
		return false, "Doucement, réessaie dans un instant."
	end
	lastRequest[player] = now

	if typeof(countryId) ~= "string" or not Countries[countryId] then
		return false, "Pays inconnu."
	end
	if not MatchState.isRunning() then
		return false, "La partie se termine : choisis ton pays dès que la nouvelle commence."
	end
	if CountryAssignment.getCountryOf(player) then
		return false, "Tu diriges déjà un pays."
	end
	local folder = countryFolder(countryId)
	if not folder or folder:GetAttribute("Joueur") ~= 0 then
		return false, "Ce pays est déjà dirigé par un autre joueur."
	end

	folder:SetAttribute("Joueur", player.UserId)
	folder:SetAttribute("JoueurNom", player.DisplayName)
	folder:SetAttribute("Absent", nil)
	player:SetAttribute("Pays", countryId)
	for _, listener in assignedListeners do
		task.spawn(listener, player, countryId)
	end
	return true, nil
end

-- Un joueur quitte son pays pour en diriger un autre, libre (gouvernement en exil, nouvelle partie).
-- Son ancien pays redevient libre : l'IA le reprend.
function CountryAssignment.switch(player: Player, countryId: unknown): (boolean, string?)
	if typeof(countryId) ~= "string" or not Countries[countryId] then
		return false, "Pays inconnu."
	end
	local folder = countryFolder(countryId)
	if not folder or folder:GetAttribute("Joueur") ~= 0 then
		return false, "Ce pays est déjà dirigé par un autre joueur."
	end
	release(player)
	return choose(player, countryId)
end

-- Fin de partie : tous les joueurs quittent leur pays (ils en choisiront un pour la suivante)
function CountryAssignment.releaseAll()
	for _, player in Players:GetPlayers() do
		release(player)
	end
end

-- À appeler après RegionService.init() (qui crée EtatMonde)
function CountryAssignment.init()
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local pays = Instance.new("Folder")
	pays.Name = "Pays"
	for id in Countries do
		local folder = Instance.new("Folder")
		folder.Name = id
		folder:SetAttribute("Joueur", 0)
		folder:SetAttribute("JoueurNom", "")
		folder.Parent = pays
	end
	pays.Parent = state

	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end
	local remote = Instance.new("RemoteFunction")
	remote.Name = "ChoisirPays"
	remote.OnServerInvoke = function(player: Player, countryId: unknown)
		return choose(player, countryId)
	end
	remote.Parent = remotes

	Players.PlayerRemoving:Connect(function(player: Player)
		release(player)
		lastRequest[player] = nil
	end)
end

return CountryAssignment
