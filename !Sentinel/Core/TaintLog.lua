-- Sentinel: TaintLog.lua
-- Thin wrapper around Blizzard's `taintLog` CVar (12.0+). Levels 0–4 write
-- debug output to taint.log in the WoW install folder (see Resources/CVars.lua).

local _, ns = ...
local L = ns.L

local TaintLog = {}
ns.TaintLog = TaintLog

local CVAR = "taintLog"
local MAX_LEVEL = 4

local floor = math.floor

local function levelName(level)
	if level == 0 then
		return L["TaintLog level 0"]
	end
	return L["TaintLog level " .. level] or tostring(level)
end

function TaintLog.IsAvailable()
	return GetCVar(CVAR) ~= nil
end

function TaintLog.GetLevel()
	if not TaintLog.IsAvailable() then
		return 0
	end
	return floor(tonumber(GetCVar(CVAR) or "0") or 0)
end

function TaintLog.SetLevel(level)
	if not TaintLog.IsAvailable() then
		return 0
	end
	level = floor(level or 0)
	if level < 0 then
		level = 0
	elseif level > MAX_LEVEL then
		level = MAX_LEVEL
	end
	SetCVar(CVAR, tostring(level))
	return level
end

function TaintLog.CycleLevel()
	local level = TaintLog.GetLevel() + 1
	if level > MAX_LEVEL then
		level = 0
	end
	return TaintLog.SetLevel(level)
end

function TaintLog.GetButtonLabel()
	local level = TaintLog.GetLevel()
	if level == 0 then
		return L["TaintLog: Off"]
	end
	return (L["TaintLog: %d"]):format(level)
end

function TaintLog.GetTooltip()
	return L["TaintLog button tooltip"]
end

function TaintLog.GetStatusLine(level)
	level = level or TaintLog.GetLevel()
	if level == 0 then
		return L["Taint log is now off."]
	end
	return (L["Taint log level set to %d (%s). Output: taint.log"]):format(level, levelName(level))
end

function TaintLog.GetLevelName(level)
	return levelName(level or TaintLog.GetLevel())
end
