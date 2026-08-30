--!nonstrict
-- Bar widget: shows the active GPU mode (glyph + label) and opens the
-- picker panel on click. State comes from service.luau over noctalia.state.

local PANEL_ID = "you/cardwire-gpu:panel"

local GLYPH = {
	integrated = "leaf",
	hybrid = "topology-star-3",
	smart = "bolt",
	manual = "adjustments",
}

local currentMode: string = noctalia.state.get("mode") or "hybrid"
local hasError: boolean = noctalia.state.get("error") ~= nil

noctalia.state.watch("mode", function(value)
	if value then
		currentMode = value
	end
end)

noctalia.state.watch("error", function(value)
	hasError = value ~= nil
end)

function update()
	noctalia.setUpdateInterval(1000)

	if hasError then
		barWidget.setGlyph("alert-triangle")
		barWidget.setText(noctalia.tr("widget.error"))
		barWidget.setTooltip(noctalia.tr("widget.error.tooltip"))
		return
	end

	barWidget.setGlyph(GLYPH[currentMode] or "cpu")
	barWidget.setText(noctalia.tr("mode." .. currentMode))
	barWidget.setTooltip(noctalia.tr("widget.tooltip"))
end

function onClick()
	noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
	noctalia.togglePanel(PANEL_ID)
end
