--!strict
-- Vue « Contrats » de l'onglet Marché : commerce direct avec d'autres pays (joueurs ou IA).
--   - propositions reçues (accepter, refuser) et tes contrats (état, livraisons, annuler) ;
--   - nouveau contrat : partenaire, vendre ou acheter, ressource, quantité par cycle, nombre de
--     livraisons, prix par rapport au marché ; embargo contre le partenaire choisi.
-- Le serveur valide tout (ContractService, DiplomacyService).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Trade = require(Config:WaitForChild("Trade")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Economy = require(Config:WaitForChild("Economy")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local UI = script.Parent.Parent
local UIStyle = require(UI:WaitForChild("UIStyle"))
local Sfx = require(script.Parent.Parent.Parent:WaitForChild("Audio"):WaitForChild("Sfx"))
local ResourceText = require(UI:WaitForChild("ResourceText"))
local RegionView = require(UI.Parent:WaitForChild("Map"):WaitForChild("RegionView"))

local STATUS = {
	Propose = "⏳ en attente de réponse",
	Actif = "✅ actif",
	Bloque = "⛔ bloqué",
	Termine = "✔️ terminé",
	Rompu = "❌ rompu",
	Refuse = "❌ refusé",
	Expire = "⌛ sans réponse",
}

local ContractsView = {}

local function nameOf(countryId: string): string
	return if Countries[countryId] then Countries[countryId].name else countryId
end

local function decimal(x: number): string
	return (string.format("%.1f", x):gsub("%.", ","))
end

-- Route commerciale (mêmes règles que le serveur) : « Terre », « Mer » ou nil
local function route(a: string, b: string): string?
	local portA, portB = false, false
	for regionId, region in Regions do
		local owner = RegionView.getOwner(regionId)
		if owner == a then
			portA = portA or region.port ~= nil
			for _, link in region.neighbors do
				if not link.bySea and RegionView.getOwner(link.region) == b then
					return "Terre"
				end
			end
		elseif owner == b then
			portB = portB or region.port ~= nil
		end
	end
	return if portA and portB then "Mer" else nil
end

-- Remplit `container` ; renvoie une fonction qui arrête les mises à jour
function ContractsView.build(container: Instance, countryId: string): () -> ()
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local contracts = state:WaitForChild("Contrats")
	local market = state:WaitForChild("Marche")
	local pays = state:WaitForChild("Pays")
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local message: string? = nil
	local busy = false
	local lastSignature = ""
	local live: { { label: TextLabel, text: () -> string } } = {}

	-- choix du nouveau contrat
	local partnerIndex, resourceIndex = 1, 1
	local sell = true
	local quantity: number = Trade.quantities[2]
	local deliveries: number = Trade.deliveries[2]
	local priceFactor: number = 1

	local render: () -> ()

	local function ask(remoteName: string, ...: any)
		if busy then
			return
		end
		busy = true
		local remote = remotes:WaitForChild(remoteName) :: RemoteFunction
		local args = { ... }
		local ok, accepted, reason = pcall(function()
			return remote:InvokeServer(table.unpack(args))
		end)
		busy = false
		Sfx.actionResult(remoteName, ok and accepted == true)
		message = if ok and accepted == true then nil elseif ok and typeof(reason) == "string" then reason else "Le serveur ne répond pas."
		lastSignature = ""
		render()
	end

	local order = 0
	local function add(instance: GuiObject): GuiObject
		order += 1
		instance.LayoutOrder = 100 + order -- sous le sélecteur Marché / Contrats
		instance.Parent = container
		return instance
	end
	local function text(content: string, size: number?, font: Font?, color: Color3?): TextLabel
		return add(UIStyle.text("Texte", content, size or 16, font, color)) :: TextLabel
	end
	local function title(content: string)
		text(`<b>{content}</b>`, 19, UIStyle.FONT_BOLD)
	end
	-- rangée de petits boutons ; selected : bouton mis en avant
	local function choices(name: string, labels: { string }, selected: number?, onPick: (index: number) -> ())
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.BackgroundTransparency = 1
		frame.Size = UDim2.new(1, 0, 0, 36)
		UIStyle.list(frame, 6, true)
		for i, label in labels do
			local b = UIStyle.button(name .. "_" .. i, label, i == selected)
			b.LayoutOrder = i
			b.Size = UDim2.new(1 / #labels, -6, 1, 0)
			b.TextSize = 14
			b.Activated:Connect(function()
				onPick(i)
			end)
			b.Parent = frame
		end
		add(frame)
	end
	local function row(name: string, label: () -> string, buttonText: string?, onClick: (() -> ())?)
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.BackgroundColor3 = UIStyle.PANEL_ALT
		frame.BackgroundTransparency = 0.16
		frame.Size = UDim2.new(1, 0, 0, 0)
		frame.AutomaticSize = Enum.AutomaticSize.Y
		UIStyle.corner(frame, 8)
		UIStyle.stroke(frame, 0.68, UIStyle.BORDER_SOFT)
		UIStyle.padding(frame, 6, 8)
		local info = UIStyle.text("Info", label(), 14)
		info.Size = UDim2.new(1, if buttonText then -104 else 0, 0, 0)
		info.Parent = frame
		table.insert(live, { label = info, text = label })
		if buttonText and onClick then
			local b = UIStyle.button(name .. "_Bouton", buttonText)
			b.AnchorPoint = Vector2.new(1, 0.5)
			b.Position = UDim2.new(1, 0, 0.5, 0)
			b.Size = UDim2.fromOffset(96, 34)
			b.TextSize = 14
			b.Activated:Connect(onClick)
			b.Parent = frame
		end
		add(frame)
	end

	local function price(resourceId: string): number
		local value = market:GetAttribute(resourceId)
		return if typeof(value) == "number" then value else 0
	end

	-- Partenaires possibles : voisins, alliés, pays des joueurs et partenaires actuels (avec une route)
	local function partners(): { string }
		local seen: { [string]: boolean } = { [countryId] = true }
		local list = {}
		local function consider(id: string?)
			if id and not seen[id] and Countries[id] then
				seen[id] = true
				if route(countryId, id) then
					table.insert(list, id)
				end
			end
		end
		for regionId, region in Regions do
			if RegionView.getOwner(regionId) == countryId then
				for _, link in region.neighbors do
					consider(RegionView.getOwner(link.region))
				end
			end
		end
		for _, ally in DiplomacyState.alliesOf(countryId) do
			consider(ally)
		end
		for _, folder in pays:GetChildren() do
			if folder:GetAttribute("Joueur") ~= 0 then
				consider(folder.Name)
			end
		end
		for _, contract in contracts:GetChildren() do
			consider(contract:GetAttribute("Vendeur") :: string?)
			consider(contract:GetAttribute("Acheteur") :: string?)
		end
		table.sort(list, function(a, b)
			return nameOf(a) < nameOf(b)
		end)
		return list
	end

	local function describe(contract: Instance): string
		local seller, buyer = contract:GetAttribute("Vendeur") :: string, contract:GetAttribute("Acheteur") :: string
		local mineSells = seller == countryId
		local other = if mineSells then buyer else seller
		local r = Resources.list[contract:GetAttribute("Ressource") :: string]
		local way = if contract:GetAttribute("Voie") == "Mer" then "🌊 mer" else "🛤️ terre"
		local fee = contract:GetAttribute("Frais") :: number
		local status = contract:GetAttribute("Statut") :: string
		local total = contract:GetAttribute("Livraisons") :: number
		local done = total - (contract:GetAttribute("Restantes") :: number)
		local head = if mineSells then `📤 Vente à <b>{nameOf(other)}</b>` else `📥 Achat à <b>{nameOf(other)}</b>`
		local info = contract:GetAttribute("Info")
		local line2 = `{STATUS[status] or status} · {done}/{total} livraisons · {way}{if fee > 0 then ` (frais {math.floor(fee * 100 + 0.5)} %)` else ""}`
		if status == "Propose" then
			local left = math.max(0, math.ceil((contract:GetAttribute("Expire") :: number) - workspace:GetServerTimeNow()))
			line2 = `{STATUS.Propose} ({left} s) · {total} livraisons · {way}`
		end
		return `{head} : {contract:GetAttribute("Quantite")} {r.icon} {r.name} / cycle à {decimal(contract:GetAttribute("Prix") :: number)} {Resources.currency.icon}\n`
			.. `<font color="{UIStyle.GREY_HEX}">{line2}{if typeof(info) == "string" and info ~= "" then "\n" .. info else ""}</font>`
	end

	local function renderAll()
		text(`Un contrat livre une ressource à chaque cycle ({Economy.productionInterval} s), à prix fixe. Route par la terre (frontière commune) ou par la mer (un port de chaque côté). En guerre : frais de transport.`, 14, UIStyle.FONT, UIStyle.TEXT_DIM)

		-- propositions reçues
		local received, mine = {}, {}
		for _, contract in contracts:GetChildren() do
			local seller, buyer = contract:GetAttribute("Vendeur"), contract:GetAttribute("Acheteur")
			if seller ~= countryId and buyer ~= countryId then
				continue
			end
			if contract:GetAttribute("Statut") == "Propose" and contract:GetAttribute("ProposePar") ~= countryId then
				table.insert(received, contract)
			else
				table.insert(mine, contract)
			end
		end
		table.sort(mine, function(a, b)
			return (tonumber(a.Name:sub(2)) or 0) > (tonumber(b.Name:sub(2)) or 0)
		end)
		if #received > 0 then
			title("📨 Contrats proposés")
			for _, contract in received do
				local id = contract.Name
				row("Recu_" .. id, function(): string
					return describe(contract)
				end)
				choices("Reponse_" .. id, { "Refuser", "Accepter" }, 2, function(i: number)
					ask("RepondreContrat", id, i == 2)
				end)
			end
		end

		title("📦 Tes contrats")
		if #mine == 0 then
			text("Aucun contrat pour l'instant.", 15, UIStyle.FONT, UIStyle.TEXT_DIM)
		end
		for _, contract in mine do
			local id = contract.Name
			local status = contract:GetAttribute("Statut")
			local open = status == "Actif" or status == "Bloque" or status == "Propose"
			row("Contrat_" .. id, function(): string
				return describe(contract)
			end, if open then (if status == "Propose" then "Retirer" else "Annuler") else nil, function()
				ask("AnnulerContrat", id)
			end)
		end

		-- nouveau contrat
		title("✍️ Nouveau contrat")
		local list = partners()
		if #list == 0 then
			text("Aucun partenaire possible : il faut une frontière commune ou un port de chaque côté.", 15, UIStyle.FONT, UIStyle.TEXT_DIM)
			return
		end
		partnerIndex = math.clamp(partnerIndex, 1, #list)
		local partner = list[partnerIndex]
		local way = route(countryId, partner)
		local relation = DiplomacyState.relation(countryId, partner)
		local embargoBy = table.find((DiplomacyState.embargoes(countryId)), partner) ~= nil
		choices("Partenaire", { "◀", `{nameOf(partner)}`, "▶" }, 2, function(i: number)
			if i == 1 then
				partnerIndex = if partnerIndex <= 1 then #list else partnerIndex - 1
			elseif i == 3 then
				partnerIndex = if partnerIndex >= #list then 1 else partnerIndex + 1
			end
			lastSignature = ""
			render()
		end)
		text(`<font color="{UIStyle.GREY_HEX}">Route : {if way == "Mer" then "🌊 par la mer" else "🛤️ par la terre"}{if relation == "Guerre" then " · ⚔️ en guerre" elseif relation == "Allie" then " · 🤝 allié" else ""}{if DiplomacyState.hasEmbargo(countryId, partner) then " · 🚫 embargo" else ""}</font>`, 14)
		choices("Sens", { "📤 Vendre", "📥 Acheter" }, if sell then 1 else 2, function(i: number)
			sell = i == 1
			lastSignature = ""
			render()
		end)
		local resourceId = Resources.order[resourceIndex]
		local r = Resources.list[resourceId]
		choices("Ressource", { "◀", `{r.icon} {r.name}`, "▶" }, 2, function(i: number)
			if i == 1 then
				resourceIndex = if resourceIndex <= 1 then #Resources.order else resourceIndex - 1
			elseif i == 3 then
				resourceIndex = if resourceIndex >= #Resources.order then 1 else resourceIndex + 1
			end
			lastSignature = ""
			render()
		end)
		local qLabels, qSelected = {}, 1
		for i, q in Trade.quantities do
			table.insert(qLabels, `{q} / cycle`)
			if q == quantity then
				qSelected = i
			end
		end
		choices("Quantite", qLabels, qSelected, function(i: number)
			quantity = Trade.quantities[i]
			lastSignature = ""
			render()
		end)
		local dLabels, dSelected = {}, 1
		for i, d in Trade.deliveries do
			table.insert(dLabels, `{d} livraisons`)
			if d == deliveries then
				dSelected = i
			end
		end
		choices("Livraisons", dLabels, dSelected, function(i: number)
			deliveries = Trade.deliveries[i]
			lastSignature = ""
			render()
		end)
		local fLabels, fSelected = {}, 1
		for i, factor in Trade.priceFactors do
			table.insert(fLabels, if factor == 1 then "prix du marché" else `{if factor > 1 then "+" else ""}{math.floor((factor - 1) * 100 + 0.5)} %`)
			if factor == priceFactor then
				fSelected = i
			end
		end
		choices("Prix", fLabels, fSelected, function(i: number)
			priceFactor = Trade.priceFactors[i]
			lastSignature = ""
			render()
		end)
		row("Resume", function(): string
			local unit = math.max(0.1, math.floor(price(resourceId) * priceFactor * 10 + 0.5) / 10)
			local total = math.floor(unit * quantity * deliveries + 0.5)
			local verb = if sell then "Tu vends" else "Tu achètes"
			return `{verb} {quantity} {r.icon} {r.name} par cycle pendant {deliveries} cycles, à {decimal(unit)} {Resources.currency.icon} l'unité : <b>{ResourceText.number(total)} {Resources.currency.icon}</b> au total.`
		end)
		local propose = UIStyle.button("Proposer", `Proposer à {nameOf(partner)}`, true)
		propose.Size = UDim2.new(1, 0, 0, 42)
		propose.TextSize = 16
		UIStyle.setButtonEnabled(propose, relation ~= "Guerre" and not DiplomacyState.hasEmbargo(countryId, partner))
		propose.Activated:Connect(function()
			if UIStyle.isEnabled(propose) then
				ask("ProposerContrat", partner, resourceId, sell, quantity, deliveries, priceFactor)
			end
		end)
		add(propose)
		local embargo = UIStyle.button("Embargo", if embargoBy then `Lever l'embargo contre {nameOf(partner)}` else `🚫 Embargo contre {nameOf(partner)}`)
		embargo.Size = UDim2.new(1, 0, 0, 38)
		embargo.TextSize = 14
		embargo.Activated:Connect(function()
			ask("Embargo", partner, not embargoBy)
		end)
		add(embargo)

		-- embargos en place
		local by, against = DiplomacyState.embargoes(countryId)
		if #by > 0 or #against > 0 then
			local names = function(ids: { string }): string
				local out = {}
				for _, id in ids do
					table.insert(out, nameOf(id))
				end
				return table.concat(out, ", ")
			end
			text(`🚫 {if #by > 0 then "Tu bloques : " .. names(by) else ""}{if #by > 0 and #against > 0 then "\n" else ""}{if #against > 0 then "Te bloquent : " .. names(against) else ""}`, 14, UIStyle.FONT, UIStyle.TEXT_DIM)
		end
	end

	-- redessine seulement si l'affichage change (évite de perdre un clic)
	local function signature(): string
		local parts = { message or "", tostring(partnerIndex), tostring(resourceIndex), tostring(sell), tostring(quantity), tostring(deliveries), tostring(priceFactor) }
		for _, contract in contracts:GetChildren() do
			if contract:GetAttribute("Vendeur") == countryId or contract:GetAttribute("Acheteur") == countryId then
				table.insert(parts, contract.Name .. tostring(contract:GetAttribute("Statut")))
			end
		end
		local by, against = DiplomacyState.embargoes(countryId)
		table.insert(parts, table.concat(by, ",") .. "/" .. table.concat(against, ","))
		table.insert(parts, table.concat(DiplomacyState.enemiesOf(countryId), ","))
		return table.concat(parts, "|")
	end

	render = function()
		local sig = signature()
		if sig == lastSignature then
			return
		end
		lastSignature = sig
		for _, child in container:GetChildren() do
			if child:IsA("GuiObject") and child.LayoutOrder > 100 then
				child:Destroy()
			end
		end
		order = 0
		table.clear(live)
		renderAll()
		if message then
			text(message, 15, UIStyle.FONT_MEDIUM, UIStyle.DANGER)
		end
	end

	render()
	local connections = {
		contracts.ChildAdded:Connect(render),
		contracts.ChildRemoved:Connect(render),
	}
	local alive = true
	task.spawn(function()
		while alive do
			task.wait(1)
			if alive then
				render()
				for _, item in live do
					item.label.Text = item.text()
				end
			end
		end
	end)
	return function()
		alive = false
		for _, connection in connections do
			connection:Disconnect()
		end
		for _, child in container:GetChildren() do
			if child:IsA("GuiObject") and child.LayoutOrder > 100 then
				child:Destroy()
			end
		end
	end
end

return ContractsView
