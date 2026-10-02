--!strict
-- Onglet « Marché » : deux vues, « Marché mondial » et « Contrats » (voir ContractsView).
-- Marché mondial : acheter et vendre au prix du marché, qui suit l'offre et la demande.
--   En haut : graphique des 10 dernières minutes de la ressource choisie (toucher une ligne).
--   Lignes : stock, prix, tendance sur 1 minute, boutons Acheter / Vendre avec le montant exact.
-- Les prix viennent du serveur (ReplicatedStorage.EtatMonde.Marche) ; chaque échange passe par
-- Remotes.Acheter / Remotes.Vendre avec le montant affiché (refusé si le prix a bougé entre-temps).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Market = require(Config:WaitForChild("Market")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local MarketMath = require(Shared:WaitForChild("MarketMath")) :: any
local UI = script.Parent.Parent
local UIStyle = require(UI:WaitForChild("UIStyle"))
local Sfx = require(script.Parent.Parent.Parent:WaitForChild("Audio"):WaitForChild("Sfx"))
local ResourceText = require(UI:WaitForChild("ResourceText"))
local PriceChart = require(UI:WaitForChild("PriceChart"))
local ContractsView = require(script.Parent:WaitForChild("ContractsView"))
local IncomeView = require(script.Parent:WaitForChild("IncomeView"))
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local Trade = require(Config:WaitForChild("Trade")) :: any
local Council = require(Config:WaitForChild("Council")) :: any
local CouncilState = require(Shared:WaitForChild("CouncilState")) :: any

local UP, DOWN = "#78DC82", "#EB5F55"
local TICKER_SPEED = 60 -- vitesse du bandeau des prix (pixels par seconde)

local RunService = game:GetService("RunService")

local MarketTab = {}

local function decimal(x: number): string
	return (string.format("%.1f", x):gsub("%.", ","))
end

-- « ▲ +5,2 % » / « ▼ -3,0 % »
local function trend(percent: number): string
	if math.abs(percent) < 0.05 then
		return `<font color="{UIStyle.GREY_HEX}">= 0 %</font>`
	end
	local up = percent > 0
	return `<font color="{if up then UP else DOWN}">{if up then "▲ +" else "▼ "}{decimal(percent)} %</font>`
end

-- Vue « Marché mondial » : remplit `container` ; renvoie une fonction qui arrête les mises à jour
local function buildMarket(container: Instance, countryId: string): () -> ()
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local folder = state:WaitForChild("Pays"):WaitForChild(countryId)
	local market = state:WaitForChild("Marche")
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local quantity: number = Market.quantities[1]
	local selected = "Petrole"
	local busy = false

	-- bandeau des prix en direct (défile de droite à gauche)
	local band = Instance.new("Frame")
	band.Name = "BandeauPrix"
	band.LayoutOrder = 0
	band.Size = UDim2.new(1, 0, 0, 28)
	band.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
	band.ClipsDescendants = true
	UIStyle.corner(band, 6)
	local ticker = UIStyle.text("Defilant", "", 15, UIStyle.FONT_MEDIUM)
	ticker.AutomaticSize = Enum.AutomaticSize.X
	ticker.Size = UDim2.new(0, 0, 1, 0)
	ticker.TextWrapped = false
	ticker.TextYAlignment = Enum.TextYAlignment.Center
	ticker.Parent = band
	band.Parent = container
	local offset = 0
	local scrolling = RunService.RenderStepped:Connect(function(dt: number)
		offset += dt * TICKER_SPEED
		local width, room = ticker.AbsoluteSize.X, band.AbsoluteSize.X
		if offset > width + room then
			offset = 0
		end
		ticker.Position = UDim2.fromOffset(room - offset, 0)
	end)

	-- graphique de la ressource choisie
	local chartTitle = UIStyle.text("TitreGraphique", "", 17)
	chartTitle.LayoutOrder = 1
	chartTitle.Parent = container
	local chart = PriceChart.create(container, 2)

	local credits = UIStyle.text("Credits", "", 17)
	credits.LayoutOrder = 3
	credits.Parent = container

	-- choix de la quantité échangée
	local picker = Instance.new("Frame")
	picker.Name = "Quantite"
	picker.LayoutOrder = 4
	picker.BackgroundTransparency = 1
	picker.Size = UDim2.new(1, 0, 0, 38)
	local pickerLayout = UIStyle.list(picker, 8, true)
	pickerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	local label = UIStyle.text("Label", "Quantité :", 16, UIStyle.FONT_MEDIUM)
	label.AutomaticSize = Enum.AutomaticSize.None
	label.Size = UDim2.new(0.25, -6, 1, 0)
	label.TextWrapped = false
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Parent = picker
	local quantityButtons: { [number]: TextButton } = {}
	for i, q in Market.quantities do
		local b = UIStyle.button("Q" .. q, "x " .. q)
		b.LayoutOrder = i
		b.Size = UDim2.new(0.25, -6, 0, 36)
		b.TextSize = 16
		b.Parent = picker
		quantityButtons[q] = b
	end
	picker.Parent = container

	local message = UIStyle.text("Message", "", 15, UIStyle.FONT_MEDIUM, UIStyle.DANGER)
	message.LayoutOrder = 5
	message.Visible = false
	message.Parent = container

	local hint = UIStyle.text(
		"Aide",
		`Les prix suivent l'offre et la demande : acheter fait monter le prix, vendre le fait baisser. Revente à {math.floor(Market.sellRatio * 100)} % de la valeur.`,
		14,
		UIStyle.FONT,
		UIStyle.TEXT_DIM
	)
	hint.LayoutOrder = 6
	hint.Parent = container

	-- revenus automatiques : impôts et vente automatique des surplus (IncomeView)
	local stopIncome = IncomeView.build(container, countryId, 8)

	-- une ligne par ressource
	type Row = { frame: Frame, info: TextLabel, buy: TextButton, sell: TextButton, pick: TextButton }
	local rows: { [string]: Row } = {}
	for i, id in Resources.order do
		local row = Instance.new("Frame")
		row.Name = id
		row.LayoutOrder = 10 + i
		row.BackgroundColor3 = UIStyle.PANEL_ALT
		row.Size = UDim2.new(1, 0, 0, 70)
		UIStyle.corner(row, 8)
		UIStyle.stroke(row, 0.68, UIStyle.BORDER_SOFT)

		local info = UIStyle.text("Info", "", 14)
		info.AutomaticSize = Enum.AutomaticSize.None
		info.Position = UDim2.fromOffset(10, 0)
		info.Size = UDim2.new(1, -196, 1, 0)
		info.TextYAlignment = Enum.TextYAlignment.Center
		info.Parent = row
		-- toucher la partie gauche de la ligne affiche son graphique
		local pick = Instance.new("TextButton")
		pick.Name = "Choisir"
		pick.BackgroundTransparency = 1
		pick.Text = ""
		pick.Size = UDim2.new(1, -196, 1, 0)
		pick.Parent = row

		local buy = UIStyle.button("Acheter", "Acheter", true)
		buy.AnchorPoint = Vector2.new(1, 0.5)
		buy.Position = UDim2.new(1, -94, 0.5, 0)
		buy.Size = UDim2.fromOffset(88, 38)
		buy.TextSize = 15
		buy.Parent = row
		local sell = UIStyle.button("Vendre", "Vendre")
		sell.AnchorPoint = Vector2.new(1, 0.5)
		sell.Position = UDim2.new(1, -4, 0.5, 0)
		sell.Size = UDim2.fromOffset(86, 38)
		sell.TextSize = 15
		sell.Parent = row

		rows[id] = { frame = row, info = info, buy = buy, sell = sell, pick = pick }
		row.Parent = container
	end

	local function stock(id: string): number
		local value = folder:GetAttribute(id)
		return if typeof(value) == "number" then value else 0
	end

	local function price(id: string): number?
		local value = market:GetAttribute(id)
		return if typeof(value) == "number" then value else nil
	end

	local function atWar(): boolean
		return #DiplomacyState.enemiesOf(countryId) > 0
	end

	-- montants affichés sur les boutons (servent aussi de limite envoyée au serveur) ;
	-- en guerre, les frais de transport s'y ajoutent, comme sur le serveur
	local function quote(id: string): (number, number)
		local p = price(id) or 0
		local liquidity = Market.liquidity[id]
		local cost = MarketMath.buyCost(p, quantity, liquidity)
		local revenue = MarketMath.sellRevenue(p, quantity, liquidity, Market.sellRatio)
		if atWar() then
			cost = MarketMath.withWarFee(cost, Trade.marketWarFee, true)
			revenue = MarketMath.withWarFee(revenue, Trade.marketWarFee, false)
		end
		if CouncilState.sanctioned(countryId) then
			cost = MarketMath.withWarFee(cost, Council.sanctionFee, true)
			revenue = MarketMath.withWarFee(revenue, Council.sanctionFee, false)
		end
		return cost, revenue
	end

	local function refresh()
		local money = stock(Resources.currency.id)
		credits.Text = `{Resources.currency.icon} <b>{ResourceText.number(money)}</b> {Resources.currency.name} disponibles`
			.. (if atWar() then `   <font color="#FF9A78">⚔️ en guerre : frais de transport {math.floor(Trade.marketWarFee * 100)} %</font>` else "")
			.. (if CouncilState.sanctioned(countryId) then `   <font color="#EB5F55">⛔ sanctions du Conseil : +{math.floor(Council.sanctionFee * 100)} %</font>` else "")
		for q, b in quantityButtons do
			UIStyle.setButtonSelected(b, q == quantity)
		end

		local tickerParts = {}
		for _, id in Resources.order do
			local row = rows[id]
			local r = Resources.list[id]
			local p = price(id)
			if not p or not row then
				continue
			end
			local history = MarketMath.parseHistory(market:GetAttribute("Historique_" .. id))
			local change = MarketMath.variation(history, Market.variationPoints, p)
			local cost, revenue = quote(id)
			table.insert(tickerParts, `{r.icon} {r.name} <b>{decimal(p)}</b> {trend(change)}`)
			-- plus haut et plus bas des 10 dernières minutes, volume de la dernière minute
			local high, low = p, p
			for _, value in history do
				high = math.max(high, value)
				low = math.min(low, value)
			end
			local volume = market:GetAttribute("Volume_" .. id)
			local extra = `10 min : ▲ {decimal(high)} ▼ {decimal(low)} · volume {if typeof(volume) == "number" then volume else 0}/min`
			-- sa position : quantité achetée au marché encore détenue, et plus-value latente
			local held = folder:GetAttribute("PositionQ_" .. id)
			local average = folder:GetAttribute("PositionP_" .. id)
			if typeof(held) == "number" and held > 0 and typeof(average) == "number" and average > 0 then
				local gain = (p * Market.sellRatio - average) / average * 100
				extra ..= `\n📦 {held} achetés à {decimal(average)} : {trend(gain)} à la revente`
			end
			row.frame.BackgroundTransparency = if id == selected then 0.02 else 0.16
			row.info.Text = `{r.icon} <b>{r.name}</b>   <font color="{UIStyle.GREY_HEX}">stock {ResourceText.number(stock(id))}</font>\n`
				.. `{decimal(p)} {Resources.currency.icon}   {trend(change)}\n<font color="{UIStyle.GREY_HEX}">{extra}</font>`
			row.buy.Text = `Acheter\n{ResourceText.number(cost)}`
			row.sell.Text = `Vendre\n+{ResourceText.number(revenue)}`
			UIStyle.setButtonEnabled(row.buy, money >= cost)
			UIStyle.setButtonEnabled(row.sell, stock(id) >= quantity)
		end
		ticker.Text = table.concat(tickerParts, "      ")

		-- graphique de la ressource choisie
		local r = Resources.list[selected]
		local history = MarketMath.parseHistory(market:GetAttribute("Historique_" .. selected))
		local p = price(selected) or 0
		chartTitle.Text = `📈 <b>{r.icon} {r.name}</b>   {decimal(p)} {Resources.currency.icon}   {trend(MarketMath.variation(history, Market.variationPoints, p))} <font color="{UIStyle.GREY_HEX}">en 1 min</font>`
		chart.set(history, Market.basePrices[selected])
	end

	local function trade(remoteName: string, id: string, limit: number)
		if busy then
			return
		end
		busy = true
		local remote = remotes:WaitForChild(remoteName) :: RemoteFunction
		local ok, accepted, reason = pcall(function()
			return remote:InvokeServer(id, quantity, limit)
		end)
		busy = false
		Sfx.actionResult(remoteName, ok and accepted == true)
		if ok and accepted == true then
			message.Visible = false
		else
			message.Text = if ok and typeof(reason) == "string" then reason else "Le serveur ne répond pas."
			message.Visible = true
		end
		refresh()
	end

	for q, b in quantityButtons do
		b.Activated:Connect(function()
			quantity = q
			refresh()
		end)
	end
	for id, row in rows do
		row.pick.Activated:Connect(function()
			selected = id
			refresh()
		end)
		row.buy.Activated:Connect(function()
			if UIStyle.isEnabled(row.buy) then
				local cost = quote(id)
				trade("Acheter", id, cost)
			end
		end)
		row.sell.Activated:Connect(function()
			if UIStyle.isEnabled(row.sell) then
				local _, revenue = quote(id)
				trade("Vendre", id, revenue)
			end
		end)
	end

	-- plusieurs attributs changent d'un coup (9 prix + 9 historiques) : un seul redessin par image
	local pending = false
	local function scheduleRefresh()
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
		folder.AttributeChanged:Connect(scheduleRefresh),
		market.AttributeChanged:Connect(scheduleRefresh),
	}
	refresh()
	return function()
		scrolling:Disconnect()
		stopIncome()
		for _, c in connections do
			c:Disconnect()
		end
	end
