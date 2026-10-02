--!strict
-- Effets sonores (voir Config/Audio.sounds) :
--   Sfx.play(nom)                 son d'interface ou d'action, entendu partout
--   Sfx.playAt(nom, position)     son placé sur la carte (bataille), audible seulement de près
--   Sfx.loop(nom, position)       son en boucle sur la carte ; renvoie la fonction qui l'arrête
--   Sfx.actionResult(remote, ok)  son de la réponse du serveur à une demande du joueur
-- Volume : réglage « Effets » du joueur (groupe de sons « Effets »).

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Audio = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Audio")) :: any
local Settings = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("Settings"))

type JingleListener = (duration: number) -> ()

local Sfx = {}

local group: SoundGroup? = nil
local sounds: { [string]: Sound } = {} -- sons non placés, réutilisés
local lastPlayed: { [string]: number } = {}
local playToken: { [string]: number } = {}
local fading: { [string]: Tween } = {} -- fondu de fin d'un jingle en cours
local jingleListeners: { JingleListener } = {}

local function getGroup(): SoundGroup
	local existing = group
	if existing then
		return existing
	end
	local g = Instance.new("SoundGroup")
	g.Name = "Effets"
	g.Volume = Settings.get("effectsVolume")
	g.Parent = SoundService
	Settings.onChanged(function(key: string, value: any)
		if key == "effectsVolume" then
			g.Volume = value
		end
	end)
	group = g
	return g
end

local function make(name: string, parent: Instance): Sound?
	local def = Audio.sounds[name]
	if not def then
		warn(`[Sfx] son inconnu : {name}`)
		return nil
	end
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = def.id
	sound.Volume = def.volume
	sound.SoundGroup = getGroup()
	sound.Parent = parent
	return sound
end

-- Évite qu'un même son se répète en rafale (plusieurs messages d'un coup, tirs...)
local function throttled(name: string): boolean
	local now = os.clock()
	local last = lastPlayed[name]
	if last and now - last < Audio.spatial.minInterval then
		return true
	end
	lastPlayed[name] = now
	return false
end

-- Charge à l'avance les sons d'interface (le premier clic ne doit pas attendre)
function Sfx.preload()
	local list = {}
	for name in Audio.sounds do
		if not sounds[name] then
			local sound = make(name, SoundService)
			if sound then
				sounds[name] = sound
				table.insert(list, sound)
			end
		end
	end
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(list)
		end)
	end)
end

function Sfx.play(name: string)
	if throttled(name) then
		return
	end
	local def = Audio.sounds[name]
	local sound = sounds[name]
	if not sound then
		sound = make(name, SoundService)
		if not sound then
			return
		end
		sounds[name] = sound
	end
	local s = sound :: Sound
	local token = (playToken[name] or 0) + 1
	playToken[name] = token
	local previousFade = fading[name]
	if previousFade then
		previousFade:Cancel()
		fading[name] = nil
	end
	s.Volume = def.volume
	s.TimePosition = 0
	s:Play()
	-- jingle trop long : on le coupe en fondu
	if def.maxLength then
		task.delay(def.maxLength, function()
			if playToken[name] == token and s.IsPlaying then
				local fade = TweenService:Create(s, TweenInfo.new(0.8), { Volume = 0 })
				fading[name] = fade
				fade:Play()
				fade.Completed:Wait()
				if playToken[name] == token then
					fading[name] = nil
					s:Stop()
				end
			end
		end)
	end
	if Audio.jingles[name] then
		for _, listener in jingleListeners do
			task.spawn(listener, def.maxLength or 5)
		end
	end
end

-- Point d'attache d'un son sur la carte (le terrain est à l'origine du monde)
local function attachAt(position: Vector3): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = "Son"
	attachment.Position = position
	attachment.Parent = workspace.Terrain
	return attachment
end

local function placed(name: string, position: Vector3): (Sound?, Attachment)
	local attachment = attachAt(position)
	local sound = make(name, attachment)
	if sound then
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMinDistance = Audio.spatial.minDistance
		sound.RollOffMaxDistance = Audio.spatial.maxDistance
	end
	return sound, attachment
end

function Sfx.playAt(name: string, position: Vector3)
	if throttled(name) then
		return
	end
	local sound, attachment = placed(name, position)
	if not sound then
		attachment:Destroy()
		return
	end
	sound.Ended:Connect(function()
		attachment:Destroy()
	end)
	sound:Play()
	task.delay(15, function() -- au cas où le son ne se charge jamais
		if attachment.Parent then
			attachment:Destroy()
		end
	end)
end

-- Son en boucle sur la carte (fusillade d'une bataille) ; la fonction renvoyée l'arrête en fondu
function Sfx.loop(name: string, position: Vector3): () -> ()
	local sound, attachment = placed(name, position)
	if not sound then
		attachment:Destroy()
		return function() end
	end
	sound.Looped = true
	sound.TimePosition = math.random() * 3 -- deux batailles voisines ne sont pas synchrones
	sound:Play()
	local stopped = false
	return function()
		if stopped then
			return
		end
		stopped = true
		local fade = TweenService:Create(sound, TweenInfo.new(1.5), { Volume = 0 })
		fade:Play()
		fade.Completed:Connect(function()
			attachment:Destroy()
		end)
	end
end

-- Réponse du serveur à une demande (nom du RemoteFunction) : son de l'action, ou de refus
function Sfx.actionResult(remoteName: string, accepted: boolean)
	if not accepted then
		Sfx.play("Refus")
		return
	end
	local name = Audio.actionSounds[remoteName]
	if name then
		Sfx.play(name)
	end
end

-- Appelé quand un jingle commence (la musique baisse pendant `duration` secondes)
function Sfx.onJingle(listener: JingleListener)
	table.insert(jingleListeners, listener)
end

return Sfx
