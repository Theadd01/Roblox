--!strict
-- Calculs du marché, partagés par le serveur (qui décide) et le client (qui affiche).
-- Le prix bouge pendant l'échange : acheter q unités d'une ressource de profondeur L
-- fait passer le prix de P à P x e^(q/L), et le coût est la somme de ces prix successifs.

local MarketMath = {}

-- Coût total (crédits) pour acheter `quantity` unités au prix courant `price`
function MarketMath.buyCost(price: number, quantity: number, liquidity: number): number
	local cost = price * liquidity * (math.exp(quantity / liquidity) - 1)
	return math.max(1, math.floor(cost + 0.5))
end

-- Recette totale (crédits) pour vendre `quantity` unités ; ratio = part de la valeur reversée
function MarketMath.sellRevenue(price: number, quantity: number, liquidity: number, ratio: number): number
	local value = price * liquidity * (1 - math.exp(-quantity / liquidity))
	return math.max(0, math.floor(value * ratio))
end

-- Frais de transport d'un pays en guerre (fee : part de la valeur) : achats plus chers, ventes moins payées
function MarketMath.withWarFee(amount: number, fee: number, buying: boolean): number
	return if buying then math.ceil(amount * (1 + fee)) else math.floor(amount * (1 - fee))
end

function MarketMath.priceAfterBuy(price: number, quantity: number, liquidity: number): number
	return price * math.exp(quantity / liquidity)
end

function MarketMath.priceAfterSell(price: number, quantity: number, liquidity: number): number
	return price * math.exp(-quantity / liquidity)
end

-- Historique publié sous forme de texte « 12.1,12.3,... » -> liste de nombres
function MarketMath.parseHistory(text: unknown): { number }
	local list = {}
	if typeof(text) == "string" then
		for part in text:gmatch("[^,]+") do
			local n = tonumber(part)
			if n then
				table.insert(list, n)
			end
		end
	end
	return list
end

-- Variation en % entre le prix actuel (ou le dernier point) et le point d'il y a `back` points
function MarketMath.variation(history: { number }, back: number, current: number?): number
	local n = #history
	if n < 2 then
		return 0
	end
	local old = history[math.max(1, n - back)]
	local now = current or history[n]
	return if old > 0 then (now - old) / old * 100 else 0
end

return MarketMath
