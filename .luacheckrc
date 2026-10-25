std = "lua51"
max_line_length = false

exclude_files = {
	"!Sentinel/Libs",
	"!Sentinel/tools",
	"!Sentinel/Core/LocaleOverrides.lua",
}

-- Unused arguments are normal in event handlers and script callbacks.
ignore = { "212" }

globals = {
	"SentinelDB",
	"SentinelCharDB",
	"SLASH_SENTINEL1",
	"SLASH_SENTINEL2",
	"SlashCmdList",
	"StaticPopupDialogs",
	"UISpecialFrames",
	"seterrorhandler",
}

read_globals = {
	"AddonCompartmentFrame",
	"CANCEL",
	"CLOSE",
	"C_AddOns",
	"C_StringUtil",
	"C_Timer",
	"CreateColorFromHexString",
	"CreateFrame",
	"CreateSettingsButtonInitializer",
	"EventRegistry",
	"GameTooltip",
	"GameTooltip_Hide",
	"GetBuildInfo",
	"GetCVar",
	"GetCallstackHeight",
	"GetCursorPosition",
	"GetErrorCallstackHeight",
	"GetTime",
	"InCombatLockdown",
	"IsAltKeyDown",
	"IsInInstance",
	"IsShiftKeyDown",
	"LibStub",
	"LinkTypes",
	"LinkUtil",
	"Minimap",
	"NineSliceUtil",
	"PlaySound",
	"ReloadUI",
	"ScriptErrorsFrame",
	"SearchBoxTemplate_OnTextChanged",
	"SetCVar",
	"Settings",
	"SettingsPanel",
	"StaticPopup_Show",
	"UIParent",
	"WOW_PROJECT_ID",
	"WOW_PROJECT_MAINLINE",
	"date",
	"debuglocals",
	"debugstack",
	"hooksecurefunc",
	"time",
	"tinsert",
	"wipe",
	"issecretvalue",
	"canaccessvalue",
	"GameEvent",
	"GetMinimapShape",
}

files["tests/"] = {
	globals = { "_G" },
	ignore = { "212", "111", "112", "113", "121", "122", "131", "142", "143" },
}
