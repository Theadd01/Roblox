--!strict
-- Batailles sur la carte (côté client, purement visuel) :
--   - les troupes « sortent » du général et se déploient devant lui (6 modèles au maximum), par
--     escouades, jusqu'à une place à couvert (relief, ville) face aux miliciens de la région, qui se
--     mettent eux aussi à couvert (voir SquadBehavior : PathfindingService) ;
--   - chacun tire sur l'ennemi le plus proche ; une armée trop touchée recule vers son général ;
--   - de loin (ou hors de l'écran), les tirs et les explosions ne sont pas dessinés ;
--   - à chaque manche : tirs lumineux et explosions stylisées (pas de sang) ;
--   - les unités perdues disparaissent dans un éclair ; à la fin, tout rentre et le résultat s'affiche ;
--   - sons : fusillade et explosions placées sur la carte (audibles de près), fanfare ou jingle
--     de défaite pour le joueur concerné.
-- Le serveur décide de tout (ReplicatedStorage.EtatMonde.Batailles) ; ici on ne fait qu'afficher.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Combat = require(Config:WaitForChild("Combat")) :: any
local Units = require(Config:WaitForChild("Units")) :: any
local Countries = require(Config:WaitForChild("Countries")) :: any
local Regions = require(Config:WaitForChild("Regions")) :: any
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any
local UnitPainter = require(Shared:WaitForChild("UnitPainter")) :: any
local MapProjection = require(Shared:WaitForChild("MapProjection")) :: any
local FrenchNames = require(Shared:WaitForChild("FrenchNames")) :: any
local MatchState = require(Shared:WaitForChild("MatchState")) :: any
local ArmyView = require(script.Parent:WaitForChild("ArmyView"))
local ArmyState = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("ArmyState"))
local Fog = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("Fog"))
local Toast = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Toast"))
local Sfx = require(script.Parent.Parent:WaitForChild("Audio"):WaitForChild("Sfx"))
local SquadBehavior = require(script.Parent:WaitForChild("SquadBehavior"))
local MilitaryMath = require(Shared:WaitForChild("MilitaryMath")) :: any

local FONT = Font.fromEnum(Enum.Font.BuilderSansExtraBold)
local SHOT_ATTACK = Color3.fromRGB(255, 230, 120)
local SHOT_DEFENSE = Color3.fromRGB(255, 150, 90)
local BLAST = Color3.fromRGB(255, 170, 60)
local MAX_MILITIA_MODELS = 4
local SQUAD_SIZE = 3 -- un chef d'escouade et ses hommes
local MARCH_SPEED = 3.5 -- studs par seconde
local COVER_RADIUS = 5 -- distance de recherche d'un abri
local DRAW_DISTANCE = 900 -- au-delà, les tirs et explosions ne sont pas dessinés

type Deployed = { model: Model, kind: string, mover: SquadBehavior.Mover }
type Battle = {
	folder: Instance,
	group: Model,
	origin: CFrame, -- position de la force attaquante (au sol, en vol ou en mer)
	defense: CFrame, -- position des défenseurs (au sol, près de la ville ou de la côte)
	attackers: { Deployed },
	defenders: { Deployed },
	ended: boolean,
	retreating: boolean, -- l'armée attaquante recule (moral en chute)
	stopSound: () -> (), -- arrête la fusillade
}

local BattleView = {}

local container: Folder? = nil
local templates: Instance? = nil
local battles: { [Instance]: Battle } = {}
local lifts: { [string]: number } = {}
local obstacles: { Instance } = {} -- reliefs et villes de la carte (abris)

local function myCountry(): string?
	local id = Players.LocalPlayer:GetAttribute("Pays")
	return if typeof(id) == "string" then id else nil
end

-- Hauteur du pivot d'un modèle au-dessus de son point le plus bas (mise en cache)
local function liftOf(name: string, model: Model): number
	if lifts[name] == nil then
		local box, size = model:GetBoundingBox()
		lifts[name] = model:GetPivot().Position.Y - (box.Position.Y - size.Y / 2)
	end
	return lifts[name]
end

