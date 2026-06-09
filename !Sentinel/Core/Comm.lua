-- Sentinel: Comm.lua
-- Lets you send a caught error to another Sentinel user. Uses AceComm-3.0 for
-- chunked, throttled transport and AceSerializer-3.0 for safe (de)serialization.
--
-- Midnight note: addon messages are blocked entirely while inside an instance, so
-- we refuse to send there and point the user at Export instead (Secret Values guide).

local _, ns = ...
local Comm = ns.Comm
local DB = ns.DB
local L = ns.L
local issecretvalue = ns.G.issecretvalue

local AceComm = LibStub and LibStub("AceComm-3.0", true)
local AceSerializer = LibStub and LibStub("AceSerializer-3.0", true)

-- If the libs failed to load, sharing is simply unavailable (Export still works).
function Comm.IsAvailable()
	return AceComm ~= nil and AceSerializer ~= nil
end

if not Comm.IsAvailable() then
	function Comm.SendError()
		ns.Print("Sharing is unavailable (missing libraries). Use Export instead.")
	end
	return
end

-- Private transport object so we don't expose Ace methods on our public table.
local transport = {}
AceComm:Embed(transport)
AceSerializer:Embed(transport)

-----------------------------------------------------------------------
-- Build a serializable, Secret-free copy of an error.
-----------------------------------------------------------------------
local function sanitize(err)
	local copy = {}
	copy.message = (not issecretvalue(err.message)) and err.message or "<secret error>"
	copy.stack = (err.stack and not issecretvalue(err.stack)) and err.stack or nil
	copy.locals = (err.locals and not issecretvalue(err.locals)) and err.locals or nil
	copy.counter = err.counter
	copy.time = err.time
	return copy
end

-----------------------------------------------------------------------
-- Send
-----------------------------------------------------------------------
function Comm.SendError(player, errorObject)
	-- Trim surrounding whitespace so a stray space from the input box can't make
	-- the whisper miss its target.
	if type(player) == "string" then
		player = player:gsub("^%s+", ""):gsub("%s+$", "")
	end
	if type(player) ~= "string" or player == "" then
		ns.Print(L["Enter a valid player name."])
		return
	end
	if not errorObject then
		ns.Print(L["Nothing selected to send."])
		return
	end
	if ns.G.IsInInstance() then
		ns.Print(L["Cannot send while in an instance (Midnight blocks addon messages there). Use Export instead."])
		return
	end

	local payload = transport:Serialize({ sanitize(errorObject) })
	transport:SendCommMessage(ns.PREFIX, payload, "WHISPER", player, "BULK")
	ns.Print(L["Sent error to %s."]:format(player))
end

-----------------------------------------------------------------------
-- Receive
-----------------------------------------------------------------------
local function onComm(prefix, message, _, sender)
	if prefix ~= ns.PREFIX then
		return
	end
	local ok, errors = transport:Deserialize(message)
	if not ok or type(errors) ~= "table" then
		return
	end

	local session = DB.GetSessionId()
	local received = 0
	for i = 1, #errors do
		local e = errors[i]
		if type(e) == "table" and type(e.message) == "string" then
			e.source = sender
			e.session = session
			e.counter = e.counter or 1
			DB.Store(e)
			received = received + 1
		end
	end

	if received > 0 then
		ns.Print(L["You received an error report from %s."]:format(sender))
		-- A received bug is someone else's, not a fresh local fault. Fire a distinct
		-- event so the displays (window + minimap badge) refresh, but the local alert
		-- pipeline (sound, "a new error was caught" chat, auto-open) stays silent --
		-- matching the proven BugGrabber/BugSack split between "grabbed" and "received".
		EventRegistry:TriggerEvent("Sentinel.ErrorReceived")
	end
end

transport:RegisterComm(ns.PREFIX, onComm)
