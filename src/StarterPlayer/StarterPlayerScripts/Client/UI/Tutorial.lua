--!strict
-- Tutoriel guidé (5 minutes au plus) : produire, vendre, recruter, déplacer une armée.
-- Une carte en bas de l'écran donne la consigne de l'étape ; l'élément à toucher clignote en
-- doré. Chaque étape se valide toute seule quand le joueur l'a faite (état publié par le serveur).
-- Lancé par le bouton « Tutoriel » de l'écran titre, ou proposé au début de la première partie.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Countries = require(Config:WaitForChild("Countries")) :: any
local Economy = require(Config:WaitForChild("Economy")) :: any
local FrenchNames = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FrenchNames")) :: any
local Client = script.Parent.Parent
local ArmyState = require(Client:WaitForChild("State"):WaitForChild("ArmyState"))
local FactoryState = require(Client:WaitForChild("State"):WaitForChild("FactoryState"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local TabBar = require(script.Parent:WaitForChild("TabBar"))

type Step = {
	text: string,
	targets: { string }?, -- chemins (sous PlayerGui) des éléments à faire clignoter, le premier trouvé
	done: (() -> boolean)?, -- nil : étape d'information (bouton « Suivant »)
}

local CHECK_INTERVAL = 0.5

local Tutorial = {}

local offered = false -- la proposition n'est faite qu'une fois par session

-- Élément de l'interface au bout d'un chemin (« Onglets.Barre.Marche ») ; un morceau qui finit par
-- « * » désigne le premier enfant dont le nom commence ainsi (« Ligne_* »)
local function find(path: string): GuiObject?
	local parts = path:split(".")
	local function walk(node: Instance, i: number): Instance?
		if i > #parts then
			return node
		end
		local part = parts[i]
		if part:sub(-1) == "*" then
			local prefix = part:sub(1, -2)
			for _, child in node:GetChildren() do
				if child.Name:sub(1, #prefix) == prefix then
					local found = walk(child, i + 1)
					if found then
						return found
					end
				end
			end
			return nil
		end
		local child = node:FindFirstChild(part)
		return if child then walk(child, i + 1) else nil
	end
	local found = walk(Players.LocalPlayer:WaitForChild("PlayerGui"), 1)
	return if found and found:IsA("GuiObject") and found.Visible then found else nil
end

local function troops(army: Instance): number
	local _, total = ArmyState.troops(army)
	return total
end

local function steps(countryId: string, folder: Instance): { Step }
	local startCredits = 0
	return {
		{
			text = `👋 Bienvenue ! Tu diriges <b>{FrenchNames.the(Countries[countryId].name)}</b>. Tes régions produisent des ressources toutes les {Economy.productionInterval} secondes : regarde la barre du haut.`,
		},
		{
			text = "💹 Tes crédits arrivent tout seuls (impôts de tes habitants, ventes automatiques). Ouvre l'onglet <b>Marché</b> pour voir tes revenus.",
			targets = { "Onglets.Barre.Marche" },
			done = function(): boolean
				if TabBar.getCurrent() == "Marche" then
					startCredits = (folder:GetAttribute("Credits") :: number?) or 0
					return true
				end
				return false
			end,
		},
		{
			text = "🌾 Vends de la nourriture : choisis <b>x 10</b>, puis touche <b>Vendre</b> sur la ligne Nourriture.",
			targets = { "Onglets.Panneau.Contenu.Nourriture.Vendre", "Onglets.Panneau.Contenu.Quantite.Q10", "Onglets.Barre.Marche" },
			done = function(): boolean
				return ((folder:GetAttribute("Credits") :: number?) or 0) > startCredits
			end,
		},
		{
			text = "🏗️ Construis : ouvre l'onglet <b>Bâtiments</b>, puis <b>+ Construire ici</b> dans ta capitale (des champs de blé, par exemple).",
			targets = { "Onglets.Panneau.Contenu.Regions", "Onglets.Barre.Batiments" },
			done = function(): boolean
				for _, building in FactoryState.ownedBy(countryId) do
					if building:GetAttribute("Depart") ~= true then
						return true -- le camp militaire offert au départ ne compte pas
					end
				end
				return false
			end,
		},
		{
			text = "🎖️ Recrute : ouvre l'onglet <b>Armée</b>, nomme un général, puis recrute de l'infanterie.",
			targets = { "Onglets.Panneau.Contenu.Recruter_Infanterie", "Onglets.Panneau.Contenu.Nommer_Terre", "Onglets.Barre.Armee" },
			done = function(): boolean
				for _, army in ArmyState.ownedBy(countryId) do
					if troops(army) > 0 then
						return true
					end
				end
				return false
			end,
		},
		{
			text = "🗺️ Déplace ton armée : touche ton général sur la carte, puis une région (même lointaine : il y va de région en région). Vers un pays étranger, c'est une attaque (et une déclaration de guerre) !",
			targets = { "Onglets.Panneau.Contenu.Aller_*", "Onglets.Panneau.Contenu.Ligne_*.Ouvrir", "Onglets.Barre.Armee" },
			done = function(): boolean
				for _, army in ArmyState.ownedBy(countryId) do
					-- en route, ou déjà déplacée (sa région n'est plus celle où elle a été nommée)
					if ArmyState.isMoving(army) or army:GetAttribute("Provenance") ~= army:GetAttribute("Region") then
						return true
					end
				end
				return false
			end,
		},
		{
			text = "🎉 <b>Bravo !</b> Tu sais produire, vendre, recruter et déplacer une armée. Suis tes objectifs nationaux en haut à gauche, et garde un œil sur la Diplomatie : tu peux proposer une trêve, la paix ou une résolution au Conseil mondial (les autres pays votent). Bonne partie !",
		},
	}
end

local function run(countryId: string)
	local folder = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Pays"):WaitForChild(countryId)
	local list = steps(countryId, folder)

	local gui = Instance.new("ScreenGui")
	gui.Name = "Tutoriel"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 6
	-- en haut à gauche, sous les objectifs ; les clics passent au travers (sauf sur ses boutons)
	local card = UIStyle.panel("Carte", UDim.new(0, 340))
	card.Active = false
	card.Position = UDim2.fromOffset(12, 150)
	UIStyle.padding(card, 10, 14)
	UIStyle.list(card, 8)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(math.max(260, workspace.CurrentCamera.ViewportSize.X - 24), math.huge)
	limit.Parent = card
	local title = UIStyle.text("Etape", "", 14, UIStyle.FONT_BOLD, UIStyle.ACCENT)
	title.LayoutOrder = 1
	title.Parent = card
	local body = UIStyle.text("Consigne", "", 16)
	body.LayoutOrder = 2
	body.Parent = card
	local row = Instance.new("Frame")
	row.Name = "Boutons"
	row.LayoutOrder = 3
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 36)
	UIStyle.list(row, 8, true)
	local skip = UIStyle.button("Passer", "Passer le tutoriel")
	skip.Size = UDim2.new(0.5, -4, 1, 0)
	skip.TextSize = 14
	skip.Parent = row
	local nextButton = UIStyle.button("Suivant", "Suivant", true)
	nextButton.LayoutOrder = 2
	nextButton.Size = UDim2.new(0.5, -4, 1, 0)
	nextButton.TextSize = 15
	nextButton.Parent = row
	row.Parent = card
	card.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local index = 1
	local highlight: UIStroke? = nil
	local highlighted: GuiObject? = nil
	local pulse: Tween? = nil
	local finished = false

	local function clearHighlight()
		if pulse then
			pulse:Cancel()
			pulse = nil
		end
		if highlight then
			highlight:Destroy()
			highlight = nil
		end
		highlighted = nil
	end

	local function finish()
		finished = true
		clearHighlight()
		gui:Destroy()
	end

	local function show()
		local step = list[index]
		if not step then
			finish()
			return
		end
		clearHighlight()
		title.Text = `📘 Tutoriel · étape {index}/{#list}`
		body.Text = step.text
		nextButton.Visible = step.done == nil
		nextButton.Text = if index == #list then "Terminer" else "Suivant"
		skip.Visible = index < #list
	end

	nextButton.Activated:Connect(function()
		index += 1
		show()
	end)
	skip.Activated:Connect(finish)

	-- suit l'avancement : valide l'étape en cours, fait clignoter l'élément à toucher
	task.spawn(function()
		while not finished and gui.Parent do
			local step = list[index]
			if step and step.done and step.done() then
				index += 1
				show()
			elseif step and step.targets then
				local target: GuiObject? = nil
				for _, path in step.targets do
					target = find(path)
					if target then
						break
					end
				end
				if target ~= highlighted then
					clearHighlight()
					if target then
						local stroke = Instance.new("UIStroke")
						stroke.Name = "SurbrillanceTutoriel"
						stroke.Color = UIStyle.ACCENT
						stroke.Thickness = 3
						stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
						stroke.Parent = target
						pulse = TweenService:Create(stroke, TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Transparency = 0.8 })
						if pulse then
							pulse:Play()
						end
						highlight, highlighted = stroke, target
						-- dans un panneau qui défile : on fait défiler jusqu'à l'élément
						local scroller = target:FindFirstAncestorWhichIsA("ScrollingFrame")
						if scroller then
							local offset = target.AbsolutePosition.Y - scroller.AbsolutePosition.Y + scroller.CanvasPosition.Y
							scroller.CanvasPosition = Vector2.new(0, math.max(0, offset - scroller.AbsoluteSize.Y / 3))
						end
					end
				end
			end
			task.wait(CHECK_INTERVAL)
		end
	end)
	show()
end

-- Lance le tutoriel pour ce pays (requested : demandé depuis l'écran titre), ou le propose une fois
function Tutorial.start(countryId: string, requested: boolean)
	if requested then
		offered = true
		run(countryId)
		return
	end
	if offered then
		return
	end
	offered = true
	local gui = Instance.new("ScreenGui")
	gui.Name = "PropositionTutoriel"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 6
	local card = UIStyle.panel("Carte", UDim.new(0, 340))
	card.Active = false
	card.Position = UDim2.fromOffset(12, 150)
	UIStyle.padding(card, 10, 14)
	UIStyle.list(card, 8)
	local text = UIStyle.text("Texte", "📘 <b>Première partie ?</b> Le tutoriel guidé t'apprend l'essentiel en 5 minutes.", 16)
	text.LayoutOrder = 1
	text.Parent = card
	local row = Instance.new("Frame")
	row.Name = "Boutons"
	row.LayoutOrder = 2
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 36)
	UIStyle.list(row, 8, true)
	local no = UIStyle.button("NonMerci", "Non merci")
	no.Size = UDim2.new(0.5, -4, 1, 0)
	no.TextSize = 14
	no.Parent = row
	local yes = UIStyle.button("Suivre", "Suivre le tutoriel", true)
	yes.LayoutOrder = 2
	yes.Size = UDim2.new(0.5, -4, 1, 0)
	yes.TextSize = 14
	yes.Parent = row
	row.Parent = card
	card.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	no.Activated:Connect(function()
		gui:Destroy()
	end)
	yes.Activated:Connect(function()
		gui:Destroy()
		run(countryId)
	end)
	task.delay(30, function()
		if gui.Parent then
			gui:Destroy()
		end
	end)
end

return Tutorial
