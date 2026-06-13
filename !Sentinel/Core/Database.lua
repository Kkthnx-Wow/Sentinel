-- Sentinel: Database.lua
-- Owns the SavedVariables. Because the TOC declares `LoadSavedVariablesFirst: 1`,
-- SentinelDB / SentinelCharDB are already populated when this file runs, so the
-- capture engine (loaded immediately after) can persist errors right away.

local _, ns = ...
local DB = ns.DB

local CURRENT_SCHEMA = 1

-- Per-account defaults. Re-queryable game data is NOT stored here (see optimization
-- guide section 10) -- only user settings and the caught error objects themselves.
local DEFAULTS = {
	minimap = true,
	sound = true,
	chat = true,
	autoOpen = false,
	captureTaint = true,
	capturePaused = false,
}
ns.DEFAULTS = DEFAULTS

-----------------------------------------------------------------------
-- Initialize SavedVariables + start a new session
-----------------------------------------------------------------------
local function migrate(sv)
	-- (Future schema migrations keyed off sv.version slot in here; see
	-- optimization guide section 10.)
	sv.version = CURRENT_SCHEMA
end

local sv
do
	if type(SentinelDB) ~= "table" then
		SentinelDB = {}
	end
	sv = SentinelDB
	if type(sv.errors) ~= "table" then
		sv.errors = {}
	end
	if type(sv.session) ~= "number" then
		sv.session = 0
	end
	if type(sv.config) ~= "table" then
		sv.config = {}
	end

	-- Fill in any missing config defaults without clobbering the user's choices.
	for k, v in pairs(DEFAULTS) do
		if sv.config[k] == nil then
			sv.config[k] = v
		end
	end

	migrate(sv)

	-- Begin a fresh session for this login/reload.
	sv.session = sv.session + 1

	-- Trim down to MAX_ERRORS so the file never grows unbounded.
	local errors = sv.errors
	while #errors > ns.MAX_ERRORS do
		table.remove(errors, 1)
	end

	if type(SentinelCharDB) ~= "table" then
		SentinelCharDB = {}
	end
end

DB.errors = sv.errors
DB.config = sv.config
ns.State.sessionId = sv.session

-----------------------------------------------------------------------
-- Accessors
-----------------------------------------------------------------------
function DB.GetSessionId()
	return ns.State.sessionId
end

function DB.GetAll()
	return DB.errors
end

-- Returns a freshly-built array of errors belonging to `sessionId`.
function DB.GetBySession(sessionId)
	local out = {}
	local errors = DB.errors
	for i = 1, #errors do
		local e = errors[i]
		if e.session == sessionId then
			out[#out + 1] = e
		end
	end
	return out
end

-- Returns every error that arrived from another player.
function DB.GetReceived()
	local out = {}
	local errors = DB.errors
	for i = 1, #errors do
		local e = errors[i]
		if e.source then
			out[#out + 1] = e
		end
	end
	return out
end

-- Linear scan from newest to oldest (matches BugGrabber). The error list is
-- small in practice, so this is cheaper than maintaining a parallel hash.
function DB.FetchByMessage(message)
	local errors = DB.errors
	for i = #errors, 1, -1 do
		local e = errors[i]
		if e.message == message then
			return e, i
		end
	end
end

function DB.Store(errorObject)
	local errors = DB.errors
	errors[#errors + 1] = errorObject
	if #errors > ns.MAX_ERRORS then
		table.remove(errors, 1)
	end
end

function DB.Remove(index)
	table.remove(DB.errors, index)
end

function DB.RemoveObject(errorObject)
	local errors = DB.errors
	for i = #errors, 1, -1 do
		if errors[i] == errorObject then
			table.remove(errors, i)
			return true
		end
	end
	return false
end

function DB.Reset()
	wipe(DB.errors)
end

function DB.Count()
	return #DB.errors
end

function DB.SessionCount()
	local n = 0
	local errors = DB.errors
	local session = ns.State.sessionId
	for i = 1, #errors do
		if errors[i].session == session then
			n = n + 1
		end
	end
	return n
end