local function spawnModel(battle: Battle, name: string, color: Color3, cf: CFrame): Model?
	local template = templates and templates:FindFirstChild(name)
	if not template or not template:IsA("Model") then
		return nil
	end
	local model = template:Clone()
	UnitPainter.paint(model, color)
	-- soldat (Humanoid) : seule la racine est ancrée, pour que la marche s'anime ; véhicule : tout
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = humanoid == nil or d == model.PrimaryPart
			d.CanQuery = false
			d.CanCollide = false
		end
	end
	local lift = liftOf(name, template)
	model:PivotTo(cf + Vector3.new(0, lift, 0))
	model.Parent = battle.group
	return model
end

-- Petite boule lumineuse qui grossit puis s'efface (impact, explosion)
local function flash(position: Vector3, color: Color3, size: number, duration: number)
	local c = container
	if not c then
		return
	end
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Material = Enum.Material.Neon
	ball.Color = color
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.CastShadow = false
	ball.Size = Vector3.one * 0.4
	ball.Position = position
	ball.Parent = c
	local tween = TweenService:Create(ball, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.one * size,
		Transparency = 1,
	})
	tween:Play()
	tween.Completed:Connect(function()
		ball:Destroy()
	end)
end

-- Tir : un trait lumineux qui file de `from` à `to`
local function shot(from: Vector3, to: Vector3, color: Color3)
	local c = container
	if not c then
		return
	end
	local tracer = Instance.new("Part")
	tracer.Material = Enum.Material.Neon
	tracer.Color = color
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.CanTouch = false
	tracer.CastShadow = false
	tracer.Size = Vector3.new(0.18, 0.18, 1.4)
	tracer.CFrame = CFrame.lookAt(from, to)
	tracer.Parent = c
	local tween = TweenService:Create(tracer, TweenInfo.new(0.25, Enum.EasingStyle.Linear), { CFrame = CFrame.lookAt(to, to + (to - from)) })
	tween:Play()
	tween.Completed:Connect(function()
		tracer:Destroy()
		flash(to, color, 1.6, 0.25)
	end)
end

local function removeModel(entry: Deployed)
	local box = entry.model:GetBoundingBox()
	flash(box.Position, Color3.new(1, 1, 1), 3, 0.35)
	entry.model:Destroy()
end

-- Répartit `slots` modèles entre les types présents, proportionnellement aux effectifs
local function allocate(counts: { [string]: number }, slots: number): { [string]: number }
	local total = 0
	for _, n in counts do
		total += n
	end
	local result: { [string]: number } = {}
	if total == 0 then
		return result
	end
	local used = 0
	local remainders = {}
	for typeId, n in counts do
		local exact = math.min(n, n / total * slots)
		local whole = math.floor(exact)
		if n > 0 and whole == 0 then
			whole = 1 -- chaque type présent est visible
		end
		result[typeId] = whole
		used += whole
		table.insert(remainders, { id = typeId, rest = exact - math.floor(exact), n = n })
	end
	table.sort(remainders, function(a, b)
		return a.rest > b.rest
	end)
	for _, r in remainders do
		if used >= slots then
			break
		end
		if result[r.id] < r.n then
			result[r.id] += 1
			used += 1
		end
	end
	return result
end

-- La caméra est-elle assez proche de ce point (et le voit-elle) pour dessiner les tirs ?
local function nearCamera(position: Vector3): boolean
	local camera = workspace.CurrentCamera
	if (camera.CFrame.Position - position).Magnitude > DRAW_DISTANCE then
		return false
	end
	local _, onScreen = camera:WorldToViewportPoint(position)
	return onScreen
end

