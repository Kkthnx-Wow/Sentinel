-- Sentinel: Locales.lua
-- Localization table. Defaults to enUS; falls back to the key itself for any
-- missing entry via the metatable, so the UI never shows nil.

local _, ns = ...

local L = setmetatable({}, {
	__index = function(t, k)
		rawset(t, k, k)
		return k
	end,
})
ns.L = L

-- enUS (default)
L["Sentinel"] = "Sentinel"
L["No errors caught \226\128\148 your UI is clean."] = "No errors caught \226\128\148 your UI is clean."
L["All bugs"] = "All bugs"
L["This session"] = "This session"
L["Previous session"] = "Previous session"
L["Received"] = "Received"
L["Copy"] = "Copy"
L["Export"] = "Export"
L["Send"] = "Send"
L["Delete"] = "Delete"
L["Clear"] = "Clear"
L["Reload UI"] = "Reload UI"
L["Select an error on the left to see its full stack trace and locals here."] = "Select an error on the left to see its full stack trace and locals here."

-- Tab tooltips
L["Every error stored across every session, including reports received from other players."] = "Every error stored across every session, including reports received from other players."
L["Errors caught since your last login or UI reload."] = "Errors caught since your last login or UI reload."
L["Errors caught during your previous play session."] = "Errors caught during your previous play session."
L["Error reports other players have sent to you with Sentinel."] = "Error reports other players have sent to you with Sentinel."

-- Action button tooltips
L["Copies the one error selected on the left. Opens a text box \226\128\148 select all and press Ctrl-C."] = "Copies the one error selected on the left. Opens a text box \226\128\148 select all and press Ctrl-C."
L["Exports every error in the current tab at once. Opens a text box \226\128\148 select all and press Ctrl-C."] = "Exports every error in the current tab at once. Opens a text box \226\128\148 select all and press Ctrl-C."
L["Send the selected error to another Sentinel user. Unavailable inside instances."] = "Send the selected error to another Sentinel user. Unavailable inside instances."
L["Permanently delete only the selected error."] = "Permanently delete only the selected error."
L["Reload your interface \226\128\148 handy after disabling a broken addon."] = "Reload your interface \226\128\148 handy after disabling a broken addon."

-- Error row tooltip
L["Occurrences"] = "Occurrences"
L["Last seen"] = "Last seen"
L["Session"] = "Session"
L["Sent by"] = "Sent by"
L["Click to view full details."] = "Click to view full details."

-- Alerts
L["A new error was caught. Type /sentinel to view it."] = "A new error was caught. Type /sentinel to view it."
L["Capture paused: too many errors per second. Fix or disable the failing addon."] = "Capture paused: too many errors per second. Fix or disable the failing addon."
L["[%s] AddOn '%s' tried to call the protected function '%s'."] = "[%s] AddOn '%s' tried to call the protected function '%s'."
L["Macro tried to call the protected function '%s'."] = "Macro tried to call the protected function '%s'."

-- Sharing
L["Select the text below, then press Ctrl-C to copy."] = "Select the text below, then press Ctrl-C to copy."
L["Send the currently selected error to a player."] = "Send the currently selected error to a player."
L["Sent error to %s."] = "Sent error to %s."
L["You received an error report from %s."] = "You received an error report from %s."
L["Cannot send while in an instance (Midnight blocks addon messages there). Use Export instead."] = "Cannot send while in an instance (Midnight blocks addon messages there). Use Export instead."
L["Enter a valid player name."] = "Enter a valid player name."
L["Nothing selected to send."] = "Nothing selected to send."
L["Nothing selected to delete."] = "Nothing selected to delete."
L["Deleted selected error."] = "Deleted selected error."

