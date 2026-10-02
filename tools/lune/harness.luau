--!nocheck
-- Banc d'essai hors de Studio (Lune) : reconstruit l'arbre des scripts du jeu depuis src/ (même
-- disposition que default.project.json) et charge les ModuleScripts avec un faux `script`, un faux
-- `game` et un `require` qui suit cet arbre. Suffisant pour les modules « purs » (calculs, règles)
-- et leurs tests *.spec ; tout ce qui touche au moteur Roblox (signaux, réseau...) n'existe pas ici.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local Harness = {}

-- ---- Faux arbre d'instances -------------------------------------------------------------------

local Node = {}
Node.__index = function(self, key)
	local method = Node[key]
	if method ~= nil then
		return method
	end
	local children = rawget(self, "_children")
	local child = children and children[key]
	if child then
		return child
	end
	error(`{key} is not a valid member of {rawget(self, "Name")}`, 2)
end

local function newNode(name: string, className: string, parent)
	local node = setmetatable({ Name = name, ClassName = className, Parent = parent, _children = {}, _attributes = {} }, Node)
	if parent then
		parent._children[name] = node
	end
	return node
end

function Node.FindFirstChild(self, name: string)
	return self._children[name]
end

function Node.WaitForChild(self, name: string)
	local child = self._children[name]
	if not child then
		error(`[harness] {self:GetFullName()}.{name} introuvable (WaitForChild)`, 2)
	end
	return child
end

function Node.GetChildren(self)
	local list = {}
	for _, child in self._children do
		table.insert(list, child)
	end
	table.sort(list, function(a, b)
		return a.Name < b.Name
	end)
	return list
end

function Node.GetDescendants(self)
	local list = {}
	for _, child in self:GetChildren() do
		table.insert(list, child)
		for _, d in child:GetDescendants() do
			table.insert(list, d)
		end
	end
	return list
end

function Node.IsA(self, className: string): boolean
	if className == "Instance" or className == self.ClassName then
		return true
	end
	if className == "LuaSourceContainer" then
		return self.ClassName == "ModuleScript" or self.ClassName == "Script" or self.ClassName == "LocalScript"
	end
	return false
end

function Node.GetFullName(self): string
	if self.Parent and self.Parent.ClassName ~= "DataModel" then
		return self.Parent:GetFullName() .. "." .. self.Name
	end
	return self.Name
end

function Node.GetAttribute(self, name: string)
	return self._attributes[name]
end

function Node.SetAttribute(self, name: string, value)
	self._attributes[name] = value
end

function Node.GetAttributes(self)
	return table.clone(self._attributes)
end

function Node.GetService(self, name: string)
	local service = self._children[name]
	if not service then
		service = newNode(name, name, self)
	end
	return service
end

-- ---- Chargement de src/ ------------------------------------------------------------------------

local function scriptInfo(fileName: string): (string?, string?)
	for _, suffix in { { ".server.lua", "Script" }, { ".client.lua", "LocalScript" }, { ".server.luau", "Script" }, { ".client.luau", "LocalScript" }, { ".lua", "ModuleScript" }, { ".luau", "ModuleScript" } } do
		local ext, className = suffix[1], suffix[2]
		if string.sub(fileName, -#ext) == ext then
			return string.sub(fileName, 1, #fileName - #ext), className
		end
	end
	return nil, nil
end

local function mount(dir: string, parent)
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			mount(path, parent:FindFirstChild(entry) or newNode(entry, "Folder", parent))
		else
			local name, className = scriptInfo(entry)
			if name then
				local node = newNode(name, className, parent)
				node._path = path
			end
		end
	end
end

-- Remplacements de modules (module réel -> table de remplacement), le temps d'un test
local overrides: { [any]: any } = {}

function Harness.build(root: string)
	local game = newNode("Game", "DataModel", nil)
	local replicated = game:GetService("ReplicatedStorage")
	local serverScripts = game:GetService("ServerScriptService")
	local starterPlayer = game:GetService("StarterPlayer")
	local playerScripts = newNode("StarterPlayerScripts", "StarterPlayerScripts", starterPlayer)
	mount(root .. "/src/ReplicatedStorage", replicated)
	mount(root .. "/src/ServerScriptService", serverScripts)
	mount(root .. "/src/StarterPlayer/StarterPlayerScripts", playerScripts)
	local workspaceNode = game:GetService("Workspace")
	local clock = 0
	function workspaceNode.GetServerTimeNow(_self)
		return clock
	end
	Harness.game = game
	Harness.workspace = workspaceNode
	Harness.setTime = function(t: number)
		clock = t
	end
	return game
end

-- Random (Roblox) : générateur déterministe simple
local Random = {}
Random.__index = Random
function Random.new(seed: number?)
	return setmetatable({ state = math.floor(seed or 12345) % 2147483647 + 1 }, Random)
end
function Random:NextNumber(min: number?, max: number?): number
	self.state = (self.state * 48271) % 2147483647
	local x = self.state / 2147483647
	if min and max then
		return min + (max - min) * x
	end
	return x
end
function Random:NextInteger(min: number, max: number): number
	return math.floor(self:NextNumber(min, max + 1 - 1e-9))
end

local cache: { [any]: any } = {}

local function requireNode(node)
	if overrides[node] ~= nil then
		return overrides[node]
	end
	if type(node) ~= "table" or not node._path then
		error(`[harness] require d'un objet qui n'est pas un ModuleScript : {tostring(node)}`, 2)
	end
	local cached = cache[node]
	if cached ~= nil then
		return cached
	end
	local source = fs.readFile(node._path)
	local env = setmetatable({
		script = node,
		game = Harness.game,
		workspace = Harness.workspace,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		Color3 = roblox.Color3,
		CFrame = roblox.CFrame,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Enum = roblox.Enum,
		Font = roblox.Font,
		NumberRange = roblox.NumberRange,
		Random = Random,
		Instance = roblox.Instance,
		task = task,
		warn = function(...)
			print("[warn]", ...)
		end,
	}, { __index = _G })
	env.require = requireNode
	local chunk = luau.load(source, { debugName = node:GetFullName(), environment = env })
	local result = chunk()
	cache[node] = result
	return result
end

Harness.require = requireNode

-- Remplace un module (par son nœud) pour les prochains require ; nil retire le remplacement
function Harness.override(node, value)
	overrides[node] = value
	cache[node] = nil
end

function Harness.clearCache()
	table.clear(cache)
end

return Harness
