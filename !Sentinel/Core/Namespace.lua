-- Sentinel: Namespace.lua
-- The first file loaded. Creates the private shared namespace and shared constants.
-- Every other file does `local addonName, ns = ...` to grab this same table
-- reference, so nothing here needs a global.

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
	hadNewErrorThisLoad = false,
	-- Set when the error window (or auto-open) is deferred across combat.
	reopenAfterCombat = false,
}

-----------------------------------------------------------------------
-- Constants
-----------------------------------------------------------------------
ns.ADDON_NAME = addonName
ns.DISPLAY_NAME = "Sentinel"
ns.PREFIX = "Sentinel" -- addon comm prefix
-- Version string straight from the .toc, so the UI never drifts out of sync.
ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version")) or ""
-- Built-in game textures, always present, so no bundled media is needed.
ns.ICON = "Interface\\COMMON\\Indicator-Green"
ns.ICON_ALERT = "Interface\\COMMON\\Indicator-Red"

-- Keep at most this many stored errors. Beyond this the oldest are dropped so the
-- SavedVariables file never balloons (see optimization guide section 10).
ns.MAX_ERRORS = 1000

-- If errors arrive faster than this per second, capture pauses to protect the
-- frame rate, since addon CPU time competes with rendering.
ns.ERRORS_PER_SEC_BEFORE_THROTTLE = 10

ns.COLORS = {
	chat = "|cff00bfff", -- Sentinel brand color, electric blue, matches the title counter and syntax
	good = "|cff44ff44",
	bad = "|cffff4411",
	warn = "|cffffea00",
}

-- Flat, modern dark theme (RGBA 0-1). The window fill is Material Dark (#121212) and
-- nested panes use Charcoal (#1A1A1A) so they layer cleanly, edged in Deep Cyan-Gray.
ns.THEME = {
	window = { 18 / 255, 18 / 255, 18 / 255, 0.97 }, -- #121212 Material Dark
	pane = { 26 / 255, 26 / 255, 26 / 255, 0.95 }, -- #1A1A1A Charcoal
	paneBorder = { 45 / 255, 64 / 255, 74 / 255, 1 }, -- #2D404A Deep Cyan-Gray
}

-- Syntax-highlighting palette (cyan and silver, tuned for the #121212 pane).
-- Each entry caches the final color-code prefix in `.code`, which avoids
-- ColorMixin:GenerateHexColor() work during row and detail formatting
-- (optimization section 3), while still exposing GetRGB() for widget base colors.
local function makeSyntaxColor(hex, r, g, b)
	local color = CreateColorFromHexString and CreateColorFromHexString(hex)
	if not color then
		return {
			code = "|c" .. hex,
			GetRGB = function()
				return r, g, b
			end,
		}
	end
	return {
		code = "|c" .. hex,
		GetRGB = function()
			return color:GetRGB()
		end,
	}
end

ns.SYNTAX = {
	counter = makeSyntaxColor("ff00bfff", 0, 191 / 255, 1), -- frequency badge (1x), electric blue
	message = makeSyntaxColor("ffffffff", 1, 1, 1), -- headline error message, crisp white
	header = makeSyntaxColor("ff00bfff", 0, 191 / 255, 1), -- "Locals" label, electric blue like the counter
	path = makeSyntaxColor("ff4dd0e1", 77 / 255, 208 / 255, 225 / 255), -- file paths, soft cyan
	line = makeSyntaxColor("ff00ffff", 0, 1, 1), -- line numbers, bright cyan
	punct = makeSyntaxColor("ff607d8b", 96 / 255, 125 / 255, 139 / 255), -- punctuation, slate gray
	varName = makeSyntaxColor("ff80deea", 128 / 255, 222 / 255, 234 / 255), -- locals names, light aqua under the header
	string = makeSyntaxColor("ffcfd8dc", 207 / 255, 216 / 255, 220 / 255), -- string values, light silver
	number = makeSyntaxColor("ff00bfff", 0, 191 / 255, 1), -- numeric values, electric blue
	nilValue = makeSyntaxColor("ffff6b6b", 1, 107 / 255, 107 / 255), -- nil, soft red so the empty value pops
	keyword = makeSyntaxColor("ffffb74d", 1, 183 / 255, 77 / 255), -- true and false, warm amber
	stackText = makeSyntaxColor("ff90a4ae", 144 / 255, 164 / 255, 174 / 255), -- stack base, blue-gray under the strings
}

-----------------------------------------------------------------------
-- Cached globals used in hot paths (optimization section 3).
-- Each consumer file aliases these to file-scope locals at load time.
-----------------------------------------------------------------------
ns.G = {
	issecretvalue = _G.issecretvalue or function()
		return false
	end,
	canaccessvalue = _G.canaccessvalue or function()
		return true
	end,
	GetTime = GetTime,
	time = time,
	IsInInstance = IsInInstance,
}

-- Midnight Secret Value helpers. IsSecret asks whether a value is secret at all,
-- CanAccess asks whether tainted code is allowed to read it.
function ns.IsSecret(v)
	return v ~= nil and ns.G.issecretvalue(v)
end

function ns.NotSecret(v)
	return v == nil or not ns.G.issecretvalue(v)
end

function ns.CanAccess(v)
	return v ~= nil and ns.G.canaccessvalue(v)
end

local tocVersion = tonumber(select(4, GetBuildInfo()) or 0) or 0
ns.IS_MIDNIGHT = tocVersion >= 120000
ns.IS_12_0_7 = tocVersion >= 120007

-----------------------------------------------------------------------
-- Lightweight chat printer
-----------------------------------------------------------------------
local prefix = ns.COLORS.chat .. ns.DISPLAY_NAME .. ":|r "
function ns.Print(...)
	print(prefix, ...)
end

-----------------------------------------------------------------------
-- Public API table, the single intentional global (optimization section 2).
-- Other addons and displays can read the `Sentinel` global but cannot overwrite it.
-----------------------------------------------------------------------
ns.API = {}
_G[ns.DISPLAY_NAME] = setmetatable({}, {
	__index = ns.API,
	__newindex = function() end,
	__metatable = false,
})
