--!strict
-- Onglet « Bâtiments » : la population du pays (habitants, repas, croissance, impôts, divisions
-- possibles) puis, région par région, ses bâtiments (2 par région, 4 dans la capitale) :
-- améliorer, construire (champs de blé, mines, puits, usines, camps militaires).
-- Toucher 🔍 centre la carte sur la région. Le serveur vérifie tout (FactoryService).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local Factories = require(Config:WaitForChild("Factories")) :: any
local BuildingRules = require(Shared:WaitForChild("BuildingRules")) :: any
local PopulationRules = require(Shared:WaitForChild("PopulationRules")) :: any
local UI = script.Parent.Parent
local Client = UI.Parent
local UIStyle = require(UI:WaitForChild("UIStyle"))
local ResourceText = require(UI:WaitForChild("ResourceText"))
local BuildingWidgets = require(UI:WaitForChild("BuildingWidgets"))
local RegionView = require(Client:WaitForChild("Map"):WaitForChild("RegionView"))
local FactoryState = require(Client:WaitForChild("State"):WaitForChild("FactoryState"))
local MilitaryState = require(Client:WaitForChild("Military"):WaitForChild("MilitaryState"))

export type Options = {
	focusRegion: (regionId: string) -> (),
}

local REFRESH = 0.5 -- secondes entre deux vérifications (chantiers, stocks)

local BuildingsTab = {}

local function number(value: unknown): number
	return if typeof(value) == "number" then value else 0
end

