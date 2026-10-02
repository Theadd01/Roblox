--!strict
-- Boucle centrale du système militaire (SYSTEME_MILITAIRE.md, section 9) : un seul
-- RunService.Heartbeat, avec un accumulateur de temps par système. Les modules s'y inscrivent
-- (ticks de combat, déplacements, ravitaillement, IA des généraux...) au lieu de lancer chacun
-- leur propre boucle « while true do wait() ».

local RunService = game:GetService("RunService")

type System = {
	name: string,
	interval: number, -- secondes entre deux appels (0 : à chaque image)
	run: (dt: number, now: number) -> (),
	elapsed: number,
}

local MilitaryLoop = {}

local systems: { System } = {}
local started = false

-- Inscrit un système, appelé toutes les `interval` secondes avec le temps écoulé depuis son
-- dernier appel et l'heure du serveur (workspace:GetServerTimeNow())
function MilitaryLoop.every(name: string, interval: number, run: (dt: number, now: number) -> ())
	table.insert(systems, { name = name, interval = interval, run = run, elapsed = 0 })
end

-- Dans Studio : temps le plus long de chaque système (ms) sur les 10 dernières secondes, publié en
-- attributs de ServerStorage.PerfMilitaire (pour repérer ce qui ralentit le serveur)
local studio = RunService:IsStudio()
local worst: { [string]: number } = {}
local perfClock = 0

local function publishPerf()
	local ServerStorage = game:GetService("ServerStorage")
	local folder = ServerStorage:FindFirstChild("PerfMilitaire")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "PerfMilitaire"
		folder.Parent = ServerStorage
	end
	for name, ms in worst do
		(folder :: Instance):SetAttribute(name, math.floor(ms * 10 + 0.5) / 10)
	end
	table.clear(worst)
end

function MilitaryLoop.start()
	if started then
		return
	end
	started = true
	RunService.Heartbeat:Connect(function(dt: number)
		local now = workspace:GetServerTimeNow()
		for _, system in systems do
			system.elapsed += dt
			if system.elapsed >= system.interval then
				local elapsed = system.elapsed
				system.elapsed = 0
				-- une erreur dans un système ne bloque pas les autres
				local begin = os.clock()
				local ok, err = pcall(system.run, elapsed, now)
				if not ok then
					warn(`[Militaire] {system.name} : {err}`)
				end
				if studio then
					local ms = (os.clock() - begin) * 1000
					worst[system.name] = math.max(worst[system.name] or 0, ms)
				end
			end
		end
		if studio then
			perfClock += dt
			if perfClock >= 10 then
				perfClock = 0
				publishPerf()
			end
		end
	end)
end

return MilitaryLoop