-- Met les modèles d'un camp en accord avec les effectifs du serveur. Les nouveaux sortent de
-- `spawn` (le général, ou la ville) et rejoignent par escouades leur place, à couvert face à `enemy`.
local function syncSide(battle: Battle, side: { Deployed }, wanted: { [string]: number }, color: Color3, origin: CFrame, front: number, facing: number, spawn: CFrame, enemy: Vector3)
	-- retirer les modèles en trop (les pertes disparaissent)
	local have: { [string]: number } = {}
	for i = #side, 1, -1 do
		local entry = side[i]
		have[entry.kind] = (have[entry.kind] or 0) + 1
		if have[entry.kind] > (wanted[entry.kind] or 0) then
			removeModel(entry)
			table.remove(side, i)
		end
	end
	-- ajouter les modèles manquants (au début de la bataille)
	local count: { [string]: number } = {}
	for _, entry in side do
		count[entry.kind] = (count[entry.kind] or 0) + 1
	end
	for kind, n in wanted do
		local model = if kind == "Milice" then "Soldat" else Units.types[kind].model
		while (count[kind] or 0) < n do
			local slot = #side
			local x = (slot % 3 - 1) * 5 + (if slot >= 3 then 2.5 else 0)
			local z = front + (if slot >= 3 then 3.5 * math.sign(front) else 0)
			local cf = origin * CFrame.new(x, 0, z) * CFrame.Angles(0, facing, 0)
			local start = CFrame.new(spawn.Position + Vector3.new(math.random() - 0.5, 0, math.random() - 0.5)) * CFrame.Angles(0, facing, 0)
			local m = spawnModel(battle, model, color, start)
			if not m then
				break
			end
			local mover = SquadBehavior.prepare(m, liftOf(model, (templates :: Instance):FindFirstChild(model) :: Model))
			-- escouade : le chef part le premier, ses hommes le suivent
			local squad, member = slot // SQUAD_SIZE, slot % SQUAD_SIZE
			SquadBehavior.moveTo(mover, SquadBehavior.cover(cf, enemy, COVER_RADIUS, obstacles), MARCH_SPEED, squad * 0.4 + member * 0.2)
			table.insert(side, { model = m, kind = kind, mover = mover })
			count[kind] = (count[kind] or 0) + 1
		end
	end
end

local function attackerCounts(battle: Battle): { [string]: number }
	local army = ArmyState.get(battle.folder:GetAttribute("Armee") :: string)
	if not army then
		return {}
	end
	local counts = ArmyState.troops(army)
	return allocate(counts, Combat.visibleModels)
end

local function update(battle: Battle)
	if battle.ended then
		return
	end
	local attacker = Countries[battle.folder:GetAttribute("Attaquant") :: string]
	local defender = Countries[battle.folder:GetAttribute("Defenseur") :: string]
	local garrison = (battle.folder:GetAttribute("Garnison") :: number?) or 0
	-- repère : +Z = vers le sud (vers la ville pour une armée postée au nord). Les modèles regardent
	-- vers -Z par défaut : les attaquants sont tournés de 180° vers le sud, les défenseurs gardent
	-- leur orientation et font face au nord, vers eux
	syncSide(battle, battle.attackers, attackerCounts(battle), attacker.color, battle.origin, 3, math.pi, battle.origin, battle.defense.Position)
	syncSide(battle, battle.defenders, { Milice = math.min(MAX_MILITIA_MODELS, garrison) }, defender.color, battle.defense, 0, 0, battle.defense, battle.origin.Position)
	-- armée trop touchée (moral proche du repli) : ses troupes reculent vers leur général
	local army = ArmyState.get(battle.folder:GetAttribute("Armee") :: string)
	if army and not battle.retreating and MilitaryMath.morale(army) < Combat.morale.retreatBelow + 10 then
		battle.retreating = true
		for i, entry in battle.attackers do
			local back = battle.origin * CFrame.new((i % 3 - 1) * 2, 0, -2) * CFrame.Angles(0, math.pi, 0)
			SquadBehavior.moveTo(entry.mover, back, MARCH_SPEED * 1.4, (i - 1) * 0.1)
		end
	end
end

