--!strict
-- Panneau de sélection (SYSTEME_MILITAIRE.md, 6.3), en bas de l'écran : les divisions
-- sélectionnées (icône, nom, barres d'organisation et de force, état), chacune avec un bouton
-- pour la retirer ; bouton « Sélection multiple » (mobile : les appuis ajoutent ou retirent),
-- bouton ⏹ (les divisions en route s'arrêtent à la prochaine région) et bouton pour tout
-- désélectionner. Placé au centre si possible, sinon à côté des panneaux latéraux ouverts (fiche du
-- général, bataille) ; sur un téléphone trop chargé, il attend que la place se libère.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Regions = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Regions")) :: any
local Client = script.Parent.Parent
local UIStyle = require(Client:WaitForChild("UI"):WaitForChild("UIStyle"))
local Toast = require(Client:WaitForChild("UI"):WaitForChild("Toast"))
local MilitaryState = require(script.Parent:WaitForChild("MilitaryState"))
local Selection = require(script.Parent:WaitForChild("Selection"))
local CommandSender = require(script.Parent:WaitForChild("CommandSender"))
local ScreenSpace = require(script.Parent:WaitForChild("ScreenSpace"))

local ROW_HEIGHT = 30
local MAX_ROWS = 6 -- au-delà, la liste défile (moins sur un petit écran)
local HEADER = 52 -- en-tête, marges et espacement du panneau (pixels avant mise à l'échelle)
local MAX_WIDTH = 560
local MIN_WIDTH = 320 -- plus étroit : pas assez de place, le panneau attend
local COMPACT_WIDTH = 420 -- plus étroit : titre raccourci

local SelectionPanel = {}

local panel: Frame? = nil
local list: ScrollingFrame? = nil
local title: TextLabel? = nil
local multiButton: TextButton? = nil
local stopButton: TextButton? = nil
local maxRows = MAX_ROWS
local lastSelected: { Instance } = {}
local squeezed = false -- pas assez de place à l'écran
local compact = false -- panneau étroit
local rows: { [Instance]: Frame } = {}

-- Région que la division attaque (nil : elle n'attaque pas ; elle peut défendre la sienne)
local function attackedRegion(d: Instance): string?
	local id = d:GetAttribute("Bataille")
	if typeof(id) ~= "string" then
		return nil
	end
	local battles = ReplicatedStorage:FindFirstChild("EtatMonde")
	battles = battles and battles:FindFirstChild("Batailles")
	local battle = battles and battles:FindFirstChild(id)
	local regionId = battle and battle:GetAttribute("Region")
	return if typeof(regionId) == "string" and regionId ~= d:GetAttribute("Region") then regionId else nil
end

-- Le bouton ⏹ n'apparaît que si une division sélectionnée est en route ou mène une attaque
local function updateStop()
	local button, label = stopButton, title
	if not button or not label then
		return
	end
	local moving = false
	for _, d in Selection.get() do
		if MilitaryState.isMoving(d) or attackedRegion(d) then
			moving = true
			break
		end
	end
	button.Visible = moving
	label.Size = UDim2.new(1, if moving then -236 else -190, 1, 0)
end

local function statusOf(d: Instance): string
	local training = d:GetAttribute("Entrainement")
	if typeof(training) == "number" then
		return `⏳ {math.max(0, math.ceil(training - workspace:GetServerTimeNow()))} s`
	end
	if d:GetAttribute("Bataille") then
		local target = attackedRegion(d)
		local region = target and Regions[target]
		return if region then `⚔️ attaque {region.name}` else "🛡️ défend"
	end
	local destination = d:GetAttribute("Destination")
	if typeof(destination) == "string" and destination ~= "" then
		local region = Regions[destination]
		return `→ {if region then region.name else "?"}`
	end
	local region = Regions[d:GetAttribute("Region") :: string]
	local entrenchment = (d:GetAttribute("Retranchement") :: number?) or 0
	local dug = if entrenchment >= 0.05 then ` · ⛏ {math.floor(entrenchment * 100)} %` else ""
	-- coupée du ravitaillement : réserve restante, puis plus rien
	if d:GetAttribute("Ravitaillee") == false then
		dug = " · ⚠ sans ravitaillement"
	elseif d:GetAttribute("Encerclee") == true then
		dug = ` · 📦 réserve {d:GetAttribute("Reserve") or 0} s`
	end
	return if region then region.name .. dug else dug
end

local function bar(name: string, color: Color3, y: number, parent: Instance): Frame
	local back = Instance.new("Frame")
	back.Name = name
	back.Position = UDim2.new(0, 0, 0, y)
	back.Size = UDim2.new(1, 0, 0, 5)
	back.BackgroundColor3 = Color3.fromRGB(28, 31, 38)
	back.BorderSizePixel = 0
	local fill = Instance.new("Frame")
	fill.Name = "Remplissage"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = back
	back.Parent = parent
	return back
end

local function refreshRow(d: Instance, row: Frame)
	local org = (d:GetAttribute("Org") :: number?) or 0
	local orgMax = math.max((d:GetAttribute("OrgMax") :: number?) or 1, 1)
	local force = (d:GetAttribute("Force") :: number?) or 0
	local bars = row:FindFirstChild("Barres") :: Frame
	((bars:FindFirstChild("Org") :: Frame):FindFirstChild("Remplissage") :: Frame).Size = UDim2.fromScale(math.clamp(org / orgMax, 0, 1), 1);
	((bars:FindFirstChild("Force") :: Frame):FindFirstChild("Remplissage") :: Frame).Size = UDim2.fromScale(math.clamp(force / 100, 0, 1), 1);
	(row:FindFirstChild("Etat") :: TextLabel).Text = statusOf(d)
end

local function makeRow(d: Instance, order: number): Frame
	local row = Instance.new("Frame")
	row.Name = d.Name
	row.LayoutOrder = order
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, -8, 0, ROW_HEIGHT)
	local t = MilitaryState.typeOf(d)
	local name = UIStyle.text("Nom", `{t.icon} <b>{d:GetAttribute("Nom")}</b>`, 14)
	name.AutomaticSize = Enum.AutomaticSize.None
	name.TextWrapped = false
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Position = UDim2.fromOffset(0, 0)
	name.Size = UDim2.new(0.5, -4, 1, 0)
	name.TextYAlignment = Enum.TextYAlignment.Center
	name.Parent = row
	local bars = Instance.new("Frame")
	bars.Name = "Barres"
	bars.BackgroundTransparency = 1
	bars.Position = UDim2.new(0.5, 0, 0, 9)
	bars.Size = UDim2.new(0.18, 0, 0, 12)
	bar("Org", Color3.fromRGB(110, 210, 110), 0, bars)
	bar("Force", Color3.fromRGB(240, 160, 60), 7, bars)
	bars.Parent = row
	local state = UIStyle.text("Etat", "", 13, UIStyle.FONT, UIStyle.TEXT_DIM)
	state.AutomaticSize = Enum.AutomaticSize.None
	state.TextWrapped = false
	state.TextTruncate = Enum.TextTruncate.AtEnd
	state.Position = UDim2.new(0.68, 4, 0, 0)
	state.Size = UDim2.new(0.32, -40, 1, 0)
	state.TextYAlignment = Enum.TextYAlignment.Center
	state.Parent = row
	local remove = UIStyle.button("Retirer", "×")
	remove.AnchorPoint = Vector2.new(1, 0.5)
	remove.Position = UDim2.new(1, 0, 0.5, 0)
	remove.Size = UDim2.fromOffset(28, 24)
	remove.TextSize = 15
	remove.Parent = row
	remove.Activated:Connect(function()
		Selection.remove(d)
	end)
	refreshRow(d, row)
	return row
end

-- En bas de la place libre, centré si possible, sans passer sous les panneaux latéraux ouverts ni
-- sous les boutons flottants
local function place()
	local frame = panel
	if not frame then
		return
	end
	local scale = ScreenSpace.scale()
	local bottom = ScreenSpace.bottom()
	local height = (HEADER + math.max(1, math.min(#lastSelected, maxRows)) * (ROW_HEIGHT + 2)) * scale
	local x0, x1 = ScreenSpace.band(bottom - height, bottom)
	local width = math.min(MAX_WIDTH * scale, x1 - x0)
	squeezed = width < MIN_WIDTH * scale
	if squeezed then
		return
	end
	compact = width < COMPACT_WIDTH * scale
	local center = math.clamp(ScreenSpace.width() / 2, x0 + width / 2, x1 - width / 2)
	frame.Position = UDim2.fromOffset(center, bottom)
	frame.Size = UDim2.fromOffset(width / scale, 0)
end

local function render(selected: { Instance })
	lastSelected = selected
	local p, l, header = panel, list, title
	if not p or not l or not header then
		return
	end
	place()
	p.Visible = (#selected > 0 or Selection.isMulti()) and not squeezed
	local plural = if #selected > 1 then "s" else ""
	header.Text = if #selected == 0 then (if compact then "Touche tes divisions" else "Sélection multiple : touche tes divisions")
		elseif compact then `⚔️ <b>{#selected} division{plural}</b>`
		else `⚔️ <b>{#selected} division{plural}</b> sélectionnée{plural}`
	if multiButton then
		multiButton.Text = if Selection.isMulti() then "✓ Multiple" else "Multiple"
		UIStyle.setButtonColor(multiButton, if Selection.isMulti() then UIStyle.ACCENT else UIStyle.PANEL, if Selection.isMulti() then Color3.fromRGB(30, 26, 18) else UIStyle.TEXT, 0.1)
	end
	for d, row in rows do
		if not table.find(selected, d) then
			row:Destroy()
			rows[d] = nil
		end
	end
	for i, d in selected do
		local row = rows[d]
		if not row then
			row = makeRow(d, i)
			row.Parent = l
			rows[d] = row
		end
		row.LayoutOrder = i
	end
	l.Size = UDim2.new(1, 0, 0, math.min(#selected, maxRows) * (ROW_HEIGHT + 2))
	l.CanvasSize = UDim2.fromOffset(0, #selected * (ROW_HEIGHT + 2))
	updateStop()
end

function SelectionPanel.start()
	local gui = Instance.new("ScreenGui")
	gui.Name = "PanneauSelection"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	local frame = UIStyle.panel("Panneau", UDim.new(1, -24))
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Position = UDim2.new(0.5, 0, 1, -134)
	frame.Visible = false
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(MAX_WIDTH, math.huge)
	limit.Parent = frame
	UIStyle.padding(frame, 8, 10)
	UIStyle.list(frame, 6)

	local header = Instance.new("Frame")
	header.Name = "Entete"
	header.LayoutOrder = 1
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 30)
	local label = UIStyle.text("Titre", "", 15, UIStyle.FONT_MEDIUM)
	label.AutomaticSize = Enum.AutomaticSize.None
	label.TextWrapped = false
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Size = UDim2.new(1, -190, 1, 0)
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Parent = header
	local multi = UIStyle.button("Multiple", "Multiple")
	multi.AnchorPoint = Vector2.new(1, 0.5)
	multi.Position = UDim2.new(1, -44, 0.5, 0)
	multi.Size = UDim2.fromOffset(110, 28)
	multi.TextSize = 14
	multi.Parent = header
	multi.Activated:Connect(function()
		Selection.setMulti(not Selection.isMulti())
	end)
	local clearButton = UIStyle.button("ToutRetirer", "×")
	clearButton.AnchorPoint = Vector2.new(1, 0.5)
	clearButton.Position = UDim2.new(1, 0, 0.5, 0)
	clearButton.Size = UDim2.fromOffset(36, 28)
	clearButton.TextSize = 16
	clearButton.Parent = header
	clearButton.Activated:Connect(function()
		Selection.setMulti(false)
		Selection.clear()
	end)
	local stop = UIStyle.button("Arreter", "⏹")
	stop.AnchorPoint = Vector2.new(1, 0.5)
	stop.Position = UDim2.new(1, -162, 0.5, 0)
	stop.Size = UDim2.fromOffset(38, 28)
	stop.TextSize = 15
	stop.Visible = false
	stop.Parent = header
	stop.Activated:Connect(function()
		local accepted, message = CommandSender.send("Arreter", { ids = Selection.ids() })
		if accepted then
			Toast.show("Arrêt : elles finissent l'étape en cours, et les attaques cessent.", "info", false)
		else
			Toast.show(message or "Ordre refusé.", "danger", false)
		end
	end)
	header.Parent = frame

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Liste"
	scroll.LayoutOrder = 2
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.Size = UDim2.new(1, 0, 0, 0)
	scroll.CanvasSize = UDim2.new()
	UIStyle.list(scroll, 2)
	scroll.Parent = frame

	frame.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	panel, list, title, multiButton, stopButton = frame, scroll, label, multi, stop
	-- place libre à l'écran (téléphone compris) : au-dessus du bandeau d'actualités et des onglets
	ScreenSpace.onChanged(function()
		ScreenSpace.applyScale(frame)
		-- au plus la moitié de la place libre : la carte doit rester visible
		local height = (ScreenSpace.bottom() - ScreenSpace.top()) * 0.5 / ScreenSpace.scale()
		maxRows = math.clamp(math.floor((height - HEADER) / (ROW_HEIGHT + 2)), 1, MAX_ROWS)
		render(lastSelected)
	end)

	Selection.onChanged(render)
	-- barres et états des divisions affichées
	MilitaryState.onChanged(function(d: Instance, removed: boolean)
		local row = rows[d]
		if row and not removed then
			refreshRow(d, row)
			updateStop()
		end
	end)
	-- compte à rebours des entraînements et des trajets
	task.spawn(function()
		while true do
			task.wait(1)
			for d, row in rows do
				if d.Parent then
					refreshRow(d, row)
				end
			end
		end
	end)
end

return SelectionPanel
