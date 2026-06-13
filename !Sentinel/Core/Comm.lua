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
local GetTime = ns.G.GetTime
local time = ns.G.time
local floor = math.floor

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
-- Everything that arrives over the wire is untrusted: a malicious or buggy peer
-- could send an oversized payload, a flood of reports, or junk fields. We bound
-- every dimension before anything touches our SavedVariables or the chat frame.
local MAX_PAYLOAD = 64 * 1024 -- drop serialized blobs larger than this (a single report is well under)
local MAX_RECV_PER_MSG = 10 -- process at most this many errors from one message
local MAX_MSG_LEN = 2000 -- truncate the headline message to this many bytes
local MAX_BLOCK_LEN = 8000 -- truncate stack / locals blocks to this many bytes
local MAX_COUNTER = 99999 -- clamp a sender-supplied occurrence count
local RECV_NOTICE_THROTTLE = 5 -- seconds between "received from X" chat lines

local lastRecvNotice = 0

-- Truncate to a byte budget (returns nil for non-strings so optional fields drop).
local function clip(s, max)
	if type(s) ~= "string" then
		return nil
	end
	if #s > max then
		return s:sub(1, max) .. "..."
	end
	return s
end

-- Dedupe: a repeat of the same report from the same sender bumps the existing entry
-- instead of adding another row, mirroring the local capture path. Newest-first scan.
local function findReceived(message, sender)
	local errors = DB.GetAll()
	for i = #errors, 1, -1 do
		local e = errors[i]
		if e.source == sender and e.message == message then
			return e
		end
	end
end

local function onComm(prefix, message, _, sender)
	if prefix ~= ns.PREFIX then
		return
	end
	-- Bound the work *before* deserializing, so a huge blob can't burn memory/CPU.
	if type(message) ~= "string" or #message > MAX_PAYLOAD then
		return
	end
	local ok, errors = transport:Deserialize(message)
	if not ok or type(errors) ~= "table" then
		return
	end

	local session = DB.GetSessionId()
	local received = 0
	local n = #errors
	if n > MAX_RECV_PER_MSG then
		n = MAX_RECV_PER_MSG
	end
	for i = 1, n do
		local e = errors[i]
		if type(e) == "table" and type(e.message) == "string" then
			local msg = clip(e.message, MAX_MSG_LEN)
			local existing = findReceived(msg, sender)
			if existing then
				existing.counter = (existing.counter or 1) + 1
				existing.time = time()
			else
				-- Rebuild from only known fields (never store attacker-controlled
				-- extras) and stamp with our own clock, not the sender's.
				local counter = e.counter
				if type(counter) ~= "number" or counter < 1 then
					counter = 1
				elseif counter > MAX_COUNTER then
					counter = MAX_COUNTER
				end
				DB.Store({
					message = msg,
					stack = clip(e.stack, MAX_BLOCK_LEN),
					locals = clip(e.locals, MAX_BLOCK_LEN),
					counter = floor(counter),
					time = time(),
					session = session,
					source = sender,
				})
			end
			received = received + 1
		end
	end

	if received > 0 then
		-- Throttle the chat line so a peer can't flood the chat frame by whispering
		-- reports in quick succession (the window/badge still update every time).
		local now = GetTime()
		if now > lastRecvNotice then
			lastRecvNotice = now + RECV_NOTICE_THROTTLE
			ns.Print(L["You received an error report from %s."]:format(sender))
		end
		-- A received bug is someone else's, not a fresh local fault. Fire a distinct
		-- event so the displays (window + minimap badge) refresh, but the local alert
		-- pipeline (sound, "a new error was caught" chat, auto-open) stays silent --
		-- matching the proven BugGrabber/BugSack split between "grabbed" and "received".
		EventRegistry:TriggerEvent("Sentinel.ErrorReceived")
	end
end

transport:RegisterComm(ns.PREFIX, onComm)
