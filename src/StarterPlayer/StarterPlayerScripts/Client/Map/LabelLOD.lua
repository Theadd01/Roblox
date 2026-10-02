--!strict
-- Noms sur la carte selon la hauteur de la caméra (comme dans Hearts of Iron) :
--   de près : noms des régions ;
--   de loin (au-dessus de MapSettings.labels.countryHeight) : noms des pays, sauf ceux qui ont
--   perdu leur capitale (attribut Vivant posé par MapBuilder.paintRegion).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MapSettings = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("MapSettings")) :: any

local CHECK_INTERVAL = 0.2 -- secondes entre deux mesures de la hauteur de la caméra

local LabelLOD = {}

local far = false

function LabelLOD.start(carte: Model)
	local regions = carte:WaitForChild("Regions")
	local names = carte:WaitForChild("NomsPays")
	local countryLabels: { BillboardGui } = {}
	for _, gui in names:GetDescendants() do
		if gui:IsA("BillboardGui") then
			table.insert(countryLabels, gui)
		end
	end

	local function applyCountry(gui: BillboardGui)
		gui.Enabled = far and gui:GetAttribute("Vivant") ~= false
	end
	local function apply()
		for _, model in regions:GetChildren() do
			local label = model:FindFirstChild("Etiquette")
			if label and label:IsA("BillboardGui") then
				label.Enabled = not far
			end
		end
		for _, gui in countryLabels do
			applyCountry(gui)
		end
	end
	-- un pays perd (ou reprend) sa capitale : son nom disparaît (ou revient)
	for _, gui in countryLabels do
		gui:GetAttributeChangedSignal("Vivant"):Connect(function()
			applyCountry(gui)
		end)
	end

	far = workspace.CurrentCamera.CFrame.Position.Y > MapSettings.labels.countryHeight
	apply()
	local clock = 0
	RunService.RenderStepped:Connect(function(dt: number)
		clock += dt
		if clock < CHECK_INTERVAL then
			return
		end
		clock = 0
		local nowFar = workspace.CurrentCamera.CFrame.Position.Y > MapSettings.labels.countryHeight
		if nowFar ~= far then
			far = nowFar
			apply()
		end
	end)
end

return LabelLOD
