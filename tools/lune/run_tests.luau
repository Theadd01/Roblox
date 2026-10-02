--!nocheck
-- Lance hors de Studio les tests *.spec de ServerScriptService/Tests (mêmes fichiers que
-- LanceurTests dans Studio) : `lune run tools/lune/run_tests.luau [nom de suite...]`.
-- Code de sortie 1 si un test échoue ou si une suite ne se charge pas.

local process = require("@lune/process")
local Harness = require("./harness")

local root = process.cwd
local game = Harness.build(root)
local tests = game:GetService("ServerScriptService"):WaitForChild("Tests")

local wanted: { [string]: boolean } = {}
for _, name in process.args do
	wanted[name] = true
end

local failures = 0
for _, node in tests:GetChildren() do
	if node.ClassName ~= "ModuleScript" or string.sub(node.Name, -5) ~= ".spec" then
		continue
	end
	local suite = string.sub(node.Name, 1, -6)
	if next(wanted) and not wanted[suite] then
		continue
	end
	local ok, run = pcall(Harness.require, node)
	if not ok then
		print(`[Tests] {suite} : impossible de charger ({run})`)
		failures += 1
		continue
	end
	local results = run()
	local passed = 0
	for i, r in results do
		if r.ok then
			passed += 1
			print(`[Tests] {suite} {i} OK : {r.name} ({r.detail})`)
		else
			failures += 1
			print(`[Tests] {suite} {i} ÉCHEC : {r.name} ({r.detail})`)
		end
	end
	print(`[Tests] {suite} : {passed}/{#results} réussis`)
end

process.exit(if failures > 0 then 1 else 0)
