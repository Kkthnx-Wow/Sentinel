-- Sentinel: Core.lua
-- Loads last. Wires together capture notifications, alerts, slash commands, the
-- settings panel, and the public API. Uses an event dispatch table (optimization
-- guide section 5) rather than an if/elseif chain.

local addonName, ns = ...
local DB = ns.DB
local UI = ns.UI
local L = ns.L

local GetTime = ns.G.GetTime

local SOUND_KIT = 48942 -- short alert blip
local ALERT_THROTTLE = 3 -- seconds between sound + chat alerts

local lastAlert = 0

-----------------------------------------------------------------------
-- React to a newly captured error
-----------------------------------------------------------------------
local function onErrorCaptured()
	local config = DB.config

	-- Throttle the noisy alerts (sound + chat) so a spamming error can't flood
	-- the chat frame or play sounds every frame.
	local now = GetTime()
	local alerting = now > lastAlert
	if alerting then
		lastAlert = now + ALERT_THROTTLE
	end

	if alerting and config.sound then
		PlaySound(SOUND_KIT, "Master")
	end

	if alerting and config.chat then
		ns.Print(L["A new error was caught. Type /sentinel to view it."])
	end

	-- Auto-open, but never during combat (avoids fighting the secure/lockdown
	-- environment -- optimization guide section 9).
	if config.autoOpen and not InCombatLockdown() and not UI.IsShown() then
		UI.Open()
	end
end

-- Unique owner table (CallbackRegistryMixin forbids the same owner registering an
-- event twice; the UI files subscribe to this same event with their own owners).
local CB_OWNER = {}
EventRegistry:RegisterCallback("Sentinel.ErrorCaptured", onErrorCaptured, CB_OWNER)

-----------------------------------------------------------------------
-- Slash commands
-----------------------------------------------------------------------
SLASH_SENTINEL1 = "/sentinel"
SLASH_SENTINEL2 = "/sen"
-- Fire a genuine runtime error on the next frame so it travels through
-- seterrorhandler with a real stack + locals -- the most faithful capture test.
local function fireTestError()
	local sentinelTestLocal = "this is a test local captured by Sentinel"
	C_Timer.After(0, function()
		local victim = nil
		-- Deliberate nil index -> raises "attempt to index a nil value".
		return victim.thisIsAFakeSentinelTestError .. sentinelTestLocal
	end)
end

SlashCmdList.SENTINEL = function(msg)
	msg = (msg or ""):lower():gsub("%s", "")
	if msg == "config" or msg == "options" or msg == "settings" then
		ns.Config.Open()
	elseif msg == "clear" or msg == "wipe" then
		DB.Reset()
		if UI.UpdateMinimapCount then
			UI.UpdateMinimapCount()
		end
		UI.Refresh()
		ns.Print(L["All stored errors have been wiped."])
	elseif msg == "test" then
		ns.Print("Generating a test error...")
		fireTestError()
	elseif msg == "wowbuild" or msg == "build" then
		-- GetBuildInfo returns the client version, build number, build date, and the
		-- numeric interface (TOC) version -- everything useful for a bug report.
		local version, build, date, tocVersion = GetBuildInfo()
		local label = ns.SYNTAX.varName.code
		local value = ns.SYNTAX.message.code
		local R = "|r"
		ns.Print(label .. "Version" .. R .. ": " .. value .. tostring(version) .. R)
		ns.Print(label .. "Build" .. R .. ": " .. value .. tostring(build) .. R)
		ns.Print(label .. "Build date" .. R .. ": " .. value .. tostring(date) .. R)
		ns.Print(label .. "Interface" .. R .. ": " .. value .. tostring(tocVersion) .. R)
	else
		UI.Toggle()
	end
end

-----------------------------------------------------------------------
-- Public API (read from the `Sentinel` global)
-----------------------------------------------------------------------
ns.API.Open = UI.Open
ns.API.Close = UI.Close
ns.API.Toggle = UI.Toggle
ns.API.GetErrors = DB.GetAll
ns.API.GetSessionId = DB.GetSessionId
ns.API.Reset = DB.Reset

-- Lets other display addons advertise themselves the way BugSack does.
function ns.API.FormatError(err)
	return ns.Format.FormatError(err)
end

-----------------------------------------------------------------------
-- Lifecycle
-----------------------------------------------------------------------
local handlers = {}

function handlers.ADDON_LOADED(loadedAddon)
	if loadedAddon ~= addonName then
		return
	end
	ns.Config.Initialize()
	ns.State.initialized = true
end

function handlers.PLAYER_LOGIN()
	if UI.UpdateMinimapCount then
		UI.UpdateMinimapCount()
	end
	-- If errors were caught during loading (before the player logged in), alert once.
	if DB.SessionCount() > 0 then
		onErrorCaptured()
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event, ...)
	local handler = handlers[event]
	if handler then
		handler(...)
	end
end)
