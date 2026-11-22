-- Sentinel: Capture.lua
-- The error-capture engine. It takes over the error handler as early as it can
-- (this file loads near the top of the list), reads the call stack and locals for
-- each fault, and flood-protects so a spamming addon can't tank the frame rate.
-- Error messages can be Secret Values, so we guard those before ever calling
-- tostring on them. Lua warnings arrive as plain text and need no such guard.

local _, ns = ...
local DB = ns.DB
local L = ns.L

local G = ns.G
local issecretvalue = G.issecretvalue
local GetTime = G.GetTime
local time = G.time
local tostring = tostring
local wipe = wipe

-- Hot-path upvalues for the capture path, which can get bursty (optimization section 3).
local State = ns.State
local MAX_PER_SEC = ns.ERRORS_PER_SEC_BEFORE_THROTTLE

-----------------------------------------------------------------------
-- Only one addon can own the error handler at a time. Older error grabbers
-- install their own and then blank out seterrorhandler, which would quietly
-- swallow ours, so we disable the known ones. This takes effect on the next reload.
-----------------------------------------------------------------------
if C_AddOns and C_AddOns.DisableAddOn then
	for _, name in ipairs({ "!BugGrabber", "!BaudErrorFrame", "!Swatter", "!ImprovedErrorFrame" }) do
		-- DisableAddOn throws on a name it doesn't recognize, so wrap it in pcall.
		pcall(C_AddOns.DisableAddOn, name)
	end
end

-----------------------------------------------------------------------
-- Walk the call stack back to the frame where the error actually happened, so
-- the reported trace starts at the real fault site and not inside our handler.
-----------------------------------------------------------------------
local resolveErrorStack
-- Stack height when the client entered captureError. The faulting function is the
-- frame that called the handler, so it sits exactly one level past captureError.
local handlerHeight
-- Last-resort level for clients without GetCallstackHeight: resolveErrorStack,
-- captureStackLocals, storeError, pcall and captureError sit above the fault.
local FIXED_FAULT_LEVEL = 6
local GetCallstackHeight = GetCallstackHeight
do
	local GetErrorCallstackHeight = GetErrorCallstackHeight
	local debugstack = debugstack
	function resolveErrorStack()
		local height = GetCallstackHeight and GetCallstackHeight()
		local errorCallStackHeight = GetErrorCallstackHeight and GetErrorCallstackHeight()
		if errorCallStackHeight and height then
			local debugStackLevel = height - (errorCallStackHeight - 1)
			if debugStackLevel >= 1 then
				return debugstack(debugStackLevel), debugStackLevel
			end
		end
		-- The client sometimes reports no error height. A fixed offset breaks whenever
		-- the capture path changes shape (it once pointed into our own store step), so
		-- measure from the handler's own entry height instead.
		local level = FIXED_FAULT_LEVEL
		if height and handlerHeight then
			level = height - handlerHeight + 2
		end
		return debugstack(level), level
	end
end

local function resolveErrorLocals(level)
	if debuglocals then
		-- The second arg is skipFunctionsAndUserdata. Passing true drops function and
		-- userdata locals, which matches Blizzard's own handler and keeps the dump
		-- small and readable instead of spilling whole tables and closures.
		return debuglocals(level, true)
	end
	return nil
end

-----------------------------------------------------------------------
-- The error handler
-----------------------------------------------------------------------
local msgsAllowed = MAX_PER_SEC
local msgsAllowedLastTime = GetTime()
local lastWarningTime = 0

-- How long the paused state keeps reporting after the last dropped error. The token
-- bucket refills within a tenth of a second, so without a hold the status line and
-- tooltip could never actually show it. It is refreshed on every dropped error, so it
-- only expires once the storm has genuinely stopped.
local FLOOD_PAUSE_HOLD = 5

-- Flood protection is momentary, so the raw State.paused flag is not safe to read from
-- status displays: it is only cleared by the next captured error, which may never come,
-- leaving "paused (flood protection)" showing for the rest of the session. Everything
-- that reports the pause asks this instead, and the flag clears itself once it expires.
function ns.IsFloodPaused()
	local untilTime = State.floodResumeAt
	if untilTime and GetTime() < untilTime then
		return true
	end
	if untilTime then
		-- The hold has lapsed, so stop reporting a pause and let the warning gate reset.
		State.floodResumeAt = nil
		State.paused = false
	end
	return false
end

-- Re-entrancy guard. It is true only while we are in the middle of capturing one
-- error. If a second error fires during that window our own capture code faulted,
-- so we surface it and bail out to avoid an infinite handler loop. This is far more
-- precise than matching on the addon folder name, which wrongly dropped any error
-- that merely mentioned our path (the /sen test error and real Sentinel UI bugs).
local processing = false

