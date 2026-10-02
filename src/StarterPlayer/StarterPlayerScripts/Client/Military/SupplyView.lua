--!strict
-- Poches d'encerclement sur la carte (SYSTEME_MILITAIRE.md, 5.6), côté client, purement visuel :
-- une région où se trouvent des divisions coupées de leur ravitaillement (attribut Encerclee) est
-- entourée d'un contour rouge clignotant ; d'abord celles du joueur, puis celles qu'il voit.
-- Le serveur décide (Supply) ; ici on ne fait qu'afficher.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local MilitaryState = require(script.Parent:WaitForChild("MilitaryState"))
local Fog = require(Client:WaitForChild("State"):WaitForChild("Fog"))

local MAX_POCKETS = 10 -- contours au plus (Roblox limite le nombre de Highlight affichés)
local POCKET_COLOR = Color3.fromRGB(235, 60, 50)
local REFRESH = 0.5

local SupplyView = {}

local folder: Folder? = nil
local highlights: { [string]: Highlight } = {}

local function myCountry(): string?
	local me = Players.LocalPlayer:GetAttribute("Pays")
	return if typeof(me) == "string" and me ~= "" then me else nil
end

-- Régions qui forment une poche : les miennes d'abord, puis celles des autres que je vois
local function pockets(): { string }
	local me = myCountry()
	local mine, others = {}, {}
	local seen: { [string]: boolean } = {}
	for _, d in MilitaryState.list() do
		if d:GetAttribute("Encerclee") ~= true then
			continue
		end
		local regionId = d:GetAttribute("Region")
		if typeof(regionId) ~= "string" or seen[regionId] then
			continue
		end
		if d:GetAttribute("Proprietaire") == me then
			seen[regionId] = true
			table.insert(mine, regionId)
		elseif Fog.isArmyVisible(d) then
			seen[regionId] = true
			table.insert(others, regionId)
		end
	end
	for _, regionId in others do
		table.insert(mine, regionId)
	end
	return mine
end

local function refresh(carte: Model)
	local regions = carte:FindFirstChild("Regions")
	local wanted: { [string]: boolean } = {}
	for i, regionId in pockets() do
		if i > MAX_POCKETS then
			break
		end
		wanted[regionId] = true
		if not highlights[regionId] then
			local model = regions and regions:FindFirstChild(regionId)
			if model then
				local h = Instance.new("Highlight")
				h.Name = regionId
				h.Adornee = model
				h.FillTransparency = 1
				h.OutlineColor = POCKET_COLOR
				h.DepthMode = Enum.HighlightDepthMode.Occluded
				h.Parent = folder
				highlights[regionId] = h
			end
		end
	end
	for regionId, h in highlights do
		if not wanted[regionId] then
			h:Destroy()
			highlights[regionId] = nil
		end
	end
end

function SupplyView.start(carte: Model)
	local f = Instance.new("Folder")
	f.Name = "Poches"
	f.Parent = carte
	folder = f
	local clock = 0
	RunService.RenderStepped:Connect(function(dt: number)
		clock += dt
		if clock >= REFRESH then
			clock = 0
			refresh(carte)
		end
		-- clignotement du contour
		local blink = 0.5 + 0.5 * math.sin(os.clock() * 5)
		for _, h in highlights do
			h.OutlineTransparency = 0.6 * blink
		end
	end)
end

return SupplyView
