--!strict
-- Tableau des stocks d'un pays : pour chaque ressource, stock, production des régions,
-- bilan des usines au dernier cycle, entretien de l'armée et total par cycle.
-- Composant placé dans un conteneur.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Resources = require(Config:WaitForChild("Resources")) :: any
local Economy = require(Config:WaitForChild("Economy")) :: any
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local ResourceText = require(script.Parent:WaitForChild("ResourceText"))

local COLUMNS = { 0.3, 0.15, 0.14, 0.13, 0.13, 0.15 } -- Ressource | Stock | Régions | Bâtiments | Consommation (armée, habitants) | Total
local GREEN, RED = "#78DC82", "#EB5F55"

local StockTable = {}

local function signed(n: number): string
	if n == 0 then
		return `<font color="{UIStyle.GREY_HEX}">—</font>`
	end
	return `<font color="{if n > 0 then GREEN else RED}">{if n > 0 then "+" else "-"}{ResourceText.number(math.abs(n))}</font>`
end

local function makeRow(parent: Instance, name: string, order: number, texts: { string }, header: boolean?): { TextLabel }
	local row = Instance.new("Frame")
	row.Name = name
	row.LayoutOrder = order
	row.BackgroundColor3 = if header then UIStyle.PANEL_RAISED else UIStyle.PANEL_ALT
	row.BackgroundTransparency = if header then 0.08 elseif order % 2 == 0 then 0.48 else 1
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, 0, 0, 28)
	local labels = {}
	local x = 0
	for i, width in COLUMNS do
		local label = UIStyle.text("Col" .. i, texts[i] or "", if header then 13 else 16, if header then UIStyle.FONT_MEDIUM else UIStyle.FONT)
		label.AutomaticSize = Enum.AutomaticSize.None
		label.Position = UDim2.new(x, if i == 1 then 8 else 0, 0, 0)
		label.Size = UDim2.new(width, -8, 1, 0)
		label.TextXAlignment = if i == 1 then Enum.TextXAlignment.Left else Enum.TextXAlignment.Right
		label.TextYAlignment = Enum.TextYAlignment.Center
		label.TextWrapped = false
		label.TextTruncate = Enum.TextTruncate.AtEnd
		if header then
			label.TextColor3 = UIStyle.TEXT_DIM
		end
		label.Parent = row
		table.insert(labels, label)
		x += width
	end
	row.Parent = parent
	return labels
end

-- Crée le tableau dans `parent` ; renvoie la fonction de mise à jour (stocks du dossier du pays + flux)
function StockTable.create(parent: Instance, order: number): (folder: Instance, flows: any) -> ()
	local frame = Instance.new("Frame")
	frame.Name = "TableauStocks"
	frame.LayoutOrder = order
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	UIStyle.list(frame, 2)
	frame.Parent = parent

	makeRow(frame, "Entetes", 0, { "Ressource", "Stock", "Régions", "Bâtiments", "Conso.", `Total / {Economy.productionInterval} s` }, true)
	local cells: { [string]: { TextLabel } } = {}
	for i, id in Resources.order do
		local r = Resources.list[id]
		cells[id] = makeRow(frame, id, i, { `{r.icon} {r.name}` })
	end

	return function(folder: Instance, flows: any)
		for _, id in Resources.order do
			local labels = cells[id]
			local stock = folder:GetAttribute(id)
			local regions = flows.regions[id] or 0
			local factories = flows.factories[id] or 0
			-- consommation : forces militaires et habitants
			local army = (flows.army[id] or 0) + (flows.population and flows.population[id] or 0)
			labels[2].Text = `<b>{ResourceText.number(if typeof(stock) == "number" then stock else 0)}</b>`
			labels[3].Text = signed(regions)
			labels[4].Text = signed(factories)
			labels[5].Text = signed(army)
			labels[6].Text = `<b>{signed(regions + factories + army)}</b>`
		end
	end
end

return StockTable
