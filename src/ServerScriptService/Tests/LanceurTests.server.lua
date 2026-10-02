--!strict
-- Lance les tests automatisés au démarrage d'une partie dans Studio (jamais sur les vrais serveurs)
-- et écrit le résultat dans la fenêtre Output : « [Tests] Combat : 5/5 réussis »,
-- « [Tests] Ravitaillement : 2/2 réussis », « [Tests] Généraux : 1/1 réussis » (scénarios 1 à 9).

local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

local suites = {
	{ name = "Combat", module = script.Parent:WaitForChild("Combat.spec") },
	{ name = "Ravitaillement", module = script.Parent:WaitForChild("Supply.spec") },
	{ name = "Généraux", module = script.Parent:WaitForChild("Generals.spec") },
	{ name = "Revenus", module = script.Parent:WaitForChild("Income.spec") },
	{ name = "Économie", module = script.Parent:WaitForChild("Economy.spec") },
	{ name = "Population", module = script.Parent:WaitForChild("Population.spec") },
	{ name = "Bâtiments", module = script.Parent:WaitForChild("Buildings.spec") },
	{ name = "Recherche", module = script.Parent:WaitForChild("Research.spec") },
}

for _, suite in suites do
	local ok, run = pcall(require, suite.module)
	if not ok then
		warn(`[Tests] {suite.name} : impossible de charger les tests ({run})`)
		continue
	end
	local results = (run :: any)()
	local passed = 0
	for i, r in results do
		if r.ok then
			passed += 1
			print(`[Tests] {suite.name} {i} OK : {r.name} ({r.detail})`)
		else
			warn(`[Tests] {suite.name} {i} ÉCHEC : {r.name} ({r.detail})`)
		end
	end
	print(`[Tests] {suite.name} : {passed}/{#results} réussis`)
end
