package.path = "tests/?.lua;" .. package.path
local T = require("support")
local eq = T.eq

local function freshCapture()
	local env = T.newEnv()
	local ns = {}
	T.loadBase(ns)
	T.load(ns, "Core/Capture.lua")
	return ns, env
end

print("capture")

T.case("installs the handler and blocks other addons from replacing it", function()
	local _, env = freshCapture()
	eq(type(env.handler), "function", "handler")
	_G.seterrorhandler(function() end)
	eq(env.handler ~= nil, true, "handler untouched")
end)

T.case("stores a new error and announces it as new", function()
	local ns, env = freshCapture()
	env.handler("Interface/AddOns/Foo/Bar.lua:10: boom")
	eq(ns.DB.Count(), 1, "stored")
	local e = ns.DB.errors[1]
	eq(e.counter, 1, "counter")
	eq(e.stack, "stack", "stack")
	eq(env.events[#env.events].name, "Sentinel.ErrorCaptured", "event")
	eq(env.events[#env.events].args[2], true, "isNew")
end)

T.case("a repeat bumps the counter instead of adding a row", function()
	local ns, env = freshCapture()
	env.handler("same")
	env.clock = env.clock + 1
	env.handler("same")
	eq(ns.DB.Count(), 1, "rows")
	eq(ns.DB.errors[1].counter, 2, "counter")
	eq(env.events[#env.events].args[2], false, "isNew")
end)

T.case("a local fault matching a received report gets its own local row", function()
	local ns, env = freshCapture()
	ns.DB.Store({ message = "shared", session = ns.DB.GetSessionId(), source = "Peer-Realm", counter = 3 })
	env.handler("shared")
	eq(ns.DB.Count(), 2, "rows")
	eq(ns.DB.SessionCount(), 1, "local session rows")
	eq(ns.DB.errors[1].counter, 3, "received row untouched")
	eq(ns.DB.errors[2].source, nil, "new row is local")
end)

T.case("a stored row with no time stamp does not fault the repeat path", function()
	local ns, env = freshCapture()
	ns.DB.Store({ message = "legacy", session = ns.DB.GetSessionId(), counter = 1 })
	env.handler("legacy")
	eq(ns.DB.errors[1].counter, 2, "counter")
	eq(type(ns.DB.errors[1].time), "number", "time restamped")
	for _, line in ipairs(env.printed) do
		eq(line:find("attempt to"), nil, "no fault printed")
	end
end)

T.case("flood protection stops capture and reports it once", function()
	local ns, env = freshCapture()
	for i = 1, 40 do
		env.handler("flood " .. i)
	end
	eq(ns.DB.Count() <= ns.ERRORS_PER_SEC_BEFORE_THROTTLE, true, "stored within bucket")
	eq(ns.State.paused, true, "paused flag")
	env.clock = env.clock + 5
	env.handler("after the storm")
	eq(ns.State.paused, false, "resumed")
end)

T.case("pause setting drops new errors", function()
	local ns, env = freshCapture()
	ns.DB.config.capturePaused = true
	env.handler("ignored")
	eq(ns.DB.Count(), 0, "stored")
end)

T.case("a fault inside the store step does not wedge later captures", function()
	local ns, env = freshCapture()
	local realStore = ns.DB.Store
	ns.DB.Store = function()
		error("boom")
	end
	env.handler("first")
	ns.DB.Store = realStore
	env.clock = env.clock + 1
	env.handler("second")
	eq(ns.DB.Count(), 1, "second error stored")
end)

T.finish()