-- Une manche : quelques tirs croisés et, pour les blindés et l'artillerie, des explosions
local function volley(battle: Battle)
	if #battle.attackers == 0 or #battle.defenders == 0 or not nearCamera(battle.defense.Position) then
		return
	end
	local function center(entry: Deployed): Vector3
		return (entry.model:GetBoundingBox()).Position
	end
	local function models(list: { Deployed }): { Model }
		local result = {}
		for _, entry in list do
			table.insert(result, entry.model)
		end
		return result
	end
	-- chaque tireur vise l'ennemi le plus proche
	local defenders, attackers = models(battle.defenders), models(battle.attackers)
	for _ = 1, 3 do
		local a = battle.attackers[math.random(#battle.attackers)]
		local target = SquadBehavior.nearest(center(a), defenders)
		if target then
			shot(center(a), (target:GetBoundingBox()).Position, SHOT_ATTACK)
		end
		local d = battle.defenders[math.random(#battle.defenders)]
		task.delay(0.15, function()
			local back = SquadBehavior.nearest(center(d), attackers)
			if d.model.Parent and back then
				shot(center(d), (back:GetBoundingBox()).Position, SHOT_DEFENSE)
			end
		end)
	end
	for _, a in battle.attackers do
		if a.kind == "Blindes" or a.kind == "Artillerie" then
			local target = battle.defenders[math.random(#battle.defenders)]
			local point = center(target) + Vector3.new(math.random() * 2 - 1, 0, math.random() * 2 - 1)
			task.delay(0.3, function()
				flash(point, BLAST, 5, 0.5)
				Sfx.playAt("Explosion", point)
				flash(point, Color3.fromRGB(90, 90, 90), 3.5, 1.1) -- petite fumée
			end)
			break -- une explosion par manche suffit
		end
	end
end

local function banner(battle: Battle, text: string, color: Color3)
	local anchor = Instance.new("Part")
	anchor.Name = "Resultat"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.CFrame = battle.defense * CFrame.new(0, 10, 0)
	anchor.Parent = battle.group
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(260, 50)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Parent = anchor
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.FontFace = FONT
	label.TextSize = 34
	label.TextColor3 = color
	label.Text = text
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Parent = label
	label.Parent = gui
end

local function finish(battle: Battle)
	if battle.ended then
		return
	end
	battle.ended = true
	battle.stopSound()
	local folder = battle.folder
	local state = folder:GetAttribute("Etat")
	local regionName = Regions[folder:GetAttribute("Region") :: string].name
	local attacker = folder:GetAttribute("Attaquant")
	local defender = folder:GetAttribute("Defenseur")
	local won = state == "Victoire"
	local retreated = state == "Repli"
	local raid = folder:GetAttribute("Raid") == true
	banner(
		battle,
		if won then (if raid then "Raid réussi !" else "Victoire !") elseif retreated then "Repli" else "Défaite",
		if won then Color3.fromRGB(150, 240, 160) elseif retreated then Color3.fromRGB(255, 190, 110) else Color3.fromRGB(255, 130, 120)
	)

	local me = myCountry()
	if me == attacker then
		if won and raid then
			Toast.show(`💣 Raid réussi sur <b>{regionName}</b> : ses divisions sont affaiblies. Attaque-la avec tes divisions pour la prendre !`, "success")
		elseif won then
			Toast.show(`🏆 Victoire ! <b>{regionName}</b> est à toi.`, "success", "Victoire")
		elseif retreated then
			Toast.show(`↩️ Repli : ta force quitte <b>{regionName}</b> pour une région amie.`, "info")
		else
			Toast.show(`💀 Défaite en <b>{regionName}</b> : ta force a été détruite et son chef capturé.`, "danger", "Defaite")
		end
	elseif me == defender then
		if won and raid then
			Toast.show(`💣 <b>{regionName}</b> a subi un raid : ses divisions sont affaiblies.`, "danger")
		elseif won then
			Toast.show(`🚩 Tu as perdu <b>{regionName}</b>.`, "danger", "Defaite")
		else
			Toast.show(`🛡️ <b>{regionName}</b> a repoussé l'attaque !`, "success", "Victoire")
		end
	end

	-- les troupes « rentrent » dans le général, les défenseurs se retirent
	task.delay(1.5, function()
		for _, list in { battle.attackers, battle.defenders } do
			for _, entry in list do
				if entry.model.Parent then
					removeModel(entry)
				end
			end
			table.clear(list)
		end
	end)
	task.delay(Combat.resultDelay - 0.5, function()
		battle.group:Destroy()
	end)
end

local function track(folder: Instance)
	if battles[folder] or not container then
		return
	end
	-- batailles terrestres des divisions : affichées par Military/BattleRenderer
	if folder:GetAttribute("Genre") == "Terre" then
		return
	end
	local armyId = folder:GetAttribute("Armee") :: string
	local regionId = folder:GetAttribute("Region") :: string
	-- brouillard de guerre : une bataille hors de vue ne s'affiche pas (sauf celles du joueur)
	local me = myCountry()
	if not Fog.isRegionVisible(regionId) and me ~= folder:GetAttribute("Attaquant") and me ~= folder:GetAttribute("Defenseur") then
		return
	end
	-- position logique de la force (à l'arrêt dans la région attaquée : au sol, en vol ou en mer)
	local position = ArmyView.positionOf(armyId)
	local region = Regions[regionId]
	local city = region and region.city
	if not position or not city then
		return
	end
	local kind = folder:GetAttribute("Genre")
	local cityPoint = MapProjection.toVector3(city.lon, city.lat, MapSettings.regionTop)
	-- défenseurs : devant la ville, ou sur la côte face à une flotte
	local defensePoint = cityPoint + Vector3.new(0, 0, -2)
	if kind == "Mer" then
		local toCity = Vector3.new(cityPoint.X - position.X, 0, cityPoint.Z - position.Z)
		local shore = position + (if toCity.Magnitude > 0 then toCity.Unit * math.min(10, toCity.Magnitude) else Vector3.zero)
		defensePoint = Vector3.new(shore.X, MapSettings.regionTop, shore.Z)
	end
	local group = Instance.new("Model")
	group.Name = folder.Name
	group.Parent = container
	local battle: Battle = {
		folder = folder,
		group = group,
		origin = CFrame.new(position),
		defense = CFrame.new(defensePoint),
		attackers = {},
		defenders = {},
		ended = false,
		retreating = false,
		-- fusillade entre les deux camps, audible quand la caméra est proche
		stopSound = Sfx.loop("Fusillade", (position + defensePoint) / 2),
	}
	battles[folder] = battle

	if me == folder:GetAttribute("Defenseur") then
		Toast.show(`⚔️ <b>{Regions[regionId].name}</b> est attaquée par {FrenchNames.the(Countries[folder:GetAttribute("Attaquant") :: string].name)} !`, "danger")
	end

	update(battle)
	folder.AttributeChanged:Connect(function(attribute: string)
		if attribute == "Etat" and folder:GetAttribute("Etat") ~= "EnCours" then
			update(battle)
			finish(battle)
		elseif attribute == "Manche" then
			update(battle)
			volley(battle)
		elseif attribute == "Garnison" then
			update(battle)
		end
	end)
	-- pertes de l'attaquant (effectifs de l'armée)
	local army = ArmyState.get(armyId)
	if army then
		army.AttributeChanged:Connect(function()
			update(battle)
		end)
	end
end

function BattleView.start(carte: Model)
	local folder = Instance.new("Folder")
	folder.Name = "Batailles"
	folder.Parent = carte
	container = folder
	-- abris possibles pour les troupes : reliefs et bâtiments des villes
	for _, name in { "Reliefs", "Villes" } do
		local f = carte:FindFirstChild(name)
		if f then
			table.insert(obstacles, f)
		end
	end
	templates = ReplicatedStorage:WaitForChild("Modeles", 30)

	local batailles = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Batailles")
	for _, battle in batailles:GetChildren() do
		task.spawn(track, battle)
	end
	batailles.ChildAdded:Connect(function(battle: Instance)
		task.wait() -- laisse arriver les attributs de la bataille
		track(battle)
	end)
	batailles.ChildRemoved:Connect(function(battle: Instance)
		local b = battles[battle]
		if b then
			if not b.ended then
				if MatchState.isRunning() then
					finish(b)
				else
					-- nouvelle partie : la bataille est effacée, sans résultat ni message
					b.ended = true
					b.stopSound()
					b.group:Destroy()
				end
			end
			battles[battle] = nil
		end
	end)
end

return BattleView
