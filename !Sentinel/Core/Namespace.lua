-- Sentinel: Namespace.lua
-- The first file loaded. Creates the private shared namespace and shared constants.
-- Per the optimization guide, every other file does `local addonName, ns = ...`
-- to grab this same table reference -- no globals required.

local addonName, ns = ...

-----------------------------------------------------------------------
-- Module containers
-----------------------------------------------------------------------
ns.DB = {}
ns.Format = {}
ns.Comm = {}
ns.UI = {}
ns.Config = {}

-- Shared, mutable runtime state (never written from a secure path).
ns.State = {
	initialized = false,
	sessionId = -1,
	paused = false,
	soundTime = 0,
}

-----------------------------------------------------------------------
-- Constants
-----------------------------------------------------------------------
ns.ADDON_NAME = addonName
ns.DISPLAY_NAME = "Sentinel"
ns.PREFIX = "Sentinel" -- addon comm prefix
-- Version string straight from the .toc, so the UI never drifts out of sync.
ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version")) or ""
-- Built-in Blizzard textures (guaranteed to exist -- no bundled media needed).
ns.ICON = "Interface\\COMMON\\Indicator-Green"
ns.ICON_ALERT = "Interface\\COMMON\\Indicator-Red"

-- Keep at most this many stored errors. Beyond this the oldest are dropped so the
-- SavedVariables file never balloons (see optimization guide section 10).
ns.MAX_ERRORS = 1000

-- If errors arrive faster than this per second, capture pauses to protect FPS
-- (see optimization guide section 1 -- addon CPU competes with frame rendering).
ns.ERRORS_PER_SEC_BEFORE_THROTTLE = 10

ns.COLORS = {
	chat = "|cff33ff99", -- Sentinel brand color
	good = "|cff44ff44",
	bad = "|cffff4411",
	warn = "|cffffea00",
}

-- Flat, modern dark theme (RGBA 0-1). The window fill is Material Dark (#121212);
-- nested panes use Charcoal (#1A1A1A) so they layer cleanly, edged in Deep Cyan-Gray.
ns.THEME = {
	window = { 18 / 255, 18 / 255, 18 / 255, 0.97 }, -- #121212 Material Dark
	pane = { 26 / 255, 26 / 255, 26 / 255, 0.95 }, -- #1A1A1A Charcoal
	paneBorder = { 45 / 255, 64 / 255, 74 / 255, 1 }, -- #2D404A Deep Cyan-Gray
}

-----------------------------------------------------------------------
-- Cached globals (used in hot paths -- see optimization guide section 3).
-- Each consumer file aliases these to file-scope locals at load time.
-----------------------------------------------------------------------
ns.G = {
	issecretvalue = _G.issecretvalue or function()
		return false
	end,
	GetTime = GetTime,
	time = time,
	IsInInstance = IsInInstance,
}

-----------------------------------------------------------------------
-- Lightweight chat printer
-----------------------------------------------------------------------
local prefix = ns.COLORS.chat .. ns.DISPLAY_NAME .. ":|r "
function ns.Print(...)
	print(prefix, ...)
end

-----------------------------------------------------------------------
-- Public API table (the single intentional global, see optimization guide section 2)
-- Other addons / displays can read from the `Sentinel` global, but cannot overwrite it.
-----------------------------------------------------------------------
ns.API = {}
_G[ns.DISPLAY_NAME] = setmetatable({}, {
	__index = ns.API,
	__newindex = function() end,
	__metatable = false,
})
