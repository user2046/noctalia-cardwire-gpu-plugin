--!nonstrict
-- Polls `cardwire get` and publishes the current GPU mode so the bar widget
-- and panel can stay in sync without each shelling out on their own.

local KNOWN_MODES = { "integrated", "hybrid", "smart", "manual" }

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function isKnownMode(word: string): boolean
	for _, mode in ipairs(KNOWN_MODES) do
		if word == mode then
			return true
		end
	end
	return false
end

-- IMPORTANT: this used to check KNOWN_MODES in a fixed order and return the
-- first one found ANYWHERE in the output. That meant if `cardwire get`
-- printed anything containing the word "integrated" (e.g. a list of
-- available modes next to the actual current mode), it always won, no
-- matter what the real current mode was. Fixed to prefer an exact match,
-- then an explicit "mode: X" declaration, then the right-most mode word
-- in the text (current-mode lines tend to come after any mode list).
local function parseMode(output: string?): string?
	if output == nil then
		return nil
	end
	local lowered = string.lower(trim(output))

	if isKnownMode(lowered) then
		return lowered
	end

	local declared = string.match(lowered, "mode%s*[:=]%s*(%a+)") or string.match(lowered, "mode is%s+(%a+)")
	if declared and isKnownMode(declared) then
		return declared
	end

	local lastMatch: string? = nil
	for word in string.gmatch(lowered, "%a+") do
		if isKnownMode(word) then
			lastMatch = word
		end
	end
	return lastMatch
end

local function refresh()
	noctalia.runAsync({ "cardwire", "get" }, function(result)
		if result.exitCode == 0 then
			local mode = parseMode(result.stdout)
			if mode then
				noctalia.state.set("mode", mode)
				noctalia.state.set("error", nil)
			else
				noctalia.state.set("error", "parse_failed")
				noctalia.log("cardwire-gpu: could not parse `cardwire get` output: [" .. tostring(result.stdout) .. "]")
			end
		else
			noctalia.log("cardwire-gpu: `cardwire get` failed: " .. tostring(result.stderr))
			noctalia.state.set("error", "get_failed")
		end
	end)
end

local interval = noctalia.getConfig("poll_interval_ms")
if interval == nil then
	interval = 3000
end
noctalia.setUpdateInterval(interval)

-- Fetch once immediately at load instead of waiting for the first interval tick.
refresh()

function update()
	refresh()
end

function onConfigChanged()
	local newInterval = noctalia.getConfig("poll_interval_ms")
	if newInterval ~= nil then
		noctalia.setUpdateInterval(newInterval)
	end
end
