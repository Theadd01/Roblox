--!strict
-- Onglet Diplomatie : ton pays (stabilité, opinion publique, leader de la partie),
-- ton bloc (et le quitter), propositions reçues (accepter, refuser),
-- tes guerres (proposer la paix), tes trêves, tes voisins (proposer une alliance, déclarer
-- la guerre) et les blocs du monde. Le serveur valide chaque demande (DiplomacyService).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Personalities = require(Config:WaitForChild("Personalities")) :: any
local Diplomacy = require(Config:WaitForChild("Diplomacy")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local StabilityRules = require(Shared:WaitForChild("StabilityRules")) :: any
local Politics = require(Config:WaitForChild("Politics")) :: any
local CouncilState = require(Shared:WaitForChild("CouncilState")) :: any
local UI = script.Parent.Parent
local UIStyle = require(UI:WaitForChild("UIStyle"))
local Sfx = require(script.Parent.Parent.Parent:WaitForChild("Audio"):WaitForChild("Sfx"))
local RegionView = require(UI.Parent:WaitForChild("Map"):WaitForChild("RegionView"))

local GREEN, RED, ORANGE = "#78DC82", "#EB5F55", "#FF9A78"
local CONFIRM_TIME = 4 -- secondes pour confirmer une déclaration de guerre

local DiplomacyTab = {}

local function nameOf(countryId: string): string
	return if Countries[countryId] then Countries[countryId].name else countryId
end

local function colorDot(countryId: string): string
	local country = Countries[countryId]
	return if country then `<font color="#{country.color:ToHex()}">●</font>` else "●"
end

local function duration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return if seconds >= 60 then `{math.floor(seconds / 60)} min {seconds % 60} s` else `{seconds} s`
end

-- Remplit `container` ; renvoie une fonction qui arrête les mises à jour
function DiplomacyTab.build(container: Instance, countryId: string): () -> ()
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local pays = state:WaitForChild("Pays")
	local diplomatie = state:WaitForChild("Diplomatie")
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local message: string? = nil
	local busy = false
	local lastSignature = ""
	local confirmWar: { target: string, untilTime: number }? = nil
	local live: { { label: TextLabel, text: () -> string } } = {} -- textes mis à jour chaque seconde (comptes à rebours)

	local render: () -> ()

	local function ask(remoteName: string, a: any, b: any)
		if busy then
			return
		end
		busy = true
		local remote = remotes:WaitForChild(remoteName) :: RemoteFunction
		local ok, accepted, reason = pcall(function()
			return remote:InvokeServer(a, b)
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
		instance.LayoutOrder = order
		instance.Parent = container
		return instance
	end
	local function text(content: string, size: number?, font: Font?, color: Color3?): TextLabel
		return add(UIStyle.text("Texte", content, size or 16, font, color)) :: TextLabel
	end
	local function title(content: string)
		text(`<b>{content}</b>`, 19, UIStyle.FONT_BOLD)
	end
	-- Ligne : un texte à gauche (fonction : mis à jour chaque seconde) et jusqu'à deux boutons à droite
	local function row(name: string, label: string | () -> string, buttons: { { name: string, text: string, primary: boolean?, enabled: boolean?, onClick: () -> () } })
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.BackgroundColor3 = UIStyle.PANEL_ALT
		frame.BackgroundTransparency = 0.16
		frame.Size = UDim2.new(1, 0, 0, 0)
		frame.AutomaticSize = Enum.AutomaticSize.Y
		UIStyle.corner(frame, 8)
		UIStyle.stroke(frame, 0.68, UIStyle.BORDER_SOFT)
		UIStyle.padding(frame, 6, 8)
		local width = #buttons * 118
		local info = UIStyle.text("Info", "", 15)
		info.Size = UDim2.new(1, -width - 8, 0, 0)
		if typeof(label) == "function" then
			info.Text = label()
			table.insert(live, { label = info, text = label })
		else
			info.Text = label
		end
		info.Parent = frame
		for i, b in buttons do
			local button = UIStyle.button(b.name, b.text, b.primary)
			button.AnchorPoint = Vector2.new(1, 0.5)
			button.Position = UDim2.new(1, -(i - 1) * 118, 0.5, 0)
			button.Size = UDim2.fromOffset(112, 36)
			button.TextSize = 14
			UIStyle.setButtonEnabled(button, b.enabled ~= false)
			button.Activated:Connect(function()
				if UIStyle.isEnabled(button) then
					b.onClick()
				end
			end)
			button.Parent = frame
		end
		add(frame)
	end

	local function personalityOf(id: string): string
		local folder = pays:FindFirstChild(id)
		if folder and folder:GetAttribute("Joueur") ~= 0 and folder:GetAttribute("Absent") ~= true then
			return `👤 {folder:GetAttribute("JoueurNom")}`
		end
		local personality = Personalities.list[folder and folder:GetAttribute("Personnalite") or ""]
		return if personality then `🤖 {personality.icon} {personality.name}` else "🤖 IA"
	end

	local function relationText(other: string): string
		local relation = DiplomacyState.relation(countryId, other)
		if relation == "Allie" then
			return `<font color="{GREEN}">🤝 allié</font>`
		elseif relation == "Guerre" then
			return `<font color="{RED}">⚔️ en guerre</font>`
		elseif relation == "Treve" then
			return `<font color="{ORANGE}">🕊️ trêve {duration(DiplomacyState.truceLeft(countryId, other))}</font>`
		end
		return "☮️ en paix"
	end

	-- Pays voisins (par la terre ou la mer) de ses régions
	local function neighbours(): { string }
		local seen: { [string]: boolean } = {}
		local list = {}
		for regionId, region in Regions do
			if RegionView.getOwner(regionId) == countryId then
				for _, link in region.neighbors do
					local owner = RegionView.getOwner(link.region)
					if owner and owner ~= countryId and not seen[owner] then
						seen[owner] = true
						table.insert(list, owner)
					end
				end
			end
		end
		table.sort(list, function(a, b)
			return nameOf(a) < nameOf(b)
		end)
		return list
	end

	local function proposalsTo(): { Instance }
		local list = {}
		for _, proposal in diplomatie.Propositions:GetChildren() do
			if proposal:GetAttribute("A") == countryId and proposal:GetAttribute("Reponse") == nil then
				table.insert(list, proposal)
			end
		end
		return list
	end

	local function pendingFrom(target: string, kind: string): boolean
		for _, proposal in diplomatie.Propositions:GetChildren() do
			if proposal:GetAttribute("De") == countryId and proposal:GetAttribute("A") == target
				and proposal:GetAttribute("Type") == kind and proposal:GetAttribute("Reponse") == nil then
				return true
			end
		end
		return false
	end

	local function renderAll()
		-- ton pays : stabilité, opinion publique et leur effet, leader de la partie
		title("🏛️ Ton pays")
		local me = pays:WaitForChild(countryId)
		row("Pays", function(): string
			local value = me:GetAttribute("Stabilite")
			local stability = if typeof(value) == "number" then value else 100
			local production = math.floor(StabilityRules.productionFactor(stability) * 100 + 0.5)
			local recruit = math.floor((StabilityRules.recruitFactor(stability) - 1) * 100 + 0.5)
			local reasons = me:GetAttribute("StabiliteRaisons")
			local aid = me:GetAttribute("Aide")
			local leader = state:GetAttribute("Leader")
			local lines = {
				`Stabilité <b>{stability} %</b> · opinion {StabilityRules.opinion(stability)} · réputation {DiplomacyState.reputation(countryId)}/100`,
				`<font color="{UIStyle.GREY_HEX}">production {production} %{if recruit > 0 then ` · recrues +{recruit} % de crédits` else ""}{if stability < Politics.revolt.below then " · ⚠️ révoltes possibles dans tes conquêtes" else ""}</font>`,
			}
			if typeof(reasons) == "string" and reasons ~= "" then
				table.insert(lines, `<font color="{UIStyle.GREY_HEX}">{reasons}</font>`)
			end
			if typeof(aid) == "number" and aid > 0 then
				table.insert(lines, `🆘 aide internationale : +{aid} 💰 par cycle`)
			end
			local protection = DiplomacyState.protectionLeft(countryId)
			if protection > 0 then
				table.insert(lines, `🛡️ Protection de départ : personne ne peut t'attaquer pendant encore {duration(protection)}`)
			end
			-- Conseil mondial : prochain vote et effets en cours
			local conseil = state:FindFirstChild("Conseil")
			local nextSession = conseil and conseil:GetAttribute("Prochaine")
			if conseil and conseil:GetAttribute("Etat") == "Vote" then
				table.insert(lines, `🏛️ <b>Vote en cours au Conseil mondial</b> : {conseil:GetAttribute("Titre")}`)
			elseif typeof(nextSession) == "number" then
				table.insert(lines, `🏛️ Prochain Conseil mondial dans {duration(nextSession - workspace:GetServerTimeNow())}`)
			end
			local sanctioned, sanctionLeft = CouncilState.sanction()
			if sanctioned then
				table.insert(lines, `⛔ Sanctions contre {nameOf(sanctioned)} : encore {duration(sanctionLeft)}`)
			end
			local ceasefire = CouncilState.ceasefireLeft()
			if ceasefire > 0 then
				table.insert(lines, `🕊️ Cessez-le-feu mondial : encore {duration(ceasefire)}`)
			end
			if typeof(leader) == "string" and leader ~= "" then
				table.insert(lines, if leader == countryId
					then `👑 <b>Tu domines la partie</b> : les autres pays se liguent contre toi.`
					else `👑 Pays dominant : {colorDot(leader)} <b>{nameOf(leader)}</b> (les IA se liguent contre lui)`)
			end
			return table.concat(lines, "\n")
		end, {})

		local now = workspace:GetServerTimeNow()
		-- ton bloc
		title("🤝 Ton bloc")
		local blocName = DiplomacyState.blocName(countryId)
		local allies = DiplomacyState.alliesOf(countryId)
		local enemies = DiplomacyState.enemiesOf(countryId)
		if blocName then
			local names = {}
			for _, id in allies do
				table.insert(names, `{colorDot(id)} {nameOf(id)}`)
			end
			text(`<b>{blocName}</b>  <font color="{UIStyle.GREY_HEX}">{#allies + 1}/{Diplomacy.maxBlocSize} pays</font>\nAvec : {table.concat(names, ", ")}`, 16)
			local atWar = #enemies > 0
			for _, ally in allies do
				atWar = atWar or #DiplomacyState.enemiesOf(ally) > 0
			end
			if atWar then
				text("⚠️ Quitter le bloc pendant une guerre est une trahison : les IA s'en souviendront.", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
			end
			local leave = UIStyle.button("QuitterBloc", "Quitter le bloc")
			leave.Size = UDim2.new(1, 0, 0, 40)
			leave.TextSize = 15
			leave.Activated:Connect(function()
				ask("QuitterBloc")
			end)
			add(leave)
		else
			text("Tu n'es dans aucun bloc. Propose une alliance à un voisin : les membres d'un bloc se défendent et combattent ensemble.", 15, UIStyle.FONT, UIStyle.TEXT_DIM)
		end

		-- propositions reçues
		local received = proposalsTo()
		if #received > 0 then
			title("📨 Propositions reçues")
			for _, proposal in received do
				local from = proposal:GetAttribute("De") :: string
				local kind = proposal:GetAttribute("Type")
				local expire = proposal:GetAttribute("Expire") :: number
				local label = if kind == "Alliance"
					then `🤝 {colorDot(from)} <b>{nameOf(from)}</b> te propose une alliance`
					else `🕊️ {colorDot(from)} <b>{nameOf(from)}</b> te propose la paix`
				local id = proposal.Name
				row("Proposition_" .. id, function(): string
					return `{label}\n<font color="{UIStyle.GREY_HEX}">encore {duration(expire - workspace:GetServerTimeNow())}</font>`
				end, {
					{ name = "Refuser_" .. id, text = "Refuser", onClick = function()
						ask("RepondreProposition", id, false)
					end },
					{ name = "Accepter_" .. id, text = "Accepter", primary = true, onClick = function()
						ask("RepondreProposition", id, true)
					end },
				})
			end
		end

		-- guerres
		if #enemies > 0 then
			title("⚔️ Tes guerres")
			for _, enemy in enemies do
				local since = DiplomacyState.warSince(countryId, enemy)
				local pending = pendingFrom(enemy, "Paix")
				row("Guerre_" .. enemy, function(): string
					local elapsed = if since then workspace:GetServerTimeNow() - since else 0
					return `{colorDot(enemy)} <b>{nameOf(enemy)}</b>  <font color="{UIStyle.GREY_HEX}">{personalityOf(enemy)}</font>\ndepuis {duration(elapsed)}`
				end, {
					{ name = "Paix_" .. enemy, text = if pending then "En attente…" else "Proposer la paix", enabled = not pending, onClick = function()
						ask("ProposerPaix", enemy)
					end },
				})
			end
		end

		-- voisins
		title("🌍 Tes voisins")
		local list = neighbours()
		if #list == 0 then
			text("Aucun voisin.", 15, UIStyle.FONT, UIStyle.TEXT_DIM)
		end
		for _, other in list do
			local relation = DiplomacyState.relation(countryId, other)
			local otherBloc = DiplomacyState.blocName(other)
			local function label(): string
				return `{colorDot(other)} <b>{nameOf(other)}</b>  {relationText(other)}\n<font color="{UIStyle.GREY_HEX}">{personalityOf(other)}{if otherBloc then " · " .. otherBloc else ""}</font>`
			end
			local buttons = {}
			if relation == "Paix" then
				local pending = pendingFrom(other, "Alliance")
				local confirming = confirmWar and confirmWar.target == other and os.clock() < confirmWar.untilTime
				table.insert(buttons, {
					name = "Guerre_" .. other,
					text = if confirming then "Confirmer ?" else "⚔️ Guerre",
					onClick = function()
						if confirmWar and confirmWar.target == other and os.clock() < confirmWar.untilTime then
							confirmWar = nil
							ask("DeclarerGuerre", other)
						else
							confirmWar = { target = other, untilTime = os.clock() + CONFIRM_TIME }
							lastSignature = ""
							render()
						end
					end,
				})
				table.insert(buttons, {
					name = "Alliance_" .. other,
					text = if pending then "En attente…" else "🤝 Alliance",
					primary = true,
					enabled = not pending,
					onClick = function()
						ask("ProposerAlliance", other)
					end,
				})
			end
			row("Voisin_" .. other, label, buttons)
		end

		-- blocs du monde
		local blocs = DiplomacyState.blocs()
		if #blocs > 0 then
			title("🗺️ Blocs du monde")
			for _, bloc in blocs do
				local names = {}
				for _, id in bloc.members do
					table.insert(names, nameOf(id))
				end
				text(`<b>{bloc.name}</b> : {table.concat(names, ", ")}`, 15)
			end
		end
	end

	-- redessine seulement si l'affichage change (évite de perdre un clic)
	local function signature(): string
		local parts = { message or "", tostring(confirmWar and os.clock() < confirmWar.untilTime and confirmWar.target) }
		for _, name in { "Blocs", "Guerres", "Treves", "Propositions" } do
			for _, item in diplomatie[name]:GetChildren() do
				local attrs = {}
				for key, value in item:GetAttributes() do
					if key ~= "Fin" and key ~= "Expire" and key ~= "Depuis" then
						table.insert(attrs, key .. "=" .. tostring(value))
					end
				end
				table.sort(attrs)
				table.insert(parts, item.Name .. ":" .. table.concat(attrs, ","))
			end
		end
		return table.concat(parts, "|")
	end

	render = function()
		local sig = signature()
		if sig == lastSignature then
			return
		end
		lastSignature = sig
		for _, child in container:GetChildren() do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
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
	local connections = {}
	for _, name in { "Blocs", "Guerres", "Treves", "Propositions" } do
		local folder = diplomatie[name]
		table.insert(connections, folder.ChildAdded:Connect(render))
		table.insert(connections, folder.ChildRemoved:Connect(render))
		table.insert(connections, folder.DescendantAdded:Connect(render))
	end
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
	end
end

return DiplomacyTab
