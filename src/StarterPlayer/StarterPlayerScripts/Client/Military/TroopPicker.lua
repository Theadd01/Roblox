--!strict
-- Troupes à rattacher à un général (cahier des charges v2, 5.1) : par type et par nombre, depuis
-- les régions où elles se trouvent. Une carte par région avec des divisions disponibles (à l'arrêt,
-- prêtes, hors bataille, hors armée d'un général) ; pour chaque type, un compteur (− / +) et
-- « Tout ». Les troupes choisies disparaissent de la carte : elles rejoignent l'armée du général.
-- Le serveur vérifie tout (ordre « AbsorberTroupes »).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local DivisionConfig = require(Config:WaitForChild("Divisions")) :: any
local MilitaryConfig = require(Config:WaitForChild("Military")) :: any
local Client = script.Parent.Parent
local UI = Client:WaitForChild("UI")
local UIStyle = require(UI:WaitForChild("UIStyle"))
local ModalHost = require(UI:WaitForChild("ModalHost"))
local Toast = require(UI:WaitForChild("Toast"))
local RegionView = require(Client:WaitForChild("Map"):WaitForChild("RegionView"))
local MilitaryState = require(script.Parent:WaitForChild("MilitaryState"))
local CommandSender = require(script.Parent:WaitForChild("CommandSender"))

local TroopPicker = {}

local gui: ScreenGui? = nil
local busy = false

local function myCountry(): string?
	local me = Players.LocalPlayer:GetAttribute("Pays")
	return if typeof(me) == "string" and me ~= "" then me else nil
end

local function screen(): ScreenGui
	local existing = gui
	if existing and existing.Parent then
		return existing
	end
	local created = Instance.new("ScreenGui")
	created.Name = "ChoixTroupes"
	created.ResetOnSpawn = false
	created.DisplayOrder = 25
	created.IgnoreGuiInset = true
	created.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	gui = created
	return created
end

-- Divisions disponibles : région -> type -> nombre
local function available(countryId: string): { [string]: { [string]: number } }
	local result: { [string]: { [string]: number } } = {}
	for _, d in MilitaryState.ofCountry(countryId, true) do
		local regionId = d:GetAttribute("Region")
		if typeof(regionId) ~= "string" or RegionView.getOwner(regionId) ~= countryId or MilitaryState.isTraining(d)
			or MilitaryState.isMoving(d) or d:GetAttribute("Bataille") ~= nil then
			continue
		end
		local typeId = d:GetAttribute("Type") :: string
		result[regionId] = result[regionId] or {}
		result[regionId][typeId] = (result[regionId][typeId] or 0) + 1
	end
	return result
end

local function capacityOf(general: Instance): number
	local level = math.clamp((general:GetAttribute("Niveau") :: number?) or 1, 1, #MilitaryConfig.generals.capacity)
	return MilitaryConfig.generals.capacity[level]
end

-- Ouvre le choix des troupes pour un de ses généraux
function TroopPicker.open(general: Instance)
	local me = myCountry()
	if not me or general:GetAttribute("Proprietaire") ~= me then
		return
	end
	local parent = screen()
	for _, child in parent:GetChildren() do
		child:Destroy()
	end
	local stock = available(me)
	local picks: { [string]: { [string]: number } } = {}
	local room = capacityOf(general) - ((general:GetAttribute("Troupes") :: number?) or 0)

	local shade = Instance.new("Frame")
	shade.Name = "FondModal"
	shade.Active = true
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = UIStyle.BACKDROP
	shade.BackgroundTransparency = 0.35
	shade.BorderSizePixel = 0
	shade.Visible = false
	shade.Parent = parent
	local viewport = workspace.CurrentCamera.ViewportSize
	local desktop = viewport.X >= 600
	local panel = UIStyle.panel("Fenetre", if desktop then UDim.new(0, 480) else UDim.new(1, -24))
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	UIStyle.padding(panel, 14, 16)
	UIStyle.list(panel, 8)
	panel.Parent = shade

	local function close()
		ModalHost.hide(shade)
		shade:Destroy()
	end

	local title = UIStyle.text("Titre", `🎖️ <b>Troupes pour {general:GetAttribute("Nom")}</b>`, 19, UIStyle.FONT_BOLD)
	title.LayoutOrder = 1
	title.Parent = panel
	local info = UIStyle.text("Info", "", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
	info.LayoutOrder = 2
	info.Parent = panel

	local list = Instance.new("ScrollingFrame")
	list.Name = "Regions"
	list.LayoutOrder = 3
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Size = UDim2.new(1, 0, 0, math.clamp(viewport.Y - 260, 160, 420))
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	UIStyle.styleScroll(list)
	UIStyle.list(list, 8)
	list.Parent = panel

	local footer = Instance.new("Frame")
	footer.Name = "Boutons"
	footer.LayoutOrder = 4
	footer.BackgroundTransparency = 1
	footer.Size = UDim2.new(1, 0, 0, 44)
	local footerLayout = UIStyle.list(footer, 8, true)
	footerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	footer.Parent = panel
	local cancel = UIStyle.button("Annuler", "Annuler", false)
	cancel.LayoutOrder = 1
	cancel.Size = UDim2.new(0.35, -4, 1, 0)
	cancel.TextSize = 17
	cancel.Parent = footer
	local confirm = UIStyle.button("Rattacher", "Rattacher", true)
	confirm.LayoutOrder = 2
	confirm.Size = UDim2.new(0.65, -4, 1, 0)
	confirm.TextSize = 17
	confirm.Parent = footer

	local counters: { [string]: TextLabel } = {}

	local function total(): number
		local n = 0
		for _, types in picks do
			for _, count in types do
				n += count
			end
		end
		return n
	end

	local function refresh()
		local chosen = total()
		info.Text = `Armée : {(general:GetAttribute("Troupes") :: number?) or 0}/{capacityOf(general)} troupes · choisies : <b>{chosen}</b>`
			.. (if chosen >= room then ` <font color="{UIStyle.GREY_HEX}">(armée pleine)</font>` else "")
		for key, label in counters do
			local regionId, typeId = string.match(key, "^(.-)|(.*)$")
			label.Text = tostring(picks[regionId :: string] and picks[regionId :: string][typeId :: string] or 0)
		end
		confirm.Text = if chosen > 0 then `Rattacher {chosen} troupe{if chosen > 1 then "s" else ""}` else "Rattacher"
		UIStyle.setButtonEnabled(confirm, chosen > 0 and not busy)
	end

	local function setPick(regionId: string, typeId: string, value: number)
		local max = stock[regionId][typeId]
		local current = picks[regionId] and picks[regionId][typeId] or 0
		local others = total() - current
		value = math.clamp(value, 0, math.min(max, room - others))
		picks[regionId] = picks[regionId] or {}
		picks[regionId][typeId] = value
		refresh()
	end

	-- régions : celle du général d'abord, puis les mieux fournies
	local regionIds = {}
	for regionId in stock do
		table.insert(regionIds, regionId)
	end
	local here = general:GetAttribute("Region")
	local function size(regionId: string): number
		local n = 0
		for _, count in stock[regionId] do
			n += count
		end
		return n
	end
	table.sort(regionIds, function(a: string, b: string): boolean
		if (a == here) ~= (b == here) then
			return a == here
		end
		if size(a) ~= size(b) then
			return size(a) > size(b)
		end
		return a < b
	end)
	if #regionIds == 0 then
		local empty = UIStyle.text("Vide", "Aucune division disponible : elles sont à l'entraînement, en route, au combat ou déjà dans l'armée d'un général. Recrute-en dans l'onglet Armée.", 15, UIStyle.FONT, UIStyle.TEXT_DIM)
		empty.Parent = list
	end
	for index, regionId in regionIds do
		local card = UIStyle.card("Region_" .. regionId)
		card.LayoutOrder = index
		UIStyle.padding(card, 8, 10)
		UIStyle.list(card, 4)
		local region = Regions[regionId]
		local header = UIStyle.text("Nom", `📍 <b>{if region then region.name else regionId}</b>{if regionId == here then ` <font color="{UIStyle.GREY_HEX}">(région du général)</font>` else ""}`, 15, UIStyle.FONT_MEDIUM)
		header.LayoutOrder = 0
		header.Parent = card
		local order = 0
		for _, typeId in DivisionConfig.order do
			local count = stock[regionId][typeId]
			if not count then
				continue
			end
			order += 1
			local t = DivisionConfig.types[typeId]
			local row = Instance.new("Frame")
			row.Name = typeId
			row.LayoutOrder = order
			row.BackgroundTransparency = 1
			row.Size = UDim2.new(1, 0, 0, 32)
			row.Parent = card
			local label = UIStyle.text("Type", `{t.icon} {t.name} <font color="{UIStyle.GREY_HEX}">· {count} dispo</font>`, 14)
			label.AutomaticSize = Enum.AutomaticSize.None
			label.TextWrapped = false
			label.TextTruncate = Enum.TextTruncate.AtEnd
			label.Size = UDim2.new(1, -170, 1, 0)
			label.TextYAlignment = Enum.TextYAlignment.Center
			label.Parent = row
			local function small(name: string, text: string, x: number, width: number): TextButton
				local b = UIStyle.button(name, text, false)
				b.AnchorPoint = Vector2.new(1, 0.5)
				b.Position = UDim2.new(1, -x, 0.5, 0)
				b.Size = UDim2.fromOffset(width, 28)
				b.TextSize = 15
				b.Parent = row
				return b
			end
			local all = small("Tout", "Tout", 0, 46)
			local plus = small("Plus", "+", 52, 30)
			local value = UIStyle.text("Nombre", "0", 15, UIStyle.FONT_BOLD)
			value.AutomaticSize = Enum.AutomaticSize.None
			value.AnchorPoint = Vector2.new(1, 0.5)
			value.Position = UDim2.new(1, -86, 0.5, 0)
			value.Size = UDim2.fromOffset(42, 28)
			value.TextXAlignment = Enum.TextXAlignment.Center
			value.TextYAlignment = Enum.TextYAlignment.Center
			value.Parent = row
			local minus = small("Moins", "−", 132, 30)
			counters[regionId .. "|" .. typeId] = value
			local function current(): number
				return picks[regionId] and picks[regionId][typeId] or 0
			end
			minus.Activated:Connect(function()
				setPick(regionId, typeId, current() - 1)
			end)
			plus.Activated:Connect(function()
				setPick(regionId, typeId, current() + 1)
			end)
			all.Activated:Connect(function()
				setPick(regionId, typeId, if current() >= count then 0 else count)
			end)
		end
		card.Parent = list
	end

	cancel.Activated:Connect(close)
	confirm.Activated:Connect(function()
		if busy or total() == 0 then
			return
		end
		local troops = {}
		for regionId, types in picks do
			for typeId, count in types do
				if count > 0 then
					table.insert(troops, { region = regionId, type = typeId, nombre = count })
				end
			end
		end
		busy = true
		refresh()
		local accepted, message = CommandSender.send("AbsorberTroupes", { general = general.Name, troupes = troops })
		busy = false
		if accepted then
			Toast.show(message or `🎖️ Troupes rattachées à {general:GetAttribute("Nom")}.`, "success", false)
			close()
		else
			Toast.show(message or "Ordre refusé.", "danger", false)
			refresh()
		end
	end)
	refresh()
	ModalHost.show(shade, function()
		if shade.Parent then
			shade:Destroy()
		end
	end)
end

return TroopPicker
