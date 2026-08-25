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

	-- Drop corrupt rows where legacy grabbers stored a table as the message field.
	if type(sv.lastSanitation) ~= "number" or sv.lastSanitation < 1 then
		local errors = sv.errors
		for i = #errors, 1, -1 do
			local e = errors[i]
			if type(e) ~= "table" or type(e.message) == "table" then
				table.remove(errors, i)
			end
		end
		sv.lastSanitation = 1
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

-- Returns an array of errors belonging to `sessionId`. Reuses `out` when provided
-- (wipe + refill) to avoid throwaway tables in UI refresh paths.
function DB.GetBySession(sessionId, out)
	out = out or sessionScratch
	wipe(out)
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
function DB.GetReceived(out)
	out = out or receivedScratch
	wipe(out)
	local errors = DB.errors
	for i = 1, #errors do
		local e = errors[i]
		if e.source then
			out[#out + 1] = e
		end
	end
	return out
end

-- Linear scan from newest to oldest. The error list is small in practice, so
-- this is cheaper than maintaining a parallel hash.
function DB.FetchByMessage(message)
	local errors = DB.errors
	for i = #errors, 1, -1 do
		local e = errors[i]
		if e.message == message then
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
