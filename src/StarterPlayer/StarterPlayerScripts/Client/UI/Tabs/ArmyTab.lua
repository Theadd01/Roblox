--!strict
-- Onglet « Armée » : tes forces, en deux vues.
--   Liste : divisions terrestres (SYSTEME_MILITAIRE.md : nombre par type, entraînement,
--     recrutement dans une de tes régions), puis escadrilles et flottes (boutons pour nommer un chef).
--   Fiche d'une force : troupes, recrutement, destinations possibles, itinéraire en cours.
-- Sur la carte, toucher un général puis une région lointaine l'y envoie de région en région
-- (voir Map/ArmyOrders) ; le bouton « Choisir sur la carte » fait la même chose.
-- Une force d'un autre pays s'affiche en lecture seule.
-- Demandes au serveur : Remotes.NommerGeneral(région, genre) / Recruter / DeplacerArmee (validées par lui).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Units = require(Config:WaitForChild("Units")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any
local Client = script.Parent.Parent.Parent
local ArmyState = require(Client:WaitForChild("State"):WaitForChild("ArmyState"))
local RegionView = require(Client:WaitForChild("Map"):WaitForChild("RegionView"))
local UI = script.Parent.Parent
local UIStyle = require(UI:WaitForChild("UIStyle"))
local Sfx = require(script.Parent.Parent.Parent:WaitForChild("Audio"):WaitForChild("Sfx"))
local ResourceText = require(UI:WaitForChild("ResourceText"))
local MilitaryMath = require(Shared:WaitForChild("MilitaryMath")) :: any
local DiplomacyState = require(Shared:WaitForChild("DiplomacyState")) :: any
local StabilityRules = require(Shared:WaitForChild("StabilityRules")) :: any
local GeneralTraits = require(Shared:WaitForChild("GeneralTraits")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local Generals = require(Config:WaitForChild("Generals")) :: any
local Resources = require(Config:WaitForChild("Resources")) :: any
local ArmyOrders = require(Client:WaitForChild("Map"):WaitForChild("ArmyOrders"))
local MilitaryFolder = Client:WaitForChild("Military")
local MilitaryState = require(MilitaryFolder:WaitForChild("MilitaryState"))
local CommandSender = require(MilitaryFolder:WaitForChild("CommandSender"))
local GeneralPanel = require(MilitaryFolder:WaitForChild("GeneralPanel"))
local DivisionConfig = require(Config:WaitForChild("Divisions")) :: any
local MilitaryConfig = require(Config:WaitForChild("Military")) :: any
local PopulationRules = require(Shared:WaitForChild("PopulationRules")) :: any
local BuildingRules = require(Shared:WaitForChild("BuildingRules")) :: any
local TechState = require(Shared:WaitForChild("TechState")) :: any

local POSTURES = {
	{ id = "Normal", label = "Normal" },
	{ id = "Defendre", label = "🛡️ Défendre" },
	{ id = "Tenir", label = "📌 Tenir" },
}
local POSTURE_HELP = {
	Normal = "Normal : se replie seule si le moral s'effondre.",
	Defendre = "Défendre : +25 % quand elle défend sa région.",
	Tenir = "Tenir la position : ne recule jamais, se bat jusqu'au bout.",
}

local MAX_DESTINATIONS = 12 -- destinations proposées au plus (les plus proches) pour l'air et la mer

export type Options = {
	selected: string?, -- force à afficher tout de suite (clic sur un chef)
	focusArmy: (armyId: string) -> (), -- centre la caméra sur une force
	defaultRegion: () -> string, -- région où nommer un nouveau chef
	onSelect: (armyId: string?) -> (), -- force affichée (pour la surbrillance sur la carte)
}

local ArmyTab = {}

-- Mêmes calculs que le serveur (ArmyService) : points d'ancrage, distances, durées
local function anchorOf(regionId: string, kind: string): Vector3?
	local region = Regions[regionId]
	local lonLat = region and (if kind == "Mer" then region.port else region.city)
	return if lonLat then MapProjection.toVector3(lonLat.lon, lonLat.lat, MapSettings.regionTop) else nil
end

local function distance(from: string, to: string, kind: string): number
	local a, b = anchorOf(from, kind), anchorOf(to, kind)
	return if a and b then (b - a).Magnitude else math.huge
end

local function travelTime(from: string, to: string, kind: string, bySea: boolean?): number
	local k = Units.kinds[if bySea then "Mer" else kind]
	local d = distance(from, to, if kind == "Mer" then "Mer" else "Terre")
	if d == math.huge then
		d = 0
	end
	return math.floor(math.clamp(d / k.speed, k.minTime, k.maxTime) + 0.5)
end

-- Remplit `container` ; renvoie une fonction qui arrête les mises à jour
function ArmyTab.build(container: Instance, countryId: string, options: Options): () -> ()
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local stocks = state:WaitForChild("Pays"):WaitForChild(countryId)
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local selected: string? = options.selected
	local message: string? = nil
	local busy = false
	local lastSignature = ""

	local generalFolder = state:WaitForChild("Generaux")
	local function myGenerals(): { Instance }
		local list = {}
		for _, g in generalFolder:GetChildren() do
			if g:GetAttribute("Proprietaire") == countryId then
				table.insert(list, g)
			end
		end
		table.sort(list, function(a: Instance, b: Instance): boolean
			return a.Name < b.Name
		end)
		return list
	end

	-- état publié d'une région (EtatMonde.Regions.<id>) : fortifications, bataille
	local function regionState(regionId: string): Instance?
		local regions = state:FindFirstChild("Regions")
		return regions and regions:FindFirstChild(regionId)
	end

	local function stock(id: string): number
		local value = stocks:GetAttribute(id)
		return if typeof(value) == "number" then value else 0
	end
	local function canAfford(costs: { [string]: number }): boolean
		for id, amount in costs do
			if stock(id) < amount then
				return false
			end
		end
		return true
	end
	-- coût réel d'une recrue : un pays instable paie plus cher (même règle que le serveur)
	local function recruitCost(typeId: string): { [string]: number }
		local stability = stocks:GetAttribute("Stabilite")
		return StabilityRules.recruitCost(Units.types[typeId].cost, if typeof(stability) == "number" then stability else 100, Resources.currency.id)
	end
	local function fleetInPort(regionId: string): boolean
		for _, force in ArmyState.ownedBy(countryId) do
			if ArmyState.kind(force) == "Mer" and force:GetAttribute("Region") == regionId
				and not ArmyState.isMoving(force) and not force:GetAttribute("EnCombat") then
				return true
			end
		end
		return false
	end

	local render: () -> ()

	local function ask(remoteName: string, a: any, b: any)
		if busy then
			return
		end
		busy = true
		local remote = remotes:WaitForChild(remoteName) :: RemoteFunction
		local ok, accepted, reason = pcall(function()
			return remote:InvokeServer(a, b)
		end)
		busy = false
		Sfx.actionResult(remoteName, ok and accepted == true)
		message = if ok and accepted == true then nil elseif ok and typeof(reason) == "string" then reason else "Le serveur ne répond pas."
		lastSignature = ""
		render()
	end

	-- ordre militaire (RemoteEvent CommandeMilitaire), même retour que ask()
	local function command(order: string, data: { [string]: any })
		if busy then
			return
		end
		busy = true
		local accepted, reason = CommandSender.send(order, data)
		busy = false
		Sfx.actionResult("Recruter", accepted)
		message = if accepted then nil else reason or "Ordre refusé."
		lastSignature = ""
		render()
	end

	local function clear()
		for _, child in container:GetChildren() do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end
	end

	local order = 0
	local function add(instance: GuiObject): GuiObject
		order += 1
		instance.LayoutOrder = order
		instance.Parent = container
		return instance
	end
	local function text(content: string, size: number?, font: Font?, color: Color3?): TextLabel
		return add(UIStyle.text("Texte", content, size or 16, font, color)) :: TextLabel
	end
	local function button(name: string, label: string, primary: boolean?, enabled: boolean?, onClick: () -> ()): TextButton
		local b = UIStyle.button(name, label, primary)
		b.Size = UDim2.new(1, 0, 0, 42)
		b.TextSize = 16
		UIStyle.setButtonEnabled(b, enabled ~= false)
		b.Activated:Connect(function()
			if UIStyle.isEnabled(b) then
				onClick()
			end
		end)
		return add(b) :: TextButton
	end

	-- Couleur du moral : vert, orange, rouge
	local function moraleColor(morale: number): string
		return if morale >= 60 then "#78DC82" elseif morale >= 30 then "#F0AA46" else "#EB5F55"
	end

	-- Moral en couleur, suivi de ⚠️ si la force n'est pas ravitaillée
	local function statusText(force: Instance): string
		local morale = MilitaryMath.morale(force)
		local warning = if MilitaryMath.isSupplied(force) then "" else "  ⚠️"
		return `❤️ <font color="{moraleColor(morale)}">{math.floor(morale)} %</font>{warning}`
	end

	local function whereText(force: Instance): string
		if typeof(force:GetAttribute("EnCombat")) == "string" then
			return `⚔️ au combat en {Regions[force:GetAttribute("Region") :: string].name}`
		elseif ArmyState.isMoving(force) then
			local steps = ArmyState.itinerary(force)
			local final = if #steps > 0 then steps[#steps] else force:GetAttribute("Destination") :: string
			return `en route vers {Regions[final].name}`
		end
		return Regions[force:GetAttribute("Region") :: string].name
	end

	-- Divisions qu'un pays peut avoir : selon sa population (attribut « DivisionsMax », serveur)
	local function maxDivisions(): number
		local value = stocks:GetAttribute("DivisionsMax")
		return if typeof(value) == "number" then value else 0
	end

	-- Généraux (cahier des charges v2, section 5) : les siens (toucher : sa fiche) et l'achat ; un
	-- général acheté ouvre tout de suite le choix de ses troupes
	local function renderGenerals(regionId: string)
		local G = MilitaryConfig.generals
		local mine = myGenerals()
		text(`🎖️ <b>Généraux</b>  <font color="{UIStyle.GREY_HEX}">{#mine}/{G.maxPerCountry}</font>`, 19, UIStyle.FONT_BOLD)
		for _, g in mine do
			local count = (g:GetAttribute("Troupes") :: number?) or 0
			local capacity = (g:GetAttribute("Capacite") :: number?) or G.capacity[1]
			local level = (g:GetAttribute("Niveau") :: number?) or 1
			local destination = g:GetAttribute("Destination")
			local where = if typeof(destination) == "string" and destination ~= "" then "→ " .. Regions[destination].name else Regions[g:GetAttribute("Region") :: string].name
			local pending = ((g:GetAttribute("ChoixBonus") :: number?) or 0) > 0
			local b = button("General_" .. g.Name, `🎖️ {g:GetAttribute("Nom")} {string.rep("★", level)} · {where} · 🪖 {count}/{capacity}{if pending then " · 🎁" else ""}`, false, true, function()
				GeneralPanel.focus(g)
			end)
			b.Size = UDim2.new(1, 0, 0, 38)
		end
		local region = Regions[regionId]
		if region and RegionView.getOwner(regionId) == countryId then
			local b = button("NommerGeneral", `🎖️ Acheter un général en {region.name} : {ResourceText.cost(G.cost)}`, false,
				#mine < G.maxPerCountry and canAfford(G.cost), function()
					if busy then
						return
					end
					busy = true
					local accepted, reason = CommandSender.send("NommerGeneral", { region = regionId })
					busy = false
					Sfx.actionResult("Recruter", accepted)
					message = if accepted then nil else reason or "Ordre refusé."
					lastSignature = ""
					render()
					-- le serveur renvoie l'identifiant du nouveau général : choix de ses troupes
					if accepted and typeof(reason) == "string" then
						local general = generalFolder:WaitForChild(reason, 5)
						if general then
							GeneralPanel.openNew(general)
						end
					end
				end)
			b.Size = UDim2.new(1, 0, 0, 38)
		end
		text(`Un général est une armée : achète-le, puis choisis ses troupes (par type et par nombre). Elles quittent la carte et le suivent ; il ignore la limite de {MilitaryConfig.maxDivisionsPerRegion} par région et attaque avec toute son armée ({G.capacity[1]} troupes au niveau 1, {G.capacity[#G.capacity]} au niveau {#G.capacity}).`, 14, UIStyle.FONT, UIStyle.TEXT_DIM)
	end

	-- Divisions terrestres : nombre par type, entraînements en cours, recrutement
	local function renderDivisions(regionId: string)
		local mine = MilitaryState.ofCountry(countryId)
		local max = maxDivisions()
		text(`⚔️ <b>Divisions</b>  <font color="{UIStyle.GREY_HEX}">{#mine}/{max}</font>`, 19, UIStyle.FONT_BOLD)
		local counts: { [string]: number } = {}
		local training = {}
		for _, d in mine do
			local typeId = d:GetAttribute("Type") :: string
			counts[typeId] = (counts[typeId] or 0) + 1
			if MilitaryState.isTraining(d) then
				table.insert(training, d)
			end
		end
		local parts = {}
		for _, typeId in DivisionConfig.order do
			if counts[typeId] then
				table.insert(parts, `{DivisionConfig.types[typeId].icon} {counts[typeId]}`)
			end
		end
		if counts.Milice then
			table.insert(parts, `{DivisionConfig.types.Milice.icon} {counts.Milice}`)
		end
		text(if #parts > 0 then table.concat(parts, "   ") else "Aucune division.", 16)
		-- consommation des divisions (Supply) : ce qui manque se voit tout de suite au combat
		if stocks:GetAttribute("PenuriePetrole") == true then
			text("⚠️ Plus de pétrole : blindés et motorisés se traînent et attaquent moitié moins. Achète du pétrole au marché.", 15, UIStyle.FONT_MEDIUM, UIStyle.DANGER)
		end
		if stocks:GetAttribute("PenurieNourriture") == true then
			text("⚠️ Plus de nourriture : le moral de tes divisions ne remonte plus.", 15, UIStyle.FONT_MEDIUM, UIStyle.DANGER)
		end
		for _, d in training do
			local left = math.max(0, math.ceil((d:GetAttribute("Entrainement") :: number) - workspace:GetServerTimeNow()))
			text(`⏳ {d:GetAttribute("Nom")} : prête dans {left} s`, 15, UIStyle.FONT, UIStyle.TEXT_DIM)
		end
		local region = Regions[regionId]
		if not region or RegionView.getOwner(regionId) ~= countryId then
			return
		end
		-- les divisions se forment dans un camp militaire : celui de la région choisie, sinon le premier
		-- de ses camps (la capitale d'abord)
		local campRegion: string? = if BuildingRules.campLevel(regionId) > 0 then regionId else nil
		if not campRegion then
			local camps = {}
			for id in Regions do
				if RegionView.getOwner(id) == countryId and BuildingRules.campLevel(id) > 0 then
					table.insert(camps, id)
				end
			end
			table.sort(camps, function(a: string, b: string): boolean
				if (a == countryId) ~= (b == countryId) then
					return a == countryId
				end
				return a < b
			end)
			campRegion = camps[1]
			if campRegion then
				text(`⛺ Pas de camp militaire en {region.name} : les divisions se forment au camp de {Regions[campRegion].name}.`, 14, UIStyle.FONT, UIStyle.TEXT_DIM)
			end
		end
		if not campRegion then
			text("⛺ Aucun camp militaire : construis-en un dans l'onglet Bâtiments pour former des divisions.", 15, UIStyle.FONT_MEDIUM, UIStyle.DANGER)
			return
		end
		local recruitRegion = campRegion :: string
		local camp = BuildingRules.campLevel(recruitRegion)
		local here = #MilitaryState.inRegion(recruitRegion)
		local capacity = TechState.stationingCap(countryId)
		local full = here >= capacity
		-- habitants de la région : les soldats sont pris parmi eux (Config/Divisions.manpower)
		local people = regionState(recruitRegion) and regionState(recruitRegion):GetAttribute("Population")
		local inhabitants = if typeof(people) == "number" then people else 0
		text(`Recruter en <b>{Regions[recruitRegion].name}</b> (⛺ camp niv. {camp})  <font color="{UIStyle.GREY_HEX}">{here}/{capacity} divisions · 👥 {PopulationRules.format(inhabitants)} habitants</font>`, 16)
		for _, typeId in DivisionConfig.order do
			local t = DivisionConfig.types[typeId]
			if t.recruitable then
				local seconds = math.ceil(t.trainSeconds * BuildingRules.campFactor(camp) * TechState.recruitTimeFactor(countryId))
				local b = button("Division_" .. typeId, `{t.icon} {t.name} : {ResourceText.cost(t.cost)} · 👥 {t.manpower} k · {seconds} s`, false,
					not full and #mine < max and canAfford(t.cost) and inhabitants >= t.manpower, function()
						command("Recruter", { type = typeId, region = recruitRegion })
					end)
				b.Size = UDim2.new(1, 0, 0, 38)
			end
		end
		-- fortifications de la région (Config/Military.fortification)
		local F = MilitaryConfig.fortification
		local fortState = regionState(regionId)
		local level = (fortState and fortState:GetAttribute("Fortification") :: number?) or 0
		local finish = fortState and fortState:GetAttribute("FortificationFin")
		if typeof(finish) == "number" then
			local left = math.max(0, math.ceil(finish - workspace:GetServerTimeNow()))
			text(`🏰 Fortifications niveau {level}/{F.maxLevel} : niveau {level + 1} prêt dans {left} s`, 15, UIStyle.FONT, UIStyle.TEXT_DIM)
		elseif level >= F.maxLevel then
			text(`🏰 Fortifications au maximum (niveau {F.maxLevel} : défense +{math.floor(level * F.defensePerLevel * 100)} %)`, 15, UIStyle.FONT, UIStyle.TEXT_DIM)
		else
			local fight = fortState and fortState:GetAttribute("Bataille")
			local b = button("Fortifier", `🏰 Fortifier (niveau {level + 1}, défense +{math.floor((level + 1) * F.defensePerLevel * 100)} %) : {ResourceText.cost(F.cost)} · {F.buildSeconds} s`, false,
				not fight and canAfford(F.cost), function()
					command("Fortifier", { region = regionId })
				end)
			b.Size = UDim2.new(1, 0, 0, 38)
		end
		text("Astuce : on recrute et on fortifie dans la dernière de tes régions sur laquelle tu as cliqué.", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
		renderGenerals(regionId)
	end

	-- Liste des forces du pays, par sorte
	local function renderList()
		local regionId = options.defaultRegion()
		local region = Regions[regionId]
		renderDivisions(regionId)
		for _, kindId in Units.kindOrder do
			if kindId == "Terre" then
				continue -- sur terre : les divisions (ci-dessus)
			end
			local k = Units.kinds[kindId]
			local forces = {}
			for _, force in ArmyState.ownedBy(countryId) do
				if ArmyState.kind(force) == kindId then
					table.insert(forces, force)
				end
			end
			text(`{k.icon} <b>{k.name}s</b>  <font color="{UIStyle.GREY_HEX}">{#forces}/{k.maxPerCountry}</font>`, 19, UIStyle.FONT_BOLD)
			for _, force in forces do
				local _, total = ArmyState.troops(force)
				local row = Instance.new("Frame")
				row.Name = "Ligne_" .. force.Name
				row.BackgroundColor3 = UIStyle.PANEL_ALT
				row.BackgroundTransparency = 0.16
				row.Size = UDim2.new(1, 0, 0, 52)
				UIStyle.corner(row, 8)
				UIStyle.stroke(row, 0.68, UIStyle.BORDER_SOFT)
				local info = UIStyle.text(
					"Info",
					`<b>{force:GetAttribute("Nom")}</b>  <font color="{UIStyle.GREY_HEX}">{whereText(force)}</font>\n{ArmyState.troopText(force)}  <font color="{UIStyle.GREY_HEX}">({total}/{ArmyState.capacity(force)})</font>   {statusText(force)}`,
					15
				)
				info.AutomaticSize = Enum.AutomaticSize.None
				info.Position = UDim2.fromOffset(10, 0)
				info.Size = UDim2.new(1, -110, 1, 0)
				info.TextYAlignment = Enum.TextYAlignment.Center
				info.Parent = row
				local open = UIStyle.button("Ouvrir", "Ouvrir")
				open.AnchorPoint = Vector2.new(1, 0.5)
				open.Position = UDim2.new(1, -6, 0.5, 0)
				open.Size = UDim2.fromOffset(92, 36)
				open.TextSize = 15
				open.Parent = row
				local id = force.Name
				open.Activated:Connect(function()
					selected = id
					message = nil
					options.onSelect(id)
					options.focusArmy(id)
					lastSignature = ""
					render()
				end)
				add(row)
			end
			if #forces < k.maxPerCountry and region then
				local needsPort = k.coastal and not region.port
				button(
					"Nommer_" .. kindId,
					if needsPort
						then `{k.createLabel} : {region.name} n'a pas de port`
						else `{k.createLabel} ({region.name}) : {ResourceText.cost(k.cost)}`,
					kindId == "Terre",
					not needsPort and canAfford(k.cost),
					function()
						ask("NommerGeneral", regionId, kindId)
					end
				)
			end
		end
		text("Astuce : le chef est nommé dans la dernière de tes régions sur laquelle tu as cliqué.", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
	end

	-- Destinations possibles d'une force (les plus proches d'abord pour l'air et la mer)
	local function destinations(force: Instance, here: string): { { id: string, label: string, enabled: boolean? } }
		local kind = ArmyState.kind(force)
		local list = {}
		-- texte du bouton, et s'il est utilisable (pas d'attaque pendant une trêve)
		local function describe(id: string, seconds: number, bySea: boolean?): (string, boolean)
			local target = Regions[id]
			local sea = if bySea then "⛴️ " else ""
			local owner = RegionView.getOwner(id)
			if owner and owner ~= countryId then
				if DiplomacyState.areAllies(countryId, owner) then
					return `{sea}🤝 {target.name} (allié) · {seconds} s`, true
				end
				local truce = DiplomacyState.truceLeft(countryId, owner)
				if truce > 0 then
					return `🕊️ {target.name} : trêve encore {math.ceil(truce)} s`, false
				end
				local protection = DiplomacyState.protectionLeft(owner)
				if protection > 0 then
					return `🛡️ {target.name} : protégé encore {math.ceil(protection)} s`, false
				end
				local verb = if kind == "Terre" then "⚔️ Attaquer" else "💣 Bombarder"
				local war = if DiplomacyState.atWar(countryId, owner) then "" else " (déclare la guerre)"
				return `{sea}{verb} {FrenchNames.the(target.name)}{war} · {seconds} s · ⚔️ {#MilitaryState.inRegion(id)} div.`, true
			end
			return `{sea}{target.name} · {seconds} s`, true
		end
		if kind == "Terre" then
			local port = fleetInPort(here)
			for _, l in Regions[here].neighbors do
				if not l.bySea or port then
					local label, enabled = describe(l.region, math.floor(travelTime(here, l.region, kind, l.bySea) * MilitaryMath.travelFactor(force) + 0.5), l.bySea)
					table.insert(list, { id = l.region, label = label, enabled = enabled })
				end
			end
			return list
		end
		local k = Units.kinds[kind]
		local candidates = {}
		for id, region in Regions do
			if id ~= here and (kind ~= "Mer" or region.port) then
				local d = distance(here, id, kind)
				if d <= k.range then
					table.insert(candidates, { id = id, d = d })
				end
			end
		end
		table.sort(candidates, function(a, b)
			return a.d < b.d
		end)
		for i = 1, math.min(MAX_DESTINATIONS, #candidates) do
			local id = candidates[i].id
			local label, enabled = describe(id, math.floor(travelTime(here, id, kind) * MilitaryMath.travelFactor(force) + 0.5))
			table.insert(list, { id = id, label = label, enabled = enabled })
		end
		return list
	end

	-- Fiche d'une force
	local function renderArmy(force: Instance)
		local mine = force:GetAttribute("Proprietaire") == countryId
		local owner = Countries[force:GetAttribute("Proprietaire") :: string]
		local kind = ArmyState.kind(force)
		local k = Units.kinds[kind]
		local counts, total = ArmyState.troops(force)
		local capacity = ArmyState.capacity(force)
		local here = force:GetAttribute("Region") :: string

		if mine then
			button("Retour", "← Mes forces", false, true, function()
				selected = nil
				message = nil
				options.onSelect(nil)
				lastSignature = ""
				render()
			end)
		end
		text(`{k.icon} <b>{force:GetAttribute("Nom")}</b>`, 22, UIStyle.FONT_BOLD)
		text(
			`<font color="#{owner and owner.color:ToHex() or "FFFFFF"}">●</font> {owner and owner.name or "?"}   <font color="{UIStyle.GREY_HEX}">{string.lower(k.name)} · niveau {force:GetAttribute("Niveau")} · {total}/{capacity}</font>`,
			16
		)

		local fighting = typeof(force:GetAttribute("EnCombat")) == "string"
		local steps = ArmyState.itinerary(force)
		if fighting then
			text(`⚔️ <b>Bataille en cours</b> à {Regions[here].name}`, 16, UIStyle.FONT_BOLD, Color3.fromRGB(255, 170, 120))
		elseif ArmyState.isMoving(force) then
			local destination = Regions[force:GetAttribute("Destination") :: string]
			local left = (force:GetAttribute("Arrivee") :: number) - workspace:GetServerTimeNow()
			local how = if force:GetAttribute("ParMer") then "⛴️ Traversée vers" elseif kind == "Air" then "✈️ En vol vers" elseif kind == "Mer" then "⚓ Cap sur" else "🚶 En route vers"
			text(`{how} <b>{destination.name}</b> : arrivée dans {math.max(0, math.ceil(left))} s`, 16)
		else
			text(`📍 Position : <b>{Regions[here].name}</b>`, 16)
		end
		-- itinéraire : la suite de la route, région par région (batailles en chemin)
		if #steps > 0 then
			local final = Regions[steps[#steps]]
			text(`🗺️ Puis {#steps} étape{if #steps > 1 then "s" else ""} jusqu'à <b>{final and final.name or "?"}</b>`, 15)
			if mine then
				local b = button("Arreter", "⏹️ S'arrêter à la prochaine étape", false, true, function()
					ask("OrdreArmee", force.Name, "Arreter")
				end)
				b.Size = UDim2.new(1, 0, 0, 38)
			end
		end

		-- moral, expérience, ravitaillement, entretien
		local morale = MilitaryMath.morale(force)
		local xp = MilitaryMath.experience(force)
		text(`❤️ Moral : <b><font color="{moraleColor(morale)}">{math.floor(morale)} %</font></b>   ⭐ {MilitaryMath.rank(xp)} <font color="{UIStyle.GREY_HEX}">({math.floor(xp)}/100)</font>`, 16)
		-- traits du chef (ils se renforcent avec son niveau)
		local traits = GeneralTraits.of(force)
		local level = (force:GetAttribute("Niveau") :: number?) or 1
		local traitTexts = {}
		for _, id in traits do
			table.insert(traitTexts, GeneralTraits.describe(id, level))
		end
		if #traitTexts > 0 then
			text(`<b>Traits</b> : {table.concat(traitTexts, " · ")}` .. (if #traits < 2 then `  <font color="{UIStyle.GREY_HEX}">(2e trait au niveau {Generals.secondTraitLevel})</font>` else ""), 15)
		end
		local supplyText = "📦 Ravitaillée"
		if not MilitaryMath.isSupplied(force) then
			local lacking = force:GetAttribute("Penurie")
			supplyText = if force:GetAttribute("HorsDePortee")
				then "⚠️ Coupée du ravitaillement (trop loin de ton territoire)"
				elseif typeof(lacking) == "string" and lacking ~= ""
				then `⚠️ Pénurie : {lacking}`
				else "⚠️ Mal ravitaillée"
		end
		local upkeep = MilitaryMath.upkeep(force)
		local upkeepText = if next(upkeep) then `   <font color="{UIStyle.GREY_HEX}">entretien {ResourceText.cost(upkeep)} / cycle</font>` else ""
		text(supplyText .. upkeepText, 15)

		text("<b>Unités</b>", 18, UIStyle.FONT_BOLD)
		if total == 0 then
			text("Aucune unité pour l'instant.", 15, UIStyle.FONT, UIStyle.TEXT_DIM)
		else
			for _, typeId in k.order do
				if counts[typeId] > 0 then
					local u = Units.types[typeId]
					text(`{u.icon} {u.name} × <b>{counts[typeId]}</b>`, 16)
				end
			end
		end

		-- ordres (aussi pendant une bataille, pour pouvoir se replier)
		if mine and not ArmyState.isMoving(force) then
			text("<b>Ordres</b>", 18, UIStyle.FONT_BOLD)
			local posture = force:GetAttribute("Posture") or "Normal"
			for _, p in POSTURES do
				local b = button("Posture_" .. p.id, p.label .. (if posture == p.id then "  ✓" else ""), posture == p.id, true, function()
					ask("OrdreArmee", force.Name, p.id)
				end)
				b.Size = UDim2.new(1, 0, 0, 38)
			end
			text(POSTURE_HELP[posture] or "", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
			if fighting or RegionView.getOwner(here) ~= countryId then
				button("Replier", "↩️ Se replier vers une région amie", false, true, function()
					ask("OrdreArmee", force.Name, "Replier")
				end)
			end
		end

		if not mine or ArmyState.isMoving(force) or fighting then
			return
		end

		-- recrutement (sur son propre territoire)
		if RegionView.getOwner(here) == countryId then
			text("<b>Recruter</b>", 18, UIStyle.FONT_BOLD)
			for _, typeId in k.order do
				local u = Units.types[typeId]
				local cost = recruitCost(typeId)
				button("Recruter_" .. typeId, `{u.icon} {u.name} : {ResourceText.cost(cost)}`, false, total < capacity and canAfford(cost), function()
					ask("Recruter", force.Name, typeId)
				end)
			end
		else
			text("On ne recrute que sur son propre territoire.", 15, UIStyle.FONT, UIStyle.TEXT_DIM)
		end

		-- déplacements : sur la carte (n'importe quelle région), ou vers une voisine
		text(if kind == "Air" then "<b>Voler vers</b>" elseif kind == "Mer" then "<b>Naviguer vers</b>" else "<b>Déplacer vers</b>", 18, UIStyle.FONT_BOLD)
		button("ChoisirCarte", "🗺️ Choisir la destination sur la carte", true, true, function()
			ArmyOrders.select(force.Name)
		end)
		if kind == "Terre" then
			text("Une région lointaine est atteinte de région en région, en livrant bataille en chemin.", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
		end
		local list = destinations(force, here)
		for _, d in list do
			button("Aller_" .. d.id, d.label, false, d.enabled ~= false, function()
				ask("DeplacerArmee", force.Name, d.id)
			end)
		end
		if #list == 0 then
			text("Aucune destination possible d'ici.", 15, UIStyle.FONT, UIStyle.TEXT_DIM)
		end
		if kind == "Terre" and not fleetInPort(here) then
			text("Pour traverser la mer, amène une de tes flottes au port de cette région.", 14, UIStyle.FONT, UIStyle.TEXT_DIM)
		end
	end

	-- redessine seulement si l'affichage change (évite de perdre un clic)
	local function signature(): string
		local parts = { selected or "liste", message or "", options.defaultRegion() }
		for _, force in ArmyState.list() do
			if force:GetAttribute("Proprietaire") == countryId or force.Name == selected then
				local left = if ArmyState.isMoving(force) then math.ceil((force:GetAttribute("Arrivee") :: number) - workspace:GetServerTimeNow()) else 0
				table.insert(parts, `{force.Name}:{force:GetAttribute("Region")}:{force:GetAttribute("Destination")}:{force:GetAttribute("EnCombat")}:{ArmyState.troopText(force)}:{left}:{math.floor(MilitaryMath.morale(force))}:{math.floor(MilitaryMath.experience(force))}:{force:GetAttribute("Ravitaillee")}:{force:GetAttribute("Penurie")}:{force:GetAttribute("Posture")}:{force:GetAttribute("Itineraire")}`)
			end
		end
		for typeId, u in Units.types do
			table.insert(parts, typeId .. tostring(canAfford(recruitCost(typeId))) .. tostring(recruitCost(typeId)[Resources.currency.id]))
		end
		for kindId, k in Units.kinds do
			table.insert(parts, kindId .. tostring(canAfford(k.cost)))
		end
		-- divisions : nombre, entraînements, place dans la région de recrutement
		local divisions = MilitaryState.ofCountry(countryId)
		table.insert(parts, "D" .. #divisions .. ":" .. #MilitaryState.inRegion(options.defaultRegion()))
		-- camps militaires (lieux de recrutement) et habitants, plafond de divisions
		for _, building in BuildingRules.list() do
			if building:GetAttribute("Proprietaire") == countryId and building:GetAttribute("Type") == "CampMilitaire" then
				table.insert(parts, `{building:GetAttribute("Region")}:{building:GetAttribute("Niveau")}:{building:GetAttribute("Statut")}`)
			end
		end
		table.insert(parts, tostring(stocks:GetAttribute("DivisionsMax")))
		for _, d in divisions do
			local training = d:GetAttribute("Entrainement")
			if typeof(training) == "number" then
				table.insert(parts, d.Name .. ":" .. math.ceil(training - workspace:GetServerTimeNow()))
			end
		end
		for typeId, t in DivisionConfig.types do
			table.insert(parts, typeId .. tostring(canAfford(t.cost)))
		end
		table.insert(parts, `P{stocks:GetAttribute("PenuriePetrole")}{stocks:GetAttribute("PenurieNourriture")}`)
		-- ses généraux (quartier général, trajet, niveau, armée) et la région de nomination occupée ;
		-- pas ceux des autres pays : ils bougent sans cesse et redessiner l'onglet ferait rater les clics
		local home = options.defaultRegion()
		for _, g in generalFolder:GetChildren() do
			if g:GetAttribute("Proprietaire") == countryId then
				table.insert(parts, `{g.Name}{g:GetAttribute("Region")}{g:GetAttribute("Destination")}{g:GetAttribute("Niveau")}{g:GetAttribute("Troupes")}{g:GetAttribute("ChoixBonus")}`)
			elseif g:GetAttribute("Region") == home or g:GetAttribute("Destination") == home then
				table.insert(parts, "occupe" .. g.Name)
			end
		end
		table.insert(parts, tostring(canAfford(MilitaryConfig.generals.cost)))
		-- fortifications de la région de recrutement (niveau, chantier, bataille)
		local fortified = regionState(options.defaultRegion())
		if fortified then
			local finish = fortified:GetAttribute("FortificationFin")
			table.insert(parts, `F{fortified:GetAttribute("Fortification")}:{if typeof(finish) == "number" then math.ceil(finish - workspace:GetServerTimeNow()) else ""}:{fortified:GetAttribute("Bataille")}:{canAfford(MilitaryConfig.fortification.cost)}`)
		end
		-- relations (alliés, trêves) : les boutons de destination en dépendent
		for _, enemy in DiplomacyState.enemiesOf(countryId) do
			table.insert(parts, "G" .. enemy)
		end
		for _, ally in DiplomacyState.alliesOf(countryId) do
			table.insert(parts, "A" .. ally)
		end
		return table.concat(parts, "|")
	end

	render = function()
		local sig = signature()
		if sig == lastSignature then
			return
		end
		lastSignature = sig
		clear()
		order = 0
		local force = if selected then ArmyState.get(selected) else nil
		if force then
			renderArmy(force)
		else
			selected = nil
			renderList()
		end
		if message then
			text(message, 15, UIStyle.FONT_MEDIUM, UIStyle.DANGER)
		end
	end

	options.onSelect(selected)
	render()

	local unsubscribe = ArmyState.onChanged(function()
		render()
	end)
	local unsubscribeDivisions = MilitaryState.onRegionChanged(function()
		render()
	end)
	local connection = stocks.AttributeChanged:Connect(function()
		render()
	end)
	local alive = true
	task.spawn(function()
		-- compte à rebours des trajets
		while alive do
			task.wait(1)
			if alive then
				render()
			end
		end
	end)

	return function()
		alive = false
		unsubscribe()
		unsubscribeDivisions()
		connection:Disconnect()
		options.onSelect(nil)
	end
end

return ArmyTab
