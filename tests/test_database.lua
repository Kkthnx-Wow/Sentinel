package.path = "tests/?.lua;" .. package.path
local T = require("support")
local eq = T.eq

local function freshDB(saved)
	local env = T.newEnv()
	_G.SentinelDB = saved
	local ns = {}
	T.loadBase(ns)
	return ns, env
end

print("database")

T.case("drops rows that are not tables or lack a string message", function()
	local ns = freshDB({ errors = { 1, { message = "keep", session = 1 }, { message = {} }, "x", { session = 2 } } })
	eq(#ns.DB.errors, 1, "row count")
	eq(ns.DB.errors[1].message, "keep", "survivor")
end)

T.case("session list and badge count skip received reports", function()
	local ns = freshDB({ errors = {}, session = 4 })
	local sid = ns.DB.GetSessionId()
	ns.DB.Store({ message = "local", session = sid })
	ns.DB.Store({ message = "peer", session = sid, source = "Peer-Realm" })
	eq(#ns.DB.GetBySession(sid, {}), 1, "session rows")
	eq(ns.DB.SessionCount(), 1, "session count")
	eq(#ns.DB.GetReceived({}), 1, "received rows")
	eq(ns.DB.Count(), 2, "total rows")
end)

T.case("local lookup ignores a received report with the same message", function()
	local ns = freshDB({ errors = {}, session = 1 })
	ns.DB.Store({ message = "same", session = 2, source = "Peer-Realm" })
	eq(ns.DB.FetchByMessage("same"), nil, "received row must not match")
	local mine = { message = "same", session = 2 }
	ns.DB.Store(mine)
	eq(ns.DB.FetchByMessage("same"), mine, "local row matches")
end)

T.case("over the cap, received reports are evicted before local errors", function()
	local ns = freshDB({ errors = {}, session = 1 })
	ns.MAX_ERRORS = 4
	ns.DB.Store({ message = "l1", session = 2 })
	ns.DB.Store({ message = "r1", session = 2, source = "P" })
	ns.DB.Store({ message = "l2", session = 2 })
	ns.DB.Store({ message = "r2", session = 2, source = "P" })
	ns.DB.Store({ message = "l3", session = 2 })
	local seen = {}
	for _, e in ipairs(ns.DB.errors) do
		seen[e.message] = true
	end
	eq(#ns.DB.errors, 4, "cap held")
	eq(seen.r1, nil, "oldest received evicted")
	eq(seen.l1, true, "oldest local kept")
end)

T.case("with no received reports the oldest local error goes first", function()
	local ns = freshDB({ errors = {}, session = 1 })
	ns.MAX_ERRORS = 2
	ns.DB.Store({ message = "a", session = 2 })
	ns.DB.Store({ message = "b", session = 2 })
	ns.DB.Store({ message = "c", session = 2 })
	eq(#ns.DB.errors, 2, "cap held")
	eq(ns.DB.errors[1].message, "b", "oldest dropped")
end)

T.case("ids are stable and monotonic across a reload", function()
	local saved = { errors = { { message = "old", session = 1, id = 7 } }, session = 1 }
	local ns = freshDB(saved)
	local e = { message = "new", session = 2 }
	ns.DB.Store(e)
	eq(e.id, 8, "next id")
	eq(saved.nextErrorId, 9, "persisted counter")
end)

T.case("session neighbors skip empty logins, received reports and the live session", function()
	local ns = freshDB({ errors = {}, session = 10 })
	local sid = ns.DB.GetSessionId()
	eq(sid, 11, "live session")
	ns.DB.Store({ message = "a", session = 3 })
	ns.DB.Store({ message = "b", session = 7 })
	ns.DB.Store({ message = "peer", session = 9, source = "Peer-Realm" })
	ns.DB.Store({ message = "live", session = sid })
	eq(ns.DB.GetNeighborSession(sid, -1), 7, "newest past session")
	eq(ns.DB.GetNeighborSession(7, -1), 3, "older")
	eq(ns.DB.GetNeighborSession(3, -1), nil, "nothing older")
	eq(ns.DB.GetNeighborSession(3, 1), 7, "newer")
	eq(ns.DB.GetNeighborSession(7, 1), nil, "received session 9 and the live one are skipped")
end)

T.case("rows saved before the size cap are trimmed at load without splitting UTF-8", function()
	local accent = string.char(0xC3, 0xA9) -- e with acute, two bytes
	local ns = freshDB({ errors = { { message = "old", session = 1, locals = accent:rep(6000) } }, session = 1 })
	local locals = ns.DB.errors[1].locals
	assert(#locals <= 8004, "capped: " .. #locals)
	local body = locals:sub(1, -5)
	eq(#body % 2, 0, "no half character left at the cut")
	eq(locals:sub(-4), "\n...", "marker")
end)

T.finish()
