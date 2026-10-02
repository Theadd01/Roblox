--!strict
-- Comportement des troupes déployées en bataille (purement visuel, côté client) :
--   - déplacement avec PathfindingService (contourne reliefs et bâtiments), à défaut en ligne droite,
--     avec la marche des soldats ;
--   - escouades : le chef d'escouade part le premier, ses hommes le suivent à leur place ;
--   - couverture : la place de combat se cale derrière l'obstacle le plus proche (relief, ville),
--     du côté opposé à l'ennemi ;
--   - cible : l'ennemi le plus proche ;
--   - repli : quand leur armée est trop touchée, les troupes reculent vers leur général.

local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local UnitStyles = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("UnitStyles")) :: any

export type Mover = {
	model: Model,
	lift: number, -- hauteur du pivot au-dessus du sol
	walk: AnimationTrack?,
	idle: AnimationTrack?,
	token: number, -- change à chaque nouvel ordre : l'ancien trajet s'arrête
}

local SquadBehavior = {}

local AGENT = { AgentRadius = 0.6, AgentHeight = 2.5, AgentCanJump = false, WaypointSpacing = 3 }

local function loadTrack(model: Model, id: string): AnimationTrack?
	local animator = model:FindFirstChildWhichIsA("Animator", true)
	if not animator then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = id
	local ok, track = pcall(function()
		return (animator :: Animator):LoadAnimation(animation)
	end)
	if ok and track then
		track.Looped = true
		return track
	end
	return nil
end

-- Prépare un modèle déployé (animations de marche et de repos pour les soldats)
function SquadBehavior.prepare(model: Model, lift: number): Mover
	local mover: Mover = {
		model = model,
		lift = lift,
		walk = loadTrack(model, UnitStyles.walkAnimation),
		idle = loadTrack(model, UnitStyles.idleAnimation),
		token = 0,
	}
	if mover.idle then
		mover.idle:Play()
	end
	return mover
end

local function setWalking(mover: Mover, walking: boolean)
	if walking then
		if mover.idle then
			mover.idle:Stop(0.15)
		end
		if mover.walk then
			mover.walk:Play(0.15)
		end
	else
		if mover.walk then
			mover.walk:Stop(0.15)
		end
		if mover.idle then
			mover.idle:Play(0.15)
		end
	end
end

-- Envoie un modèle jusqu'à `goal` (CFrame au sol) à `speed` studs par seconde, après `delay`
-- secondes ; chemin calculé par PathfindingService, sinon ligne droite. Un nouvel ordre annule le
-- précédent.
function SquadBehavior.moveTo(mover: Mover, goal: CFrame, speed: number, delay: number?)
	mover.token += 1
	local token = mover.token
	task.spawn(function()
		if delay and delay > 0 then
			task.wait(delay)
		end
		if mover.token ~= token or not mover.model.Parent then
			return
		end
		local position = mover.model:GetPivot().Position - Vector3.new(0, mover.lift, 0)
		local points = { goal.Position }
		local path = PathfindingService:CreatePath(AGENT)
		local ok = pcall(function()
			path:ComputeAsync(position, goal.Position)
		end)
		if ok and path.Status == Enum.PathStatus.Success then
			points = {}
			for _, waypoint in path:GetWaypoints() do
				table.insert(points, Vector3.new(waypoint.Position.X, goal.Position.Y, waypoint.Position.Z))
			end
		end
		if mover.token ~= token or not mover.model.Parent then
			return
		end
		setWalking(mover, true)
		for _, point in points do
			while (point - position).Magnitude > 0.05 do
				local dt = RunService.Heartbeat:Wait()
				if mover.token ~= token or not mover.model.Parent then
					return
				end
				local delta = point - position
				position += delta.Unit * math.min(delta.Magnitude, speed * dt)
				local look = Vector3.new(delta.X, 0, delta.Z)
				local cf = if look.Magnitude > 0.01 then CFrame.lookAt(position, position + look) else CFrame.new(position)
				mover.model:PivotTo(cf + Vector3.new(0, mover.lift, 0))
			end
		end
		mover.model:PivotTo(goal + Vector3.new(0, mover.lift, 0))
		setWalking(mover, false)
	end)
end

-- Place de combat abritée : derrière l'obstacle le plus proche de `slot` (parmi `obstacles`),
-- du côté opposé à l'ennemi, face à lui ; sans obstacle proche, la place telle quelle
function SquadBehavior.cover(slot: CFrame, enemy: Vector3, radius: number, obstacles: { Instance }): CFrame
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = obstacles
	local best: BasePart? = nil
	local bestDistance = math.huge
	for _, part in workspace:GetPartBoundsInRadius(slot.Position, radius, params) do
		local distance = (part.Position - slot.Position).Magnitude
		if distance < bestDistance then
			best, bestDistance = part, distance
		end
	end
	local obstacle = best
	if not obstacle then
		return slot
	end
	local away = Vector3.new(obstacle.Position.X - enemy.X, 0, obstacle.Position.Z - enemy.Z)
	if away.Magnitude < 0.01 then
		return slot
	end
	local half = math.max(obstacle.Size.X, obstacle.Size.Z) / 2
	local spot = Vector3.new(obstacle.Position.X, slot.Position.Y, obstacle.Position.Z) + away.Unit * (half + 1.2)
	return CFrame.lookAt(spot, Vector3.new(enemy.X, spot.Y, enemy.Z))
end

-- Modèle le plus proche de `from` parmi `candidates` (nil si aucun)
function SquadBehavior.nearest(from: Vector3, candidates: { Model }): Model?
	local best: Model? = nil
	local bestDistance = math.huge
	for _, model in candidates do
		if model.Parent then
			local distance = (model:GetPivot().Position - from).Magnitude
			if distance < bestDistance then
				best, bestDistance = model, distance
			end
		end
	end
	return best
end

return SquadBehavior
