--!strict
-- Arbitre léger des fenêtres centrales : une seule modale peut rester ouverte.
-- Une modale prioritaire peut bloquer les ouvertures ordinaires ; Échap ne ferme
-- que les modales qui l'autorisent.

local UserInputService = game:GetService("UserInputService")

type CloseCallback = () -> ()
export type ShowOptions = {
	priority: number?,
	dismissOnEscape: boolean?,
}
type Entry = {
	surface: GuiObject,
	onClosed: CloseCallback?,
	priority: number,
	dismissOnEscape: boolean,
}

local ModalHost = {}
local current: Entry? = nil

local function closeEntry(entry: Entry, notify: boolean)
	if entry.surface.Parent then
		entry.surface.Visible = false
	end
	if notify and entry.onClosed then
		task.defer(entry.onClosed)
	end
end

local function activeEntry(): Entry?
	local active = current
	if active and not active.surface.Parent then
		-- Une interface peut être détruite avec toute sa ScreenGui lors d'un
		-- changement de partie. Ne laisse jamais cette référence bloquer la suite.
		current = nil
		closeEntry(active, true)
		return nil
	end
	return active
end

function ModalHost.show(surface: GuiObject, onClosed: CloseCallback?, options: ShowOptions?): boolean
	local priority = if options and options.priority ~= nil then options.priority else 0
	local dismissOnEscape = if options and options.dismissOnEscape ~= nil then options.dismissOnEscape else true
	local active = activeEntry()
	if active and active.surface ~= surface then
		if active.priority > priority then
			-- Une décision bloquante reste au premier plan. La surface refusée est
			-- remise dans son état fermé, ainsi que son éventuel état applicatif.
			if surface.Parent then
				surface.Visible = false
			end
			if onClosed then
				task.defer(onClosed)
			end
			return false
		end
		closeEntry(active, true)
	end
	current = {
		surface = surface,
		onClosed = onClosed,
		priority = priority,
		dismissOnEscape = dismissOnEscape,
	}
	surface.Visible = true
	return true
end

function ModalHost.hide(surface: GuiObject?)
	local active = activeEntry()
	if active and (surface == nil or active.surface == surface) then
		current = nil
		closeEntry(active, true)
	elseif surface and surface.Parent then
		surface.Visible = false
	end
end

-- Ferme la fenêtre courante seulement si elle n'est pas plus prioritaire que
-- l'écran qui va s'ouvrir. Sert notamment au choix du pays, qui peut remplacer
-- une fenêtre ordinaire sans interrompre une décision obligatoire.
function ModalHost.hideAtMost(priority: number): boolean
	local active = activeEntry()
	if active and active.priority <= priority then
		ModalHost.hide(active.surface)
		return true
	end
	return false
end

function ModalHost.toggle(surface: GuiObject, onClosed: CloseCallback?, options: ShowOptions?): boolean
	if surface.Visible then
		ModalHost.hide(surface)
		return false
	else
		return ModalHost.show(surface, onClosed, options)
	end
end

function ModalHost.isOpen(surface: GuiObject): boolean
	local active = activeEntry()
	return active ~= nil and (active :: Entry).surface == surface and surface.Visible
end

UserInputService.InputBegan:Connect(function(input: InputObject, _processed: boolean)
	local active = activeEntry()
	-- Le menu Roblox marque souvent Échap comme déjà traité. La fenêtre de jeu
	-- doit tout de même se fermer, comme le faisait l'ancien écran Commerce.
	if input.KeyCode == Enum.KeyCode.Escape and active and active.dismissOnEscape then
		ModalHost.hide()
	end
end)

return ModalHost

