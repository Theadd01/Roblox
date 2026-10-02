--!strict
-- Fenêtre de confirmation en un clic (cahier des charges v2, section 3) : titre, texte, une case à
-- cocher facultative (« Attaque continue »...), boutons « Confirmer » et « Annuler ».
--   ConfirmDialog.ask(options) -> (confirmé, case cochée) : attend la réponse du joueur.
-- Une seule fenêtre centrale à la fois (ModalHost) ; Échap annule.

local Players = game:GetService("Players")

local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local ModalHost = require(script.Parent:WaitForChild("ModalHost"))

export type Options = {
	title: string,
	text: string, -- texte enrichi
	confirmText: string?,
	cancelText: string?,
	danger: boolean?, -- bouton de confirmation rouge (déclarer la guerre...)
	toggle: { text: string, value: boolean }?, -- case à cocher
}

local ConfirmDialog = {}

local gui: ScreenGui? = nil

local function screen(): ScreenGui
	local existing = gui
	if existing and existing.Parent then
		return existing
	end
	local created = Instance.new("ScreenGui")
	created.Name = "Confirmation"
	created.ResetOnSpawn = false
	created.DisplayOrder = 30
	created.IgnoreGuiInset = true
	created.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	gui = created
	return created
end

-- Demande une confirmation ; renvoie (confirmé, valeur de la case à cocher)
function ConfirmDialog.ask(options: Options): (boolean, boolean)
	local parent = screen()
	for _, child in parent:GetChildren() do
		child:Destroy()
	end
	local thread = coroutine.running()
	local answered = false
	local toggleValue = if options.toggle then options.toggle.value else false

	local shade = Instance.new("Frame")
	shade.Name = "FondModal"
	shade.Active = true
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = UIStyle.BACKDROP
	shade.BackgroundTransparency = 0.35
	shade.BorderSizePixel = 0
	shade.Visible = false
	shade.Parent = parent
	local desktop = workspace.CurrentCamera.ViewportSize.X >= 600
	local panel = UIStyle.panel("Fenetre", if desktop then UDim.new(0, 440) else UDim.new(1, -24))
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	UIStyle.padding(panel, 14, 16)
	UIStyle.list(panel, 10)
	panel.Parent = shade

	local function finish(confirmed: boolean)
		if answered then
			return
		end
		answered = true
		ModalHost.hide(shade)
		shade:Destroy()
		task.defer(thread, confirmed, toggleValue) -- après le yield, même si la réponse est immédiate
	end

	local title = UIStyle.text("Titre", `<b>{options.title}</b>`, 20, UIStyle.FONT_BOLD)
	title.LayoutOrder = 1
	title.Parent = panel
	local body = UIStyle.text("Texte", options.text, 16, UIStyle.FONT, UIStyle.TEXT_DIM)
	body.LayoutOrder = 2
	body.Parent = panel
	local toggle = options.toggle
	if toggle then
		local box = UIStyle.button("Case", "", false)
		box.LayoutOrder = 3
		box.Size = UDim2.new(1, 0, 0, 40)
		box.TextSize = 16
		box.TextXAlignment = Enum.TextXAlignment.Left
		local function refresh()
			box.Text = `   {if toggleValue then "☑" else "☐"}  {toggle.text}`
			UIStyle.setButtonSelected(box, toggleValue)
		end
		refresh()
		box.Activated:Connect(function()
			toggleValue = not toggleValue
			refresh()
		end)
		box.Parent = panel
	end
	local row = Instance.new("Frame")
	row.Name = "Boutons"
	row.LayoutOrder = 4
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 44)
	local rowLayout = UIStyle.list(row, 8, true)
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	row.Parent = panel
	local cancel = UIStyle.button("Annuler", options.cancelText or "Annuler", false)
	cancel.LayoutOrder = 1
	cancel.Size = UDim2.new(0.4, -4, 1, 0)
	cancel.TextSize = 17
	cancel.Parent = row
	local confirm = UIStyle.button("Confirmer", options.confirmText or "Confirmer", true)
	confirm.LayoutOrder = 2
	confirm.Size = UDim2.new(0.6, -4, 1, 0)
	confirm.TextSize = 17
	if options.danger then
		UIStyle.setButtonColor(confirm, UIStyle.DANGER, UIStyle.TEXT, 0)
	end
	confirm.Parent = row
	cancel.Activated:Connect(function()
		finish(false)
	end)
	confirm.Activated:Connect(function()
		finish(true)
	end)
	if not ModalHost.show(shade, function()
		finish(false)
	end) then
		finish(false)
	end
	return coroutine.yield()
end

return ConfirmDialog
