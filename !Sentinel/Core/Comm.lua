-- Sentinel: Comm.lua
-- Lets you send a caught error to another Sentinel user. Uses AceComm-3.0 for
-- chunked, throttled transport and AceSerializer-3.0 for safe (de)serialization.
--
-- On Midnight, addon messages are blocked entirely while inside an instance, so we
-- refuse to send there and point the user at Export instead.

local _, ns = ...
local Comm = ns.Comm
local DB = ns.DB
local L = ns.L
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

-- Inbound/outbound caps (receive path treats peer data as untrusted). The send path
-- clips to the same limits, so what we send is always something we would accept.
local MAX_PAYLOAD = 64 * 1024
local MAX_ERRORS_PER_MESSAGE = 50
local MAX_MSG_LEN = 2000
local MAX_BLOCK_LEN = 8000
local MAX_COUNTER = 99999
local RECV_NOTICE_THROTTLE = 5
local RECV_RATE_WINDOW = 60
-- One full message of reports must fit inside the window, with room for a second.
local RECV_RATE_MAX = 120
local RECV_RATE_PRUNE_SIZE = 64

-- Serialization escapes some bytes, so a batch stays well under the receiver's
-- MAX_PAYLOAD instead of aiming right at it.
local SEND_BATCH_BUDGET = 30 * 1024
local SEND_ENTRY_OVERHEAD = 64

local lastRecvNotice = 0
local senderRecvRate = {}
local senderRecvRateCount = 0
local rateLimitWarned = {}

-----------------------------------------------------------------------
-- Shared helpers
-----------------------------------------------------------------------
-- Truncate to a byte budget. Returns nil for non-strings so optional fields drop.
-- Deserialized wire data is plain Lua, with no Secret Values on the receive path.
local function clip(s, max)
	if type(s) ~= "string" then
		return nil
	end
	if #s > max then
		return ns.TrimPartialUTF8(s:sub(1, max)) .. "..."
	end
	return s
end

-- Trims a typed player name. Returns nil when nothing usable is left.
local function normalizePlayerName(player)
	if type(player) ~= "string" then
		return nil
	end
	player = player:match("^%s*(.-)%s*$")
	if player == "" then
		return nil
	end
	return player
end

-----------------------------------------------------------------------
-- Build a serializable, Secret-free copy of an error.
-- Capture already refuses to store Secret messages, but we still strip any stack or
-- locals that might have been secret at grab time.
-----------------------------------------------------------------------
local function sanitize(err)
	local copy = {}
	copy.message = (ns.NotSecret(err.message) and clip(err.message, MAX_MSG_LEN)) or "<secret error>"
	copy.stack = (err.stack and ns.NotSecret(err.stack)) and clip(err.stack, MAX_BLOCK_LEN) or nil
	copy.locals = (err.locals and ns.NotSecret(err.locals)) and clip(err.locals, MAX_BLOCK_LEN) or nil
	copy.counter = err.counter
	copy.time = err.time
	return copy
end

local function wrapPayload(errors)
	return { v = COMM_VERSION, errors = errors }
end

-- Accept v1 envelopes and legacy bare arrays from older Sentinel builds.
-- Serialized output is never Secret, so there is no issecretvalue on the wire path.
local function unwrapPayload(payload)
	if type(payload) ~= "table" then
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

-- Per-sender store budget. The table is bounded by dropping expired windows once it
-- grows, so a long session of one-off senders cannot leak entries.
local function pruneSenderRates(now)
	for sender, entry in pairs(senderRecvRate) do
		if now - entry.start >= RECV_RATE_WINDOW then
			senderRecvRate[sender] = nil
			rateLimitWarned[sender] = nil
			senderRecvRateCount = senderRecvRateCount - 1
		end
	end
end

local function canStoreFromSender(sender)
	local now = time()
	local entry = senderRecvRate[sender]
	if not entry or now - entry.start >= RECV_RATE_WINDOW then
		if not entry then
			if senderRecvRateCount >= RECV_RATE_PRUNE_SIZE then
				pruneSenderRates(now)
			end
			senderRecvRateCount = senderRecvRateCount + 1
		end
		entry = { start = now, count = 0 }
		senderRecvRate[sender] = entry
		rateLimitWarned[sender] = nil
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
local function entryWeight(entry)
	return #entry.message + (entry.stack and #entry.stack or 0) + (entry.locals and #entry.locals or 0) + SEND_ENTRY_OVERHEAD