end

-- Remplit `container` : sélecteur « Marché mondial » / « Contrats » en haut, puis la vue choisie ;
-- renvoie une fonction qui arrête les mises à jour
function MarketTab.build(container: Instance, countryId: string): () -> ()
	local switch = Instance.new("Frame")
	switch.Name = "Vues"
	switch.LayoutOrder = -1
	switch.BackgroundTransparency = 1
	switch.Size = UDim2.new(1, 0, 0, 40)
	UIStyle.list(switch, 8, true)
	local views = { { id = "Marche", label = "📈 Bourse mondiale" }, { id = "Contrats", label = "📦 Contrats" } }
	local buttons: { [string]: TextButton } = {}
	for i, view in views do
		local b = UIStyle.button("Vue_" .. view.id, view.label)
		b.LayoutOrder = i
		b.Size = UDim2.new(0.5, -4, 1, 0)
		b.TextSize = 16
		b.Parent = switch
		buttons[view.id] = b
	end
	switch.Parent = container

	local cleanup: (() -> ())? = nil
	local function show(viewId: string)
		if cleanup then
			cleanup()
			cleanup = nil
		end
		for _, child in container:GetChildren() do
			if child ~= switch and child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		for id, b in buttons do
			UIStyle.setButtonSelected(b, id == viewId)
		end
		cleanup = if viewId == "Contrats" then ContractsView.build(container, countryId) else buildMarket(container, countryId)
	end
	for id, b in buttons do
		b.Activated:Connect(function()
			show(id)
		end)
	end
	show("Marche")
	return function()
		if cleanup then
			cleanup()
		end
	end
end

return MarketTab
