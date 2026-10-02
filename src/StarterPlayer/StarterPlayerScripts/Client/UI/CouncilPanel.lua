--!strict
-- Conseil mondial côté joueur (EtatMonde.Conseil) : pendant un vote, une carte au milieu de
-- l'écran montre la résolution, le temps restant, le décompte des voix et les boutons
-- Pour / Contre / Abstention ; la liste « Convaincre » permet de payer des pays IA qui votent
-- autrement. La carte se réduit en une pastille ; elle montre le résultat, puis disparaît.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Council = require(Config:WaitForChild("Council")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local DiplomacyState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DiplomacyState")) :: any
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local GameSession = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("GameSession"))
local Sfx = require(script.Parent.Parent:WaitForChild("Audio"):WaitForChild("Sfx"))
local RegionView = require(script.Parent.Parent:WaitForChild("Map"):WaitForChild("RegionView"))

local MAX_LOBBY = 6 -- pays IA proposés dans « Convaincre »
local VOTE_LABELS = { Pour = "✅ Pour", Contre = "❌ Contre", Abstention = "⚪ Abstention" }

local CouncilPanel = {}

local function nameOf(countryId: string): string
	return if Countries[countryId] then Countries[countryId].name else countryId
end

function CouncilPanel.start(countryId: string)
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local conseil = state:WaitForChild("Conseil")
	local votes = conseil:WaitForChild("Votes")
	local pays = state:WaitForChild("Pays")
	local remotes = ReplicatedStorage:WaitForChild("Remotes")

	local gui = Instance.new("ScreenGui")
	gui.Name = "Conseil"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 7
	gui.Enabled = false

	local card = UIStyle.panel("Carte", UDim.new(0, 400))
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
	pill.Size = UDim2.fromOffset(300, 36)
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

	local function ask(remoteName: string, value: string)
		local remote = remotes:WaitForChild(remoteName) :: RemoteFunction
		local ok, accepted, reason = pcall(function()
			return remote:InvokeServer(value)
		end)
		Sfx.actionResult(remoteName, ok and accepted == true)
		message = if ok and accepted == true then nil elseif ok and typeof(reason) == "string" then reason else "Le serveur ne répond pas."
		lastSignature = ""
		render()
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
		for _, folder in pays:GetChildren() do
			local id = folder.Name
			local vote = votes:GetAttribute(id)
			local ai = folder:GetAttribute("Joueur") == 0 or folder:GetAttribute("Absent") == true
			if id ~= countryId and ai and vote ~= nil and vote ~= mine then
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
		pill.Text = `🏛️ Vote au Conseil mondial : {left} s (ouvrir)`
	end

	local lastStatus: unknown = nil -- état de la séance au dernier affichage

	local function signature(): string
		local mine = votes:GetAttribute(countryId)
		if os.clock() - lobbyAt >= 3 then
			lobbyAt = os.clock()
			lobbyCache = if mine == "Pour" or mine == "Contre" then lobbyTargets(mine :: string) else {}
		end
		return table.concat({
			tostring(conseil:GetAttribute("Etat")),
			tostring(conseil:GetAttribute("Titre")),
			table.concat(lobbyCache, ","),
			tostring(mine),
			tostring(conseil:GetAttribute("Resultat")),
			message or "",
			tostring(minimized),
		}, "|")
	end

	render = function()
		local status = conseil:GetAttribute("Etat")
		if status ~= lastStatus then
			-- coup de marteau à l'ouverture de la séance, puis au résultat
			if lastStatus ~= nil and (status == "Vote" or status == "Resultat") and Players.LocalPlayer:GetAttribute("Pays") == countryId then
				Sfx.play("Verdict")
			end
			lastStatus = status
		end
		gui.Enabled = status == "Vote" or status == "Resultat"
		if not gui.Enabled then
			minimized = false
			message = nil
			return
		end
		card.Visible = not minimized
		pill.Visible = minimized
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

		local header = Instance.new("Frame")
		header.Name = "EnTete"
		header.BackgroundTransparency = 1
		header.Size = UDim2.new(1, 0, 0, 30)
		local title = UIStyle.text("Titre", "🏛️ <b>Conseil mondial</b>", 20, UIStyle.FONT_BOLD)
		title.Size = UDim2.new(1, -44, 1, 0)
		title.AutomaticSize = Enum.AutomaticSize.None
		title.Parent = header
		local close = UIStyle.button("Reduire", "–")
		close.AnchorPoint = Vector2.new(1, 0)
		close.Position = UDim2.new(1, 0, 0, 0)
		close.Size = UDim2.fromOffset(36, 30)
		close.Activated:Connect(function()
			minimized = true
			lastSignature = ""
			render()
		end)
		close.Parent = header
		add(header)

		text(`<b>{conseil:GetAttribute("Titre")}</b>`, 18, UIStyle.FONT_BOLD)
		text(tostring(conseil:GetAttribute("Texte")), 15, UIStyle.FONT, UIStyle.TEXT_DIM)
		tallyLabel = text("", 16)

		if status == "Resultat" then
			updateLive()
			local adopted = conseil:GetAttribute("Resultat") == "Adoptee"
			text(if adopted then "<b>Résolution adoptée ✅</b>" else "<b>Résolution rejetée ❌</b>", 19, UIStyle.FONT_BOLD, if adopted then Color3.fromRGB(120, 220, 130) else UIStyle.DANGER)
			return
		end
		timerLabel = text("", 14, UIStyle.FONT_MEDIUM, UIStyle.ACCENT)
		updateLive()

		-- mon vote
		local mine = votes:GetAttribute(countryId)
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
			render()
		end
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
