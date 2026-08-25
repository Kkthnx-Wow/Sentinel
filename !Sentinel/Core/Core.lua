-- Sentinel: Core.lua
-- Loads last. Wires together capture notifications, alerts, slash commands, the
-- settings panel, and the public API. Uses an event dispatch table rather than an
-- if/elseif chain (optimization section 5).

local addonName, ns = ...
local DB = ns.DB
local UI = ns.UI
local L = ns.L
local Format = ns.Format
local TaintLog = ns.TaintLog

local GetTime = ns.G.GetTime

local SOUND_KIT = 48942 -- short alert blip
local ALERT_THROTTLE = 3 -- seconds between sound + chat alerts

local lastAlert = 0

-----------------------------------------------------------------------
-- React to a newly captured error
-----------------------------------------------------------------------
-- Fire the noisy alerts (sound + chat + auto-open). Throttled so a burst of new
-- errors can't flood the chat frame or play sounds every frame.
local function runAlerts(errorObject)
	local config = DB.config

	local now = GetTime()
	local alerting = now > lastAlert
	if alerting then
		lastAlert = now + ALERT_THROTTLE
	end

	if alerting and config.sound then
		PlaySound(SOUND_KIT, "Master")
	end

	if alerting and config.chat then
		local link = errorObject and Format.GetChatLink(errorObject)
		if link and link ~= "" then
			-- Clickable chat link that routes through SetItemRef into UI.OpenToError.
			ns.Print(L["A new error was caught: %s"]:format(link))
		else
			ns.Print(L["A new error was caught. Type /sentinel to view it."])
		end
	end

	-- Auto-open never happens during combat, since a window that fights Escape and
	-- focus under lockdown is a nuisance. Queue it for after combat instead.
	if config.autoOpen and not UI.IsShown() then
		if InCombatLockdown() then
			ns.State.reopenAfterCombat = true
		else
			UI.Open()
		end
	end
end

-- EventRegistry invokes a function callback as func(owner, ...triggerArgs), so the
-- args are (owner, errorObject, isNew). We alert only for genuinely new, unique
-- errors. A recurring error still refreshes the window and minimap through the UI
-- subscribers, but it must not replay the sound or re-announce in chat every few
-- seconds. That matches the setting's "new, unique error" wording and the split
-- between grabbed and received reports.
local function onErrorCaptured(_, errorObject, isNew)
	if isNew then
		runAlerts(errorObject)
	end
end

-- Unique owner table. CallbackRegistryMixin forbids the same owner registering an
-- event twice, and the UI files subscribe to this same event with their own owners.
local CB_OWNER = {}
EventRegistry:RegisterCallback("Sentinel.ErrorCaptured", onErrorCaptured, CB_OWNER)

-----------------------------------------------------------------------
-- Chat hyperlinks (LinkTypes.AddOn routed through the "SetItemRef" event)
-----------------------------------------------------------------------
-- Links look like |Haddon:sentinel:<id>|h...|h and are local only. The AddOn link
-- handler just rebroadcasts SetItemRef, and we match on the id, not a fragile
-- tostring of a table.
local LINK_OWNER = {}
EventRegistry:RegisterCallback("SetItemRef", function(_, link)
	local id = link and tonumber(link:match("^addon:sentinel:(%d+)$"))
	if not id then
		return
	end
	local err = DB.GetById(id)
	if err then
		UI.OpenToError(err)
	else
		ns.Print(L["That error is no longer stored."])
	end
end, LINK_OWNER)

-----------------------------------------------------------------------
-- Slash commands
-----------------------------------------------------------------------
SLASH_SENTINEL1 = "/sentinel"
SLASH_SENTINEL2 = "/sen"
-- Fire a genuine runtime error on the next frame so it travels through the error
-- handler with a real stack and locals, which is the most faithful capture test.
local function fireTestError()
	local sentinelTestLocal = "this is a test local captured by Sentinel"
	C_Timer.After(0, function()
		local victim = nil
		-- Deliberate nil index -> raises "attempt to index a nil value".
		---@diagnostic disable-next-line: need-check-nil, undefined-field, inject-field
		victim.thisIsAFakeSentinelTestError = sentinelTestLocal
	end)
end

