--!strict
-- Guerre depuis la carte (cahier des charges v2, section 3), dans la fiche d'une région étrangère :
--   pas en guerre avec son propriétaire -> « Déclarer la guerre » (confirmation en un clic), par la
--     MÊME fonction serveur que l'onglet Diplomatie (Remotes.DeclarerGuerre) ;
--   déjà en guerre -> « Attaquer » : toutes tes divisions prêtes des régions voisines attaquent
--     (ordre « AttaquerRegion »), avec l'option « attaque continue » ; tes généraux peuvent aussi
--     lancer leur armée sur la région ;
--   allié, trêve ou pays protégé -> la raison, et un raccourci vers l'onglet Diplomatie.
-- Le serveur vérifie tout.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local CombatConfig = require(Config:WaitForChild("CombatConfig")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local CouncilState = require(Shared:WaitForChild("CouncilState")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local Client = script.Parent.Parent
local RegionView = require(Client:WaitForChild("Map"):WaitForChild("RegionView"))
local Fog = require(Client:WaitForChild("State"):WaitForChild("Fog"))
local MilitaryFolder = Client:WaitForChild("Military")
local MilitaryState = require(MilitaryFolder:WaitForChild("MilitaryState"))
local CommandSender = require(MilitaryFolder:WaitForChild("CommandSender"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local RegionPanel = require(script.Parent:WaitForChild("RegionPanel"))
local ConfirmDialog = require(script.Parent:WaitForChild("ConfirmDialog"))
local Toast = require(script.Parent:WaitForChild("Toast"))
local Sfx = require(Client:WaitForChild("Audio"):WaitForChild("Sfx"))

local WarPanel = {}

local busy = false

local function myCountry(): string?
	local id = Players.LocalPlayer:GetAttribute("Pays")
	return if typeof(id) == "string" and id ~= "" then id else nil
end

local function nameOf(countryId: string): string
	local country = Countries[countryId]
	return if country then country.name else countryId
end

-- Divisions prêtes à attaquer la région depuis tes régions voisines (comme le serveur :
-- BattleManager.readyAttackers) : nombre de divisions et de régions
local function readyAttackers(me: string, regionId: string): (number, number)
	local divisions, regions = 0, 0
	for _, link in Regions[regionId].neighbors do
		if link.bySea or RegionView.getOwner(link.region) ~= me then
			continue
		end
		local here = 0
		for _, d in MilitaryState.inRegion(link.region) do
			local battle = d:GetAttribute("Bataille")
			if d:GetAttribute("Proprietaire") == me and not MilitaryState.isTraining(d) and not MilitaryState.isMoving(d)
				and ((d:GetAttribute("Force") :: number?) or 0) >= 5 then
				-- une division déjà engagée ailleurs (ou qui défend sa région) reste à sa bataille
				local state = ReplicatedStorage:FindFirstChild("EtatMonde")
				local battles = state and state:FindFirstChild("Batailles")
				local folder = if typeof(battle) == "string" and battles then battles:FindFirstChild(battle) else nil
				if folder and folder:GetAttribute("Region") ~= regionId then
					continue
				end
				here += 1
			end
		end
		if here > 0 then
			divisions += here
			regions += 1
		end
	end
	return divisions, regions
end

-- Ses généraux avec des troupes
local function myGenerals(me: string): { Instance }
	local list = {}
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local folder = state and state:FindFirstChild("Generaux")
	for _, g in (if folder then folder:GetChildren() else {}) do
		if g:GetAttribute("Proprietaire") == me and ((g:GetAttribute("Troupes") :: number?) or 0) > 0 then
			table.insert(list, g)
		end
	end
	table.sort(list, function(a: Instance, b: Instance): boolean
		return a.Name < b.Name
	end)
	return list
end

local function openDiplomacy()
	-- chargé à la demande : TabBar dépend de nombreux onglets
	local ok, TabBar = pcall(function()
		return require(script.Parent:WaitForChild("TabBar")) :: any
	end)
	if ok then
		RegionPanel.show(nil)
		TabBar.select("Diplomatie")
	end
end

local function declareWar(owner: string)
	if busy then
		return
	end
	local bloc = DiplomacyState.blocName(owner)
	local allies = DiplomacyState.alliesOf(owner)
	local warning = if #allies > 0 then `\nSes alliés du bloc <b>{bloc or "?"}</b> ({#allies}) entreront aussi en guerre contre toi.` else ""
	local confirmed = ConfirmDialog.ask({
		title = `Déclarer la guerre à {FrenchNames.the(nameOf(owner))} ?`,
		text = `Tu pourras ensuite attaquer ses régions.{warning}`,
		confirmText = "⚔️ Déclarer la guerre",
		danger = true,
	})
	if not confirmed then
		return
	end
	busy = true
	-- même fonction serveur que le bouton de l'onglet Diplomatie
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DeclarerGuerre") :: RemoteFunction
	local ok, accepted, reason = pcall(function()
		return remote:InvokeServer(owner)
	end)
	busy = false
	Sfx.actionResult("DeclarerGuerre", ok and accepted == true)
	if ok and accepted == true then
		Toast.show(`⚔️ Tu as déclaré la guerre à {FrenchNames.the(nameOf(owner))}.`, "danger", false)
	else
		Toast.show(if ok and typeof(reason) == "string" then reason else "Le serveur ne répond pas.", "danger", false)
	end
	RegionPanel.refresh()
end

local function attack(regionId: string, divisions: number, regions: number)
	if busy then
		return
	end
	local region = Regions[regionId]
	local confirmed, continuous = ConfirmDialog.ask({
		title = `Attaquer {region.name} ?`,
		text = `{divisions} division{if divisions > 1 then "s" else ""} de {regions} région{if regions > 1 then "s" else ""} voisine{if regions > 1 then "s" else ""} attaque{if divisions > 1 then "nt" else ""} (au plus {CombatConfig.frontWidth} au front en même temps). La région est prise dès que ses défenseurs sont tombés ; tes troupes y entrent.`,
		confirmText = "⚔️ Attaquer",
		toggle = { text = "Attaque continue : enchaîner les régions ennemies voisines", value = false },
	})
	if not confirmed then
		return
	end
	busy = true
	local accepted, message = CommandSender.send("AttaquerRegion", { region = regionId, continu = continuous })
	busy = false
	Sfx.actionResult("Recruter", accepted)
	Toast.show(message or (if accepted then "À l'attaque !" else "Ordre refusé."), if accepted then "success" else "danger", false)
	RegionPanel.refresh()
end

local function attackWithGeneral(general: Instance, regionId: string)
	if busy then
		return
	end
	local region = Regions[regionId]
	local troops = (general:GetAttribute("Troupes") :: number?) or 0
	local confirmed, continuous = ConfirmDialog.ask({
		title = `{general:GetAttribute("Nom")} attaque {region.name} ?`,
		text = `Son armée ({troops} troupe{if troops > 1 then "s" else ""}) va dans une de tes régions voisines puis attaque avec toutes ses troupes.`,
		confirmText = "🎖️ Lancer l'armée",
		toggle = { text = "Attaque continue : enchaîner les régions ennemies voisines", value = true },
	})
	if not confirmed then
		return
	end
	busy = true
	local accepted, message = CommandSender.send("DeplacerGeneral", { general = general.Name, region = regionId, continu = continuous })
	busy = false
	Sfx.actionResult("Recruter", accepted)
	Toast.show(if accepted then `🎖️ L'armée de {general:GetAttribute("Nom")} marche sur {region.name}.` else message or "Ordre refusé.", if accepted then "success" else "danger", false)
end

local function fill(regionId: string?, container: Frame)
	for _, child in container:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
	local me = myCountry()
	local owner = if regionId then RegionView.getOwner(regionId) else nil
	if not regionId or not me or not owner or owner == me then
		container.Visible = false
		return
	end
	container.Visible = true
	local order = 0
	local function add(object: GuiObject)
		order += 1
		object.LayoutOrder = order
		object.Parent = container
	end
	local function line(text: string, color: Color3?)
		add(UIStyle.text("Info", text, 15, UIStyle.FONT_MEDIUM, color))
	end
	local function button(name: string, text: string, primary: boolean, enabled: boolean, onClick: () -> ()): TextButton
		local b = UIStyle.button(name, text, primary)
		b.Size = UDim2.new(1, 0, 0, 40)
		b.TextSize = 16
		UIStyle.setButtonEnabled(b, enabled)
		b.Activated:Connect(function()
			if UIStyle.isEnabled(b) then
				task.spawn(onClick)
			end
		end)
		add(b)
		return b
	end
	local relation = DiplomacyState.relation(me, owner)
	local protection = DiplomacyState.protectionLeft(owner)
	if relation == "Allie" then
		line(`🤝 {FrenchNames.The(nameOf(owner))} est ton allié : impossible de l'attaquer.`, UIStyle.TEXT_DIM)
		button("Diplomatie", "🕊️ Ouvrir la diplomatie", false, true, openDiplomacy)
	elseif relation == "Treve" then
		line(`🕊️ Trêve avec {FrenchNames.the(nameOf(owner))} : aucune attaque encore {math.ceil(DiplomacyState.truceLeft(me, owner))} s.`, UIStyle.WARNING)
		button("Diplomatie", "🕊️ Ouvrir la diplomatie", false, true, openDiplomacy)
	elseif relation == "Guerre" then
		local ceasefire = CouncilState.ceasefireLeft()
		if ceasefire > 0 then
			line(`🕊️ Cessez-le-feu mondial : aucune attaque encore {math.ceil(ceasefire)} s.`, UIStyle.WARNING)
			return
		end
		local divisions, regions = readyAttackers(me, regionId)
		if divisions > 0 then
			button("Attaquer", `⚔️ Attaquer ({divisions} division{if divisions > 1 then "s" else ""}, {regions} région{if regions > 1 then "s" else ""})`, true, true, function()
				attack(regionId, divisions, regions)
			end)
		else
			line("Aucune division prête dans tes régions voisines de celle-ci.", UIStyle.TEXT_DIM)
		end
		for _, general in myGenerals(me) do
			local troops = (general:GetAttribute("Troupes") :: number?) or 0
			local wounded = typeof(general:GetAttribute("Blesse")) == "number"
			button("General_" .. general.Name, `🎖️ Lancer {general:GetAttribute("Nom")} (🪖 {troops}){if wounded then " 🩹" else ""}`, false, not wounded, function()
				attackWithGeneral(general, regionId)
			end)
		end
	elseif protection > 0 then
		line(`🛡️ Ce pays vient d'être choisi par un joueur : protégé encore {math.ceil(protection)} s.`, UIStyle.TEXT_DIM)
	else
		button("DeclarerGuerre", `⚔️ Déclarer la guerre à {FrenchNames.the(nameOf(owner))}`, false, true, function()
			declareWar(owner)
		end).TextColor3 = UIStyle.DANGER
	end
end

-- À appeler après RegionPanel.create
function WarPanel.attach()
	local container = RegionPanel.addSection("Guerre", 10)
	UIStyle.list(container, 6)
	RegionPanel.onShow(function(regionId: string?)
		fill(regionId, container)
	end)
	-- guerres, trêves, alliances : la fiche ouverte se met à jour
	task.spawn(function()
		local diplomacy = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Diplomatie")
		for _, name in { "Guerres", "Treves", "Blocs" } do
			local folder = diplomacy:WaitForChild(name)
			local function changed()
				if RegionPanel.getShown() then
					RegionPanel.refresh()
				end
			end
			folder.ChildAdded:Connect(changed)
			folder.ChildRemoved:Connect(changed)
		end
	end)
	-- garnisons des régions voisines : le nombre de divisions prêtes change
	MilitaryState.onRegionChanged(function(changedRegion: string)
		local shown = RegionPanel.getShown()
		if not shown or not Regions[shown] then
			return
		end
		for _, link in Regions[shown].neighbors do
			if link.region == changedRegion then
				fill(shown, container)
				return
			end
		end
	end)
	Fog.onChanged(function()
		local shown = RegionPanel.getShown()
		if shown then
			fill(shown, container)
		end
	end)
end

return WarPanel
