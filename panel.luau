--!nonstrict
-- Mode-picker panel. Renders one row per cardwire mode this plugin exposes;
-- tapping a row runs `cardwire set <mode>` and updates shared state on success.
--
-- Switching to/from Hybrid mode blocks or unblocks the dGPU at the syscall
-- level, which can crash anything currently using it -- including an
-- external display physically connected to the dGPU's output, and can leave
-- the running compositor in a stale state until the session restarts.
-- Integrated <-> Smart doesn't need either warning since the dGPU is
-- already blocked on both sides. So we only interrupt with a confirm step
-- (and a follow-up "end session" offer) when exactly one side of the
-- transition is "hybrid".
--
-- Ending the session uses `loginctl terminate-session self`, a systemd-logind
-- call rather than anything compositor-specific -- it works the same way
-- under niri, Hyprland, Sway, GNOME, KDE, etc. as long as the session is
-- tracked by logind (true for essentially every modern Wayland setup).
-- "self" (referring to the caller's own session) has been supported by
-- loginctl since systemd 246 (2020).

-- onClick must be a STRING naming a global function in this file, not a Lua
-- closure. Closures as UI-tree callbacks were only added in Noctalia
-- v5.0.0-beta.5; before that (and this keeps working after, too) the
-- declarative UI tree crosses into the renderer and can only invoke
-- callbacks it can look up by name back in this script's VM.
local MODES = {
	{ key = "integrated", label_key = "mode.integrated", desc_key = "mode.integrated.desc", glyph = "leaf", handler = "onSelectIntegrated" },
	{ key = "hybrid", label_key = "mode.hybrid", desc_key = "mode.hybrid.desc", glyph = "topology-star-3", handler = "onSelectHybrid" },
	{ key = "smart", label_key = "mode.smart", desc_key = "mode.smart.desc", glyph = "bolt", handler = "onSelectSmart" },
}

local function findMode(key: string)
	for _, m in ipairs(MODES) do
		if m.key == key then
			return m
		end
	end
	return nil
end

local currentMode: string = noctalia.state.get("mode") or "hybrid"
local busy = false
local lastErrorText: string? = nil
local pendingMode: string? = nil
local postSwitchOffer = false
local logoutBusy = false

local function needsDisconnectWarning(fromMode: string, toMode: string): boolean
	local fromHybrid = fromMode == "hybrid"
	local toHybrid = toMode == "hybrid"
	return fromHybrid ~= toHybrid
end

local function renderList()
	local children = {}

	table.insert(
		children,
		ui.row({ align = "center", justify = "space_between" }, {
			ui.label({ text = noctalia.tr("panel.title"), fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
			ui.button({ glyph = "close", variant = "ghost", onClick = "onClose" }),
		})
	)

	for _, m in ipairs(MODES) do
		local selected = m.key == currentMode
		table.insert(
			children,
			ui.row({
				key = m.key,
				gap = 10,
				align = "center",
				padding = 10,
				radius = 8,
				fill = selected and "primary/0.15" or "surface_variant/0.4",
				onClick = m.handler,
			}, {
				ui.glyph({ name = m.glyph, size = 18, color = selected and "primary" or "on_surface" }),
				ui.column({ gap = 2, flexGrow = 1 }, {
					ui.label({ text = noctalia.tr(m.label_key), fontWeight = "bold" }),
					ui.label({ text = noctalia.tr(m.desc_key), fontSize = 11, color = "on_surface_variant" }),
				}),
				selected and ui.glyph({ name = "check", size = 16, color = "primary" })
					or ui.box({ width = 16, height = 16 }),
			})
		)
	end

	if busy then
		table.insert(
			children,
			ui.label({ text = noctalia.tr("panel.applying"), fontSize = 11, color = "on_surface_variant" })
		)
	end

	if lastErrorText then
		table.insert(
			children,
			ui.label({ text = lastErrorText, fontSize = 11, color = "error" })
		)
	end

	panel.render(ui.column({ gap = 10, padding = 4 }, children))
end

local function renderConfirm()
	local target = findMode(pendingMode)
	local targetLabel = target and noctalia.tr(target.label_key) or (pendingMode or "")

	panel.render(ui.column({ gap = 12, padding = 4 }, {
		ui.row({ align = "center", justify = "space_between" }, {
			ui.label({ text = noctalia.tr("confirm.title"), fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
			ui.button({ glyph = "close", variant = "ghost", onClick = "onCancelSwitch" }),
		}),
		ui.row({ gap = 10, align = "center", padding = 10, radius = 8, fill = "error/0.12" }, {
			ui.glyph({ name = "alert-triangle", size = 20, color = "error" }),
			ui.column({ gap = 2, flexGrow = 1 }, {
				ui.label({ text = noctalia.tr("confirm.body"), fontSize = 12, color = "on_surface_variant" }),
			}),
		}),
		ui.label({
			text = noctalia.tr("confirm.target_prefix") .. " " .. targetLabel,
			fontSize = 12,
			fontWeight = "bold",
		}),
		ui.row({ gap = 8 }, {
			ui.button({ text = noctalia.tr("confirm.cancel"), variant = "ghost", flexGrow = 1, onClick = "onCancelSwitch" }),
			ui.button({ text = noctalia.tr("confirm.proceed"), variant = "primary", flexGrow = 1, onClick = "onConfirmSwitch" }),
		}),
	}))
end

local function renderLogoutOffer()
	local children = {}

	table.insert(
		children,
		ui.row({ align = "center", justify = "space_between" }, {
			ui.label({ text = noctalia.tr("logout.title"), fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
			ui.button({ glyph = "close", variant = "ghost", onClick = "onDismissLogoutOffer" }),
		})
	)

	table.insert(
		children,
		ui.row({ gap = 10, align = "center", padding = 10, radius = 8, fill = "primary/0.12" }, {
			ui.glyph({ name = "check", size = 20, color = "primary" }),
			ui.column({ gap = 2, flexGrow = 1 }, {
				ui.label({ text = noctalia.tr("logout.body"), fontSize = 12, color = "on_surface_variant" }),
			}),
		})
	)

	if logoutBusy then
		table.insert(
			children,
			ui.label({ text = noctalia.tr("logout.busy"), fontSize = 11, color = "on_surface_variant" })
		)
	else
		table.insert(
			children,
			ui.row({ gap = 8 }, {
				ui.button({ text = noctalia.tr("logout.later"), variant = "ghost", flexGrow = 1, onClick = "onDismissLogoutOffer" }),
				ui.button({ text = noctalia.tr("logout.now"), variant = "destructive", flexGrow = 1, onClick = "onLogoutNow" }),
			})
		)
	end

	panel.render(ui.column({ gap = 12, padding = 4 }, children))
end

local function render()
	if pendingMode then
		renderConfirm()
	elseif postSwitchOffer then
		renderLogoutOffer()
	else
		renderList()
	end
end

local function requestMode(mode: string)
	if busy or mode == currentMode then
		return
	end
	if needsDisconnectWarning(currentMode, mode) then
		pendingMode = mode
		render()
	else
		applyMode(mode, false)
	end
end

function applyMode(mode: string, offerLogout: boolean)
	busy = true
	lastErrorText = nil
	pendingMode = nil
	render()

	noctalia.runAsync({ "cardwire", "set", mode }, function(result)
		busy = false
		if result.exitCode == 0 then
			currentMode = mode
			noctalia.state.set("mode", mode)
			noctalia.state.set("error", nil)
			noctalia.notify(noctalia.tr("notify.title"), noctalia.tr(mode .. ".applied"))
			if offerLogout then
				postSwitchOffer = true
			end
		else
			local detail = result.stderr ~= "" and result.stderr or noctalia.tr("notify.error.body")
			lastErrorText = detail
			noctalia.notifyError(noctalia.tr("notify.error.title"), detail)
		end
		render()
	end)
end

function onSelectIntegrated()
	requestMode("integrated")
end

function onSelectHybrid()
	requestMode("hybrid")
end

function onSelectSmart()
	requestMode("smart")
end

function onConfirmSwitch()
	if pendingMode then
		local mode = pendingMode
		pendingMode = nil
		applyMode(mode, true)
	end
end

function onCancelSwitch()
	pendingMode = nil
	render()
end

function onDismissLogoutOffer()
	postSwitchOffer = false
	render()
end

function onLogoutNow()
	if logoutBusy then
		return
	end
	logoutBusy = true
	render()

	noctalia.runAsync({ "loginctl", "terminate-session", "self" }, function(result)
		logoutBusy = false
		if result.exitCode ~= 0 then
			local detail = result.stderr ~= "" and result.stderr or noctalia.tr("logout.error.body")
			noctalia.notifyError(noctalia.tr("logout.error.title"), detail)
			render()
		end
		-- On success the session ends here; nothing left to render.
	end)
end

noctalia.state.watch("mode", function(value)
	if value and value ~= currentMode then
		currentMode = value
		if not pendingMode and not postSwitchOffer then
			render()
		end
	end
end)

function onOpen(_context)
	currentMode = noctalia.state.get("mode") or currentMode
	lastErrorText = nil
	pendingMode = nil
	postSwitchOffer = false
	logoutBusy = false
	render()
end

function onClose()
	panel.close()
end
