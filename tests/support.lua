-- Headless test support. Builds just enough of the WoW environment to load
-- Sentinel's Core files under plain Lua 5.1 and drive them directly.

local Support = {}

local ADDON_DIR = "!Sentinel/"

local function noop() end

local function newFrame()
	return setmetatable({}, {
		__index = function(t, k)
			local fn = noop
			rawset(t, k, fn)
			return fn
		end,
	})
end

-- Fresh fake environment. `clock` is shared by time() and GetTime().
function Support.newEnv()
	local env = { clock = 1000, printed = {}, events = {}, handler = nil }

	_G.wipe = function(t)
		for k in pairs(t) do
			t[k] = nil
		end
		return t
	end
	_G.time = function()
		return env.clock
	end
	_G.GetTime = function()
		return env.clock
	end
	_G.GetBuildInfo = function()
		return "12.1.5", "1", "Jan 1 2026", 120105
	end
	_G.print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[#parts + 1] = tostring((select(i, ...)))
		end
		env.printed[#env.printed + 1] = table.concat(parts, " ")
	end
	_G.IsInInstance = function()
		return false
	end
	_G.C_AddOns = { DisableAddOn = noop, GetAddOnMetadata = function() return "test" end }
	_G.CreateFrame = newFrame
	_G.UIParent = newFrame()
	_G.EventRegistry = {
		TriggerEvent = function(_, name, ...)
			env.events[#env.events + 1] = { name = name, args = { ... } }
		end,
		RegisterCallback = noop,
	}
	_G.seterrorhandler = function(fn)
		env.handler = fn
	end
	_G.debugstack = function()
		return "stack"
	end
	_G.debuglocals = function()
		return "locals"
	end
	_G.strmatch = string.match
	_G.LibStub = nil
	_G.GetCallstackHeight = nil
	_G.GetErrorCallstackHeight = nil
	_G.issecretvalue = nil
	_G.canaccessvalue = nil
	_G.SentinelDB = nil
	_G.SentinelCharDB = nil
	return env
end

-- Loads one addon file with a shared namespace table, the way the client passes
-- (addonName, ns) to every file.
function Support.load(ns, path)
	local chunk = assert(loadfile(ADDON_DIR .. path))
	return chunk("Sentinel", ns)
end

function Support.loadLib(path)
	return assert(loadfile(ADDON_DIR .. "Libs/" .. path))("Sentinel", {})
end

-- Namespace, locales and database, the base every other module needs.
function Support.loadBase(ns)
	Support.load(ns, "Core/Namespace.lua")
	Support.load(ns, "Core/Locales.lua")
	Support.load(ns, "Core/Database.lua")
end

function Support.lastPrinted(env)
	return env.printed[#env.printed]
end

-- Minimal runner. Each case runs in isolation and failures are collected.
local results = { passed = 0, failed = 0 }

function Support.case(name, fn)
	local ok, err = xpcall(fn, function(e)
		return debug.traceback(tostring(e), 2)
	end)
	if ok then
		results.passed = results.passed + 1
		io.write("  ok   ", name, "\n")
	else
		results.failed = results.failed + 1
		io.write("  FAIL ", name, "\n", err, "\n")
	end
end

function Support.finish()
	io.write(("%d passed, %d failed\n"):format(results.passed, results.failed))
	os.exit(results.failed == 0 and 0 or 1)
end

function Support.eq(actual, expected, label)
	if actual ~= expected then
		error(("%s: expected %s, got %s"):format(label or "value", tostring(expected), tostring(actual)), 2)
	end
end

return Support
