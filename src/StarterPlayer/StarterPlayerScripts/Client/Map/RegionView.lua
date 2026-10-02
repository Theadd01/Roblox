--!strict
-- Affiche l'état du monde publié par le serveur (ReplicatedStorage.EtatMonde) :
--   Regions.<id>  attribut Proprietaire -> couleur de la région
--   Pays.<code>   attributs Joueur / JoueurNom -> pays dirigés par des joueurs
-- En mode « choix du pays », les pays déjà pris par d'autres joueurs sont grisés.
-- En partie, les régions hors de vue (brouillard de guerre, voir State/Fog) sont assombries.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapBuilder = require(script.Parent:WaitForChild("MapBuilder"))
local Espionage = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Espionage")) :: any

type Listener = (id: string) -> ()

export type Controller = {
	userId: number,
	name: string,
}

local RegionView = {}

local owners: { [string]: string } = {} -- région -> pays propriétaire
local controllers: { [string]: Controller } = {} -- pays -> joueur qui le dirige
local regionListeners: { Listener } = {}
local countryListeners: { Listener } = {}
local selectionMode = false
local carte: Model? = nil
local fog: { [string]: boolean }? = nil -- régions visibles (nil : pas de brouillard)

local function repaint(regionId: string)
	local owner = owners[regionId]
	if not owner or not carte then
		return
	end
	local controller = controllers[owner]
	local takenBy = nil
	if selectionMode and controller and controller.userId ~= Players.LocalPlayer.UserId then
		takenBy = controller.name
	end
	local dim = if fog and not fog[regionId] then Espionage.fogDim else nil
	MapBuilder.paintRegion(carte, regionId, owner, takenBy, dim)
end

local function notify(list: { Listener }, id: string)
	for _, listener in list do
		task.spawn(listener, id)
	end
end

function RegionView.start(map: Model)
	carte = map
	local state = ReplicatedStorage:WaitForChild("EtatMonde")

	local function trackRegion(folder: Instance)
		local regionId = folder.Name
		local function update()
			local owner = folder:GetAttribute("Proprietaire")
			if typeof(owner) ~= "string" then
				return
			end
			owners[regionId] = owner
			repaint(regionId)
			notify(regionListeners, regionId)
		end
		folder:GetAttributeChangedSignal("Proprietaire"):Connect(update)
		update()
	end

	local function trackCountry(folder: Instance)
		local countryId = folder.Name
		local function update()
			local userId = folder:GetAttribute("Joueur")
			local name = folder:GetAttribute("JoueurNom")
			if typeof(userId) == "number" and userId ~= 0 then
				controllers[countryId] = { userId = userId, name = if typeof(name) == "string" then name else "?" }
			else
				controllers[countryId] = nil
			end
			for regionId, owner in owners do
				if owner == countryId then
					repaint(regionId)
				end
			end
			notify(countryListeners, countryId)
		end
		folder:GetAttributeChangedSignal("Joueur"):Connect(update)
		folder:GetAttributeChangedSignal("JoueurNom"):Connect(update)
		update()
	end

	local regions = state:WaitForChild("Regions")
	for _, folder in regions:GetChildren() do
		trackRegion(folder)
	end
	regions.ChildAdded:Connect(trackRegion)

	local pays = state:WaitForChild("Pays")
	for _, folder in pays:GetChildren() do
		trackCountry(folder)
	end
	pays.ChildAdded:Connect(trackCountry)
end

function RegionView.getOwner(regionId: string): string?
	return owners[regionId]
end

-- Joueur qui dirige un pays (nil = pays libre, géré par l'IA)
function RegionView.getController(countryId: string): Controller?
	return controllers[countryId]
end

-- Mode « choix du pays » : grise les pays déjà pris par d'autres joueurs
function RegionView.setSelectionMode(enabled: boolean)
	selectionMode = enabled
	for regionId in owners do
		repaint(regionId)
	end
end

-- Brouillard de guerre : régions visibles (nil = tout est visible). Seules les régions dont
-- l'état change sont repeintes.
function RegionView.setFog(visible: { [string]: boolean }?)
	local previous = fog
	fog = visible
	for regionId in owners do
		local was = previous == nil or previous[regionId] == true
		local now = visible == nil or visible[regionId] == true
		if was ~= now then
			repaint(regionId)
		end
	end
end

-- Appelé à chaque changement de propriétaire d'une région
function RegionView.onOwnerChanged(listener: Listener)
	table.insert(regionListeners, listener)
end

-- Appelé quand un pays est pris ou libéré par un joueur
function RegionView.onControllerChanged(listener: Listener)
	table.insert(countryListeners, listener)
end

return RegionView
