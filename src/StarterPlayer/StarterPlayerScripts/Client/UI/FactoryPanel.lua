--!strict
-- Section « Bâtiments » de la fiche d'une région : ses bâtiments (état, effet, améliorer) et la
-- liste de ceux qu'on peut y construire (voir UI/BuildingWidgets et l'onglet Bâtiments).
-- Visible seulement pour les régions du pays dirigé par le joueur.
-- Les demandes passent par Remotes.ConstruireUsine / Remotes.AmeliorerUsine (validées par le serveur).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BuildingRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BuildingRules")) :: any
local Client = script.Parent.Parent
local RegionView = require(Client:WaitForChild("Map"):WaitForChild("RegionView"))
local FactoryState = require(Client:WaitForChild("State"):WaitForChild("FactoryState"))
local RegionPanel = require(script.Parent:WaitForChild("RegionPanel"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local BuildingWidgets = require(script.Parent:WaitForChild("BuildingWidgets"))

local FactoryPanel = {}

local expanded: string? = nil -- région dont la liste « Construire » est ouverte

local function myCountry(): string?
	local id = Players.LocalPlayer:GetAttribute("Pays")
	return if typeof(id) == "string" then id else nil
end

local function clear(container: Frame)
	for _, child in container:GetChildren() do
		child:Destroy()
	end
end

local function render(regionId: string?, container: Frame)
	local country = myCountry()
	if not regionId or not country or RegionView.getOwner(regionId) ~= country then
		clear(container)
		container:SetAttribute("Signature", nil)
		container.Visible = false
		return
	end
	-- on ne redessine que si ce qui s'affiche change (évite de perdre un clic pendant qu'un bouton
	-- est recréé)
	local open = expanded == regionId
	local sig = `{BuildingWidgets.signature(regionId, country)}|{open}`
	if container:GetAttribute("Signature") == sig then
		return
	end
	clear(container)
	container:SetAttribute("Signature", sig)
	container.Visible = true
	UIStyle.list(container, 6)

	local here = BuildingRules.inRegion(regionId)
	local slots = BuildingRules.slots(regionId)
	local title = UIStyle.text("Titre", `<b>🏗️ Bâtiments</b>  <font color="{UIStyle.GREY_HEX}">{#here}/{slots}</font>`, 18)
	title.LayoutOrder = 1
	title.Parent = container
	for i, building in here do
		BuildingWidgets.row(container, building, country, 1 + i)
	end
	if #here < slots then
		local toggle = UIStyle.button("Construire", if open then "▲ Fermer la liste" else "+ Construire ici", not open)
		toggle.LayoutOrder = 50
		toggle.Size = UDim2.new(1, 0, 0, 40)
		toggle.TextSize = 16
		toggle.Parent = container
		toggle.Activated:Connect(function()
			expanded = if expanded == regionId then nil else regionId
			RegionPanel.refresh()
		end)
		if open then
			BuildingWidgets.picker(container, regionId, country, 51)
		end
	end
end

function FactoryPanel.attach()
	RegionPanel.onShow(function(regionId: string?, container: Frame)
		render(regionId, container)
	end)
	-- redessine quand un bâtiment de la région affichée change
	FactoryState.onChanged(function(factory: Instance)
		if factory:GetAttribute("Region") == RegionPanel.getShown() then
			RegionPanel.refresh()
		end
	end)
	-- compte à rebours des chantiers + boutons qui deviennent disponibles quand les stocks montent
	task.spawn(function()
		while true do
			task.wait(1)
			local shown = RegionPanel.getShown()
			if shown and RegionView.getOwner(shown) == myCountry() then
				RegionPanel.refresh()
			end
		end
	end)
end

return FactoryPanel
