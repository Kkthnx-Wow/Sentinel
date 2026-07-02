-- Sentinel: Capture.lua
-- The error-capture engine. Adapted from the proven !BugGrabber design, then
-- hardened for WoW Midnight Secret Values and the optimization guide:
--   * hooks seterrorhandler as early as possible (this file loads near the top)
--   * captures call stack + locals the way Blizzard's own handler does
--   * flood-protects so a spamming addon can't tank the frame rate
--   * never performs string ops on a Secret error message (see Midnight guide)

local _, ns = ...
local DB = ns.DB
local L = ns.L

local G = ns.G
local issecretvalue = G.issecretvalue
local canaccessvalue = G.canaccessvalue
local GetTime = G.GetTime
local time = G.time
local tostring = tostring

-- Hot-path upvalues for the (potentially bursty) capture path (optimization §3).
local State = ns.State
local MAX_PER_SEC = ns.ERRORS_PER_SEC_BEFORE_THROTTLE

-----------------------------------------------------------------------
-- Sentinel must be the sole owner of seterrorhandler. Disable obsolete error
-- grabbers that would otherwise noop seterrorhandler and silently swallow our
-- hook (these take effect next reload; the same approach !BugGrabber uses).
-----------------------------------------------------------------------
if C_AddOns and C_AddOns.DisableAddOn then
	for _, name in ipairs({ "!BugGrabber", "!BaudErrorFrame", "!Swatter", "!ImprovedErrorFrame" }) do
		-- pcall: DisableAddOn throws on names it doesn't recognize.
		pcall(C_AddOns.DisableAddOn, name)
	end
end

-----------------------------------------------------------------------
-- Stack + locals retrieval (lifted from Blizzard's error handler so the
-- reported stack starts at the real fault site, not inside our handler).
-----------------------------------------------------------------------
local GetErrorStack
do
	local GetCallstackHeight = GetCallstackHeight
	local GetErrorCallstackHeight = GetErrorCallstackHeight
	local debugstack = debugstack
	function GetErrorStack()
		local errorCallStackHeight = GetErrorCallstackHeight and GetErrorCallstackHeight()
		if errorCallStackHeight and GetCallstackHeight then
			local errorStackOffset = errorCallStackHeight - 1
			local debugStackLevel = GetCallstackHeight() - errorStackOffset
			return debugstack(debugStackLevel), debugStackLevel
		end
		return debugstack(3), 3
	end
end

local function GetErrorLocals(level)
	if debuglocals then
		return debuglocals(level)
	end
	return nil
end

-----------------------------------------------------------------------
-- The error handler
-----------------------------------------------------------------------
local msgsAllowed = MAX_PER_SEC
local msgsAllowedLastTime = GetTime()
local lastWarningTime = 0

-- Re-entrancy guard: true only while we're in the middle of capturing one error.
-- If a *second* error fires during that window (i.e. our own capture code faulted),
-- we surface it and bail to avoid an infinite handler loop. This is far more precise
-- than matching the addon folder name, which wrongly dropped any error that merely
-- mentioned our path (including the /sen test error and real Sentinel UI bugs).
local processing = false

local function grabError(errorMessage, isSimple)
	if DB.config.capturePaused then
		return
	end

	-- Flood protection. Refill a token bucket over time; if we run dry we stop
	-- capturing until the storm passes (keeps CPU off the render-competing path).
	local now = GetTime()
	msgsAllowed = msgsAllowed + (now - msgsAllowedLastTime) * MAX_PER_SEC
	msgsAllowedLastTime = now
	if msgsAllowed < 1 then
		if not State.paused then
			State.paused = true
			if now > lastWarningTime + 10 then
				ns.Print(L["Capture paused: too many errors per second. Fix or disable the failing addon."])
				lastWarningTime = now
			end
		end
		return
	end
	State.paused = false
	if msgsAllowed > MAX_PER_SEC then
		msgsAllowed = MAX_PER_SEC
	end
	msgsAllowed = msgsAllowed - 1

	-- Midnight guard: check before tostring() -- converting a Secret can throw.
	if errorMessage ~= nil and issecretvalue(errorMessage) then
		print(ns.COLORS.chat .. ns.DISPLAY_NAME .. ":|r", errorMessage)
		return
	end

	errorMessage = tostring(errorMessage)

	-- A Secret string can still surface after tostring; never inspect or dedupe it.
	if issecretvalue(errorMessage) then
		print(ns.COLORS.chat .. ns.DISPLAY_NAME .. ":|r", errorMessage)
		return
	end

	-- Re-entrancy guard (see note at declaration).
	if processing then
		print(ns.COLORS.chat .. ns.DISPLAY_NAME .. ":|r", errorMessage)
		return
	end
	processing = true

	local session = DB.GetSessionId()
	local errorObject, index = DB.FetchByMessage(errorMessage)
	-- Whether this is a genuinely new, unique error (not already stored). The alert
	-- pipeline (sound / chat / auto-open) keys off this so a single recurring error
	-- can't replay the sound every few seconds -- matching the "new, unique error"
	-- wording of the setting. Displays still refresh on repeats (to bump counts).
	local isNew = not errorObject

	if not errorObject then
		-- A brand new error. Store the bare object first, then enrich it; if
		-- fetching the stack itself errors we still keep the message.
		errorObject = {
			message = errorMessage,
			session = session,
			time = time(),
			counter = 1,
		}
		DB.Store(errorObject)
		if not isSimple then
			local stack, level = GetErrorStack()
			errorObject.stack = stack or "debugstack returned nil."
			errorObject.locals = GetErrorLocals(level) or "debuglocals returned nil."
		end
	else
		-- A repeat. Bump the counter; re-stamp time/stack if it's from an older
		-- session or hasn't fired in a while, and float it to the end of the list.
		errorObject.counter = errorObject.counter + 1
		if errorObject.session ~= session then
			DB.Remove(index)
			DB.Store(errorObject)
			errorObject.session = session
			errorObject.time = time()
			if not isSimple then
				local stack, level = GetErrorStack()
				errorObject.stack = stack or "debugstack returned nil."
				errorObject.locals = GetErrorLocals(level) or "debuglocals returned nil."
			end
		else
			local elapsed = time() - errorObject.time
			errorObject.time = time()
			if elapsed > 10 then
				DB.Remove(index)
				DB.Store(errorObject)
			end
			-- BugGrabber: refresh stack/locals on repeats idle >2 minutes so recurring
			-- errors don't keep a stale trace from the first occurrence.
			if not isSimple and elapsed > 120 then
				local stack, level = GetErrorStack()
				errorObject.stack = stack or "debugstack returned nil."
				errorObject.locals = GetErrorLocals(level) or "debuglocals returned nil."
			end
		end
	end

	-- Clear the guard *before* notifying displays: an error raised by the UI
	-- refresh should be captured normally, not swallowed as recursion.
	processing = false

	if isNew then
		ns.State.hadNewErrorThisLoad = true
	end

	-- Notify displays (window + minimap) without coupling to them. isNew lets the
	-- alert handler (Core.lua) sound/announce only for genuinely new errors.
	EventRegistry:TriggerEvent("Sentinel.ErrorCaptured", errorObject, isNew)
