--!strict
-- Ordres aux armées depuis la carte, façon Hearts of Iron :
--   1. clic (ou toucher) sur un général ou sur une de ses troupes : la force est sélectionnée
--      (surbrillance dorée, bandeau en bas de l'écran) ;
--   2. clic sur une région : la force y va. Une armée de terre avance de région en région (le
--      serveur calcule le chemin et enchaîne les batailles en terrain ennemi) ; escadrilles et
--      flottes y vont d'un trait, dans leur rayon d'action. La force reste sélectionnée ;
--   3. clic dans la mer, bouton × ou touche Échap : plus de sélection.
-- Un second clic sur la force sélectionnée ouvre sa fiche (onglet Armée) ; une force étrangère
-- ouvre directement sa fiche (lecture seule). Le serveur valide tout (Remotes.DeplacerArmee).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Units = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Units")) :: any
local Client = script.Parent.Parent
local ArmyState = require(Client:WaitForChild("State"):WaitForChild("ArmyState"))
local ArmyView = require(script.Parent:WaitForChild("ArmyView"))
local RegionSelector = require(script.Parent:WaitForChild("RegionSelector"))
local UI = Client:WaitForChild("UI")
local UIStyle = require(UI:WaitForChild("UIStyle"))
local Toast = require(UI:WaitForChild("Toast"))
local Sfx = require(Client:WaitForChild("Audio"):WaitForChild("Sfx"))

local BOTTOM = 134 -- au-dessus du journal défilant et de la barre d'onglets
local HINTS = {
	Terre = "touche une région : il y va de région en région",
	Air = "touche une région à portée de vol",
	Mer = "touche une région côtière à portée",
}

export type Options = {
	myCountry: () -> string?, -- pays dirigé (nil hors partie)
	openArmy: (armyId: string) -> (), -- fiche d'une force (onglet Armée)
	onSelect: () -> (), -- une force vient d'être sélectionnée (ex. fermer la fiche de région)
}

local ArmyOrders = {}

local options: Options? = nil
local selected: string? = nil
local banner: Frame? = nil
local label: TextLabel? = nil
local busy = false

local function buildBanner()
	local gui = Instance.new("ScreenGui")
	gui.Name = "OrdresArmee"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	local frame = UIStyle.panel("Bandeau", UDim.new(1, -24))
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Position = UDim2.new(0.5, 0, 1, -BOTTOM)
	frame.Visible = false
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(560, math.huge)
	limit.Parent = frame
	UIStyle.padding(frame, 8, 10)
	local layout = UIStyle.list(frame, 8, true)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center

	local text = UIStyle.text("Texte", "", 16, UIStyle.FONT_MEDIUM)
	text.Size = UDim2.new(1, -144, 0, 0)
	text.LayoutOrder = 1
	text.Parent = frame

	local sheet = UIStyle.button("Fiche", "📋 Fiche")
	sheet.Size = UDim2.fromOffset(84, 38)
	sheet.TextSize = 16
	sheet.LayoutOrder = 2
	sheet.Parent = frame
	sheet.Activated:Connect(function()
		local id = selected
		if id and options then
			options.openArmy(id)
		end
	end)

	local close = UIStyle.button("Fermer", "×")
	close.Size = UDim2.fromOffset(44, 38)
	close.TextSize = 18
	close.LayoutOrder = 3
	close.Parent = frame
	close.Activated:Connect(function()
		ArmyOrders.select(nil)
	end)

	frame.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	banner, label = frame, text
end

local function refreshBanner()
	local frame, text = banner, label
	if not frame or not text then
		return
	end
	local army = if selected then ArmyState.get(selected) else nil
	frame.Visible = army ~= nil
	if army then
		local kind = ArmyState.kind(army)
		text.Text = `{Units.kinds[kind].icon} <b>{army:GetAttribute("Nom")}</b> : {HINTS[kind] or HINTS.Terre}`
	end
end

-- Sélectionne une de ses forces (nil : aucune)
function ArmyOrders.select(armyId: string?)
	selected = armyId
	ArmyView.setSelected(armyId)
	refreshBanner()
	if armyId and options then
		options.onSelect()
	end
end

function ArmyOrders.getSelected(): string?
	return selected
end

-- Envoie la force sélectionnée vers une région (le serveur valide)
local function order(armyId: string, regionId: string)
	if busy then
		return
	end
	busy = true
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DeplacerArmee") :: RemoteFunction
	local ok, accepted, reason = pcall(function()
		return remote:InvokeServer(armyId, regionId)
	end)
	busy = false
	local success = ok and accepted == true
	Sfx.actionResult("DeplacerArmee", success)
	if not success then
		Toast.show(if ok and typeof(reason) == "string" then reason else "Le serveur ne répond pas.", "danger", false)
	end
end

-- Clic sur la carte (appelé avant la sélection des régions) : vrai si le clic est utilisé ici
function ArmyOrders.handleTap(screenPos: Vector2): boolean
	local o = options
	if not o then
		return false
	end
	local me = o.myCountry()
	local armyId = ArmyView.hitTest(screenPos)
	if armyId then
		local army = ArmyState.get(armyId)
		if army and me and army:GetAttribute("Proprietaire") == me then
			if selected == armyId then
				o.openArmy(armyId) -- second clic : la fiche
			else
				ArmyOrders.select(armyId)
			end
		else
			o.openArmy(armyId) -- force étrangère : sa fiche, en lecture seule
		end
		return true
	end
	local current = selected
	if current then
		local regionId = RegionSelector.regionAt(screenPos)
		if regionId then
			task.spawn(order, current, regionId)
		else
			ArmyOrders.select(nil) -- clic dans la mer
		end
		return true
	end
	return false
end

function ArmyOrders.start(opts: Options)
	options = opts
	buildBanner()
	-- la force sélectionnée disparaît (défaite, nouvelle partie) : plus de sélection
	ArmyState.onChanged(function(army: Instance, removed: boolean)
		if army.Name ~= selected then
			return
		end
		if removed then
			ArmyOrders.select(nil)
		else
			refreshBanner()
		end
	end)
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == Enum.KeyCode.Escape and selected then
			ArmyOrders.select(nil)
		end
	end)
end

return ArmyOrders
