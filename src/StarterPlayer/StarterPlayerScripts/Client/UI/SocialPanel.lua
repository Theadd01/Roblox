--!strict
-- Jouer entre amis : bouton 👥 en haut à droite. Il ouvre la liste des joueurs de la partie (tes
-- amis Roblox d'abord) avec le pays que chacun dirige, et pour chacun : proposer une alliance
-- (pour être dans le même bloc) et ouvrir une discussion privée pour négocier (chat Roblox, donc
-- filtré). Bouton « Inviter des amis » (invitation Roblox) et retour au chat général.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Countries = require(Shared:WaitForChild("Config"):WaitForChild("Countries")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local Friends = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("Friends"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local ModalHost = require(script.Parent:WaitForChild("ModalHost"))
local Toast = require(script.Parent:WaitForChild("Toast"))

local PRIVATE_PREFIX = "Prive_"
local PRIVATE_TAG = `<font color="#EBBE46">[Privé]</font> `

local SocialPanel = {}

local function countryOf(player: Player): string?
	local id = player:GetAttribute("Pays")
	return if typeof(id) == "string" and id ~= "" and Countries[id] then id else nil
end

local function textChannels(): Instance?
	return TextChatService:FindFirstChild("TextChannels")
end

-- Canal privé : messages marqués « [Privé] » ; prévient quand quelqu'un t'écrit
local function preparePrivate(channel: Instance)
	if not channel:IsA("TextChannel") or channel.Name:sub(1, #PRIVATE_PREFIX) ~= PRIVATE_PREFIX then
		return
	end
	local c = channel :: TextChannel
	c.OnIncomingMessage = function(message: TextChatMessage)
		local props = Instance.new("TextChatMessageProperties")
		props.PrefixText = PRIVATE_TAG .. message.PrefixText
		return props
	end
	c.MessageReceived:Connect(function(message: TextChatMessage)
		local source = message.TextSource
		local target = TextChatService.ChatInputBarConfiguration.TargetTextChannel
		if source and source.UserId ~= Players.LocalPlayer.UserId and target ~= c then
			local sender = Players:GetPlayerByUserId(source.UserId)
			Toast.show(`💬 {if sender then sender.DisplayName else "Un joueur"} t'écrit en privé : réponds avec le bouton 👥.`, "info")
		end
	end)
end

function SocialPanel.start()
	Friends.start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local remotes = ReplicatedStorage:WaitForChild("Remotes")

	local channels = textChannels()
	if channels then
		for _, channel in channels:GetChildren() do
			preparePrivate(channel)
		end
		channels.ChildAdded:Connect(preparePrivate)
	end

	-- bouton
	local buttonGui = Instance.new("ScreenGui")
	buttonGui.Name = "BoutonAmis"
	buttonGui.ResetOnSpawn = false
	buttonGui.DisplayOrder = 5
	local button = UIStyle.button("Amis", "")
	button.AnchorPoint = Vector2.new(1, 0)
	button.Position = UDim2.new(1, -140, 0, 8)
	button.Size = UDim2.fromOffset(46, 46)
	button:SetAttribute("InfoBulleTexte", "Jouer entre amis")
	local buttonIcon = UIStyle.mountIcon(button, "Social", 24, UIStyle.TEXT_DIM)
	button.Parent = buttonGui
	buttonGui.Parent = playerGui

	-- fenêtre
	local gui = Instance.new("ScreenGui")
	gui.Name = "JouerEntreAmis"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	local overlay = Instance.new("TextButton")
	overlay.Name = "FondModal"
	overlay.Active = true
	overlay.AutoButtonColor = false
	overlay.Selectable = false
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = UIStyle.BACKDROP
	overlay.BackgroundTransparency = 0.2
	overlay.BorderSizePixel = 0
	overlay.Text = ""
	overlay.Visible = false
	overlay.Parent = gui
	local panel = UIStyle.panel("Fenetre", UDim.new(1, -32))
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.AutomaticSize = Enum.AutomaticSize.None
	panel.Size = UDim2.new(1, -32, 1, -48)
	panel.ClipsDescendants = true
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(520, 650)
	limit.Parent = panel
	panel.Parent = overlay
	local header = Instance.new("Frame")
	header.Name = "Entete"
	header.Size = UDim2.new(1, 0, 0, 82)
	header.BackgroundColor3 = UIStyle.PANEL_RAISED
	header.BackgroundTransparency = 0.12
	header.BorderSizePixel = 0
	header.Parent = panel
	local overline = UIStyle.text("Rubrique", "DIPLOMATIE · JOUEURS", 11, UIStyle.FONT_BOLD, UIStyle.ACCENT)
	overline.AutomaticSize = Enum.AutomaticSize.None
	overline.Position = UDim2.fromOffset(18, 10)
	overline.Size = UDim2.new(1, -36, 0, 16)
	overline.Parent = header
	local headingIcon = UIStyle.mountIcon(header, "Social", 24, UIStyle.ACCENT)
	headingIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	headingIcon.Position = UDim2.fromOffset(30, 44)
	local heading = UIStyle.text("Titre", "Jouer entre amis", 24, UIStyle.FONT_BLACK)
	heading.AutomaticSize = Enum.AutomaticSize.None
	heading.Position = UDim2.fromOffset(52, 28)
	heading.Size = UDim2.new(1, -70, 0, 30)
	heading.Parent = header
	local intro = UIStyle.text("Intro", "Invitez, négociez en privé et coordonnez votre bloc.", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
	intro.AutomaticSize = Enum.AutomaticSize.None
	intro.Position = UDim2.fromOffset(18, 57)
	intro.Size = UDim2.new(1, -36, 0, 18)
	intro.Parent = header
	local content = Instance.new("ScrollingFrame")
	content.Name = "Contenu"
	content.Position = UDim2.fromOffset(16, 94)
	content.Size = UDim2.new(1, -32, 1, -174)
	content.BackgroundTransparency = 1
	content.CanvasSize = UDim2.new()
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	UIStyle.styleScroll(content)
	UIStyle.list(content, 9)
	content.Parent = panel
	local footer = Instance.new("Frame")
	footer.Name = "Pied"
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.fromScale(0, 1)
	footer.Size = UDim2.new(1, 0, 0, 68)
	footer.BackgroundColor3 = UIStyle.PANEL_ALT
	footer.BackgroundTransparency = 0.08
	footer.BorderSizePixel = 0
	footer.Parent = panel
	local footerDivider = UIStyle.divider("SeparateurPied")
	footerDivider.Parent = footer
	local close = UIStyle.button("Fermer", "Fermer", true)
	close.Position = UDim2.fromOffset(16, 13)
	close.Size = UDim2.new(1, -32, 0, 42)
	close.Parent = footer
	gui.Parent = playerGui

	local render: () -> ()

	local function invite()
		local ok, can = pcall(function()
			return SocialService:CanSendGameInviteAsync(Players.LocalPlayer)
		end)
		if ok and can then
			pcall(function()
				SocialService:PromptGameInvite(Players.LocalPlayer)
			end)
		else
			Toast.show("Les invitations ne sont pas disponibles ici (elles marchent dans le jeu publié).", "info")
		end
	end

	local function proposeAlliance(target: string)
		local remote = remotes:WaitForChild("ProposerAlliance") :: RemoteFunction
		local ok, accepted, reason = pcall(function()
			return remote:InvokeServer(target)
		end)
		if ok and accepted == true then
			Toast.show(`🤝 Alliance proposée {FrenchNames.to(Countries[target].name)}.`, "success")
		else
			Toast.show(if ok and typeof(reason) == "string" then reason else "Le serveur ne répond pas.", "danger", "Refus")
		end
	end

	local function openChat(other: Player)
		local remote = remotes:WaitForChild("OuvrirDiscussion") :: RemoteFunction
		local ok, accepted, result = pcall(function()
			return remote:InvokeServer(other.UserId)
		end)
		local list = textChannels()
		local channel = if ok and accepted == true and typeof(result) == "string" and list then list:WaitForChild(result, 5) else nil
		if channel and channel:IsA("TextChannel") then
			TextChatService.ChatInputBarConfiguration.TargetTextChannel = channel
			Toast.show(`💬 Discussion privée avec <b>{other.DisplayName}</b> : écris dans le chat, vous seuls la lisez.`, "success")
			ModalHost.hide(overlay)
		else
			Toast.show(if ok and typeof(result) == "string" and accepted ~= true then result else "Discussion impossible pour le moment.", "danger", "Refus")
		end
		render()
	end

	render = function()
		for _, child in content:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local order = 0
		local function add(instance: GuiObject)
			order += 1
			instance.LayoutOrder = order
			instance.Parent = content
		end
		local inviteButton = UIStyle.button("Inviter", "✉️ Inviter des amis", true)
		inviteButton.Size = UDim2.new(1, 0, 0, 44)
		inviteButton.TextSize = 17
		inviteButton.Activated:Connect(invite)
		add(inviteButton)

		local mine = countryOf(Players.LocalPlayer)
		local others = Friends.others()
		if #others == 0 then
			add(UIStyle.text("Vide", "Aucun autre joueur dans cette partie pour l'instant.", 15, UIStyle.FONT_MEDIUM, UIStyle.TEXT_DIM))
		end
		for _, other in others do
			local theirs = countryOf(other)
			local row = UIStyle.card("Joueur_" .. other.UserId)
			UIStyle.padding(row, 8, 10)
			UIStyle.list(row, 6)
			local friend = Friends.isFriend(other.UserId)
			local title = other:GetAttribute("Titre")
			local titleText = if typeof(title) == "string" and title ~= "" then ` <font color="#EBBE46">« {title} »</font>` else ""
			local where = if theirs then `dirige {FrenchNames.the(Countries[theirs].name)}` else "choisit son pays"
			local label = UIStyle.text("Nom", `{if friend then "👥 " else ""}<b>{other.DisplayName}</b>{titleText} <font color="{UIStyle.GREY_HEX}">· {where}</font>`, 16, UIStyle.FONT_MEDIUM)
			label.LayoutOrder = 1
			label.Parent = row
			local actions = Instance.new("Frame")
			actions.Name = "Actions"
			actions.LayoutOrder = 2
			actions.BackgroundTransparency = 1
			actions.Size = UDim2.new(1, 0, 0, 38)
			UIStyle.list(actions, 8, true)
			local canAlly = mine ~= nil and theirs ~= nil and not DiplomacyState.areAllies(mine :: string, theirs :: string)
			if canAlly then
				local ally = UIStyle.button("Alliance", "🤝 Alliance")
				ally.Size = UDim2.new(0.5, -4, 1, 0)
				ally.TextSize = 15
				ally.Activated:Connect(function()
					proposeAlliance(theirs :: string)
				end)
				ally.Parent = actions
			end
			local chat = UIStyle.button("Prive", "💬 Message privé")
			chat.LayoutOrder = 2
			chat.Size = if canAlly then UDim2.new(0.5, -4, 1, 0) else UDim2.new(1, 0, 1, 0)
			chat.TextSize = 15
			chat.Activated:Connect(function()
				openChat(other)
			end)
			chat.Parent = actions
			actions.Parent = row
			add(row)
		end

		local target = TextChatService.ChatInputBarConfiguration.TargetTextChannel
		if target and target.Name:sub(1, #PRIVATE_PREFIX) == PRIVATE_PREFIX then
			local back = UIStyle.button("ChatGeneral", "↩️ Revenir au chat général")
			back.Size = UDim2.new(1, 0, 0, 40)
			back.TextSize = 15
			back.Activated:Connect(function()
				local list = textChannels()
				local general = list and list:FindFirstChild("RBXGeneral")
				if general and general:IsA("TextChannel") then
					TextChatService.ChatInputBarConfiguration.TargetTextChannel = general
				end
				render()
			end)
			add(back)
		end
	end

	local function syncButtonState()
		UIStyle.setButtonSelected(button, overlay.Visible)
		UIStyle.setIconColor(buttonIcon, if overlay.Visible then UIStyle.ACCENT else UIStyle.TEXT_DIM)
	end
	button.Activated:Connect(function()
		ModalHost.toggle(overlay, syncButtonState)
		syncButtonState()
		if overlay.Visible then
			render()
		end
	end)
	close.Activated:Connect(function()
		ModalHost.hide(overlay)
		syncButtonState()
	end)
	overlay.Activated:Connect(function()
		ModalHost.hide(overlay)
		syncButtonState()
	end)
	Friends.onChanged(function()
		if overlay.Visible then
			render()
		end
	end)
	syncButtonState()
end

return SocialPanel
