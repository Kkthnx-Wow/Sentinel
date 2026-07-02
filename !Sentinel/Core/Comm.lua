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
local IsSecret = ns.IsSecret
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
		ns.Print(L["Sharing is unavailable (missing libraries). Use Export instead."])
	end
	function Comm.SendSession()
		ns.Print(L["Sharing is unavailable (missing libraries). Use Export instead."])
	end
	return
end

-- Private transport object so we don't expose Ace methods on our public table.
local transport = {}
AceComm:Embed(transport)
AceSerializer:Embed(transport)

-- Protocol version (v1 wraps errors in { v = 1, errors = { ... } }).
local COMM_VERSION = 1

-- Inbound/outbound caps (receive path treats peer data as untrusted).
local MAX_PAYLOAD = 64 * 1024
local MAX_ERRORS_PER_MESSAGE = 50
local MAX_MSG_LEN = 2000
local MAX_BLOCK_LEN = 8000
local MAX_COUNTER = 99999
local RECV_NOTICE_THROTTLE = 5
local RECV_RATE_WINDOW = 60
local RECV_RATE_MAX = 30

local lastRecvNotice = 0
local senderRecvRate = {}
local rateLimitWarned = {}

-----------------------------------------------------------------------
-- Build a serializable, Secret-free copy of an error.
-----------------------------------------------------------------------
local function sanitize(err)
	local copy = {}
	copy.message = ns.NotSecret(err.message) and err.message or "<secret error>"
	copy.stack = (err.stack and ns.NotSecret(err.stack)) and err.stack or nil
	copy.locals = (err.locals and ns.NotSecret(err.locals)) and err.locals or nil
	copy.counter = err.counter
	copy.time = err.time
	return copy
end

local function wrapPayload(errors)
	return { v = COMM_VERSION, errors = errors }
end

-- Accept v1 envelopes and legacy bare arrays from older Sentinel builds.
local function unwrapPayload(payload)
	if type(payload) ~= "table" or IsSecret(payload) then
		return nil
	end
	if payload.v == COMM_VERSION and type(payload.errors) == "table" then
		return payload.errors
	end
	if not payload.v and type(payload[1]) == "table" then
		return payload
	end
	if payload.v and payload.v ~= COMM_VERSION then
		return nil, payload.v
	end
	return nil
end

local function canStoreFromSender(sender)
	local now = time()
	local entry = senderRecvRate[sender]
	if not entry or now - entry.start >= RECV_RATE_WINDOW then
		senderRecvRate[sender] = { start = now, count = 0 }
		entry = senderRecvRate[sender]
	end
	return entry.count < RECV_RATE_MAX
end

local function noteStoredFromSender(sender)
	local entry = senderRecvRate[sender]
	if entry then
		entry.count = entry.count + 1
	end
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

	local payload = transport:Serialize(wrapPayload({ sanitize(errorObject) }))
	transport:SendCommMessage(ns.PREFIX, payload, "WHISPER", player, "BULK")
	ns.Print(L["Sent error to %s."]:format(player))
end

-----------------------------------------------------------------------
-- Send every error from a session (BugSack-style session dump).
-----------------------------------------------------------------------
function Comm.SendSession(player, sessionId)
	if type(player) == "string" then
		player = player:gsub("^%s+", ""):gsub("%s+$", "")
	end
	if type(player) ~= "string" or player == "" then
		ns.Print(L["Enter a valid player name."])
		return
	end
	if ns.G.IsInInstance() then
		ns.Print(L["Cannot send while in an instance (Midnight blocks addon messages there). Use Export instead."])
		return
	end

	sessionId = sessionId or DB.GetSessionId()
	local errors = DB.GetBySession(sessionId)
	local total = #errors
	if total == 0 then
		ns.Print(L["No errors in this session to send."])
		return
	end

	local sendCount = total
	if sendCount > MAX_ERRORS_PER_MESSAGE then
		sendCount = MAX_ERRORS_PER_MESSAGE
		ns.Print(L["Sending %d of %d session errors (message size limit)."]:format(sendCount, total))
	end

	local payloadErrors = {}
	for i = 1, sendCount do
		payloadErrors[i] = sanitize(errors[i])
	end

	local payload = transport:Serialize(wrapPayload(payloadErrors))
	transport:SendCommMessage(ns.PREFIX, payload, "WHISPER", player, "BULK")
	if sendCount == 1 then
		ns.Print(L["Sent error to %s."]:format(player))
	else
		ns.Print(L["Sent %d errors to %s."]:format(sendCount, player))
	end
