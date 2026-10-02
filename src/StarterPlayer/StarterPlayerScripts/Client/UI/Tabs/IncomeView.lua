--!strict
-- Carte « Revenus automatiques » de la Bourse mondiale (onglet Marché) : l'argent qui tombe tout
-- seul à chaque cycle de production. Impôts et ventes automatiques du dernier cycle (publiés par
-- le serveur : attributs Impots, VentesAuto, VentesAutoDetail, AchatsAuto et ReserveAuto_<ressource>
-- du pays), un bouton pour l'achat automatique de nourriture (Remotes.AchatAutomatique) et un bouton
-- par ressource pour activer ou couper sa vente automatique (Remotes.VenteAutomatique ; le serveur
-- vérifie tout, voir AutoSellService).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Resources = require(Config:WaitForChild("Resources")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Economy = require(Config:WaitForChild("Economy")) :: any
local IncomeRules = require(Shared:WaitForChild("IncomeRules")) :: any
local PopulationRules = require(Shared:WaitForChild("PopulationRules")) :: any
local UI = script.Parent.Parent
local UIStyle = require(UI:WaitForChild("UIStyle"))
local ResourceText = require(UI:WaitForChild("ResourceText"))
local Toast = require(UI:WaitForChild("Toast"))
local RegionView = require(UI.Parent:WaitForChild("Map"):WaitForChild("RegionView"))

local ON_COLOR = Color3.fromRGB(46, 112, 66)
local GAIN, LOSS = "#78DC82", "#EB5F55"

local IncomeView = {}

local function number(value: unknown): number
	return if typeof(value) == "number" then value else 0
end

-- « Nourriture:15,MineraiFer:3 » -> « 15 No, 3 Fe »
local function soldText(detail: unknown): string
	if typeof(detail) ~= "string" or detail == "" then
		return ""
	end
	local parts = {}
	for id, amount in string.gmatch(detail, "(%w+):(%d+)") do
		local r = Resources.list[id]
		table.insert(parts, `{amount} {if r then r.icon else id}`)
	end
	return table.concat(parts, ", ")
end

-- Ajoute la carte dans `container` (ordre d'affichage `order`) ; renvoie une fonction qui arrête
-- les mises à jour
function IncomeView.build(container: Instance, countryId: string, order: number): () -> ()
	local folder = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Pays"):WaitForChild(countryId)
	local regionsFolder = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Regions")
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("VenteAutomatique") :: RemoteFunction
	local buyRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("AchatAutomatique") :: RemoteFunction

	local card = Instance.new("Frame")
	card.Name = "RevenusAuto"
	card.LayoutOrder = order
	card.BackgroundColor3 = Color3.new(1, 1, 1)
	card.BackgroundTransparency = 0.93
	card.Size = UDim2.new(1, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	UIStyle.corner(card, 8)
	UIStyle.padding(card, 8, 10)
	UIStyle.list(card, 6)

	local title = UIStyle.text("Titre", "", 17, UIStyle.FONT_BOLD)
	title.LayoutOrder = 1
	title.Parent = card
	local taxes = UIStyle.text("Impots", "", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
	taxes.LayoutOrder = 2
	taxes.Parent = card
	local sales = UIStyle.text("Ventes", "", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
	sales.LayoutOrder = 3
	sales.Parent = card
	-- achat automatique de nourriture (population et divisions)
	local buyRow = Instance.new("Frame")
	buyRow.Name = "AchatsAutomatiques"
	buyRow.LayoutOrder = 4
	buyRow.BackgroundTransparency = 1
	buyRow.Size = UDim2.new(1, 0, 0, 40)
	local purchases = UIStyle.text("Achats", "", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
	purchases.AutomaticSize = Enum.AutomaticSize.None
	purchases.Size = UDim2.new(1, -150, 1, 0)
	purchases.TextYAlignment = Enum.TextYAlignment.Center
	purchases.Parent = buyRow
	local buyToggle = UIStyle.button("AchatAutoNourriture", "")
	buyToggle.AnchorPoint = Vector2.new(1, 0.5)
	buyToggle.Position = UDim2.new(1, 0, 0.5, 0)
	buyToggle.Size = UDim2.fromOffset(142, 36)
	buyToggle.TextSize = 13
	buyToggle.RichText = true
	buyToggle.Parent = buyRow
	buyRow.Parent = card
	local hint = UIStyle.text(
		"AideVente",
		"Vente automatique : à chaque cycle, ce qui dépasse la réserve est vendu au prix du marché. Touche une ressource pour l'activer ou la couper.",
		13,
		UIStyle.FONT,
		UIStyle.TEXT_DIM
	)
	hint.LayoutOrder = 5
	hint.Parent = card

	local grid = Instance.new("Frame")
	grid.Name = "VentesAutomatiques"
	grid.LayoutOrder = 6
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.new(1, 0, 0, 0)
	grid.AutomaticSize = Enum.AutomaticSize.Y
	local layout = Instance.new("UIGridLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.CellSize = UDim2.new(1 / 3, -6, 0, 42)
	layout.CellPadding = UDim2.fromOffset(6, 6)
	layout.Parent = grid
	grid.Parent = card

	local chips: { [string]: TextButton } = {}
	local busy = false
	for i, id in Resources.order do
		local chip = UIStyle.button("VenteAuto_" .. id, "")
		chip.LayoutOrder = i
		chip.TextSize = 14
		chip.TextWrapped = true
		chip.RichText = true
		chip.Parent = grid
		chips[id] = chip
		chip.Activated:Connect(function()
			if busy then
				return
			end
			busy = true
			local enabled = not IncomeRules.autoSellEnabled(folder, id)
			local ok, accepted, reason = pcall(function()
				return remote:InvokeServer(id, enabled)
			end)
			busy = false
			if not ok or accepted ~= true then
				Toast.show(if ok and typeof(reason) == "string" then reason else "Le serveur ne répond pas.", "danger", false)
			end
		end)
	end
	buyToggle.Activated:Connect(function()
		if busy then
			return
		end
		busy = true
		local ok, accepted, reason = pcall(function()
			return buyRemote:InvokeServer(not IncomeRules.autoBuyEnabled(folder))
		end)
		busy = false
		if not ok or accepted ~= true then
			Toast.show(if ok and typeof(reason) == "string" then reason else "Le serveur ne répond pas.", "danger", false)
		end
	end)
	card.Parent = container

	local function refresh()
		local tax = number(folder:GetAttribute("Impots"))
		local sold = number(folder:GetAttribute("VentesAuto"))
		local spent = number(folder:GetAttribute("AchatsAuto"))
		local net = tax + sold - spent
		title.Text = `💰 Revenus automatiques : <font color="{if net >= 0 then GAIN else LOSS}">{if net >= 0 then "+" else "-"}{ResourceText.number(math.abs(net))} {Resources.currency.icon}</font> toutes les {Economy.productionInterval} s`
		-- impôts : payés par les habitants (ceux des régions conquises paient moitié moins)
		local occupied = 0
		for regionId, region in Regions do
			if RegionView.getOwner(regionId) == countryId and region.startOwner ~= countryId then
				local state = regionsFolder:FindFirstChild(regionId)
				occupied += number(state and state:GetAttribute("Population"))
			end
		end
		local conquered = if occupied > 0 then ` (dont {PopulationRules.format(occupied)} conquis, moitié moins)` else ""
		taxes.Text = `🏛️ Impôts : +{ResourceText.number(tax)} {Resources.currency.icon} · payés par {PopulationRules.format(number(folder:GetAttribute("Population")))} d'habitants{conquered} · stabilité {number(folder:GetAttribute("Stabilite"))} %`
		local boughtText = soldText(folder:GetAttribute("AchatsAutoDetail"))
		local buying = IncomeRules.autoBuyEnabled(folder)
		purchases.Text = if not buying then "🛒 Achats automatiques coupés : surveille ta nourriture et ton pétrole."
			elseif spent > 0 then `🛒 Achats automatiques : -{ResourceText.number(spent)} {Resources.currency.icon} ({boughtText})`
			else "🛒 Achats automatiques : nourriture, pétrole et matières des usines, s'il en manque."
		buyToggle.Text = if buying then "<b>✓ Achat auto</b>" else "<b>× Achat auto</b>"
		UIStyle.setButtonColor(buyToggle, if buying then ON_COLOR else UIStyle.PANEL, if buying then UIStyle.TEXT else UIStyle.TEXT_DIM, if buying then 0.1 else 0.15)
		local detail = soldText(folder:GetAttribute("VentesAutoDetail"))
		sales.Text = `🔁 Ventes automatiques : +{ResourceText.number(sold)} {Resources.currency.icon} au dernier cycle` .. (if detail ~= "" then ` ({detail})` else "")
		for id, chip in chips do
			local r = Resources.list[id]
			local reserve = folder:GetAttribute("ReserveAuto_" .. id)
			if IncomeRules.autoSellEnabled(folder, id) then
				local keep = if typeof(reserve) == "number" then `vend au-delà de {ResourceText.number(reserve)}` else "vente auto"
				chip.Text = `<b>✓ {r.name}</b>\n<font size="12">{keep}</font>`
				UIStyle.setButtonColor(chip, ON_COLOR, UIStyle.TEXT, 0.1)
			else
				chip.Text = `<b>× {r.name}</b>\n<font size="12">gardé en stock</font>`
				UIStyle.setButtonColor(chip, UIStyle.PANEL, UIStyle.TEXT_DIM, 0.15)
			end
		end
	end

	-- plusieurs attributs changent d'un coup à chaque cycle : un seul redessin par image
	local pending = false
	local connection = folder.AttributeChanged:Connect(function()
		if pending then
			return
		end
		pending = true
		task.defer(function()
			pending = false
			if card.Parent then
				refresh()
			end
		end)
	end)
	refresh()
	return function()
		connection:Disconnect()
	end
end

return IncomeView
