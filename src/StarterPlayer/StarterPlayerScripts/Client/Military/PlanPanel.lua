--!strict
-- Ordres de plan de bataille dans la fiche d'un général (SYSTEME_MILITAIRE.md, 4.2) :
--   Front (toucher une région du pays ennemi), Ligne offensive (toucher les régions visées, autant
--   de fois que voulu), Lancer l'offensive, Ligne de repli (toucher ses régions), Tenir, Annuler ;
--   l'état du plan (front, objectifs, ordre, bonus de planification) s'affiche au-dessus.
-- Les ordres partent par CommandeMilitaire ; le serveur vérifie tout (BattlePlans).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local Client = script.Parent.Parent
local UIStyle = require(Client:WaitForChild("UI"):WaitForChild("UIStyle"))
local Toast = require(Client:WaitForChild("UI"):WaitForChild("Toast"))
local RegionSelector = require(Client:WaitForChild("Map"):WaitForChild("RegionSelector"))
local CommandSender = require(script.Parent:WaitForChild("CommandSender"))
local GeneralPanel = require(script.Parent:WaitForChild("GeneralPanel"))

local MODES = {
	Front = { order = "PlanFront", hint = "Touche une région du pays ennemi : le front sera face à lui.", once = true },
	Objectif = { order = "PlanObjectif", hint = "Touche les régions à prendre (encore une fois pour en retirer une). Rappuie sur le bouton pour finir.", once = false },
	Repli = { order = "PlanRepli", hint = "Touche tes régions de repli (encore une fois pour en retirer une). Rappuie sur le bouton pour finir.", once = false },
}

local PlanPanel = {}

local mode: string? = nil -- choix en cours sur la carte
local modeGeneral: Instance? = nil

local function list(general: Instance, attribute: string): { string }
	local raw = general:GetAttribute(attribute)
	return if typeof(raw) == "string" and raw ~= "" then string.split(raw, ",") else {}
end

local function names(ids: { string }, max: number): string
	local out = {}
	for i, id in ids do
		if i > max then
			table.insert(out, `+{#ids - max}`)
			break
		end
		table.insert(out, if Regions[id] then Regions[id].name else id)
	end
	return table.concat(out, ", ")
end

local function setMode(general: Instance?, newMode: string?)
	mode, modeGeneral = newMode, general
	if newMode then
		Toast.show(MODES[newMode].hint, "info", false)
	end
	GeneralPanel.refresh()
end

local function send(order: string, data: { [string]: any })
	local accepted, message = CommandSender.send(order, data)
	if not accepted then
		Toast.show(message or "Ordre refusé.", "danger", false)
	elseif message then
		Toast.show(message, "info", false)
	end
	GeneralPanel.refresh()
end

-- Mode en cours (pour l'affichage sur la carte, PlanRenderer)
function PlanPanel.mode(): string?
	return mode
end

-- Toucher la carte pendant un choix : la région touchée part au serveur (vrai si utilisé)
function PlanPanel.handlePick(screenPos: Vector2): boolean
	local general = modeGeneral
	if not mode or not general or not general.Parent or GeneralPanel.current() ~= general then
		mode, modeGeneral = nil, nil
		return false
	end
	local settings = MODES[mode]
	local regionId = RegionSelector.regionAt(screenPos)
	if regionId then
		task.spawn(send, settings.order, { general = general.Name, region = regionId })
	end
	if settings.once then
		mode, modeGeneral = nil, nil
		GeneralPanel.refresh()
	end
	return true
end

local function build(general: Instance, parent: Instance, firstOrder: number)
	local order = firstOrder
	local function add(object: GuiObject)
		order += 1
		object.LayoutOrder = order
		object.Parent = parent
	end
	local enemy = general:GetAttribute("FrontPays")
	local country = if typeof(enemy) == "string" then Countries[enemy] else nil
	local front, objectives, fallback = list(general, "Front"), list(general, "Objectifs"), list(general, "Repli")
	local ordre = general:GetAttribute("Ordre")
	local planning = (general:GetAttribute("Planification") :: number?) or 0
	-- état du plan
	local lines = {}
	if country then
		table.insert(lines, `🛡️ Front face à {FrenchNames.the(country.name)} : {#front} région{if #front > 1 then "s" else ""}`)
	else
		table.insert(lines, "Aucun plan : donne-lui un front.")
	end
	if #objectives > 0 then
		table.insert(lines, `➡️ Objectifs : {names(objectives, 4)}`)
	end
	if #fallback > 0 then
		table.insert(lines, `↩️ Repli : {names(fallback, 4)}`)
	end
	if country then
		local label = if ordre == "Offensive" then "offensive en cours" elseif ordre == "Tenir" then "tenir la position" else "défendre le front"
		table.insert(lines, `Ordre : {label} · planification +{math.floor(planning * 100 + 0.5)} %`)
	end
	add(UIStyle.text("Plan", table.concat(lines, "\n"), 14, UIStyle.FONT, UIStyle.TEXT_DIM))
	local function button(name: string, text: string, primary: boolean?, enabled: boolean, onClick: () -> ())
		local b = UIStyle.button(name, text, primary)
		b.Size = UDim2.new(1, 0, 0, 36)
		b.TextSize = 15
		UIStyle.setButtonEnabled(b, enabled)
		b.Activated:Connect(function()
			if UIStyle.isEnabled(b) then
				onClick()
			end
		end)
		add(b)
	end
	local picking = if modeGeneral == general then mode else nil
	button("PlanFront", if picking == "Front" then "🛡️ Touche une région ennemie…" else "🛡️ Front", false, true, function()
		setMode(general, if picking == "Front" then nil else "Front")
	end)
	button("PlanObjectif", if picking == "Objectif" then "✔️ Terminer la ligne offensive" else "➡️ Ligne offensive", false, country ~= nil, function()
		setMode(general, if picking == "Objectif" then nil else "Objectif")
	end)
	button("PlanLancer", if ordre == "Offensive" then "🚀 Offensive lancée" else "🚀 Lancer l'offensive", true, #objectives > 0 and ordre ~= "Offensive", function()
		task.spawn(send, "PlanLancer", { general = general.Name })
	end)
	button("PlanRepli", if picking == "Repli" then "✔️ Terminer la ligne de repli" else "↩️ Ligne de repli", false, true, function()
		setMode(general, if picking == "Repli" then nil else "Repli")
	end)
	button("PlanTenir", "✋ Tenir la position", false, country ~= nil and ordre ~= "Tenir", function()
		task.spawn(send, "PlanTenir", { general = general.Name })
	end)
	button("PlanAnnuler", "🗑️ Annuler les ordres", false, country ~= nil or #fallback > 0, function()
		setMode(nil, nil)
		task.spawn(send, "PlanAnnuler", { general = general.Name })
	end)
end

function PlanPanel.start()
	GeneralPanel.addButtons(function(general: Instance, parent: Instance, order: number)
		local me = game:GetService("Players").LocalPlayer:GetAttribute("Pays")
		if general:GetAttribute("Proprietaire") == me then
			build(general, parent, order)
		end
	end)
end

return PlanPanel
