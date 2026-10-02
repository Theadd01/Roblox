--!strict
-- Morceaux d'interface des bâtiments (Config/Factories, shared/BuildingRules), partagés par l'onglet
-- Bâtiments et la fiche d'une région : ligne d'un bâtiment (état, effet, bouton Améliorer) et liste
-- des bâtiments qu'on peut construire dans une région (coût, effet, ou raison). Les demandes passent
-- par Remotes.ConstruireUsine / Remotes.AmeliorerUsine (le serveur vérifie tout).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Factories = require(Config:WaitForChild("Factories")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local BuildingRules = require(Shared:WaitForChild("BuildingRules")) :: any
local UI = script.Parent
local UIStyle = require(UI:WaitForChild("UIStyle"))
local ResourceText = require(UI:WaitForChild("ResourceText"))
local Toast = require(UI:WaitForChild("Toast"))
local Sfx = require(UI.Parent:WaitForChild("Audio"):WaitForChild("Sfx"))
local RegionView = require(UI.Parent:WaitForChild("Map"):WaitForChild("RegionView"))

local STATUS = {
	Construction = { "#EBBE46", "en construction" },
	Active = { "#78DC82", "en service" },
	Partielle = { "#F0A046", "ralentie" },
	Arret = { "#EB5F55", "arrêtée" },
	Sabotee = { "#EB5F55", "sabotée" },
}

local BuildingWidgets = {}

local busy = false

local function countryFolder(countryId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
end

function BuildingWidgets.canAfford(countryId: string, costs: { [string]: number }): boolean
	local folder = countryFolder(countryId)
	for stockId, amount in costs do
		local value = folder and folder:GetAttribute(stockId)
		if (if typeof(value) == "number" then value else 0) < amount then
			return false
		end
	end
	return true
end

-- Coût du prochain bâtiment de ce type pour ce pays (le prix monte avec le nombre de bâtiments)
function BuildingWidgets.costFor(countryId: string, typeId: string): { [string]: number }
	return BuildingRules.buildCost(typeId, BuildingRules.countBuilt(countryId, RegionView.getOwner))
end

-- Envoie une demande au serveur ; message d'erreur en toast
function BuildingWidgets.ask(remoteName: string, ...: any): boolean
	if busy then
		return false
	end
	busy = true
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild(remoteName) :: RemoteFunction
	local args = { ... }
	local ok, accepted, reason = pcall(function()
		return remote:InvokeServer(table.unpack(args))
	end)
	busy = false
	local success = ok and accepted == true
	Sfx.actionResult(remoteName, success)
	if not success then
		Toast.show(if ok and typeof(reason) == "string" then reason else "Le serveur ne répond pas.", "danger", false)
	end
	return success
end

-- État d'un bâtiment : texte et couleur
function BuildingWidgets.status(building: Instance): (string, string)
	local status = building:GetAttribute("Statut") :: string
	local info = STATUS[status] or STATUS.Arret
	if status == "Construction" then
		local left = ((building:GetAttribute("FinConstruction") :: number?) or 0) - workspace:GetServerTimeNow()
		return `en construction, {math.max(0, math.ceil(left))} s`, info[1]
	elseif status == "Partielle" or (status == "Arret" and building:GetAttribute("ArretJusqua") == nil) then
		return `{info[2]}, manque {building:GetAttribute("Manque")}`, info[1]
	elseif status ~= "Active" then
		return `{info[2]} ({building:GetAttribute("Manque")})`, info[1]
	end
	return info[2], info[1]
end

-- Résumé de ce qui s'affiche pour une région (on ne redessine que s'il change)
function BuildingWidgets.signature(regionId: string, countryId: string): string
	local parts = { regionId }
	for _, building in BuildingRules.inRegion(regionId) do
		local text = BuildingWidgets.status(building)
		local kind = Factories.types[building:GetAttribute("Type") :: string]
		local level = (building:GetAttribute("Niveau") :: number?) or 1
		local cost = kind and kind.upgradeCosts[level + 1]
		table.insert(parts, `{building.Name}:{level}:{text}:{tostring(cost ~= nil and BuildingWidgets.canAfford(countryId, cost))}`)
	end
	for _, typeId in Factories.order do
		table.insert(parts, tostring(BuildingWidgets.canAfford(countryId, BuildingWidgets.costFor(countryId, typeId))))
	end
	table.insert(parts, tostring(BuildingRules.countBuilt(countryId, RegionView.getOwner)))
	return table.concat(parts, "|")
end

-- Ligne d'un bâtiment : icône, nom, niveau, état, effet ; bouton Améliorer (bâtiments du joueur)
function BuildingWidgets.row(parent: Instance, building: Instance, countryId: string, order: number): Frame
	local typeId = building:GetAttribute("Type") :: string
	local kind = Factories.types[typeId]
	local regionId = building:GetAttribute("Region") :: string
	local level = (building:GetAttribute("Niveau") :: number?) or 1
	local row = Instance.new("Frame")
	row.Name = "Batiment_" .. building.Name
	row.LayoutOrder = order
	row.BackgroundColor3 = Color3.new(1, 1, 1)
	row.BackgroundTransparency = 0.95
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	UIStyle.corner(row, 8)
	UIStyle.padding(row, 6, 8)
	UIStyle.list(row, 4)
	local text, color = BuildingWidgets.status(building)
	local effect = BuildingRules.describe(typeId, regionId, level, countryId, ResourceText.number)
	local info = UIStyle.text(
		"Info",
		`{kind.icon} <b>{kind.name}</b> niv. {level}  <font color="{color}">● {text}</font>\n<font color="{UIStyle.GREY_HEX}">{effect}</font>`,
		15
	)
	info.LayoutOrder = 1
	info.Parent = row
	local mine = RegionView.getOwner(regionId) == countryId
	if mine and building:GetAttribute("Statut") ~= "Construction" and level < kind.maxLevel then
		local cost = kind.upgradeCosts[level + 1]
		local nextEffect = BuildingRules.describe(typeId, regionId, level + 1, countryId, ResourceText.number)
		local button = UIStyle.button("Ameliorer", `⬆ Niveau {level + 1} : {ResourceText.cost(cost)}  ({nextEffect})`)
		button.LayoutOrder = 2
		button.Size = UDim2.new(1, 0, 0, 36)
		button.TextSize = 14
		button.TextWrapped = true
		UIStyle.setButtonEnabled(button, BuildingWidgets.canAfford(countryId, cost))
		button.Parent = row
		local buildingId = building.Name
		button.Activated:Connect(function()
			if UIStyle.isEnabled(button) then
				BuildingWidgets.ask("AmeliorerUsine", buildingId)
			end
		end)
	end
	row.Parent = parent
	return row
end

-- Liste des bâtiments à construire dans une région : coût et effet, ou la raison
function BuildingWidgets.picker(parent: Instance, regionId: string, countryId: string, order: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = "Construire"
	frame.LayoutOrder = order
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	UIStyle.list(frame, 4)
	local here = BuildingRules.inRegion(regionId)
	local hasCamp = false
	for _, building in here do
		local kind = Factories.types[building:GetAttribute("Type") :: string]
		if kind and kind.camp then
			hasCamp = true
		end
	end
	for i, typeId in Factories.order do
		local kind = Factories.types[typeId]
		local possible, reason = BuildingRules.canBuildIn(typeId, regionId)
		if possible and kind.camp and hasCamp then
			possible, reason = false, "Il y a déjà un camp dans cette région."
		end
		local cost = BuildingWidgets.costFor(countryId, typeId)
		local effect = BuildingRules.describe(typeId, regionId, 1, countryId, ResourceText.number)
		local label = if possible
			then `{kind.icon} <b>{kind.name}</b> : {ResourceText.cost(cost)} · {kind.buildTime} s\n<font size="13">{effect}</font>`
			else `{kind.icon} <b>{kind.name}</b>\n<font size="13">{reason}</font>`
		local button = UIStyle.button("Construire_" .. typeId, label, possible)
		button.LayoutOrder = i
		button.Size = UDim2.new(1, 0, 0, 48)
		button.TextSize = 15
		button.TextWrapped = true
		button.RichText = true
		UIStyle.setButtonEnabled(button, possible and BuildingWidgets.canAfford(countryId, cost))
		button.Parent = frame
		button.Activated:Connect(function()
			if UIStyle.isEnabled(button) then
				if BuildingWidgets.ask("ConstruireUsine", regionId, typeId) then
					Toast.show(`{kind.icon} {kind.name} : chantier lancé ({Regions[regionId].name}).`, "success", false)
				end
			end
		end)
	end
	frame.Parent = parent
	return frame
end

return BuildingWidgets