-- Remplit `container` ; renvoie une fonction qui arrête les mises à jour
function BuildingsTab.build(container: Instance, countryId: string, options: Options): () -> ()
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local folder = state:WaitForChild("Pays"):WaitForChild(countryId)
	local regionStates = state:WaitForChild("Regions")
	local alive = true
	local expanded: string? = nil -- région dont la liste « Construire » est ouverte
	local signatures: { [string]: string } = {}
	local frames: { [string]: Frame } = {}

	-- population et résumé
	local summary = Instance.new("Frame")
	summary.Name = "Population"
	summary.LayoutOrder = 1
	summary.BackgroundColor3 = Color3.new(1, 1, 1)
	summary.BackgroundTransparency = 0.93
	summary.Size = UDim2.new(1, 0, 0, 0)
	summary.AutomaticSize = Enum.AutomaticSize.Y
	UIStyle.corner(summary, 8)
	UIStyle.padding(summary, 8, 10)
	UIStyle.list(summary, 4)
	local people = UIStyle.text("Habitants", "", 17, UIStyle.FONT_BOLD)
	people.LayoutOrder = 1
	people.Parent = summary
	local details = UIStyle.text("Details", "", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
	details.LayoutOrder = 2
	details.Parent = summary
	local buildings = UIStyle.text("Batiments", "", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
	buildings.LayoutOrder = 3
	buildings.Parent = summary
	summary.Parent = container

	local hint = UIStyle.text(
		"Aide",
		`Chaque région accueille {Factories.maxPerRegion} bâtiments ({Factories.capitalSlots} dans la capitale). Les divisions se forment dans les camps militaires. Le prix monte avec le nombre de bâtiments du pays.`,
		13,
		UIStyle.FONT,
		UIStyle.TEXT_DIM
	)
	hint.LayoutOrder = 2
	hint.Parent = container

	local list = Instance.new("Frame")
	list.Name = "Regions"
	list.LayoutOrder = 3
	list.BackgroundTransparency = 1
	list.Size = UDim2.new(1, 0, 0, 0)
	list.AutomaticSize = Enum.AutomaticSize.Y
	UIStyle.list(list, 8)
	list.Parent = container

	-- ses régions : la capitale d'abord, puis par nom
	local function ownedRegions(): { string }
		local owned = {}
		for regionId in Regions do
			if RegionView.getOwner(regionId) == countryId then
				table.insert(owned, regionId)
			end
		end
		table.sort(owned, function(a: string, b: string): boolean
			if (a == countryId) ~= (b == countryId) then
				return a == countryId
			end
			return Regions[a].name < Regions[b].name
		end)
		return owned
	end

	local function regionPeople(regionId: string): number
		local regionState = regionStates:FindFirstChild(regionId)
		return number(regionState and regionState:GetAttribute("Population"))
	end

	local renderRegion: (regionId: string, order: number) -> ()

	renderRegion = function(regionId: string, order: number)
		local here = BuildingRules.inRegion(regionId)
		local slots = BuildingRules.slots(regionId)
		local open = expanded == regionId
		local signature = `{BuildingWidgets.signature(regionId, countryId)}|{open}|{PopulationRules.format(regionPeople(regionId))}`
		local frame = frames[regionId]
		if frame and signatures[regionId] == signature then
			frame.LayoutOrder = order
			return
		end
		if frame then
			frame:Destroy()
		end
		signatures[regionId] = signature
		local region = Regions[regionId]
		local box = Instance.new("Frame")
		box.Name = regionId
		box.LayoutOrder = order
		box.BackgroundColor3 = Color3.new(1, 1, 1)
		box.BackgroundTransparency = 0.96
		box.Size = UDim2.new(1, 0, 0, 0)
		box.AutomaticSize = Enum.AutomaticSize.Y
		UIStyle.corner(box, 8)
		UIStyle.padding(box, 6, 8)
		UIStyle.list(box, 5)

		-- en-tête : nom, capitale, emplacements, habitants, bouton pour la voir sur la carte
		local header = Instance.new("Frame")
		header.Name = "Entete"
		header.LayoutOrder = 1
		header.BackgroundTransparency = 1
		header.Size = UDim2.new(1, 0, 0, 34)
		local capital = if regionId == countryId then " · capitale" else ""
		local conquered = if region.startOwner ~= countryId then " · conquise" else ""
		local title = UIStyle.text(
			"Titre",
			`📍 <b>{region.name}</b><font color="{UIStyle.GREY_HEX}">{capital}{conquered} · {#here}/{slots} · 👥 {PopulationRules.format(regionPeople(regionId))}</font>`,
			15
		)
		title.AutomaticSize = Enum.AutomaticSize.None
		title.Size = UDim2.new(1, -46, 1, 0)
		title.TextWrapped = false
		title.TextTruncate = Enum.TextTruncate.AtEnd
		title.TextYAlignment = Enum.TextYAlignment.Center
		title.Parent = header
		local look = UIStyle.button("Voir", "🔍")
		look.AnchorPoint = Vector2.new(1, 0.5)
		look.Position = UDim2.new(1, 0, 0.5, 0)
		look.Size = UDim2.fromOffset(40, 32)
		look.TextSize = 16
		look.Parent = header
		look.Activated:Connect(function()
			options.focusRegion(regionId)
		end)
		header.Parent = box

		for i, building in here do
			BuildingWidgets.row(box, building, countryId, 1 + i)
		end
		if #here < slots then
			local toggle = UIStyle.button("Ouvrir", if open then "▲ Fermer la liste" else `+ Construire ici ({slots - #here} place{if slots - #here > 1 then "s" else ""})`, not open)
			toggle.LayoutOrder = 50
			toggle.Size = UDim2.new(1, 0, 0, 38)
			toggle.TextSize = 15
			toggle.Parent = box
			toggle.Activated:Connect(function()
				expanded = if expanded == regionId then nil else regionId
				renderRegion(regionId, box.LayoutOrder)
			end)
			if open then
				BuildingWidgets.picker(box, regionId, countryId, 51)
			end
		elseif #here == 0 then
			local empty = UIStyle.text("Vide", "Pas de place ici.", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
			empty.LayoutOrder = 50
			empty.Parent = box
		end
		box.Parent = list
		frames[regionId] = box
	end

	local function refresh()
		if not alive then
			return
		end
		-- population
		local total = number(folder:GetAttribute("Population"))
		local growth = number(folder:GetAttribute("Croissance"))
		local food = PopulationRules.food(total)
		local trend = if folder:GetAttribute("Famine") == true then `<font color="#EB5F55">famine : la nourriture manque, la population baisse</font>`
			elseif growth > 0 then `<font color="#78DC82">+{ResourceText.number(growth)} k par cycle</font>`
			else "stable"
		people.Text = `👥 <b>Population : {PopulationRules.format(total)}</b>  {trend}`
		local mine = 0
		for _, d in MilitaryState.list() do
			if d:GetAttribute("Proprietaire") == countryId then
				mine += 1
			end
		end
		details.Text = `🍞 Mange {ResourceText.number(food)} {Resources.list.Nourriture.icon} par cycle · 💰 impôts +{number(folder:GetAttribute("Impots"))} {Resources.currency.icon} · 🎖️ divisions {mine}/{number(folder:GetAttribute("DivisionsMax"))}`
		local built = BuildingRules.countBuilt(countryId, RegionView.getOwner)
		local extra = math.max(0, built - Factories.freeBuildings) * Factories.costGrowth
		buildings.Text = `🏗️ {built} bâtiment{if built > 1 then "s" else ""} construit{if built > 1 then "s" else ""} · prix des prochains : {if extra > 0 then `+{math.floor(extra * 100 + 0.5)} %` else "normal"}`
		-- régions
		local owned = ownedRegions()
		local keep: { [string]: boolean } = {}
		for i, regionId in owned do
			keep[regionId] = true
			renderRegion(regionId, i)
		end
		for regionId, frame in frames do
			if not keep[regionId] then
				frame:Destroy()
				frames[regionId] = nil
				signatures[regionId] = nil
			end
		end
	end

	-- plusieurs attributs changent d'un coup à chaque cycle : un seul redessin par image
	local pending = false
	local function schedule()
		if pending then
			return
		end
		pending = true
		task.defer(function()
			pending = false
			refresh()
		end)
	end
	local connections = {
		folder.AttributeChanged:Connect(schedule),
	}
	local stopFactories = FactoryState.onChanged(function()
		schedule()
	end)
	-- comptes à rebours des chantiers, régions conquises ou perdues
	task.spawn(function()
		while alive do
			task.wait(REFRESH)
			if alive then
				refresh()
			end
		end
	end)
	refresh()
	return function()
		alive = false
		for _, c in connections do
			c:Disconnect()
		end
		stopFactories()
	end
end

return BuildingsTab
