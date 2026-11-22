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
	-- A new error was captured and no alert has announced it yet.
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
-- C_AddOns is the modern accessor, and a client without it still exposes the older global.
-- Without this fallback the title bar would render a bare "v" on those clients.
local versionFromCAddOns = C_AddOns and C_AddOns.GetAddOnMetadata
local versionFromGlobal = GetAddOnMetadata
ns.VERSION = (versionFromCAddOns and versionFromCAddOns(addonName, "Version"))
	or (versionFromGlobal and versionFromGlobal(addonName, "Version"))
	or ""
-- Bundled media. The addon owns its icons and minimap button art, so it never depends
-- on built-in Indicator-* paths or magic texture fileIDs that can move between patches.
ns.MEDIA = "Interface\\AddOns\\" .. addonName .. "\\Media\\"
ns.ICON = ns.MEDIA .. "Indicator-Green.tga"
ns.ICON_ALERT = ns.MEDIA .. "Indicator-Red.tga"

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
	addon = makeSyntaxColor("ffffd180", 1, 209 / 255, 128 / 255), -- addon folder in a stack frame, soft gold so the owner stands out
	dim = makeSyntaxColor("ff788893", 120 / 255, 136 / 255, 147 / 255), -- game and engine frames, pushed back but still about 4.8:1 on the pane
	funcName = makeSyntaxColor("ffe0e0e0", 224 / 255, 224 / 255, 224 / 255), -- named functions in a stack frame
	secret = makeSyntaxColor("ffce93d8", 206 / 255, 147 / 255, 216 / 255), -- <secret ...> placeholders, lavender
	typeName = makeSyntaxColor("ff81c784", 129 / 255, 199 / 255, 132 / 255), -- widget and table references in locals, soft green
}

-----------------------------------------------------------------------
-- Cached globals used in hot paths (optimization section 3).
-- Each consumer file aliases these to file-scope locals at load time.
-----------------------------------------------------------------------
ns.G = {
	-- The one Secret Value primitive the addon needs. Midnight wraps values tainted code
	-- may not read, and the capture boundary uses this to turn them into plain text
	-- before they are stored. Older clients get the always-false fallback.
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
-- Public API table, the single intentional global (optimization section 2).
-- Other addons and displays can read the `Sentinel` global but cannot overwrite it.
-----------------------------------------------------------------------
ns.API = {}
_G[ns.DISPLAY_NAME] = setmetatable({}, {
	__index = ns.API,
	__newindex = function() end,
	__metatable = false,
})
