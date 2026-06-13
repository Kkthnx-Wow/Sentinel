-- Sentinel: Config.lua
-- Options panel built on the modern Blizzard Settings API. Settings are bound
-- directly to the SavedVariables config table (DB.config).

local _, ns = ...
local Config = ns.Config
local DB = ns.DB
local L = ns.L

local category

local function addCheckbox(varKey, name, tooltip, onChange)
	local setting = Settings.RegisterAddOnSetting(category, "SENTINEL_" .. varKey:upper(), varKey, DB.config, Settings.VarType.Boolean, name, ns.DEFAULTS[varKey])
	Settings.CreateCheckbox(category, setting, tooltip)
	if onChange then
		setting:SetValueChangedCallback(function(_, value)
			onChange(value)
		end)
	end
	return setting
end

function Config.Initialize()
	if category then
		return
	end
	category = Settings.RegisterVerticalLayoutCategory(ns.DISPLAY_NAME)
	ns.Config.category = category

	addCheckbox("minimap", L["Show minimap button"], L["Toggle the Sentinel button next to the minimap."], function(value)
		if ns.UI.SetMinimapShown then
			ns.UI.SetMinimapShown(value)
		end
	end)
	addCheckbox("sound", L["Play a sound on new errors"], L["Plays a short sound (throttled) whenever a new, unique error is caught."])
	addCheckbox("chat", L["Announce new errors in chat"], L["Prints a short notice to chat when a new error is caught."])
	addCheckbox("autoOpen", L["Auto-open on error"], L["Automatically open the window when a new error is caught (never during combat)."])
	addCheckbox("captureTaint", L["Capture blocked-action errors"], L["Capture ADDON_ACTION_FORBIDDEN and other blocked-action (taint) events. Turn off to ignore this taint noise from other addons entirely."])
	addCheckbox("capturePaused", L["Pause error capture"], L["Temporarily stop recording new errors and warnings. Turn this on while a known issue is spamming, then turn it back off when you are ready to capture again."])

	-- Wipe button
	if CreateSettingsButtonInitializer then
		local initializer = CreateSettingsButtonInitializer(L["Wipe all stored errors"], L["Wipe all stored errors"], function()
			DB.Reset()
			if ns.UI.UpdateMinimapCount then
				ns.UI.UpdateMinimapCount()
			end
			ns.UI.Refresh()
			ns.Print(L["All stored errors have been wiped."])
		end, L["Permanently delete every stored error from every session."], true)
		local layout = SettingsPanel:GetLayout(category)
		if layout then
			layout:AddInitializer(initializer)
		end
	end

	Settings.RegisterAddOnCategory(category)
end

function Config.Open()
	if not category then
		Config.Initialize()
	end
	if category then
		Settings.OpenToCategory(category:GetID())
	end
end
