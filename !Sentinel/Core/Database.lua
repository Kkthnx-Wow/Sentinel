-- Sentinel: Database.lua
-- Owns the SavedVariables. Because the TOC declares `LoadSavedVariablesFirst: 1`,
-- SentinelDB / SentinelCharDB are already populated when this file runs, so the
-- capture engine (loaded immediately after) can persist errors right away.

local _, ns = ...
local DB = ns.DB

local CURRENT_SCHEMA = 1

-- Per-account defaults. Re-queryable game data is not stored here (optimization
-- section 10), only user settings and the caught error objects themselves.
local DEFAULTS = {
	minimap = true,
	sound = true,
	chat = true,
	autoOpen = false,
	hideInCombat = true,
	captureTaint = true,
	capturePaused = false,
	-- Detail-pane font size, an index into the size list in MainFrame (2 is normal).
	detailFontSize = 2,
}
ns.DEFAULTS = DEFAULTS

-----------------------------------------------------------------------
-- Initialize SavedVariables + start a new session
-----------------------------------------------------------------------
local function migrate(sv)
	-- Future schema migrations key off the sv.version slot right here
	-- (optimization section 10).
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

	-- Drop rows that are not tables or have no string message. A hand-edited or
	-- half-written SavedVariables file would otherwise fault every list scan.
	do
		local errors = sv.errors
		for i = #errors, 1, -1 do
			local e = errors[i]
			if type(e) ~= "table" or type(e.message) ~= "string" then
				table.remove(errors, i)
			end
		end
	end

	-- Begin a fresh session for this login/reload.
	sv.session = sv.session + 1

	-- Trim down to MAX_ERRORS so the file never grows unbounded.
	local errors = sv.errors
	while #errors > ns.MAX_ERRORS do
		table.remove(errors, 1)
	end

	-- Stable numeric ids for chat hyperlinks. Table-pointer identity dies across
	-- /reload, so we backfill legacy rows once and keep a persistent counter.
	local maxId = 0
	for i = 1, #errors do
		local e = errors[i]
		if type(e) == "table" and type(e.id) == "number" and e.id > maxId then
			maxId = e.id
		end
	end
	for i = 1, #errors do
		local e = errors[i]
		if type(e) == "table" and type(e.id) ~= "number" then
			maxId = maxId + 1
			e.id = maxId
		end
	end
	if type(sv.nextErrorId) ~= "number" or sv.nextErrorId <= maxId then
		sv.nextErrorId = maxId + 1
	end

	if type(SentinelCharDB) ~= "table" then
		SentinelCharDB = {}
	end
end

DB.errors = sv.errors
DB.config = sv.config
DB.nextErrorId = sv.nextErrorId
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

local sessionScratch = {}
local receivedScratch = {}

-- Returns an array of locally caught errors belonging to `sessionId`. Reports
-- received from other players carry `source` and live in GetReceived instead, so they
-- never inflate the session tab, the minimap badge, or a session you send out.
-- Reuses `out` when provided (wipe + refill) to avoid throwaway tables in UI refresh paths.
function DB.GetBySession(sessionId, out)
	out = out or sessionScratch
	wipe(out)
	local errors = DB.errors
	local n = 0
	for i = 1, #errors do
		local e = errors[i]
		if e.session == sessionId and not e.source then
			n = n + 1
			out[n] = e
		end
	end
	return out
end

-- Returns every error that arrived from another player.
function DB.GetReceived(out)
	out = out or receivedScratch
	wipe(out)
	local errors = DB.errors
	local n = 0
	for i = 1, #errors do
		local e = errors[i]
		if e.source then
			n = n + 1
			out[n] = e
		end
	end
	return out
end

-- Finds a locally caught error by message, newest first. Received reports are
-- skipped, otherwise a local fault that matches a peer's report would be folded into
-- that row and show up under Received instead of This session. The list is capped
-- at MAX_ERRORS, so a scan beats maintaining a parallel hash.
function DB.FetchByMessage(message)
	local errors = DB.errors
	for i = #errors, 1, -1 do
		local e = errors[i]
		if e.message == message and not e.source then
			return e, i
		end
	end
end

-- Chat hyperlinks look up by stable id, not table pointer (survives /reload).
function DB.GetById(id)
	if type(id) ~= "number" then
		return nil
	end
	local errors = DB.errors
	for i = #errors, 1, -1 do
		local e = errors[i]
		if e.id == id then
			return e, i
		end
	end
end

-- Over the cap, the oldest received report goes first, so a peer flooding reports
-- can never push your own errors out of the list. With none left it is plain oldest-first.
local function evictOne(errors)
	for i = 1, #errors do
		if errors[i].source then
			table.remove(errors, i)
			return
		end
	end
	table.remove(errors, 1)
end

function DB.Store(errorObject)
	if type(errorObject.id) ~= "number" then
		local nextId = DB.nextErrorId or 1
		errorObject.id = nextId
		DB.nextErrorId = nextId + 1
		-- Mirror into the SavedVariables root so the counter persists.
		if SentinelDB then
			SentinelDB.nextErrorId = DB.nextErrorId
		end
	end
	local errors = DB.errors
	errors[#errors + 1] = errorObject
	while #errors > ns.MAX_ERRORS do
		evictOne(errors)
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
		local e = errors[i]
		if e.session == session and not e.source then
			n = n + 1
		end
	end
	return n
end
