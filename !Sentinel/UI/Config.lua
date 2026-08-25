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

-- A number-backed dropdown bound to DB.config, for the handful of non-boolean options.
local function addDropdown(varKey, name, tooltip, labels, onChange)
	local setting = Settings.RegisterAddOnSetting(category, "SENTINEL_" .. varKey:upper(), varKey, DB.config, Settings.VarType.Number, name, ns.DEFAULTS[varKey])
	local function options()
		local container = Settings.CreateControlTextContainer()
		for i = 1, #labels do
			container:Add(i, labels[i])
		end
		return container:GetData()
	end
	Settings.CreateDropdown(category, setting, options, tooltip)
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
	addCheckbox("chat", L["Announce new errors in chat"], L["Prints a short notice to chat when a new error is caught. Includes a clickable link to open that error."])
	addCheckbox("autoOpen", L["Auto-open on error"], L["Automatically open the window when a new error is caught (never during combat)."])
	addCheckbox("hideInCombat", L["Hide the window when entering combat"], L["Automatically hide the error window when you enter combat, then restore it when combat ends. Turn this off to let the window stay open through combat. Either way, you can always open or close it manually with Escape or the close button."])
	addCheckbox("captureTaint", L["Capture blocked-action errors"], L["Capture ADDON_ACTION_FORBIDDEN and other blocked-action (taint) events. Turn off to ignore this taint noise from other addons entirely."])
	addCheckbox("capturePaused", L["Pause error capture"], L["Temporarily stop recording new errors and warnings. Turn this on while a known issue is spamming, then turn it back off when you are ready to capture again."])
	addDropdown("detailFontSize", L["Detail font size"], L["Font size for the stack trace and locals in the detail pane."], {
		L["Small"],
		L["Normal"],
		L["Large"],
		L["X-Large"],
	}, function(value)
		if ns.UI.SetDetailFontSize then
			ns.UI.SetDetailFontSize(value)
		end
	end)

	-- Wipe button
	if CreateSettingsButtonInitializer then
		local initializer = CreateSettingsButtonInitializer(L["Wipe all stored errors"], L["Wipe all stored errors"], function()
			if ns.UI.ConfirmWipe then
				ns.UI.ConfirmWipe()
			end
		end, L["Permanently delete every stored error from every session."], true)
		local layout = SettingsPanel:GetLayout(category)
		if layout then
			layout:AddInitializer(initializer)
		end
	end

	-- Taint log (12.0+ retail only)
	if CreateSettingsButtonInitializer and ns.TaintLog.IsAvailable() then
		local initializer = CreateSettingsButtonInitializer(
			L["Taint log"],
			L["Taint log"],
			function()
				local level = ns.TaintLog.CycleLevel()
				if ns.UI.UpdateTaintLogButton then
					ns.UI.UpdateTaintLogButton()
				end
				ns.Print(ns.TaintLog.GetStatusLine(level))
			end,
			L["Cycle Blizzard taintLog level (0-4). Output is written to taint.log."],
			false
		)
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