local function printHelp()
	ns.Print(L["Usage: /sen [help|status|config|clear|pause|resume|sound|chat|test|build]"])
	ns.Print(L["/sen or /sentinel - toggle the error window."])
	ns.Print(L["/sen status - show current capture and alert settings."])
	ns.Print(L["/sen config - open Sentinel settings."])
	ns.Print(L["/sen clear - wipe all stored errors."])
	ns.Print(L["/sen pause - stop capturing new errors."])
	ns.Print(L["/sen resume - start capturing new errors again."])
	ns.Print(L["/sen sound - toggle the new-error sound."])
	ns.Print(L["/sen chat - toggle new-error chat announcements."])
	ns.Print(L["/sen taintlog - cycle Blizzard taintLog level (0-4)."])
	ns.Print(L["/sen test - generate a test error."])
	ns.Print(L["/sen build - print your WoW build information."])
end

local function printStatus()
	local config = DB.config
	local on = L["on"]
	local off = L["off"]
	local captureState
	if config.capturePaused then
		captureState = off
	elseif ns.State.paused then
		captureState = L["paused (flood protection)"]
	else
		captureState = on
	end
	ns.Print(L["Capture"] .. ": " .. captureState)
	ns.Print(L["Sound"] .. ": " .. (config.sound and on or off))
	ns.Print(L["Chat alerts"] .. ": " .. (config.chat and on or off))
	ns.Print(L["Blocked-action capture"] .. ": " .. (config.captureTaint and on or off))
	ns.Print(L["Stored errors"] .. ": " .. tostring(DB.Count()) .. " (" .. L["this session"] .. ": " .. tostring(DB.SessionCount()) .. ")")
	if TaintLog.IsAvailable() then
		local level = TaintLog.GetLevel()
		ns.Print(L["Taint log"] .. ": " .. (level == 0 and off or (level .. " (" .. TaintLog.GetLevelName(level) .. ")")))
	end
end

SlashCmdList.SENTINEL = function(msg)
	msg = (msg or ""):lower():gsub("%s", "")
	if msg == "help" or msg == "?" then
		printHelp()
	elseif msg == "status" then
		printStatus()
	elseif msg == "config" or msg == "options" or msg == "settings" then
		ns.Config.Open()
	elseif msg == "clear" or msg == "wipe" then
		UI.ConfirmWipe()
	elseif msg == "pause" then
		DB.config.capturePaused = true
		ns.Print(L["Error capture is now paused."])
	elseif msg == "resume" or msg == "unpause" then
		DB.config.capturePaused = false
		ns.Print(L["Error capture is now active."])
	elseif msg == "sound" or msg == "mute" then
		DB.config.sound = not DB.config.sound
		ns.Print(DB.config.sound and L["Error sound is now on."] or L["Error sound is now off."])
	elseif msg == "chat" then
		DB.config.chat = not DB.config.chat
		ns.Print(DB.config.chat and L["Error chat alerts are now on."] or L["Error chat alerts are now off."])
	elseif msg == "taintlog" or msg == "taint" then
		if not TaintLog.IsAvailable() then
			ns.Print(L["Taint log is not available on this client."])
		else
			local level = TaintLog.CycleLevel()
			if UI.UpdateTaintLogButton then
				UI.UpdateTaintLogButton()
			end
			ns.Print(TaintLog.GetStatusLine(level))
		end
	elseif msg == "test" then
		ns.Print(L["Generating a test error..."])
		fireTestError()
	elseif msg == "wowbuild" or msg == "build" then
		-- GetBuildInfo returns the client version, build number, build date, and the
		-- numeric interface (TOC) version, everything useful for a bug report.
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
ns.API.IsCapturePaused = function()
	return DB.config.capturePaused
end
ns.API.SetCapturePaused = function(paused)
	DB.config.capturePaused = not not paused
end
ns.API.GetVersion = function()
	return ns.VERSION
end
ns.API.IsFloodPaused = function()
	return ns.State.paused
end
ns.API.GetTaintLogLevel = TaintLog.GetLevel
ns.API.SetTaintLogLevel = TaintLog.SetLevel
ns.API.CycleTaintLogLevel = TaintLog.CycleLevel
ns.API.SendSession = function(player, sessionId)
	return ns.Comm.SendSession(player, sessionId)
end

-- Public format helper for external consumers of the Sentinel API.
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
	-- Alert only when a genuinely new error was captured during load (not a deduped
	-- repeat moved into this session from a prior one).
	if ns.State.hadNewErrorThisLoad then
		runAlerts()
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
