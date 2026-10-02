--!strict
-- Lumière de la carte : pas de brume (la carte reste lisible quand on dézoome),
-- pas de reflets du ciel et soleil placé pour que son reflet reste hors de l'écran.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local MapSettings = require(Config:WaitForChild("MapSettings")) :: any

local MapLighting = {}

function MapLighting.apply()
	local L = MapSettings.lighting
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmosphere then
		atmosphere.Density = L.atmosphereDensity
		atmosphere.Haze = 0
		atmosphere.Glare = 0
	end
	Lighting.FogEnd = 1e6
	Lighting.EnvironmentSpecularScale = L.environmentSpecularScale
	Lighting.EnvironmentDiffuseScale = L.environmentDiffuseScale
	Lighting.Ambient = L.ambient
	Lighting.OutdoorAmbient = L.outdoorAmbient
	Lighting.ClockTime = L.clockTime
	Lighting.Brightness = L.brightness
	Lighting.ExposureCompensation = L.exposureCompensation
	Lighting.GeographicLatitude = L.geographicLatitude
	local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
	if not bloom then
		bloom = Instance.new("BloomEffect")
		bloom.Name = "CarteBloom"
		bloom.Parent = Lighting
	end
	bloom.Intensity = L.bloomIntensity
	bloom.Size = L.bloomSize
	bloom.Threshold = L.bloomThreshold

	local colorGrade = Lighting:FindFirstChild("CarteColorGrade")
	if not colorGrade or not colorGrade:IsA("ColorCorrectionEffect") then
		if colorGrade then
			colorGrade:Destroy()
		end
		colorGrade = Instance.new("ColorCorrectionEffect")
		colorGrade.Name = "CarteColorGrade"
		colorGrade.Parent = Lighting
	end
	local correction = colorGrade :: ColorCorrectionEffect
	correction.Brightness = L.colorBrightness
	correction.Contrast = L.colorContrast
	correction.Saturation = L.colorSaturation
	correction.TintColor = L.colorTint
end

return MapLighting