-- Config
L["Show minimap button"] = "Show minimap button"
L["Toggle the Sentinel button next to the minimap."] = "Toggle the Sentinel button next to the minimap."
L["Play a sound on new errors"] = "Play a sound on new errors"
L["Plays a short sound (throttled) whenever a new, unique error is caught."] = "Plays a short sound (throttled) whenever a new, unique error is caught."
L["Announce new errors in chat"] = "Announce new errors in chat"
L["Prints a short notice to chat when a new error is caught."] = "Prints a short notice to chat when a new error is caught."
L["Auto-open on error"] = "Auto-open on error"
L["Automatically open the window when a new error is caught (never during combat)."] = "Automatically open the window when a new error is caught (never during combat)."
L["Capture blocked-action errors"] = "Capture blocked-action errors"
L["Capture ADDON_ACTION_FORBIDDEN and other blocked-action (taint) events. Turn off to ignore this taint noise from other addons entirely."] = "Capture ADDON_ACTION_FORBIDDEN and other blocked-action (taint) events. Turn off to ignore this taint noise from other addons entirely."
L["Pause error capture"] = "Pause error capture"
L["Temporarily stop recording new errors and warnings. Turn this on while a known issue is spamming, then turn it back off when you are ready to capture again."] = "Temporarily stop recording new errors and warnings. Turn this on while a known issue is spamming, then turn it back off when you are ready to capture again."
L["Wipe all stored errors"] = "Wipe all stored errors"
L["Permanently delete every stored error from every session."] = "Permanently delete every stored error from every session."
L["All stored errors have been wiped."] = "All stored errors have been wiped."
L["Error capture is paused."] = "Error capture is paused."
L["Error capture is now paused."] = "Error capture is now paused."
L["Error capture is now active."] = "Error capture is now active."
L["Error sound is now on."] = "Error sound is now on."
L["Error sound is now off."] = "Error sound is now off."
L["Error chat alerts are now on."] = "Error chat alerts are now on."
L["Error chat alerts are now off."] = "Error chat alerts are now off."
L["on"] = "on"
L["off"] = "off"
L["Capture"] = "Capture"
L["Sound"] = "Sound"
L["Chat alerts"] = "Chat alerts"
L["Blocked-action capture"] = "Blocked-action capture"
L["Stored errors"] = "Stored errors"
L["this session"] = "this session"
L["Usage: /sen [help|status|config|clear|pause|resume|sound|chat|test|build]"] = "Usage: /sen [help|status|config|clear|pause|resume|sound|chat|test|build]"
L["/sen or /sentinel - toggle the error window."] = "/sen or /sentinel - toggle the error window."
L["/sen status - show current capture and alert settings."] = "/sen status - show current capture and alert settings."
L["/sen config - open Sentinel settings."] = "/sen config - open Sentinel settings."
L["/sen clear - wipe all stored errors."] = "/sen clear - wipe all stored errors."
L["/sen pause - stop capturing new errors."] = "/sen pause - stop capturing new errors."
L["/sen resume - start capturing new errors again."] = "/sen resume - start capturing new errors again."
L["/sen sound - toggle the new-error sound."] = "/sen sound - toggle the new-error sound."
L["/sen chat - toggle new-error chat announcements."] = "/sen chat - toggle new-error chat announcements."
L["/sen test - generate a test error."] = "/sen test - generate a test error."
L["/sen build - print your WoW build information."] = "/sen build - print your WoW build information."

-- Minimap tooltip
L["Left-click: open the error window"] = "Left-click: open the error window"
L["Right-click: open settings"] = "Right-click: open settings"
L["Shift-click: reload the UI"] = "Shift-click: reload the UI"
L["Alt-click: wipe all errors"] = "Alt-click: wipe all errors"

do
	local locale = GetLocale()
	if locale == "zhCN" then
		L["Sentinel"] = "哨兵"
		L["No errors caught \226\128\148 your UI is clean."] = "未捕获到错误 \226\128\148 你的界面很干净。"
		L["All bugs"] = "全部错误"
		L["This session"] = "本次会话"
		L["Previous session"] = "上次会话"
		L["Received"] = "已接收"
		L["Copy"] = "复制"
		L["Export"] = "导出"
		L["Send"] = "发送"
		L["Delete"] = "删除"
		L["Clear"] = "清除"
		L["Reload UI"] = "重载界面"
	end
end
