--!strict
-- Stocks des pays : crédits et ressources. Seul le serveur les modifie.
-- Publiés comme attributs de ReplicatedStorage.EtatMonde.Pays.<code> :
--   Credits, Petrole, Gaz, Charbon, MineraiFer, Acier, TerresRares, Puces, Nourriture, Munitions

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Resources = require(Config:WaitForChild("Resources")) :: any
local Economy = require(Config:WaitForChild("Economy")) :: any

local CURRENCY: string = Resources.currency.id

local Stocks = {}

local function isStock(stockId: string): boolean
	return stockId == CURRENCY or Resources.list[stockId] ~= nil
end

local function isAmount(value: unknown): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < 1e12
end

local function folderFor(countryId: string): Instance?
	local state = ReplicatedStorage:FindFirstChild("EtatMonde")
	local pays = state and state:FindFirstChild("Pays")
	return pays and pays:FindFirstChild(countryId)
end

-- À appeler après CountryAssignment.init() (qui crée EtatMonde.Pays)
function Stocks.init()
	local pays = ReplicatedStorage:WaitForChild("EtatMonde"):WaitForChild("Pays")
	for _, folder in pays:GetChildren() do
		folder:SetAttribute(CURRENCY, Economy.startingCredits)
		for _, id in Resources.order do
			folder:SetAttribute(id, Economy.startingStocks[id] or 0)
		end
	end
end

-- Nouvelle partie : stocks de départ pour tous les pays
function Stocks.reset()
	Stocks.init()
end

function Stocks.get(countryId: string, stockId: string): number
	local folder = folderFor(countryId)
	local value = folder and folder:GetAttribute(stockId)
	return if typeof(value) == "number" then value else 0
end

-- Ajoute (ou retire si négatif) ; refuse si le stock deviendrait négatif
function Stocks.add(countryId: string, stockId: string, amount: number): boolean
	local folder = folderFor(countryId)
	if not folder or not isStock(stockId) or not isAmount(amount) then
		return false
	end
	local value = Stocks.get(countryId, stockId) + math.floor(amount)
	if value < 0 then
		return false
	end
	folder:SetAttribute(stockId, value)
	return true
end

-- Ajoute plusieurs ressources d'un coup (production)
function Stocks.addMany(countryId: string, amounts: { [string]: number })
	for stockId, amount in amounts do
		Stocks.add(countryId, stockId, amount)
	end
end

function Stocks.canAfford(countryId: string, costs: { [string]: number }): boolean
	for stockId, amount in costs do
		if not isStock(stockId) or not isAmount(amount) or amount < 0 or Stocks.get(countryId, stockId) < amount then
			return false
		end
	end
	return true
end

-- Dépense tout ou rien : si un seul stock manque, rien n'est retiré
function Stocks.spend(countryId: string, costs: { [string]: number }): boolean
	if not Stocks.canAfford(countryId, costs) then
		return false
	end
	for stockId, amount in costs do
		Stocks.add(countryId, stockId, -amount)
	end
	return true
end

return Stocks