end

local function sendBatch(player, batch)
	transport:SendCommMessage(ns.PREFIX, transport:Serialize(wrapPayload(batch)), "WHISPER", player, "BULK")
end

-- Sends sanitized entries in as many messages as the size budget needs. One oversized
-- message would be dropped whole by the receiver, so large sessions go out in pieces.
local function sendEntries(player, entries)
	local batch, size = {}, 0
	for i = 1, #entries do
		local entry = entries[i]
		local weight = entryWeight(entry)
		if #batch > 0 and (size + weight > SEND_BATCH_BUDGET or #batch >= MAX_ERRORS_PER_MESSAGE) then
			sendBatch(player, batch)
			batch, size = {}, 0
		end
		batch[#batch + 1] = entry
		size = size + weight
	end
	if #batch > 0 then
		sendBatch(player, batch)
	end
end

function Comm.SendError(player, errorObject)
	-- Trim surrounding whitespace so a stray space from the input box can't make
	-- the whisper miss its target.
	player = normalizePlayerName(player)
	if not player then
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

	sendEntries(player, { sanitize(errorObject) })
	ns.Print(L["Sent error to %s."]:format(player))
end

-----------------------------------------------------------------------
-- Send every error from a session.
-----------------------------------------------------------------------
function Comm.SendSession(player, sessionId)
	player = normalizePlayerName(player)
	if not player then
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

	-- Keep the newest errors when the session is over the cap, they are the ones the
	-- player is most likely still chasing.
	local sendCount = total
	if sendCount > MAX_ERRORS_PER_MESSAGE then
		sendCount = MAX_ERRORS_PER_MESSAGE
		ns.Print(L["Sending %d of %d session errors (message size limit)."]:format(sendCount, total))
	end

	local entries = {}
	local first = total - sendCount
	for i = 1, sendCount do
		entries[i] = sanitize(errors[first + i])
	end

	sendEntries(player, entries)
	if sendCount == 1 then
		ns.Print(L["Sent error to %s."]:format(player))
	else
		ns.Print(L["Sent %d errors to %s."]:format(sendCount, player))
	end
end

-----------------------------------------------------------------------
-- Receive
-----------------------------------------------------------------------
-- Everything that arrives over the wire is untrusted. A malicious or buggy peer
-- could send an oversized payload, a flood of reports, or junk fields. We bound
-- every dimension before anything touches our SavedVariables or the chat frame.

-- Dedupe a repeat of the same report from the same sender by bumping the existing
-- entry instead of adding another row, the way the local capture path does. This
-- scans newest first.
local function findReceived(message, sender)
	local errors = DB.GetAll()
	for i = #errors, 1, -1 do
		local e = errors[i]
		if e.source == sender and e.message == message then
			return e
		end
	end
end

-- Stores or merges one wire entry. Returns true when it changed the list.
local function acceptEntry(e, sender, session)
	if type(e) ~= "table" then
		return false
	end
	local msg = clip(e.message, MAX_MSG_LEN)
	if not msg then
		return false
	end

	local existing = findReceived(msg, sender)
	if existing then
		local counter = (existing.counter or 1) + 1
		existing.counter = counter > MAX_COUNTER and MAX_COUNTER or counter
		existing.time = time()
		return true
	end

	if not canStoreFromSender(sender) then
		if not rateLimitWarned[sender] then
			rateLimitWarned[sender] = true
			ns.Print(L["Too many error reports from %s. Further reports ignored for now."]:format(sender))
		end
		return false
	end

	-- Rebuild from only the known fields so we never store attacker controlled
	-- extras, and stamp with our own clock, not the sender's.
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
	return true
end

local function onComm(prefix, message, _, sender)
	if prefix ~= ns.PREFIX then
		return
	end
	-- Bound the work before deserializing so a huge blob can't burn memory or CPU.
	if type(message) ~= "string" or #message > MAX_PAYLOAD then
		return
	end
	local ok, payload = transport:Deserialize(message)
	if not ok or type(payload) ~= "table" then
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
		if acceptEntry(errors[i], sender, session) then
			received = received + 1
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
		-- pipeline (sound, chat announce, auto-open) stays silent.
		EventRegistry:TriggerEvent("Sentinel.ErrorReceived")
	end
end

transport:RegisterComm(ns.PREFIX, onComm)

-- Test seam, headless tests call the receive handler directly.
Comm._onComm = onComm
