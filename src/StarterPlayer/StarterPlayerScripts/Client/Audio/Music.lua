--!strict
-- Musique d'ambiance : une piste au hasard de l'ambiance en cours (Titre, Paix, Tension, Guerre,
-- voir Config/Audio.music), enchaînée en fondu avec la suivante. Changer d'ambiance passe aussitôt
-- à une piste de la nouvelle ambiance. La musique baisse pendant les jingles (victoire, défaite...).
-- Volume : réglage « Musique » du joueur (groupe de sons « Musique »).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Audio = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Audio")) :: any
local Settings = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("Settings"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

type Track = { id: string, name: string }

local Music = {}

local group: SoundGroup? = nil
local mood: string? = nil
local current: Sound? = nil
local generation = 0 -- change à chaque nouvelle piste : les rappels de l'ancienne s'annulent
local lastTrack: { [string]: string } = {} -- ambiance -> dernière piste jouée (pas deux fois de suite)
local failed: { [string]: boolean } = {} -- pistes qui n'ont pas pu se charger
local duckUntil = 0

local function getGroup(): SoundGroup
	local existing = group
	if existing then
		return existing
	end
	local g = Instance.new("SoundGroup")
	g.Name = "Musique"
	g.Volume = Settings.get("musicVolume")
	g.Parent = SoundService
	Settings.onChanged(function(key: string, value: any)
		if key == "musicVolume" then
			g.Volume = value
		end
	end)
	group = g
	return g
end

local function targetVolume(): number
	return Audio.musicBase * (if os.clock() < duckUntil then Audio.duckFactor else 1)
end

local function pick(moodName: string): Track?
	local list: { Track } = Audio.music[moodName] or {}
	local candidates = {}
	for _, track in list do
		if not failed[track.id] and track.id ~= lastTrack[moodName] then
			table.insert(candidates, track)
		end
	end
	if #candidates == 0 then
		for _, track in list do
			if not failed[track.id] then
				table.insert(candidates, track)
			end
		end
	end
	return if #candidates > 0 then candidates[math.random(#candidates)] else nil
end

local function fadeOutAndDestroy(sound: Sound)
	local fade = TweenService:Create(sound, TweenInfo.new(Audio.crossfade), { Volume = 0 })
	fade:Play()
	fade.Completed:Connect(function()
		sound:Destroy()
	end)
end

local playNext: () -> ()

local function start(track: Track)
	generation += 1
	local myGeneration = generation
	local sound = Instance.new("Sound")
	sound.Name = "Musique"
	sound.SoundId = track.id
	sound.Volume = 0
	sound.SoundGroup = getGroup()
	sound.Parent = SoundService
	local previous = current
	current = sound
	if previous then
		fadeOutAndDestroy(previous)
	end
	if mood then
		lastTrack[mood] = track.id
	end
	task.spawn(function()
		local waited = 0
		while not sound.IsLoaded and waited < Audio.loadTimeout and sound.Parent do
			waited += task.wait(0.25)
		end
		if generation ~= myGeneration then
			return
		end
		if not sound.IsLoaded or sound.TimeLength <= 0 then
			warn(`[Musique] piste impossible à charger : {track.name} ({track.id})`)
			failed[track.id] = true
			playNext()
			return
		end
		sound:Play()
		TweenService:Create(sound, TweenInfo.new(Audio.crossfade), { Volume = targetVolume() }):Play()
		-- la suivante démarre pendant la fin de celle-ci (fondu enchaîné)
		task.delay(math.max(1, sound.TimeLength - Audio.crossfade), function()
			if generation == myGeneration then
				playNext()
			end
		end)
	end)
end

function playNext()
	local moodName = mood
	if not moodName then
		return
	end
	local track = pick(moodName)
	if track then
		start(track)
	end
end

-- Ambiance voulue : "Titre", "Paix", "Tension" ou "Guerre" (rien ne change si c'est déjà elle)
function Music.setMood(newMood: string)
	if newMood == mood then
		return
	end
	mood = newMood
	playNext()
end

function Music.getMood(): string?
	return mood
end

-- Baisse la musique pendant `duration` secondes (jingle de victoire, de défaite...)
function Music.duck(duration: number)
	duckUntil = math.max(duckUntil, os.clock() + duration)
	local sound = current
	if sound then
		TweenService:Create(sound, TweenInfo.new(0.4), { Volume = targetVolume() }):Play()
	end
	task.delay(duration + 0.05, function()
		local s = current
		if s and os.clock() >= duckUntil then
			TweenService:Create(s, TweenInfo.new(1.5), { Volume = targetVolume() }):Play()
		end
	end)
end

function Music.start()
	getGroup()
	Sfx.onJingle(Music.duck)
end

return Music