-- Highest counter we let a single error reach. Deduped repeats bump this, and a
-- long-lived spammy error would otherwise grow it without bound.
local MAX_COUNTER = 99999

local capBlock = ns.CapBlock

-- Stack and locals can embed Secret Values too. Store readable placeholders instead
-- of opaque values in SavedVariables.
local function captureStackLocals()
	local stack, level = resolveErrorStack()
	stack = stack or "debugstack returned nil."
	local locals = resolveErrorLocals(level) or "debuglocals returned nil."
	if issecretvalue(stack) then
		stack = "<secret stack>"
	end
	if issecretvalue(locals) then
		locals = "<secret locals>"
	end
	return capBlock(stack), capBlock(locals)
end

-- The actual store and dedupe work. Runs behind the re-entrancy guard and inside
-- pcall (see captureError), so a fault in here can never wedge capture. Returns the
-- stored error object and whether it was genuinely new.
local function storeError(errorMessage, isSimple, session)
	local errorObject, index = DB.FetchByMessage(errorMessage)
	local isNew = not errorObject

	if isNew then
		-- A brand new error. Store the bare object first, then enrich it. If
		-- fetching the stack itself errors we still keep the message.
		errorObject = {
			message = errorMessage,
			session = session,
			time = time(),
			counter = 1,
		}
		DB.Store(errorObject)
		if not isSimple then
			errorObject.stack, errorObject.locals = captureStackLocals()
		end
	else
		-- A repeat. Bump the counter, re-stamp time and stack if it is from an older
		-- session or hasn't fired in a while, and float it to the end of the list.
		errorObject.counter = (errorObject.counter or 1) + 1
		if errorObject.counter > MAX_COUNTER then
			errorObject.counter = MAX_COUNTER
		end
		if errorObject.session ~= session then
			DB.Remove(index)
			DB.Store(errorObject)
			errorObject.session = session
			errorObject.time = time()
			if not isSimple then
				errorObject.stack, errorObject.locals = captureStackLocals()
			end
		else
			local now = time()
			local elapsed = now - (errorObject.time or 0)
			errorObject.time = now
			if elapsed > 10 then
				DB.Remove(index)
				DB.Store(errorObject)
			end
			-- Refresh stack/locals on repeats idle more than two minutes so recurring
			-- errors don't keep a stale trace from the first occurrence.
			if not isSimple and elapsed > 120 then
				errorObject.stack, errorObject.locals = captureStackLocals()
			end
		end
	end

	return errorObject, isNew
end

local function captureError(errorMessage, isSimple)
	-- Recorded first, while this is still the frame directly above the fault.
	handlerHeight = GetCallstackHeight and GetCallstackHeight()
	if DB.config.capturePaused then
		return
	end

	-- Flood protection. Refill a token bucket over time, and if we run dry we stop
	-- capturing until the storm passes. That keeps our CPU off the render path.
	local now = GetTime()
	msgsAllowed = msgsAllowed + (now - msgsAllowedLastTime) * MAX_PER_SEC
	msgsAllowedLastTime = now
	if msgsAllowed < 1 then
		-- Refresh the reporting window on every dropped error, so the status line and
		-- tooltip keep showing the pause for as long as the storm lasts.
		State.floodResumeAt = now + FLOOD_PAUSE_HOLD
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

	-- The message can be a Secret Value, and tainted code may not read or tostring it.
	-- Replace it with a readable placeholder instead of bailing: the error is still
	-- counted, listed and alerted, and the stack captured below can still name the
	-- culprit addon. This is the addon's only Secret boundary; everything stored from
	-- here on is a plain string.
	if errorMessage ~= nil and issecretvalue(errorMessage) then
		errorMessage = "<secret error message>"
	else
		errorMessage = tostring(errorMessage)
	end

	-- Re-entrancy guard (see note at declaration).
	if processing then
		print(ns.COLORS.chat .. ns.DISPLAY_NAME .. ":|r", errorMessage)
		return
	end

	local session = DB.GetSessionId()

	-- The store work runs behind the guard AND inside pcall. If our own capture path
	-- ever faults, pcall catches it so the guard is always cleared afterward. Without
	-- this, one fault in here would leave processing stuck true and silently drop
	-- every future error until the next reload.
	processing = true
	local ok, errorObject, isNew = pcall(storeError, errorMessage, isSimple, session)
	processing = false

	if not ok then
		-- errorObject holds the pcall error message here. Surface our own fault once
		-- so a Sentinel bug is visible, but never leave the guard wedged.
		print(ns.COLORS.chat .. ns.DISPLAY_NAME .. ":|r", errorObject)
		return
	end

	if isNew then
		ns.State.hadNewErrorThisLoad = true
	end

	-- Notify displays (window and minimap) without coupling to them. isNew lets the
	-- alert handler in Core.lua sound and announce only for genuinely new errors.
	--
	-- pcall: a subscriber that throws would otherwise re-enter this handler, capture its
	-- own fault, dispatch again, and loop. A failed dispatch becomes one visible chat
	-- line instead of an unbreakable cycle inside the error handler.
	local dispatched, dispatchError = pcall(EventRegistry.TriggerEvent, EventRegistry, "Sentinel.ErrorCaptured", errorObject, isNew)
	if not dispatched then
		print(ns.COLORS.chat .. ns.DISPLAY_NAME .. ":|r", dispatchError)
	end
