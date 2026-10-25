package.path = "tests/?.lua;" .. package.path
local T = require("support")
local eq = T.eq

-- A small widget mock with real scroll behaviour, enough to drive MainFrame's
-- virtualized list and detail pane without the client.
local created
local widgetMethods = {}
-- Unknown names that look like verbs become no-op methods. Anything else (Left,
-- ScrollBar, NineSlice) stays nil, like a missing field on a real frame.
local NOOP_PREFIXES = {
	"Set", "Get", "Is", "Has", "Can", "Register", "Unregister", "Create", "Hook", "Clear", "Enable",
	"Disable", "Update", "Highlight", "Stop", "Start", "Raise", "Lower", "Add", "Apply", "Select",
	"Click", "Lock", "Unlock",
}

local function looksLikeMethod(key)
	if type(key) ~= "string" then
		return false
	end
	for _, prefix in ipairs(NOOP_PREFIXES) do
		if key:sub(1, #prefix) == prefix and key:sub(#prefix + 1, #prefix + 1):match("%u") then
			return true
		end
	end
	return false
end

local function newWidget(kind, name, parent, template)
	local w = {
		kind = kind,
		name = name,
		parent = parent,
		template = template,
		shown = true,
		points = 0,
		scripts = {},
		hooks = {},
		text = "",
		height = (template == "ScrollFrameTemplate") and 358 or 0,
		scroll = 0,
		setTextCalls = 0,
	}
	if template == "ScrollFrameTemplate" then
		w.ScrollBar = newWidget("Slider", nil, w)
	end
	setmetatable(w, {
		__index = function(_, key)
			local method = widgetMethods[key]
			if method then
				return method
			end
			if looksLikeMethod(key) then
				return function() end
			end
			return nil
		end,
	})
	if created then
		created[#created + 1] = w
	end
	return w
end

local function fire(self, script, ...)
	local fn = self.scripts[script]
	if fn then
		fn(self, ...)
	end
	for _, hook in ipairs(self.hooks[script] or {}) do
		hook(self, ...)
	end
end

function widgetMethods.Show(self)
	if not self.shown then
		self.shown = true
		fire(self, "OnShow")
	end
end
function widgetMethods.Hide(self)
	if self.shown then
		self.shown = false
		fire(self, "OnHide")
	end
end
function widgetMethods.SetShown(self, shown)
	if shown then
		self:Show()
	else
		self:Hide()
	end
end
function widgetMethods.IsShown(self)
	return self.shown
end
function widgetMethods.SetHeight(self, h)
	self.height = h
end
function widgetMethods.GetHeight(self)
	return self.height
end
function widgetMethods.SetWidth(self, w)
	self.width = w
end
function widgetMethods.SetSize(self, w, h)
	self.width, self.height = w, h
end
function widgetMethods.SetText(self, text)
	self.text = text
	self.setTextCalls = self.setTextCalls + 1
end
function widgetMethods.GetText(self)
	return self.text
end
function widgetMethods.SetPoint(self)
	self.points = self.points + 1
end
function widgetMethods.ClearAllPoints(self)
	self.points = 0
end
function widgetMethods.SetScript(self, script, fn)
	self.scripts[script] = fn
end
function widgetMethods.GetScript(self, script)
	return self.scripts[script]
end
function widgetMethods.HookScript(self, script, fn)
	self.hooks[script] = self.hooks[script] or {}
	table.insert(self.hooks[script], fn)
end
function widgetMethods.CreateFontString(self, name, _, template)
	return newWidget("FontString", name, self, template)
end
function widgetMethods.CreateTexture(self)
	return newWidget("Texture", nil, self)
end
function widgetMethods.GetFontString(self)
	return newWidget("FontString", nil, self)
end
function widgetMethods.GetFont()
	return "Fonts\\test.ttf", 12, ""
end
function widgetMethods.GetStringHeight(self)
	return self.stringHeight or 100
end
function widgetMethods.GetRegions() end
function widgetMethods.SetScrollChild(self, child)
	self.scrollChild = child
end
function widgetMethods.GetVerticalScrollRange(self)
	local childHeight = self.scrollChild and self.scrollChild.height or 0
	return math.max(0, childHeight - self.height)
end
function widgetMethods.GetVerticalScroll(self)
	return self.scroll
end
function widgetMethods.SetVerticalScroll(self, offset)
	offset = math.max(0, math.min(offset, self:GetVerticalScrollRange()))
	if offset ~= self.scroll then
		self.scroll = offset
		fire(self, "OnVerticalScroll", offset)
	end
end

local function freshUI()
	local env = T.newEnv()
	created = {}
	_G.CreateFrame = function(kind, name, parent, template)
		local w = newWidget(kind, name, parent, template)
		if name then
			_G[name] = w
		end
		return w
	end
	_G.UIParent = newWidget("Frame")
	_G.GameTooltip = newWidget("GameTooltip")
	_G.GameTooltip_Hide = function() end
	_G.StaticPopup_Show = function() end
	_G.StaticPopupDialogs = {}
	_G.UISpecialFrames = {}
	_G.tinsert = table.insert
	_G.CANCEL, _G.CLOSE = "Cancel", "Close"
	_G.InCombatLockdown = function()
		return false
	end
	_G.GetCVar = function() end
	_G.IsShiftKeyDown = function()
		return false
	end
	_G.C_Timer = {
		After = function(_, fn)
			fn()
		end,
	}

	local ns = {}
	T.loadBase(ns)
	T.load(ns, "Core/Format.lua")
	ns.Comm.IsAvailable = function()
		return false
	end
	T.load(ns, "Core/TaintLog.lua")
	T.load(ns, "UI/MainFrame.lua")
	return ns, env
end

local function storeErrors(ns, count, extra)
	local sid = ns.DB.GetSessionId()
	for i = 1, count do
		local e = { message = "err " .. i, session = sid, counter = 1, time = 1000 + i }
		for k, v in pairs(extra or {}) do
			e[k] = v
		end
		ns.DB.Store(e)
	end
end

local function visibleRows()
	local out = {}
	for _, w in ipairs(created) do
		if w.kind == "Button" and w.errorObject and w.shown then
			out[#out + 1] = w
		end
	end
	return out
end

local function rowCount()
	local n = 0
	for _, w in ipairs(created) do
		if w.kind == "Button" and w.scripts.OnClick and w.sel then
			n = n + 1
		end
	end
	return n
end

local function findScroll(index)
	local n = 0
	for _, w in ipairs(created) do
		if w.template == "ScrollFrameTemplate" then
			n = n + 1
			if n == index then
				return w
			end
		end
	end
end

local function rowFor(errorObject)
	for _, row in ipairs(visibleRows()) do
		if row.errorObject == errorObject then
			return row
		end
	end
end

local function rowTextCalls()
	local n = 0
	for _, w in ipairs(created) do
		if w.kind == "FontString" and w.template == "GameFontHighlightSmall" then
			n = n + w.setTextCalls
		end
	end
	return n
end

print("mainframe")

T.case("a 500 error list only builds the rows in view, newest first", function()
	local ns = freshUI()
	storeErrors(ns, 500)
	ns.UI.Open()
	local shown = visibleRows()
	eq(#shown, 21, "visible rows")
	assert(rowCount() <= 21, "pool grew past the viewport: " .. rowCount())
	local newest = false
	for _, row in ipairs(shown) do
		if row.errorObject.message == "err 500" then
			newest = true
		end
	end
	eq(newest, true, "newest error is on screen")
end)

T.case("scrolling swaps the visible slice and rebinds only the rows that moved", function()
	local ns = freshUI()
	storeErrors(ns, 500)
	ns.UI.Open()
	local list = findScroll(1)
	list:SetVerticalScroll(18 * 100)
	local messages = {}
	for _, row in ipairs(visibleRows()) do
		messages[row.errorObject.message] = true
	end
	eq(messages["err 400"], true, "list position 101 is err 400")
	eq(messages["err 500"], nil, "top of the list scrolled away")
	local before = rowTextCalls()
	list:SetVerticalScroll(18 * 101)
	eq(rowTextCalls() - before, 1, "one row reformatted for a one row scroll")
end)

T.case("a repeat count change reformats only that row", function()
	local ns = freshUI()
	storeErrors(ns, 100)
	ns.UI.Open()
	local target = ns.DB.errors[100]
	local before = rowTextCalls()
	target.counter = 5
	ns.UI.Refresh()
	eq(rowTextCalls() - before, 1, "reformatted rows")
	assert(rowFor(target).text.text:find("5x", 1, true), "row shows the new count")
end)

T.case("a repeat of the open error keeps the detail scroll position", function()
	local ns = freshUI()
	storeErrors(ns, 5)
	ns.UI.Open()
	local detail = findScroll(2)
	local detailText
	for _, w in ipairs(created) do
		if w.template == "ChatFontNormal" then
			detailText = w
		end
	end
	detailText.stringHeight = 2000
	-- Re-render with the tall text so the scroll range exists, then read down the page.
	ns.UI.SetDetailFontSize(2)
	detail.scrollChild.height = 2004
	detail:SetVerticalScroll(300)
	eq(detail:GetVerticalScroll(), 300, "scrolled")
	local selected = ns.DB.errors[5]
	selected.counter = 2
	ns.UI.Refresh()
	eq(detail:GetVerticalScroll(), 300, "position kept after a repeat")
end)

T.case("unchanged refreshes do not re-render the detail pane", function()
	local ns = freshUI()
	storeErrors(ns, 5)
	ns.UI.Open()
	local detailText
	for _, w in ipairs(created) do
		if w.template == "ChatFontNormal" then
			detailText = w
		end
	end
	local before = detailText.setTextCalls
	ns.UI.Refresh()
	ns.UI.Refresh()
	eq(detailText.setTextCalls, before, "SetText calls")
end)

T.case("picking another error snaps the detail pane back to the top", function()
	local ns = freshUI()
	storeErrors(ns, 5)
	ns.UI.Open()
	local detail = findScroll(2)
	for _, w in ipairs(created) do
		if w.template == "ChatFontNormal" then
			w.stringHeight = 2000
		end
	end
	detail.scrollChild.height = 2004
	detail:SetVerticalScroll(300)
	local other = rowFor(ns.DB.errors[1])
	other.scripts.OnClick(other)
	eq(detail:GetVerticalScroll(), 0, "scroll after switching error")
end)

T.case("opening a deep error from a chat link scrolls it into view", function()
	local ns = freshUI()
	storeErrors(ns, 500)
	local target = ns.DB.errors[3]
	ns.UI.OpenToError(target)
	local list = findScroll(1)
	assert(list:GetVerticalScroll() > 0, "list did not scroll")
	assert(rowFor(target), "target row not on screen")
end)

T.case("a received report opens on the Received tab", function()
	local ns = freshUI()
	storeErrors(ns, 3)
	local received = { message = "from a friend", session = ns.DB.GetSessionId(), counter = 1, source = "Friend-Realm", time = 2000 }
	ns.DB.Store(received)
	ns.UI.OpenToError(received)
	local shown = visibleRows()
	eq(#shown, 1, "only received rows listed")
	eq(shown[1].errorObject, received, "row")
end)

T.case("export keeps the newest errors in reading order and reports the cut", function()
	local ns, env = freshUI()
	storeErrors(ns, 200, { stack = ("s"):rep(5000) })
	ns.UI.Open()
	local exportBtn
	for _, w in ipairs(created) do
		if w.kind == "Button" and w.text == "Export" then
			exportBtn = w
		end
	end
	exportBtn.scripts.OnClick(exportBtn)
	local edit
	for i = #created, 1, -1 do
		if created[i].kind == "EditBox" then
			edit = created[i]
			break
		end
	end
	local text = edit.text
	assert(#text <= 200000 + 6000, "export not capped: " .. #text)
	assert(text:find("err 200", 1, true) > text:find("err 170", 1, true), "oldest first ordering")
	assert(not text:find("1x err 1\n", 1, true), "oldest errors left out")
	local notice = false
	for _, line in ipairs(env.printed) do
		if line:find("Export limited", 1, true) then
			notice = true
		end
	end
	eq(notice, true, "truncation notice")
end)

T.finish()
