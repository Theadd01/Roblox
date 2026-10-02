--!strict
-- Espionnage dans la fiche d'une région étrangère (ni à toi, ni à un allié) : brouillard ou non,
-- bouton « Révéler » (tes espions y voient tout pendant quelques minutes), pour chaque usine
-- d'une région visible bouton « Saboter », et « Voler une technologie » au pays propriétaire.
-- Le serveur valide (server/Politics/EspionageService).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Espionage = require(Config:WaitForChild("Espionage")) :: any
local Factories = require(Config:WaitForChild("Factories")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local FogRules = require(Shared:WaitForChild("FogRules")) :: any
local TechState = require(Shared:WaitForChild("TechState")) :: any
local Technologies = require(Config:WaitForChild("Technologies")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local Client = script.Parent.Parent
local FactoryState = require(Client:WaitForChild("State"):WaitForChild("FactoryState"))
local Fog = require(Client:WaitForChild("State"):WaitForChild("Fog"))
local RegionView = require(Client:WaitForChild("Map"):WaitForChild("RegionView"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local RegionPanel = require(script.Parent:WaitForChild("RegionPanel"))
local Toast = require(script.Parent:WaitForChild("Toast"))
local Sfx = require(Client:WaitForChild("Audio"):WaitForChild("Sfx"))

local EspionagePanel = {}

local message: string? = nil
local messageRegion: string? = nil
local busy = false

local function myCountry(): string?
	local id = Players.LocalPlayer:GetAttribute("Pays")
	return if typeof(id) == "string" and id ~= "" then id else nil
end

local function costText(costs: { [string]: number }): string
	local parts = {}
	for id, amount in costs do
		local r = if id == Resources.currency.id then Resources.currency else Resources.list[id]
		table.insert(parts, `{amount} {if r then r.icon else id}`)
	end
	return table.concat(parts, " + ")
end

local function canAfford(country: string, costs: { [string]: number }): boolean
	local folder = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Pays"):FindFirstChild(country)
	for id, amount in costs do
		local value = folder and folder:GetAttribute(id)
		if typeof(value) ~= "number" or value < amount then
			return false
		end
	end
	return true
end

local function ask(remoteName: string, value: string, regionId: string)
	if busy then
		return
	end
	busy = true
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild(remoteName) :: RemoteFunction
	local ok, accepted, reason = pcall(function()
		return remote:InvokeServer(value)
	end)
	busy = false
	Sfx.actionResult(remoteName, ok and accepted == true)
	messageRegion = regionId
	if ok and accepted == true then
		message = nil
		if typeof(reason) == "string" then
			Toast.show(`🕵️ {reason}`, "success", false) -- résultat de l'action (vol réussi, espions démasqués...)
		end
	else
		message = if ok and typeof(reason) == "string" then reason else "Le serveur ne répond pas."
	end
	RegionPanel.refresh()
end

-- Technologies du pays visé que le joueur pourrait lui voler
local function stealable(me: string, target: string): number
	return #TechState.stealable(me, target)
end

-- Résumé de ce qui est affiché : on ne redessine que s'il change (évite de perdre un clic)
local function signature(regionId: string, me: string): string
	local parts = { regionId, message or "", tostring(Fog.isRegionVisible(regionId)), tostring(FogRules.revealedUntil(me, regionId) ~= nil) }
	for _, factory in FactoryState.inRegion(regionId) do
		table.insert(parts, `{factory.Name}:{factory:GetAttribute("Statut")}`)
	end
	table.insert(parts, tostring(canAfford(me, Espionage.reveal.cost)))
	table.insert(parts, tostring(canAfford(me, Espionage.sabotage.cost)))
	local owner = RegionView.getOwner(regionId)
	table.insert(parts, tostring(if owner then stealable(me, owner) else 0))
	table.insert(parts, tostring(canAfford(me, Technologies.steal.cost)))
	return table.concat(parts, "|")
end

local function render(regionId: string?, container: Frame)
	local me = myCountry()
	local owner = if regionId then RegionView.getOwner(regionId) else nil
	if not regionId or not me or not owner or owner == me or DiplomacyState.areAllies(me, owner) then
		container:ClearAllChildren()
		container:SetAttribute("Signature", nil)
		container.Visible = false
		return
	end
	if messageRegion ~= regionId then
		message = nil
	end
	local sig = signature(regionId, me)
	if container:GetAttribute("Signature") == sig then
		return
	end
	container:ClearAllChildren()
	container:SetAttribute("Signature", sig)
	container.Visible = true
	UIStyle.list(container, 6)
	local order = 0
	local function add(instance: GuiObject)
		order += 1
		instance.LayoutOrder = order
		instance.Parent = container
	end
	add(UIStyle.text("Titre", "<b>🕵️ Espionnage</b>", 18))

	local visible = Fog.isRegionVisible(regionId)
	local revealed = FogRules.revealedUntil(me, regionId)
	if revealed then
		local label = UIStyle.text("Etat", "", 15, UIStyle.FONT_MEDIUM, UIStyle.ACCENT)
		local function update()
			local left = math.max(0, math.ceil((FogRules.revealedUntil(me, regionId) or 0) - workspace:GetServerTimeNow()))
			label.Text = `👁️ Tes espions surveillent cette région : encore {left // 60}:{string.format("%02d", left % 60)}`
		end
		update()
		add(label)
		task.spawn(function()
			while label.Parent do
				task.wait(1)
				update()
			end
		end)
	elseif visible then
		add(UIStyle.text("Etat", "👁️ Région visible (près de tes frontières ou de tes forces).", 15, UIStyle.FONT, UIStyle.TEXT_DIM))
	else
		add(UIStyle.text("Etat", "🌫️ Région dans le brouillard : ses armées te sont cachées.", 15, UIStyle.FONT, UIStyle.TEXT_DIM))
	end
	if not revealed and not visible then -- une région déjà visible n'a pas besoin d'espions
		local reveal = UIStyle.button("Reveler", `🕵️ Révéler pendant {Espionage.reveal.duration // 60} min ({costText(Espionage.reveal.cost)})`)
		reveal.Size = UDim2.new(1, 0, 0, 40)
		reveal.TextSize = 15
		UIStyle.setButtonEnabled(reveal, canAfford(me, Espionage.reveal.cost))
		reveal.Activated:Connect(function()
			if UIStyle.isEnabled(reveal) then
				ask("RevelerRegion", regionId, regionId)
			end
		end)
		add(reveal)
	end
	-- usines de la région : sabotage
	for _, factory in FactoryState.inRegion(regionId) do
		local kind = Factories.types[factory:GetAttribute("Type") :: string]
		local sabotaged = factory:GetAttribute("Statut") == "Sabotee"
		local b = UIStyle.button(
			"Saboter_" .. factory.Name,
			if sabotaged then `💥 {kind and kind.name or "Usine"} déjà sabotée` else `💥 Saboter : {kind and kind.icon or "🏭"} {kind and kind.name or "usine"} niv. {factory:GetAttribute("Niveau")} ({costText(Espionage.sabotage.cost)})`
		)
		b.Size = UDim2.new(1, 0, 0, 40)
		b.TextSize = 15
		UIStyle.setButtonEnabled(b, visible and not sabotaged and canAfford(me, Espionage.sabotage.cost))
		local factoryId = factory.Name
		b.Activated:Connect(function()
			if UIStyle.isEnabled(b) then
				ask("SaboterUsine", factoryId, regionId)
			end
		end)
		add(b)
	end
	-- voler une technologie au pays propriétaire
	local count = stealable(me, owner)
	if count > 0 then
		local b = UIStyle.button("VolerTechnologie", `🧪 Voler une technologie {FrenchNames.of(Countries[owner].name)} ({costText(Technologies.steal.cost)})`)
		b.Size = UDim2.new(1, 0, 0, 40)
		b.TextSize = 15
		UIStyle.setButtonEnabled(b, visible and canAfford(me, Technologies.steal.cost))
		b.Activated:Connect(function()
			if UIStyle.isEnabled(b) then
				ask("VolerTechnologie", owner, regionId)
			end
		end)
		add(b)
	end
	if message then
		add(UIStyle.text("Erreur", message, 15, UIStyle.FONT_MEDIUM, UIStyle.DANGER))
	end
end

-- À appeler après RegionPanel.create
function EspionagePanel.attach()
	local section = RegionPanel.addSection("Espionnage", 21)
	RegionPanel.onShow(function(regionId: string?)
		render(regionId, section)
	end)
	-- le brouillard et les révélations changent : la fiche aussi
	Fog.onChanged(function()
		if RegionPanel.getShown() then
			RegionPanel.refresh()
		end
	end)
end

return EspionagePanel