end

-----------------------------------------------------------------------
-- Event capture for taint / blocked actions + Lua warnings
-----------------------------------------------------------------------
local events = {}

do
	local badAddons = {}
	function events.ADDON_ACTION_FORBIDDEN(event, addonName, addonFunc)
		-- Opt-out: blocked-action (taint) events are a different class from real Lua
		-- errors and are often just noise from other addons. When disabled we ignore
		-- them entirely -- no capture, no alert, no storage (checked live via DB.config).
		if not DB.config.captureTaint then
			return
		end
		local name = addonName or "<name>"
		-- Only report each offender once -- these can fire continuously.
		if not badAddons[name] then
			badAddons[name] = true
			grabError(L["[%s] AddOn '%s' tried to call the protected function '%s'."]:format(event, name, addonFunc or "<func>"), true)
		end
	end
	events.ADDON_ACTION_BLOCKED = events.ADDON_ACTION_FORBIDDEN
end

function events.MACRO_ACTION_FORBIDDEN(_, addonFunc)
	if not DB.config.captureTaint then
		return
	end
	grabError(L["Macro tried to call the protected function '%s'."]:format(addonFunc or "<func>"), true)
end
events.MACRO_ACTION_BLOCKED = events.MACRO_ACTION_FORBIDDEN

function events.LUA_WARNING(_, warnType, warningText)
	local text = warningText or warnType
	if text ~= nil and (issecretvalue(text) or not canaccessvalue(text)) then
		grabError("LUA_WARNING: <restricted>", true)
		return
	end
	grabError("LUA_WARNING: " .. tostring(text or ""), true)
end

do
	local frame = CreateFrame("Frame")
	frame:SetScript("OnEvent", function(_, event, ...)
		local handler = events[event]
		if handler then
			handler(event, ...)
		end
	end)
	frame:RegisterEvent("ADDON_ACTION_BLOCKED")
	frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
	frame:RegisterEvent("MACRO_ACTION_BLOCKED")
	frame:RegisterEvent("MACRO_ACTION_FORBIDDEN")
	frame:RegisterEvent("LUA_WARNING")

	-- Stop other (possibly abusive) addons from quietly hijacking our capture frame.
	local function noop() end
	frame.RegisterEvent = noop
	frame.UnregisterEvent = noop
	frame.SetScript = noop

	-- Let the default UI stop spamming the user with the blue blocked-action popups;
	-- we now own that information inside the window instead.
	if UIParent then
		UIParent:UnregisterEvent("ADDON_ACTION_FORBIDDEN")
		UIParent:UnregisterEvent("ADDON_ACTION_BLOCKED")
		UIParent:UnregisterEvent("MACRO_ACTION_FORBIDDEN")
		UIParent:UnregisterEvent("MACRO_ACTION_BLOCKED")
	end
	if ScriptErrorsFrame then
		ScriptErrorsFrame:UnregisterEvent("LUA_WARNING")
	end
end

-----------------------------------------------------------------------
-- Install our handler and prevent anyone else from replacing it.
-----------------------------------------------------------------------
local real_seterrorhandler = seterrorhandler
real_seterrorhandler(grabError)
_G.seterrorhandler = function() end