end

-----------------------------------------------------------------------
-- Receive
-----------------------------------------------------------------------
-- Everything that arrives over the wire is untrusted: a malicious or buggy peer
-- could send an oversized payload, a flood of reports, or junk fields. We bound
-- every dimension before anything touches our SavedVariables or the chat frame.

-- Truncate to a byte budget (returns nil for non-strings or secrets).
local function clip(s, max)
	if type(s) ~= "string" or IsSecret(s) then
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
	if not message or IsSecret(message) then
		return nil
	end
	local errors = DB.GetAll()
	for i = #errors, 1, -1 do
		local e = errors[i]
		if e.source == sender and type(e.message) == "string" and ns.NotSecret(e.message) and e.message == message then
			return e
		end
	end
end

local function onComm(prefix, message, _, sender)
	if prefix ~= ns.PREFIX then
		return
	end
	-- Bound the work *before* deserializing, so a huge blob can't burn memory/CPU.
	if type(message) ~= "string" or IsSecret(message) or #message > MAX_PAYLOAD then
		return
	end
	local ok, payload = transport:Deserialize(message)
	if not ok or type(payload) ~= "table" or IsSecret(payload) then
		return
	end

	local errors, badVersion = unwrapPayload(payload)
	if not errors then
		if badVersion then
			ns.Print(L["Unsupported error report version. Ask the sender to update Sentinel."])
		end
		return
	end

	local session = DB.GetSessionId()
	local received = 0
	local n = #errors
	if n > MAX_ERRORS_PER_MESSAGE then
		n = MAX_ERRORS_PER_MESSAGE
	end
	for i = 1, n do
		local e = errors[i]
		if type(e) == "table" and type(e.message) == "string" and ns.NotSecret(e.message) then
			local msg = clip(e.message, MAX_MSG_LEN)
			if msg then
				local existing = findReceived(msg, sender)
				if existing then
					existing.counter = (existing.counter or 1) + 1
					existing.time = time()
				elseif canStoreFromSender(sender) then
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
					noteStoredFromSender(sender)
				elseif not rateLimitWarned[sender] then
					rateLimitWarned[sender] = true
					ns.Print(L["Too many error reports from %s. Further reports ignored for now."]:format(sender))
				end
				received = received + 1
			end
		end
	end

	if received > 0 then
		-- Throttle the chat line so a peer can't flood the chat frame by whispering
		-- reports in quick succession (the window/badge still update every time).
		local now = GetTime()
		if now > lastRecvNotice then
			lastRecvNotice = now + RECV_NOTICE_THROTTLE
			if received == 1 then
				ns.Print(L["You received an error report from %s."]:format(sender))
			else
				ns.Print(L["You received %d error reports from %s."]:format(received, sender))
			end
		end
		-- A received bug is someone else's, not a fresh local fault. Fire a distinct
		-- event so the displays (window + minimap badge) refresh, but the local alert
		-- pipeline (sound, "a new error was caught" chat, auto-open) stays silent --
		-- matching the proven BugGrabber/BugSack split between "grabbed" and "received".
		EventRegistry:TriggerEvent("Sentinel.ErrorReceived")
	end
end

transport:RegisterComm(ns.PREFIX, onComm)
