--!nocheck
-- Réinjecte les scripts de src/ dans une place Roblox existante, sans toucher au reste (carte,
-- modèles, interface, réglages) : `lune run tools/lune/patch_place.luau <entrée.rbxl> <sortie.rbxl>`.
-- Suit default.project.json (dossiers $path) comme Rojo :
--   un dossier -> Folder ; X.server.lua -> Script ; X.client.lua -> LocalScript ; X.lua -> ModuleScript.
-- Les scripts qui n'existent plus dans src/ sont supprimés de la place ; les autres instances
-- (valeurs, remotes...) rangées dans ces dossiers sont gardées.

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local input, output = process.args[1], process.args[2]
if not input or not output then
	print("usage : lune run tools/lune/patch_place.luau <entrée.rbxl> <sortie.rbxl>")
	process.exit(1)
end

local game = roblox.deserializePlace(fs.readFile(input))
local project = serde.decode("json", fs.readFile("default.project.json"))

local stats = { updated = 0, unchanged = 0, created = 0, removed = 0 }
local log = {}

local function classOf(fileName: string): (string?, string?)
	local name = string.match(fileName, "^(.+)%.server%.luau?$")
	if name then
		return name, "Script"
	end
	name = string.match(fileName, "^(.+)%.client%.luau?$")
	if name then
		return name, "LocalScript"
	end
	name = string.match(fileName, "^(.+)%.luau?$")
	if name then
		return name, "ModuleScript"
	end
	return nil, nil
end

local function sync(dir: string, parent)
	local kept = {}
	local entries = fs.readDir(dir)
	table.sort(entries)
	for _, entry in entries do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			local folder = parent:FindFirstChild(entry)
			if not folder then
				folder = roblox.Instance.new("Folder")
				folder.Name = entry
				folder.Parent = parent
				table.insert(log, `+ dossier {folder:GetFullName()}`)
			end
			kept[folder] = true
			sync(path, folder)
		else
			local name, className = classOf(entry)
			if name then
				local source = fs.readFile(path)
				local existing = nil
				for _, child in parent:GetChildren() do
					if child.Name == name and child:IsA("LuaSourceContainer") then
						existing = child
						break
					end
				end
				if existing and existing.ClassName ~= className then
					-- même nom, autre type : on recrée le script et on garde ses enfants
					local replacement = roblox.Instance.new(className)
					replacement.Name = name
					for _, child in existing:GetChildren() do
						child.Parent = replacement
					end
					existing:Destroy()
					replacement.Parent = parent
					existing = replacement
					table.insert(log, `~ type changé {replacement:GetFullName()} ({className})`)
				end
				if not existing then
					existing = roblox.Instance.new(className)
					existing.Name = name
					existing.Parent = parent
					stats.created += 1
					table.insert(log, `+ {className} {existing:GetFullName()}`)
				elseif existing.Source == source then
					stats.unchanged += 1
				else
					stats.updated += 1
					table.insert(log, `* {existing:GetFullName()}`)
				end
				existing.Source = source
				kept[existing] = true
			end
		end
	end
	for _, child in parent:GetChildren() do
		if not kept[child] and child:IsA("LuaSourceContainer") then
			table.insert(log, `- {child.ClassName} {child:GetFullName()}`)
			stats.removed += 1
			child:Destroy()
		end
	end
end

local function walk(node, instance)
	for key, value in node do
		if string.sub(key, 1, 1) ~= "$" then
			local child = instance:FindFirstChild(key)
			if not child then
				if instance == game then
					child = game:GetService(key)
				else
					child = roblox.Instance.new(value["$className"] or "Folder")
					child.Name = key
					child.Parent = instance
					table.insert(log, `+ {child:GetFullName()}`)
				end
			end
			if value["$path"] then
				sync(value["$path"], child)
			end
			walk(value, child)
		end
	end
end

walk(project.tree, game)
table.sort(log)
for _, line in log do
	print(line)
end
fs.writeFile(output, roblox.serializePlace(game))
print(`[Place] {stats.updated} scripts mis à jour, {stats.created} créés, {stats.removed} supprimés, {stats.unchanged} inchangés -> {output}`)