end

-----------------------------------------------------------------------
-- Event capture for taint and blocked actions, plus Lua warnings
-----------------------------------------------------------------------
local events = {}

do
	local badAddons = {}
	local badAddonCount = 0
	local MAX_BAD_ADDONS = 64
	function events.ADDON_ACTION_FORBIDDEN(event, addonName, addonFunc)
		-- Blocked-action (taint) events are a different class from real Lua errors and
		-- are often just noise from other addons. When the option is off we ignore them
		-- entirely, no capture, no alert, no storage. The flag is read live from DB.config.
		if not DB.config.captureTaint then
			return
		end
		local name = addonName or "<name>"
		-- Only report each offender once, since these can fire continuously.
		if not badAddons[name] then
			-- Bound the map so a long session of unique offenders can't grow forever.
			if badAddonCount >= MAX_BAD_ADDONS then
				wipe(badAddons)
				badAddonCount = 0
			end
			badAddons[name] = true
			badAddonCount = badAddonCount + 1
			captureError(L["[%s] AddOn '%s' tried to call the protected function '%s'."]:format(event, name, addonFunc or "<func>"), true)
		end
	end
	events.ADDON_ACTION_BLOCKED = events.ADDON_ACTION_FORBIDDEN
end

function events.MACRO_ACTION_FORBIDDEN(_, addonFunc)
	if not DB.config.captureTaint then
		return
	end
	captureError(L["Macro tried to call the protected function '%s'."]:format(addonFunc or "<func>"), true)
end
events.MACRO_ACTION_BLOCKED = events.MACRO_ACTION_FORBIDDEN

-- The warning payload is a plain string with no secret tags, and the default
-- ScriptErrorsFrame also treats LUA_WARNING as normal text.
function events.LUA_WARNING(_, warningText)
	-- Warnings are plain text today, but tostring on a secret value would throw from
	-- inside the error handler. Guard it so a secret warning payload can never recurse
	-- back through capture or wedge the handler.
	if warningText ~= nil and issecretvalue(warningText) then
		captureError("LUA_WARNING: <secret>", true)
		return
	end
	captureError("LUA_WARNING: " .. tostring(warningText or ""), true)
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

	-- Stop other addons from quietly hijacking our capture frame.
	local function noop() end
	frame.RegisterEvent = noop
	frame.UnregisterEvent = noop
	frame.SetScript = noop

	-- Stop the default UI from spamming the blue blocked-action popups, since we now
	-- own that information inside the window instead.
	if UIParent then
		UIParent:UnregisterEvent("ADDON_ACTION_FORBIDDEN")
		UIParent:UnregisterEvent("ADDON_ACTION_BLOCKED")
		UIParent:UnregisterEvent("MACRO_ACTION_FORBIDDEN")
		UIParent:UnregisterEvent("MACRO_ACTION_BLOCKED")
	end
	-- On 12.1 and later the UIParent ADDON_ACTION events moved to GameEvent. Wrap
	-- these in pcall so a missing or renamed internal event can't break the install.
	local GameEvent = _G.GameEvent
	if GameEvent and GameEvent.UnregisterInternalEvent then
		pcall(GameEvent.UnregisterInternalEvent, "ADDON_ACTION_BLOCKED")
		pcall(GameEvent.UnregisterInternalEvent, "ADDON_ACTION_FORBIDDEN")
		pcall(GameEvent.UnregisterInternalEvent, "MACRO_ACTION_BLOCKED")
		pcall(GameEvent.UnregisterInternalEvent, "MACRO_ACTION_FORBIDDEN")
	end
	if ScriptErrorsFrame then
		ScriptErrorsFrame:UnregisterEvent("LUA_WARNING")
	end
end

-----------------------------------------------------------------------
-- Install our handler and prevent anyone else from replacing it.
-----------------------------------------------------------------------
local nativeSetErrorHandler = seterrorhandler
nativeSetErrorHandler(captureError)
_G.seterrorhandler = function() end
