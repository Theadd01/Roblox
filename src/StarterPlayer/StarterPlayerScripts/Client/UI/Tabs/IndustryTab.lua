--!strict
-- Onglet « Industrie » : tableau des stocks, liste de tous les bâtiments du pays et course aux
-- projets décisifs (en tête de l'onglet pendant la phase finale, voir ProjectsView).
-- Le bouton « Voir » centre la carte sur la région du bâtiment et ouvre sa fiche.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Factories = require(Config:WaitForChild("Factories")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local Client = script.Parent.Parent.Parent
local FactoryState = require(Client:WaitForChild("State"):WaitForChild("FactoryState"))
local CountryFlows = require(Client:WaitForChild("State"):WaitForChild("CountryFlows"))
local UI = script.Parent.Parent
local UIStyle = require(UI:WaitForChild("UIStyle"))
local StockTable = require(UI:WaitForChild("StockTable"))
local ResourceText = require(UI:WaitForChild("ResourceText"))
local ProjectsView = require(script.Parent:WaitForChild("ProjectsView"))

local STATUS = {
	Construction = { "#EBBE46", "en construction" },
	Active = { "#78DC82", "en service" },
	Partielle = { "#F0A046", "ralentie" },
	Arret = { "#EB5F55", "arrêtée" },
	Sabotee = { "#EB5F55", "sabotée" },
}

export type Options = {
	focusRegion: (regionId: string) -> (),
}

local IndustryTab = {}

local function section(parent: Instance, text: string, order: number)
	local label = UIStyle.text("Section" .. order, `<b>{text}</b>`, 19, UIStyle.FONT_BOLD)
	label.LayoutOrder = order
	label.Parent = parent
end

-- Remplit `container` ; renvoie une fonction qui arrête les mises à jour
function IndustryTab.build(container: Instance, countryId: string, options: Options): () -> ()
	local folder = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Pays"):WaitForChild(countryId)
	local credits = UIStyle.text("Credits", "", 18)
	credits.LayoutOrder = 1
	credits.Parent = container

	section(container, "Stocks", 2)
	local updateTable = StockTable.create(container, 3)

	section(container, "Bâtiments", 4)
	local summary = UIStyle.text("Resume", "", 15, UIStyle.FONT_MEDIUM, UIStyle.TEXT_DIM)
	summary.LayoutOrder = 5
	summary.Parent = container

	local list = Instance.new("Frame")
	list.Name = "ListeUsines"
	list.LayoutOrder = 6
	list.BackgroundTransparency = 1
	list.Size = UDim2.new(1, 0, 0, 0)
	list.AutomaticSize = Enum.AutomaticSize.Y
	list.Parent = container

	local lastSignature = ""
	local function refreshFactories(flows: any)
		local factories = FactoryState.ownedBy(countryId)
		-- on ne redessine la liste que si elle a changé (évite de perdre un clic)
		local parts = {}
		for _, f in factories do
			table.insert(parts, `{f.Name}:{f:GetAttribute("Statut")}:{f:GetAttribute("Niveau")}:{f:GetAttribute("Lots")}`)
		end
		local sig = table.concat(parts, "|")
		if sig == lastSignature and #list:GetChildren() > 0 then
			return
		end
		lastSignature = sig

		for _, child in list:GetChildren() do
			child:Destroy()
		end
		UIStyle.list(list, 6)
		local c = flows.counts
		summary.Text = if c.total == 0
			then "Aucun bâtiment construit. Onglet Bâtiments : champs de blé, mines, puits, usines, camps militaires."
			else `{c.total} bâtiment{if c.total > 1 then "s" else ""} : {c.running} en service, {c.stopped} arrêté{if c.stopped > 1 then "s" else ""}, {c.building} en construction`

		for i, factory in factories do
			local kind = Factories.types[factory:GetAttribute("Type") :: string]
			local regionId = factory:GetAttribute("Region") :: string
			local status = STATUS[factory:GetAttribute("Statut") :: string] or STATUS.Arret
			local row = Instance.new("Frame")
			row.Name = factory.Name
			row.LayoutOrder = i
			row.BackgroundColor3 = UIStyle.PANEL_ALT
			row.BackgroundTransparency = 0.16
			row.Size = UDim2.new(1, 0, 0, 44)
			UIStyle.corner(row, 8)
			UIStyle.stroke(row, 0.68, UIStyle.BORDER_SOFT)

			local info = UIStyle.text(
				"Info",
				`{kind.icon} <b>{kind.name}</b> niv. {factory:GetAttribute("Niveau")} · {Regions[regionId].name}   <font color="{status[1]}">● {status[2]}</font>`,
				16
			)
			info.AutomaticSize = Enum.AutomaticSize.None
			info.Position = UDim2.fromOffset(10, 0)
			info.Size = UDim2.new(1, -110, 1, 0)
			info.TextYAlignment = Enum.TextYAlignment.Center
			info.TextTruncate = Enum.TextTruncate.AtEnd
			info.TextWrapped = false
			info.Parent = row

			local see = UIStyle.button("Voir", "Voir")
			see.AnchorPoint = Vector2.new(1, 0.5)
			see.Position = UDim2.new(1, -6, 0.5, 0)
			see.Size = UDim2.fromOffset(88, 34)
			see.TextSize = 16
			see.Parent = row
			see.Activated:Connect(function()
				options.focusRegion(regionId)
			end)
			row.Parent = list
		end
	end

	local function refresh()
		local flows = CountryFlows.compute(countryId)
		local value = folder:GetAttribute(Resources.currency.id)
		credits.Text = `{Resources.currency.icon} <b>{ResourceText.number(if typeof(value) == "number" then value else 0)}</b> {Resources.currency.name}`
		updateTable(folder, flows)
		refreshFactories(flows)
	end

	local stopProjects = ProjectsView.build(container, 7, countryId)
	local connection = folder.AttributeChanged:Connect(refresh)
	local unsubscribe = FactoryState.onChanged(function()
		refresh()
	end)
	refresh()

	return function()
		connection:Disconnect()
		unsubscribe()
		stopProjects()
	end
end

return IndustryTab
