--!strict
-- Annonces du déroulé de la partie, en grand au milieu de l'écran : nouvelle phase (avec le titre
-- de la crise mondiale quand elle frappe), événements mondiaux, « fin de la partie dans 10 min,
-- 5 min, 1 min », et nouvelle partie. L'état vient du serveur (shared/MatchState).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Match = require(Shared:WaitForChild("Config"):WaitForChild("Match")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local Sfx = require(script.Parent.Parent:WaitForChild("Audio"):WaitForChild("Sfx"))

local SHOW_TIME = 7 -- secondes à l'écran

local MatchProgress = {}

local group: CanvasGroup? = nil
local headLabel: TextLabel? = nil
local bodyLabel: TextLabel? = nil
local shown = 0 -- numéro de l'annonce affichée (une nouvelle remplace la précédente)

local function build(): CanvasGroup
	local gui = Instance.new("ScreenGui")
	gui.Name = "Annonces"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 9
	local frame = Instance.new("CanvasGroup")
	frame.Name = "Annonce"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.3)
	frame.Size = UDim2.fromOffset(480, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = UIStyle.PANEL
	frame.BackgroundTransparency = 0.05
	frame.GroupTransparency = 1
	frame.Visible = false
	UIStyle.corner(frame, 14)
	UIStyle.padding(frame, 14, 20)
	UIStyle.list(frame, 6)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(math.max(260, workspace.CurrentCamera.ViewportSize.X - 32), math.huge)
	limit.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = UIStyle.ACCENT
	stroke.Thickness = 2
	stroke.Parent = frame
	local head = UIStyle.text("Titre", "", 24, UIStyle.FONT_BLACK, UIStyle.ACCENT)
	head.LayoutOrder = 1
	head.TextXAlignment = Enum.TextXAlignment.Center
	head.Parent = frame
	local body = UIStyle.text("Texte", "", 17, UIStyle.FONT_MEDIUM)
	body.LayoutOrder = 2
	body.TextXAlignment = Enum.TextXAlignment.Center
	body.Parent = frame
	frame.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	group, headLabel, bodyLabel = frame, head, body
	return frame
end

-- Affiche une annonce quelques secondes (avec un son)
local function announce(head: string, body: string, sound: string)
	local frame = group or build()
	shown += 1
	local mine = shown;
	(headLabel :: TextLabel).Text = head;
	(bodyLabel :: TextLabel).Text = body
	frame.Visible = true
	TweenService:Create(frame, TweenInfo.new(0.4), { GroupTransparency = 0 }):Play()
	Sfx.play(sound)
	task.delay(SHOW_TIME, function()
		if shown == mine then
			local fade = TweenService:Create(frame, TweenInfo.new(0.8), { GroupTransparency = 1 })
			fade:Play()
			fade.Completed:Wait()
			if shown == mine then
				frame.Visible = false
			end
		end
	end)
end

function MatchProgress.start()
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local lastPhase = state:GetAttribute("Phase")
	local lastNumber = MatchState.number()
	local warned: { [number]: boolean } = {}

	state:GetAttributeChangedSignal("Phase"):Connect(function()
		local index = state:GetAttribute("Phase")
		if index == lastPhase or typeof(index) ~= "number" then
			return
		end
		lastPhase = index
		if index == 1 or not MatchState.isRunning() then
			return -- la première phase est annoncée avec la nouvelle partie
		end
		local phase = Match.phases[index]
		if not phase then
			return
		end
		task.wait(0.5) -- le titre de la crise arrive juste après la phase
		local text = phase.text
		local crisis = state:GetAttribute("Crise")
		if phase.crisis and typeof(crisis) == "string" and crisis ~= "" then
			text = `🌋 {crisis}`
		end
		announce(`{phase.icon} Phase {index}/{#Match.phases} : {phase.name}`, text, if phase.crisis then "Alerte" else "Notification")
	end)

	-- événement mondial (crise énergétique, grève, séisme...)
	state:GetAttributeChangedSignal("EvenementHeure"):Connect(function()
		task.wait(0.2) -- le titre arrive juste après
		local title = state:GetAttribute("Evenement")
		local text = state:GetAttribute("EvenementTexte")
		if MatchState.isRunning() and typeof(title) == "string" and title ~= "" then
			announce(`🌍 Événement mondial : {title}`, if typeof(text) == "string" then text else "", "Alerte")
		end
	end)

	state:GetAttributeChangedSignal("PartieNumero"):Connect(function()
		if MatchState.number() == lastNumber then
			return
		end
		lastNumber = MatchState.number()
		table.clear(warned)
		announce("🌍 Nouvelle partie", `Choisis ton pays : {math.floor(Match.duration / 60)} minutes pour le mener en tête du classement mondial.`, "Succes")
	end)

	-- « fin de la partie dans 10 min, 5 min, 1 min »
	task.spawn(function()
		while true do
			task.wait(1)
			if MatchState.isRunning() then
				local left = MatchState.timeLeft()
				for _, seconds in Match.warnings do
					if left <= seconds and left > seconds - 5 and not warned[seconds] then
						warned[seconds] = true
						local text = if seconds >= 60 then `{seconds // 60} minute{if seconds >= 120 then "s" else ""}` else `{seconds} secondes`
						announce(`⏳ Fin de la partie dans {text}`, "Territoire, économie, armée, commerce : chaque point compte pour le classement final.", "Notification")
					end
				end
			end
		end
	end)
end

return MatchProgress
