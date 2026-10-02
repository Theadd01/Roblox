--!strict
-- Script autonome : évite de modifier le point d'entrée principal pendant que
-- d'autres systèmes du jeu sont encore en développement.

local MonetizationService = require(script.Parent:WaitForChild("Monetization"):WaitForChild("MonetizationService"))

MonetizationService.init()
