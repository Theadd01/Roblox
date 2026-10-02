--!strict
-- Messages diplomatiques pour le joueur : guerre déclarée (par lui, contre lui ou par son bloc),
-- proposition reçue, réponse à ses propositions, paix signée, entrée dans un bloc.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Countries = require(Config:WaitForChild("Countries")) :: any
local DiplomacyState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DiplomacyState")) :: any
local Toast = require(script.Parent:WaitForChild("Toast"))
local GameSession = require(script.Parent.Parent:WaitForChild("State"):WaitForChild("GameSession"))
local FrenchNames = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FrenchNames")) :: any

local DiplomacyAlerts = {}

local function nameOf(countryId: unknown): string
	return if typeof(countryId) == "string" and Countries[countryId] then Countries[countryId].name else "?"
end

-- « la Belgique » / « La Belgique » (début de phrase) ; verbe accordé (« les États-Unis refusent »)
local function the(countryId: unknown): string
	return FrenchNames.the(nameOf(countryId))
end
local function The(countryId: unknown): string
	return FrenchNames.The(nameOf(countryId))
end
local function agree(countryId: unknown, singular: string, plural: string): string
	return if FrenchNames.isPlural(nameOf(countryId)) then plural else singular
end

function DiplomacyAlerts.start(countryId: string)
	-- messages seulement tant que le joueur dirige ce pays (il peut en changer : exil)
	local function notify(text: string, kind: string?, sound: string?)
		if Players.LocalPlayer:GetAttribute("Pays") == countryId then
			Toast.show(text, kind, sound)
		end
	end
	local state = ReplicatedStorage:WaitForChild("EtatMonde")
	local diplomatie = state:WaitForChild("Diplomatie")
	local me = state:WaitForChild("Pays"):WaitForChild(countryId)

	-- guerres qui le concernent
	GameSession.track(diplomatie:WaitForChild("Guerres").ChildAdded:Connect(function(war: Instance)
		task.defer(function()
			local a, b = war:GetAttribute("A"), war:GetAttribute("B")
			if a ~= countryId and b ~= countryId then
				return
			end
			local enemy = if a == countryId then b else a
			local declarer = war:GetAttribute("Declarant")
			if declarer == countryId then
				notify(`⚔️ Tu es en guerre contre <b>{the(enemy)}</b>.`, "danger", "Guerre")
			elseif declarer == enemy then
				notify(`⚔️ <b>{The(enemy)}</b> {agree(enemy, "te déclare", "te déclarent")} la guerre !`, "danger", "Guerre")
			else
				notify(`⚔️ Ton bloc entre en guerre : tu combats maintenant <b>{the(enemy)}</b>.`, "danger", "Guerre")
			end
		end)
	end))

	-- paix signée
	GameSession.track(diplomatie:WaitForChild("Treves").ChildAdded:Connect(function(truce: Instance)
		task.defer(function()
			local a, b = truce:GetAttribute("A"), truce:GetAttribute("B")
			if a == countryId or b == countryId then
				local other = if a == countryId then b else a
				notify(`🕊️ Paix signée avec <b>{the(other)}</b> : trêve de 3 minutes.`, "success")
			end
		end)
	end))

	-- propositions reçues, et réponses à ses propositions
	local propositions = diplomatie:WaitForChild("Propositions")
	local function watch(proposal: Instance)
		task.defer(function()
			local from, to, kind = proposal:GetAttribute("De"), proposal:GetAttribute("A"), proposal:GetAttribute("Type")
			if to == countryId and proposal:GetAttribute("Reponse") == nil then
				local what = if kind == "Alliance" then "une alliance" else "la paix"
				notify(`📨 <b>{The(from)}</b> {agree(from, "te propose", "te proposent")} {what} (onglet Diplomatie).`, "info")
			end
			if from == countryId then
				proposal:GetAttributeChangedSignal("Reponse"):Connect(function()
					local answer = proposal:GetAttribute("Reponse")
					local what = if kind == "Alliance" then "ton alliance" else "la paix"
					if answer == "Acceptee" then
						notify(`✅ <b>{The(to)}</b> {agree(to, "accepte", "acceptent")} {what}.`, "success")
					elseif answer == "Refusee" then
						notify(`❌ <b>{The(to)}</b> {agree(to, "refuse", "refusent")} {what}.`, "info")
					elseif answer == "Expiree" then
						notify(`⌛ <b>{The(to)}</b> {agree(to, "n'a", "n'ont")} pas répondu.`, "info")
					end
				end)
			end
		end)
	end
	GameSession.track(propositions.ChildAdded:Connect(watch))

	-- contrats commerciaux : propositions reçues, réponses, ruptures, blocages
	local contrats = state:WaitForChild("Contrats")
	local function watchContract(contract: Instance)
		task.defer(function()
			local seller, buyer = contract:GetAttribute("Vendeur"), contract:GetAttribute("Acheteur")
			if seller ~= countryId and buyer ~= countryId then
				return
			end
			local other = if seller == countryId then buyer else seller
			local proposedByMe = contract:GetAttribute("ProposePar") == countryId
			if contract:GetAttribute("Statut") == "Propose" and not proposedByMe then
				local what = if seller == countryId then "t'acheter" else "te vendre"
				notify(`📦 <b>{The(other)}</b> {agree(other, "propose", "proposent")} de {what} une ressource (onglet Marché, Contrats).`, "info")
			end
			local previous = contract:GetAttribute("Statut")
			contract:GetAttributeChangedSignal("Statut"):Connect(function()
				local status = contract:GetAttribute("Statut")
				local info = contract:GetAttribute("Info")
				local reason = if typeof(info) == "string" and info ~= "" then ` : {info}` else ""
				if status == "Actif" and previous == "Propose" and proposedByMe then
					notify(`✅ <b>{The(other)}</b> {agree(other, "accepte", "acceptent")} ton contrat.`, "success", "Signature")
				elseif status == "Refuse" and proposedByMe then
					notify(`❌ <b>{The(other)}</b> {agree(other, "refuse", "refusent")} ton contrat.`, "info")
				elseif status == "Rompu" then
					notify(`💔 Contrat rompu avec <b>{the(other)}</b>{reason}.`, "danger")
				elseif status == "Bloque" and previous ~= "Bloque" then
					notify(`⛔ Livraisons bloquées avec <b>{the(other)}</b>{reason}.`, "danger")
				elseif status == "Termine" then
					notify(`✔️ Contrat terminé avec <b>{the(other)}</b>.`, "success")
				end
				previous = status
			end)
		end)
	end
	GameSession.track(contrats.ChildAdded:Connect(watchContract))

	-- entrée dans un bloc
	GameSession.track(me:GetAttributeChangedSignal("Bloc"):Connect(function()
		local name = DiplomacyState.blocName(countryId)
		if name then
			notify(`🤝 Tu fais partie du bloc <b>{name}</b> : ses membres se défendent ensemble.`, "success")
		end
	end))
end

return DiplomacyAlerts
