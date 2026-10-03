--!strict
-- Conseil mondial côté joueur (cahier des charges v2, section 1 ; EtatMonde.Conseil).
--   Proposer (CouncilPanel.openProposal, depuis l'onglet Diplomatie) : une trêve ou la paix avec un
--     pays en guerre contre toi, une résolution ou un événement mondial ; une offre en crédits pour
--     chaque pays IA qui votera « oui » ; le soutien estimé des IA est affiché.
--   Pendant un vote : la carte au milieu de l'écran montre la proposition, qui l'a faite, le temps
--     restant, le décompte, les boutons Pour / Contre / Abstention (pays concernés seulement) et la
--     liste « Convaincre » ; elle se réduit en une pastille.
--   Résultat : adopté ou rejeté, et le détail des votes (vote, chance de « oui » de chaque IA,
--     crédits reçus).
-- Le serveur décide de tout (Remotes.ProposerVote, VoterConseil, ConvaincreConseil).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Council = require(Config:WaitForChild("Council")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local WorldEvents = require(Config:WaitForChild("WorldEvents")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local VoteRules = require(Shared:WaitForChild("VoteRules")) :: any
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local GameSession = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("GameSession"))
local Sfx = require(script.Parent.Parent:WaitForChild("Audio"):WaitForChild("Sfx"))
local RegionView = require(script.Parent.Parent:WaitForChild("Map"):WaitForChild("RegionView"))

local MAX_LOBBY = 6 -- pays IA proposés dans « Convaincre »
local VOTE_LABELS = { Pour = "✅ Pour", Contre = "❌ Contre", Abstention = "⚪ Abstention" }
local VOTE_ICONS = { Pour = "✅", Contre = "❌", Abstention = "⚪" }

local CouncilPanel = {}

-- ouvre la fenêtre de proposition (remplie par start)
local openProposalHandler: ((kind: string?, target: string?) -> ())? = nil

local function nameOf(countryId: string): string
	return if Countries[countryId] then Countries[countryId].name else countryId
end

local function dot(countryId: string): string
	local country = Countries[countryId]
	return if country then `<font color="#{country.color:ToHex()}">●</font>` else "●"
end

-- Ouvre la proposition d'un vote ; kind et target la pré-remplissent (« Treve », pays ennemi...)
function CouncilPanel.openProposal(kind: string?, target: string?)
	local handler = openProposalHandler
	if handler then
		handler(kind, target)
	end
end

function CouncilPanel.start(countryId: string)
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local conseil = state:WaitForChild("Conseil")
	local votes = conseil:WaitForChild("Votes")
	local chances = conseil:WaitForChild("Chances")
	local payments = conseil:WaitForChild("Paiements")
	local pays = state:WaitForChild("Pays")
	local remotes = ReplicatedStorage:WaitForChild("Remotes")

	local gui = Instance.new("ScreenGui")
	gui.Name = "Conseil"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 7
	gui.Enabled = false

	local card = UIStyle.panel("Carte", UDim.new(0, 420))
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	UIStyle.padding(card, 12, 14)
	UIStyle.list(card, 8)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(math.max(260, workspace.CurrentCamera.ViewportSize.X - 24), math.huge)
	limit.Parent = card
	card.Parent = gui

	local pill = UIStyle.button("Pastille", "", true)
	pill.AnchorPoint = Vector2.new(0.5, 0)
	pill.Position = UDim2.new(0.5, 0, 0, 78)
	pill.Size = UDim2.fromOffset(320, 36)
	pill.TextSize = 15
	pill.Visible = false
	pill.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local minimized = false
	local message: string? = nil
	local lastSignature = ""
	local order = 0
	local timerLabel: TextLabel? = nil
	local tallyLabel: TextLabel? = nil
	local lobbyCache: { string } = {}
	local lobbyAt = -math.huge -- la liste « Convaincre » change au plus toutes les 3 s (clics non perdus)
	-- proposition en cours d'écriture (nil : fenêtre fermée)
	local draft: { kind: string, target: string?, region: string?, event: string?, offer: number }? = nil
	local busy = false

	local function add(instance: GuiObject): GuiObject
		order += 1
		instance.LayoutOrder = order
		instance.Parent = card
		return instance
	end
	local function text(content: string, size: number?, font: Font?, color: Color3?): TextLabel
		return add(UIStyle.text("Texte", content, size or 15, font, color)) :: TextLabel
	end

	local render: () -> ()

	local function ask(remoteName: string, value: any)
		if busy then
			return
		end
		busy = true
		local remote = remotes:WaitForChild(remoteName) :: RemoteFunction
		local ok, accepted, reason = pcall(function()
			return remote:InvokeServer(value)
		end)
		busy = false
		Sfx.actionResult(remoteName, ok and accepted == true)
		message = if ok and accepted == true then nil elseif ok and typeof(reason) == "string" then reason else "Le serveur ne répond pas."
		if ok and accepted == true and remoteName == "ProposerVote" then
			draft = nil
		end
		lastSignature = ""
		render()
	end

	local function isAI(id: string): boolean
		local folder = pays:FindFirstChild(id)
		return folder ~= nil and (folder:GetAttribute("Joueur") == 0 or folder:GetAttribute("Absent") == true)
	end

	local function voters(): { string }
		local raw = conseil:GetAttribute("Votants")
		return if typeof(raw) == "string" and raw ~= "" then string.split(raw, ",") else {}
	end

	-- Pays encore sur la carte
	local function alive(): { string }
		local seen: { [string]: boolean } = {}
		local list = {}
		for regionId in Regions do
			local owner = RegionView.getOwner(regionId)
			if owner and not seen[owner] then
				seen[owner] = true
				table.insert(list, owner)
			end
		end
		table.sort(list, function(a: string, b: string): boolean
			return nameOf(a) < nameOf(b)
		end)
		return list
	end

	-- Pays concernés par une proposition (comme le serveur) : les deux camps, ou tout le monde
	local function concerned(kind: string, target: string?): { string }
		local list = {}
		if Council.resolutions[kind].target == "ennemi" and target then
			local mine = DiplomacyState.alliesOf(countryId)
			table.insert(mine, countryId)
			local theirs = DiplomacyState.alliesOf(target)
			table.insert(theirs, target)
			for _, x in mine do
				for _, y in theirs do
					if DiplomacyState.atWar(x, y) then
						for _, id in { x, y } do
							if id ~= countryId and not table.find(list, id) then
								table.insert(list, id)
							end
						end
					end
				end
			end
		else
			for _, id in alive() do
				if id ~= countryId then
					table.insert(list, id)
				end
			end
		end
		return list
	end

	-- Régions gagnées moins perdues d'un pays (comme le serveur, d'après la carte)
	local function winning(id: string): number
		local enemies: { [string]: boolean } = {}
		for _, enemy in DiplomacyState.enemiesOf(id) do
			enemies[enemy] = true
		end
		local won, lost = 0, 0
		for regionId, region in Regions do
			local owner = RegionView.getOwner(regionId)
			if owner == id and enemies[region.startOwner] then
				won += 1
			elseif region.startOwner == id and owner ~= id then
				lost += 1
			end
		end
		return won - lost
	end

	-- Soutien estimé des pays IA concernés (sans leur intérêt propre, que le serveur ajoute)
	local function estimate(kind: string, target: string?, offer: number): (number, number)
		local total, n = 0, 0
		for _, id in concerned(kind, target) do
			if isAI(id) then
				local mineEnemies: { [string]: boolean } = {}
				for _, e in DiplomacyState.enemiesOf(countryId) do
					mineEnemies[e] = true
				end
				local common = false
				for _, e in DiplomacyState.enemiesOf(id) do
					common = common or mineEnemies[e] == true
				end
				total += VoteRules.chance({
					affinity = VoteRules.affinity({ relation = DiplomacyState.relation(id, countryId), reputation = DiplomacyState.reputation(countryId), commonEnemy = common }),
					payment = offer,
					winning = winning(id),
					war = Council.resolutions[kind].war == true,
				})
				n += 1
			end
		end
		return if n > 0 then total / n else 0, n
	end

	-- Pays IA à convaincre : ceux qui ne votent pas comme moi, voisins et alliés d'abord
	local function lobbyTargets(mine: string): { string }
		local near: { [string]: boolean } = {}
		for regionId, region in Regions do
			if RegionView.getOwner(regionId) == countryId then
				for _, link in region.neighbors do
					local owner = RegionView.getOwner(link.region)
					if owner then
						near[owner] = true
					end
				end
			end
		end
		for _, ally in DiplomacyState.alliesOf(countryId) do
			near[ally] = true
		end
		local list = {}
		for _, id in voters() do
			local vote = votes:GetAttribute(id)
			if id ~= countryId and isAI(id) and vote ~= nil and vote ~= mine then
				table.insert(list, id)
			end
		end
		table.sort(list, function(a: string, b: string): boolean
			if (near[a] == true) ~= (near[b] == true) then
				return near[a] == true
			end
			return nameOf(a) < nameOf(b)
		end)
		return { table.unpack(list, 1, math.min(MAX_LOBBY, #list)) }
	end

	-- textes mis à jour sans tout redessiner : décompte des voix et temps restant
	local function updateLive()
		local yes = (conseil:GetAttribute("Pour") :: number?) or 0
		local no = (conseil:GetAttribute("Contre") :: number?) or 0
		local abstain = (conseil:GetAttribute("Abstention") :: number?) or 0
		if tallyLabel and tallyLabel.Parent then
			tallyLabel.Text = `✅ <b>{yes}</b> pour   ❌ <b>{no}</b> contre   ⚪ {abstain} abstentions`
		end
		local finish = conseil:GetAttribute("Fin")
		local left = if typeof(finish) == "number" then math.max(0, math.ceil(finish - workspace:GetServerTimeNow())) else 0
		if timerLabel and timerLabel.Parent then
			timerLabel.Text = `⏳ Fin du vote dans {left} s`
		end
		pill.Text = if conseil:GetAttribute("Etat") == "Vote" then `🏛️ Vote au Conseil mondial : {left} s (ouvrir)` else "🏛️ Résultat du vote (ouvrir)"
	end

	local lastStatus: unknown = nil -- état de la séance au dernier affichage

	local function signature(): string
		local mine = votes:GetAttribute(countryId)
		if os.clock() - lobbyAt >= 3 then
			lobbyAt = os.clock()
			lobbyCache = if mine == "Pour" or mine == "Contre" then lobbyTargets(mine :: string) else {}
		end
		local d = draft
		local draftKey = if d then `{d.kind}:{d.target}:{d.region}:{d.event}:{d.offer}` else ""
		local details = {}
		if conseil:GetAttribute("Etat") == "Resultat" then
			for name, value in votes:GetAttributes() do
				table.insert(details, `{name}={value}`)
			end
			table.sort(details)
		end
		return table.concat({
			tostring(conseil:GetAttribute("Etat")),
			tostring(conseil:GetAttribute("Titre")),
			table.concat(lobbyCache, ","),
			tostring(mine),
			tostring(conseil:GetAttribute("Resultat")),
			message or "",
			tostring(minimized),
			draftKey,
			tostring(busy),
			table.concat(details, ","),
		}, "|")
	end

	local function header(title: string, onClose: () -> (), closeText: string)
		local frame = Instance.new("Frame")
		frame.Name = "EnTete"
		frame.BackgroundTransparency = 1
		frame.Size = UDim2.new(1, 0, 0, 30)
		local label = UIStyle.text("Titre", title, 20, UIStyle.FONT_BOLD)
		label.Size = UDim2.new(1, -44, 1, 0)
		label.AutomaticSize = Enum.AutomaticSize.None
		label.Parent = frame
		local close = UIStyle.button("Fermer", closeText)
		close.AnchorPoint = Vector2.new(1, 0)
		close.Position = UDim2.new(1, 0, 0, 0)
		close.Size = UDim2.fromOffset(36, 30)
		close.Activated:Connect(onClose)
		close.Parent = frame
		add(frame)
	end

	-- une rangée de petits boutons (choix)
	local function choices(name: string, entries: { { id: string, label: string } }, selected: string?, onPick: (id: string) -> (), scroll: boolean?)
		local holder: GuiObject
		if scroll then
			local frame = Instance.new("ScrollingFrame")
			frame.BackgroundTransparency = 1
			frame.BorderSizePixel = 0
			frame.Size = UDim2.new(1, 0, 0, 120)
			frame.CanvasSize = UDim2.new()
			frame.AutomaticCanvasSize = Enum.AutomaticSize.Y
			frame.ScrollingDirection = Enum.ScrollingDirection.Y
			UIStyle.styleScroll(frame)
			holder = frame
		else
			local frame = Instance.new("Frame")
			frame.BackgroundTransparency = 1
			frame.Size = UDim2.new(1, 0, 0, 0)
			frame.AutomaticSize = Enum.AutomaticSize.Y
			holder = frame
		end
		holder.Name = name
		local grid = Instance.new("UIGridLayout")
		grid.CellSize = UDim2.new(0.5, -4, 0, 32)
		grid.CellPadding = UDim2.fromOffset(6, 6)
		grid.SortOrder = Enum.SortOrder.LayoutOrder
		grid.Parent = holder
		for i, entry in entries do
			local b = UIStyle.button("Choix_" .. entry.id, entry.label, false)
			b.LayoutOrder = i
			b.TextSize = 14
			b.TextTruncate = Enum.TextTruncate.AtEnd
			UIStyle.setButtonSelected(b, entry.id == selected)
			b.Activated:Connect(function()
				onPick(entry.id)
			end)
			b.Parent = holder
		end
		add(holder)
	end

	-- Fenêtre de proposition
	local function renderProposal()
		local d = draft :: { kind: string, target: string?, region: string?, event: string?, offer: number }
		header("🏛️ <b>Proposer un vote</b>", function()
			draft = nil
			message = nil
			lastSignature = ""
			render()
		end, "×")
		text("Seuls les joueurs proposent. Les pays concernés votent ; ça passe à la majorité.", 13, UIStyle.FONT, UIStyle.TEXT_DIM)
		local kinds = {}
		for _, kind in Council.order do
			local definition = Council.resolutions[kind]
			table.insert(kinds, { id = kind, label = `{definition.icon} {definition.name}` })
		end
		choices("Types", kinds, d.kind, function(kind: string)
			d.kind = kind
			d.target, d.region, d.event = nil, nil, nil
			lastSignature = ""
			render()
		end)
		local definition = Council.resolutions[d.kind]
		local ready = true
		if definition.target == "ennemi" then
			local entries = {}
			for _, enemy in DiplomacyState.enemiesOf(countryId) do
				table.insert(entries, { id = enemy, label = `⚔️ {nameOf(enemy)}` })
			end
			if #entries == 0 then
				text("Tu n'es en guerre avec personne.", 14, UIStyle.FONT_MEDIUM, UIStyle.TEXT_DIM)
			else
				text("<b>Avec qui ?</b>", 14)
				choices("Cibles", entries, d.target, function(id: string)
					d.target = id
					lastSignature = ""
					render()
				end, #entries > 6)
			end
			ready = d.target ~= nil
		elseif definition.target == "pays" then
			local entries = {}
			for _, id in alive() do
				if id ~= countryId then
					table.insert(entries, { id = id, label = nameOf(id) })
				end
			end
			text("<b>Quel pays ?</b>", 14)
			choices("Cibles", entries, d.target, function(id: string)
				d.target = id
				lastSignature = ""
				render()
			end, true)
			ready = d.target ~= nil
		elseif definition.target == "conquete" then
			local entries = {}
			for regionId, region in Regions do
				local owner = RegionView.getOwner(regionId)
				if owner and owner ~= region.startOwner then
					table.insert(entries, { id = regionId, label = `{region.name} ({nameOf(owner)})` })
				end
			end
			table.sort(entries, function(a: any, b: any): boolean
				return a.label < b.label
			end)
			if #entries == 0 then
				text("Aucune région n'a encore été conquise.", 14, UIStyle.FONT_MEDIUM, UIStyle.TEXT_DIM)
			else
				text("<b>Quelle conquête ?</b>", 14)
				choices("Cibles", entries, d.region, function(id: string)
					d.region = id
					lastSignature = ""
					render()
				end, true)
			end
			ready = d.region ~= nil
		elseif definition.target == "evenement" then
			local entries = {}
			for _, event in WorldEvents.list do
				if event.proposable then
					table.insert(entries, { id = event.id, label = `{event.icon} {event.title}` })
				end
			end
			text("<b>Quel événement ?</b>", 14)
			choices("Cibles", entries, d.event, function(id: string)
				d.event = id
				lastSignature = ""
				render()
			end)
			ready = d.event ~= nil
		end
		-- texte de la proposition
		local description = definition.text
		if d.event then
			for _, event in WorldEvents.list do
				if event.id == d.event then
					description = event.text:gsub("{countries}", "de plusieurs pays"):gsub("{duration}", `{event.duration or 0} s`)
				end
			end
		end
		local target = if d.target then FrenchNames.the(nameOf(d.target)) elseif d.region then FrenchNames.the(nameOf(RegionView.getOwner(d.region) or "")) else "le pays choisi"
		text((description:gsub("{target}", function()
			return target
		end)), 14, UIStyle.FONT, UIStyle.TEXT_DIM)
		-- offre
		text("<b>Offre</b> : crédits pour chaque pays IA qui votera « oui »", 14)
		local offers = {}
		for _, amount in Council.paymentSteps do
			table.insert(offers, { id = tostring(amount), label = if amount == 0 then "Rien" else `{amount} 💰` })
		end
		choices("Offres", offers, tostring(d.offer), function(id: string)
			d.offer = tonumber(id) or 0
			lastSignature = ""
			render()
		end)
		local support, aiCount = estimate(d.kind, d.target, d.offer)
		if aiCount > 0 then
			text(`🤖 Soutien estimé des {aiCount} pays IA concernés : <b>{math.floor(support * 100 + 0.5)} %</b>{if d.offer > 0 then ` · mis de côté : {d.offer * aiCount} 💰 (rendu pour ceux qui votent non)` else ""}`, 14, UIStyle.FONT_MEDIUM)
		end
		if message then
			text(message, 14, UIStyle.FONT_MEDIUM, UIStyle.DANGER)
		end
		local send = UIStyle.button("Proposer", "🏛️ Proposer le vote", true)
		send.Size = UDim2.new(1, 0, 0, 42)
		send.TextSize = 17
		UIStyle.setButtonEnabled(send, ready and not busy)
		send.Activated:Connect(function()
			if UIStyle.isEnabled(send) then
				ask("ProposerVote", { type = d.kind, cible = d.target, region = d.region, evenement = d.event, offre = d.offer })
			end
		end)
		add(send)
	end

	-- Détail des votes (résultat)
	local function renderDetails()
		local initiator = conseil:GetAttribute("Initiateur")
		local list = voters()
		if typeof(initiator) == "string" then
			table.insert(list, 1, initiator)
		end
		local lines = {}
		for _, id in list do
			local vote = votes:GetAttribute(id)
			local chance = chances:GetAttribute(id)
			local paid = payments:GetAttribute(id)
			local who = if id == initiator then " (propose)" elseif isAI(id) then " 🤖" else " 👤"
			local extra = ""
			if typeof(chance) == "number" then
				extra ..= ` · {math.floor(chance * 100 + 0.5)} % de chances`
			end
			if typeof(paid) == "number" and paid > 0 then
				extra ..= ` · +{paid} 💰`
			end
			table.insert(lines, `{VOTE_ICONS[vote] or "⚪"} {dot(id)} {nameOf(id)}{who}<font color="{UIStyle.GREY_HEX}">{extra}</font>`)
		end
		local frame = Instance.new("ScrollingFrame")
		frame.Name = "Detail"
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Size = UDim2.new(1, 0, 0, math.min(220, 24 * #lines + 4))
		frame.CanvasSize = UDim2.new()
		frame.AutomaticCanvasSize = Enum.AutomaticSize.Y
		frame.ScrollingDirection = Enum.ScrollingDirection.Y
		UIStyle.styleScroll(frame)
		UIStyle.list(frame, 2)
		for i, line in lines do
			local label = UIStyle.text("Vote" .. i, line, 14)
			label.LayoutOrder = i
			label.Parent = frame
		end
		add(frame)
	end

	render = function()
		local status = conseil:GetAttribute("Etat")
		if status ~= lastStatus then
			-- coup de marteau à l'ouverture du vote, puis au résultat
			if lastStatus ~= nil and (status == "Vote" or status == "Resultat") and Players.LocalPlayer:GetAttribute("Pays") == countryId then
				Sfx.play("Verdict")
			end
			if status == "Vote" then
				minimized = false
			end
			lastStatus = status
		end
		local voting = status == "Vote" or status == "Resultat"
		gui.Enabled = voting or draft ~= nil
		if not gui.Enabled then
			minimized = false
			message = nil
			return
		end
		card.Visible = not minimized or (draft ~= nil and not voting)
		pill.Visible = minimized and voting
		local sig = signature()
		if sig == lastSignature then
			return
		end
		lastSignature = sig
		for _, child in card:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		order = 0
		timerLabel, tallyLabel = nil, nil
		if not voting and draft then
			renderProposal()
			return
		end

		header("🏛️ <b>Conseil mondial</b>", function()
			minimized = true
			lastSignature = ""
			render()
		end, "–")
		text(`<b>{conseil:GetAttribute("Titre")}</b>`, 18, UIStyle.FONT_BOLD)
		text(tostring(conseil:GetAttribute("Texte")), 15, UIStyle.FONT, UIStyle.TEXT_DIM)
		local initiator = conseil:GetAttribute("Initiateur")
		local offer = (conseil:GetAttribute("Offre") :: number?) or 0
		if typeof(initiator) == "string" and initiator ~= "" then
			text(`Proposé par {dot(initiator)} {nameOf(initiator)}{if offer > 0 then ` · offre : {offer} 💰 à chaque pays IA qui vote oui` else ""}`, 14, UIStyle.FONT_MEDIUM, UIStyle.TEXT_DIM)
		end
		tallyLabel = text("", 16)

		if status == "Resultat" then
			updateLive()
			local adopted = conseil:GetAttribute("Resultat") == "Adoptee"
			text(if adopted then "<b>Adopté ✅</b>" else "<b>Rejeté ❌</b>", 19, UIStyle.FONT_BOLD, if adopted then Color3.fromRGB(120, 220, 130) else UIStyle.DANGER)
			renderDetails()
			return
		end
		timerLabel = text("", 14, UIStyle.FONT_MEDIUM, UIStyle.ACCENT)
		updateLive()

		-- mon vote (pays concernés seulement)
		local mine = votes:GetAttribute(countryId)
		if initiator == countryId then
			text("Tu as proposé ce vote : tu votes « pour ».", 14, UIStyle.FONT_MEDIUM, UIStyle.TEXT_DIM)
		elseif table.find(voters(), countryId) then
			local row = Instance.new("Frame")
			row.Name = "Vote"
			row.BackgroundTransparency = 1
			row.Size = UDim2.new(1, 0, 0, 40)
			UIStyle.list(row, 6, true)
			for i, vote in { "Pour", "Contre", "Abstention" } do
				local b = UIStyle.button("Vote_" .. vote, VOTE_LABELS[vote], mine == vote)
				b.LayoutOrder = i
				b.Size = UDim2.new(1 / 3, -4, 1, 0)
				b.TextSize = 15
				b.Activated:Connect(function()
					ask("VoterConseil", vote)
				end)
				b.Parent = row
			end
			add(row)
		else
			text("Ton pays n'est pas concerné par ce vote.", 14, UIStyle.FONT_MEDIUM, UIStyle.TEXT_DIM)
		end

		-- convaincre des pays IA
		if mine == "Pour" or mine == "Contre" then
			local targets = lobbyCache
			if #targets > 0 then
				text(`<b>Convaincre</b> <font color="{UIStyle.GREY_HEX}">({Council.lobbyCost} 💰 par pays, s'il accepte)</font>`, 15)
				for _, target in targets do
					local line = Instance.new("Frame")
					line.Name = "Convaincre_" .. target
					line.BackgroundTransparency = 1
					line.Size = UDim2.new(1, 0, 0, 30)
					local label = UIStyle.text("Nom", `{nameOf(target)} <font color="{UIStyle.GREY_HEX}">vote {string.lower(tostring(votes:GetAttribute(target)))}</font>`, 14)
					label.AutomaticSize = Enum.AutomaticSize.None
					label.Size = UDim2.new(1, -110, 1, 0)
					label.TextYAlignment = Enum.TextYAlignment.Center
					label.Parent = line
					local b = UIStyle.button("Payer_" .. target, `Convaincre`)
					b.AnchorPoint = Vector2.new(1, 0.5)
					b.Position = UDim2.new(1, 0, 0.5, 0)
					b.Size = UDim2.fromOffset(104, 28)
					b.TextSize = 13
					b.Activated:Connect(function()
						ask("ConvaincreConseil", target)
					end)
					b.Parent = line
					add(line)
				end
			end
		end
		if message then
			text(message, 14, UIStyle.FONT_MEDIUM, UIStyle.DANGER)
		end
	end

	openProposalHandler = function(kind: string?, target: string?)
		local status = conseil:GetAttribute("Etat")
		if status == "Vote" then
			minimized = false
			message = "Un vote est déjà en cours : attends son résultat."
			lastSignature = ""
			render()
			return
		end
		local chosen = if kind and Council.resolutions[kind] then kind else Council.order[1]
		draft = { kind = chosen, target = target, region = nil, event = nil, offer = 0 }
		message = nil
		lastSignature = ""
		render()
	end

	pill.Activated:Connect(function()
		minimized = false
		lastSignature = ""
		render()
	end)
	GameSession.track(conseil.AttributeChanged:Connect(function()
		render()
		updateLive()
	end))
	GameSession.track(votes.AttributeChanged:Connect(function(name: string)
		if name == countryId then
			lobbyAt = -math.huge -- mon vote change : la liste « Convaincre » aussi
		end
		lastSignature = ""
		render()
		updateLive()
	end))
	local session = GameSession.token()
	task.spawn(function()
		while GameSession.alive(session) do
			task.wait(1)
			render()
			updateLive()
		end
	end)
	render()
end

return CouncilPanel
