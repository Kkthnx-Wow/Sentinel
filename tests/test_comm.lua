package.path = "tests/?.lua;" .. package.path
local T = require("support")
local eq = T.eq

local PREFIX = "Sentinel"
local MAX_PAYLOAD = 64 * 1024

-- Real LibStub and AceSerializer, so size limits are measured on genuine wire
-- strings. Only the chat transport is faked, it records what would be whispered.
local function freshComm()
	local env = T.newEnv()
	T.loadLib("LibStub/LibStub.lua")
	T.loadLib("AceSerializer-3.0/AceSerializer-3.0.lua")

	local sent = {}
	local fakeComm = _G.LibStub:NewLibrary("AceComm-3.0", 1)
	function fakeComm:Embed(transport)
		transport.RegisterComm = function() end
		transport.SendCommMessage = function(_, prefix, text, dist, player, prio)
			sent[#sent + 1] = { prefix = prefix, text = text, dist = dist, target = player, prio = prio }
		end
	end

	local ns = {}
	T.loadBase(ns)
	T.load(ns, "Core/Format.lua")
	T.load(ns, "Core/Comm.lua")
	local serializer = _G.LibStub("AceSerializer-3.0")
	return ns, env, sent, serializer
end

local function decode(serializer, message)
	local ok, payload = serializer:Deserialize(message.text)
	assert(ok, "sent message must deserialize")
	return payload
end

local function bigStack(n)
	return ("x"):rep(n)
end

print("comm")

T.case("a session of large errors is split so no message passes the receiver cap", function()
	local ns, _, sent, serializer = freshComm()
	local sid = ns.DB.GetSessionId()
	for i = 1, 50 do
		ns.DB.Store({ message = "err " .. i, session = sid, stack = bigStack(7500), locals = bigStack(7500), counter = 1 })
	end
	ns.Comm.SendSession("Friend", sid)
	assert(#sent > 1, "expected several messages")
	local total = 0
	for _, m in ipairs(sent) do
		eq(m.dist, "WHISPER", "distribution")
		assert(#m.text <= MAX_PAYLOAD, "message over the receiver cap: " .. #m.text)
		total = total + #decode(serializer, m).errors
	end
	eq(total, 50, "every error delivered")
end)

T.case("an oversized session sends the newest errors", function()
	local ns, _, sent, serializer = freshComm()
	local sid = ns.DB.GetSessionId()
	for i = 1, 60 do
		ns.DB.Store({ message = "err " .. i, session = sid, counter = 1 })
	end
	ns.Comm.SendSession("Friend", sid)
	local seen = {}
	for _, m in ipairs(sent) do
		for _, e in ipairs(decode(serializer, m).errors) do
			seen[e.message] = true
		end
	end
	eq(seen["err 60"], true, "newest sent")
	eq(seen["err 11"], true, "50th newest sent")
	eq(seen["err 10"], nil, "older dropped")
end)

T.case("a session send never relays reports received from others", function()
	local ns, _, sent, serializer = freshComm()
	local sid = ns.DB.GetSessionId()
	ns.DB.Store({ message = "mine", session = sid, counter = 1 })
	ns.DB.Store({ message = "theirs", session = sid, source = "Peer-Realm", counter = 1 })
	ns.Comm.SendSession("Friend", sid)
	local errors = decode(serializer, sent[1]).errors
	eq(#errors, 1, "entries")
	eq(errors[1].message, "mine", "entry")
end)

T.case("outgoing text is clipped to the limits the receiver enforces", function()
	local ns, _, sent, serializer = freshComm()
	ns.Comm.SendError("Friend", { message = bigStack(10000), stack = bigStack(20000), counter = 1 })
	local e = decode(serializer, sent[1]).errors[1]
	assert(#e.message <= 2003, "message not clipped")
	assert(#e.stack <= 8003, "stack not clipped")
end)

T.case("player names are trimmed and empty ones rejected", function()
	local ns, env, sent = freshComm()
	ns.Comm.SendError("   ", { message = "m" })
	eq(#sent, 0, "nothing sent")
	ns.Comm.SendError("  Friend  ", { message = "m" })
	eq(sent[1].target, "Friend", "trimmed target")
	assert(env.printed[#env.printed]:find("Friend"), "confirmation names the player")
end)

T.case("a full 50 error message from one peer is stored whole", function()
	local ns, _, sent, serializer = freshComm()
	local errors = {}
	for i = 1, 50 do
		errors[i] = { message = "peer err " .. i, counter = 1 }
	end
	local text = serializer:Serialize({ v = 1, errors = errors })
	assert(sent, "fake transport loaded")
	ns.Comm._onComm(PREFIX, text, "WHISPER", "Peer-Realm")
	eq(#ns.DB.GetReceived({}), 50, "stored")
end)

T.case("per-sender rate limit caps stores and the received count stays honest", function()
	local ns, env, _, serializer = freshComm()
	for batch = 1, 4 do
		local errors = {}
		for i = 1, 50 do
			errors[i] = { message = ("flood %d-%d"):format(batch, i), counter = 1 }
		end
		ns.Comm._onComm(PREFIX, serializer:Serialize({ v = 1, errors = errors }), "WHISPER", "Spammer-Realm")
	end
	eq(#ns.DB.GetReceived({}), 120, "stored up to the window cap")
	local limited = false
	for _, line in ipairs(env.printed) do
		if line:find("Too many error reports") then
			limited = true
		end
	end
	eq(limited, true, "rate limit notice shown")
end)

T.case("repeat reports merge and the counter is capped", function()
	local ns, _, _, serializer = freshComm()
	local text = serializer:Serialize({ v = 1, errors = { { message = "dup", counter = 99999 } } })
	ns.Comm._onComm(PREFIX, text, "WHISPER", "Peer-Realm")
	ns.Comm._onComm(PREFIX, text, "WHISPER", "Peer-Realm")
	local received = ns.DB.GetReceived({})
	eq(#received, 1, "one row")
	eq(received[1].counter, 99999, "capped counter")
end)

T.case("oversized, wrong-prefix and malformed payloads are ignored", function()
	local ns, _, _, serializer = freshComm()
	ns.Comm._onComm(PREFIX, ("x"):rep(MAX_PAYLOAD + 1), "WHISPER", "P")
	ns.Comm._onComm("Other", serializer:Serialize({ v = 1, errors = { { message = "m" } } }), "WHISPER", "P")
	ns.Comm._onComm(PREFIX, "not a serialized table", "WHISPER", "P")
	ns.Comm._onComm(PREFIX, serializer:Serialize({ v = 1, errors = { { message = 42 }, "junk" } }), "WHISPER", "P")
	eq(ns.DB.Count(), 0, "nothing stored")
end)

T.case("received data keeps only the known fields and our own clock", function()
	local ns, env, _, serializer = freshComm()
	local text = serializer:Serialize({ v = 1, errors = { { message = "m", time = 1, evil = "x", session = 99 } } })
	ns.Comm._onComm(PREFIX, text, "WHISPER", "Peer-Realm")
	local e = ns.DB.GetReceived({})[1]
	eq(e.evil, nil, "extra field dropped")
	eq(e.time, env.clock, "local timestamp")
	eq(e.session, ns.DB.GetSessionId(), "local session")
	eq(e.source, "Peer-Realm", "source")
end)

T.finish()
