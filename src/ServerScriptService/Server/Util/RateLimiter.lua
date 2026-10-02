--!strict
-- Limite la fréquence des demandes d'un joueur (anti-spam des RemoteEvent / RemoteFunction).

local Players = game:GetService("Players")

export type RateLimiter = {
	allow: (self: RateLimiter, player: Player) -> boolean,
}

local RateLimiter = {}

-- cooldown : secondes minimum entre deux demandes acceptées d'un même joueur
function RateLimiter.new(cooldown: number): RateLimiter
	local last: { [Player]: number } = {}
	Players.PlayerRemoving:Connect(function(player: Player)
		last[player] = nil
	end)
	return {
		allow = function(_self: RateLimiter, player: Player): boolean
			local now = os.clock()
			local previous = last[player]
			if previous and now - previous < cooldown then
				return false
			end
			last[player] = now
			return true
		end,
	}
end

return RateLimiter
