-- Sentinel: MainFrame.lua
-- The display window: a two-pane layout with a scrollable error list on the left
-- and a syntax-highlighted detail pane on the right, plus tabs, search, and the
-- Copy / Export / Send / Clear / Reload actions.
--
-- Built lazily (only created the first time it is opened) and entirely from stable
-- widget APIs. List rows come from a frame pool (optimization guide sections 5 & 7).

local _, ns = ...
local UI = ns.UI
local DB = ns.DB
local L = ns.L
local Format = ns.Format
local Comm = ns.Comm

local ROW_HEIGHT = 18

-- Precompute the row label format once (constant colour code + format spec) so the
-- per-row path in RefreshRows never rebuilds it (optimization guide section 3).
local ROW_FORMAT = ns.SYNTAX.counter.code .. "%dx|r %s"

-- Window-scoped widgets (filled in by Build()).
local window, listScroll, listChild, detailScroll, detailChild, detailText, countText, searchBox, listEmpty
local rowPool
local tabButtons = {}

-- Forward declarations: the export dialog (showExport, below) reuses these skinning
-- helpers that are implemented further down, so they must exist as upvalues here.
local applyMawBorder, makePane

-- Current view state.
local state = {
	tab = "session", -- all | session | previous | received | search
	list = {},
	selected = nil,
	searchText = "",
}

-- Button skin (tabs, action buttons, close). Keep Blizzard's native button
-- textures, then desaturate/tint them the same way the close button looked good:
-- grey button art, white text, original bevel/border.
-----------------------------------------------------------------------
-- Target button colour: #2596be = rgb(37,150,190) -> 0.145 / 0.588 / 0.745.
-- These are vertex tints multiplied over the desaturated (grey) native art, so the
-- base values are boosted (~1.6x rest, ~2x hover) to land on the swatch on screen.
-- The engine clamps each channel at 1.0.
local BUTTON_REST_R, BUTTON_REST_G, BUTTON_REST_B = 0, 0.74, 1
local BUTTON_HOVER_R, BUTTON_HOVER_G, BUTTON_HOVER_B = 0.29, 1.0, 1.0
local BUTTON_ACTIVE_R, BUTTON_ACTIVE_G, BUTTON_ACTIVE_B = 0.29, 1.0, 1.0

local function tintButtonTextures(b, r, g, bl)
	local textures = b.sentinelButtonTextures
	if not textures then
		return
	end
	for i = 1, #textures do
		textures[i]:SetDesaturated(true)
		textures[i]:SetVertexColor(r, g, bl)
	end
end

local function applyButtonColors(b)
	if b.isActive then
		tintButtonTextures(b, BUTTON_ACTIVE_R, BUTTON_ACTIVE_G, BUTTON_ACTIVE_B)
	else
		tintButtonTextures(b, BUTTON_REST_R, BUTTON_REST_G, BUTTON_REST_B)
	end
	-- Selected-tab halo: the active/rest vertex tints are too close to read on
	-- their own, so a soft additive glow behind the active tab makes the current
	-- view obvious. Only tabs have sentinelGlow (action/close buttons skip it).
	if b.sentinelGlow then
		b.sentinelGlow:SetShown(b.isActive)
	end
end

local function onButtonEnter(b)
	tintButtonTextures(b, BUTTON_HOVER_R, BUTTON_HOVER_G, BUTTON_HOVER_B)
end

local function onButtonLeave(b)
	applyButtonColors(b)
end

local function collectButtonTextures(b)
	local textures = {}
	local n = 0
	local function add(texture)
		if texture and texture.SetDesaturated then
			n = n + 1
			textures[n] = texture
		end
	end

	add(b.GetNormalTexture and b:GetNormalTexture())
	add(b.GetPushedTexture and b:GetPushedTexture())
	add(b.GetHighlightTexture and b:GetHighlightTexture())
	add(b.GetDisabledTexture and b:GetDisabledTexture())
	add(b.Left)
	add(b.Middle)
	add(b.Right)

	local regions = { b:GetRegions() }
	for i = 1, #regions do
		if regions[i] and regions[i].GetObjectType and regions[i]:GetObjectType() == "Texture" then
			add(regions[i])
		end
	end

	b.sentinelButtonTextures = textures
end

local function skinButton(b)
	collectButtonTextures(b)
	local fs = b:GetFontString()
	if fs then
		fs:SetTextColor(1, 1, 1)
	end
	b:HookScript("OnEnter", onButtonEnter)
	b:HookScript("OnLeave", onButtonLeave)
	applyButtonColors(b)
end

local function skinCloseButton(b)
	collectButtonTextures(b)
	b:HookScript("OnEnter", onButtonEnter)
	b:HookScript("OnLeave", onButtonLeave)
	applyButtonColors(b)
end

-- Hover help for tabs and action buttons. The title reuses the button's own label
-- (brand cyan, matching the row tooltip header) and the body explains what it does,
-- so Copy vs Export and the four tabs are no longer guesswork. HookScript appends to
-- the colour hooks set in skinButton, so both still fire.
local function setButtonTooltip(b, title, body)
	b:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(title, 0, 0.749, 1)
		if body then
			GameTooltip:AddLine(body, 1, 1, 1, true)
		end
		GameTooltip:Show()
	end)
	b:HookScript("OnLeave", GameTooltip_Hide)
end

-----------------------------------------------------------------------
-- Data: build the list for the active tab
-----------------------------------------------------------------------
local function buildList()
	local tab = state.tab
	if tab == "all" then
		return DB.GetAll()
	elseif tab == "session" then
		return DB.GetBySession(DB.GetSessionId())
	elseif tab == "previous" then
		return DB.GetBySession(DB.GetSessionId() - 1)
	elseif tab == "received" then
		return DB.GetReceived()
	elseif tab == "search" then
		local out = {}
		local needle = state.searchText:lower()
		local all = DB.GetAll()
		for i = 1, #all do
			local e = all[i]
			local m = e.message
			if type(m) == "string" and not ns.G.issecretvalue(m) and m:lower():find(needle, 1, true) then
				out[#out + 1] = e
			end
		end
		return out
	end
	return {}
end

-----------------------------------------------------------------------
-- Detail pane
-----------------------------------------------------------------------
local function updateDetail()
	if not detailText then
		return
	end
	local err = state.selected
	local text
	if err then
		text = Format.FormatError(err)
	else
		text = "|cff808080" .. L["Select an error on the left to see its full stack trace and locals here."] .. "|r"
	end
	detailText:SetText(text)
	-- Resize the scroll child so the scrollbar reflects the full formatted body.
	local height = detailText:GetStringHeight()
	detailChild:SetSize(458, math.max(height + 4, 1))
	if detailScroll then
		-- Snap back to the top when switching errors. With ScrollFrameTemplate the
		-- thin scrollbar drives the position, so nudge its value too (guarded, since
		-- the field/method only exist on the modern template) and keep the direct
		-- SetVerticalScroll as a fallback for the actual content offset.
		local bar = detailScroll.ScrollBar
		if bar and bar.SetScrollPercentage then
			bar:SetScrollPercentage(0)
		end
		detailScroll:SetVerticalScroll(0)
	end
end

-----------------------------------------------------------------------
-- List rows (frame pool)
-----------------------------------------------------------------------
local function onRowClick(row)
	state.selected = row.errorObject
	UI.RefreshRows()
	updateDetail()
end

-- Hover summary: when it last fired, how many times, which session, and -- if the
-- bug was shared by another player -- who sent it.
local function onRowEnter(row)
	local err = row.errorObject
	if not err then
		return
	end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:AddLine(ns.DISPLAY_NAME, 0, 0.749, 1)
	GameTooltip:AddLine(Format.ShortMessage(err), 1, 1, 1, true)
	GameTooltip:AddLine(" ")
	GameTooltip:AddDoubleLine(L["Occurrences"], tostring(err.counter or 1), 0.8, 0.8, 0.8, 1, 1, 1)
	if err.time then
		GameTooltip:AddDoubleLine(L["Last seen"], date("%Y-%m-%d %H:%M:%S", err.time), 0.8, 0.8, 0.8, 1, 1, 1)
	end
	GameTooltip:AddDoubleLine(L["Session"], tostring(err.session or "?"), 0.8, 0.8, 0.8, 1, 1, 1)
	if err.source then
		GameTooltip:AddDoubleLine(L["Sent by"], tostring(err.source), 0.8, 0.8, 0.8, 1, 0.5, 0)
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine(L["Click to view full details."], 0.5, 0.5, 0.5)
	GameTooltip:Show()
end

local function acquireRow()
	local row = rowPool:Acquire()
	if not row.initialized then
		row.initialized = true
		row:SetHeight(ROW_HEIGHT)
		row:SetWidth(256)
		row:RegisterForClicks("LeftButtonUp")

		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetAtlas("groupfinder-button-highlight")
		hl:SetDesaturated(true)
		hl:SetVertexColor(ns.SYNTAX.counter:GetRGB())
		hl:SetBlendMode("ADD")

		row.sel = row:CreateTexture(nil, "BACKGROUND")
		row.sel:SetAllPoints()
		row.sel:SetAtlas("groupfinder-highlightbar-green")
		row.sel:SetDesaturation(1)
		row.sel:SetBlendMode("ADD")
		row.sel:Hide()

		row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.text:SetPoint("LEFT", 4, 0)
		row.text:SetPoint("RIGHT", -4, 0)
		row.text:SetJustifyH("LEFT")
		row.text:SetWordWrap(false)

		row:SetScript("OnClick", onRowClick)
		row:SetScript("OnEnter", onRowEnter)
		row:SetScript("OnLeave", GameTooltip_Hide)
	end
	return row
end

function UI.RefreshRows()
	if not listChild then
		return
	end
	rowPool:ReleaseAll()

	local list = state.list
	local n = #list
	for i = 1, n do
		-- Show newest first.
		local err = list[n - i + 1]
		local row = acquireRow()
		row.errorObject = err
		local count = err.counter or 1
		local label = Format.ShortMessage(err)
		if err.source then
			label = "|cffff8800*|r " .. label
		end
		row.text:SetText(ROW_FORMAT:format(count, label))
		row.sel:SetShown(err == state.selected)
		row:SetPoint("TOPLEFT", listChild, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
		row:SetPoint("TOPRIGHT", listChild, "TOPRIGHT", 0, -(i - 1) * ROW_HEIGHT)
		row:Show()
	end

	listChild:SetHeight(math.max(n * ROW_HEIGHT, 1))
	countText:SetText((ns.SYNTAX.counter.code .. "%d|r"):format(n))
	if listEmpty then
		listEmpty:SetShown(n == 0)
	end
end

-----------------------------------------------------------------------
-- Refresh everything (called on open, tab change, capture, etc.)
-----------------------------------------------------------------------
function UI.Refresh()
	if not window or not window:IsShown() then
		return
	end
	state.list = buildList()

	-- Keep the current selection if it's still present; otherwise pick the newest.
	local stillThere = false
	for i = 1, #state.list do
		if state.list[i] == state.selected then
			stillThere = true
			break
		end
	end
	if not stillThere then
		state.selected = state.list[#state.list]
	end

	UI.RefreshRows()
	updateDetail()
end

-----------------------------------------------------------------------
-- Tabs
-----------------------------------------------------------------------
local function selectTab(tab)
	state.tab = tab
	state.selected = nil
	if tab ~= "search" then
		searchBox:SetText("")
	end
	for _, b in pairs(tabButtons) do
		b.isActive = (b.tab == tab)
		applyButtonColors(b)
	end
	UI.Refresh()
end

-----------------------------------------------------------------------
-- Export / Copy dialog (reusable read-only text box)
-----------------------------------------------------------------------
local exportFrame
local function showExport(text)
	if not exportFrame then
		exportFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
		exportFrame:SetSize(560, 380)
		exportFrame:SetPoint("CENTER")
		exportFrame:SetFrameStrata("FULLSCREEN_DIALOG")
		-- Same skin as the main window: Maw border + dark #121212 fill.
		applyMawBorder(exportFrame)
		exportFrame:EnableMouse(true)
		exportFrame:SetMovable(true)
		exportFrame:RegisterForDrag("LeftButton")
		exportFrame:SetScript("OnDragStart", exportFrame.StartMoving)
		exportFrame:SetScript("OnDragStop", exportFrame.StopMovingOrSizing)

		-- Brand title to match the main frame, with the copy hint beneath it.
		local title = exportFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
		title:SetPoint("TOPLEFT", 16, -16)
		title:SetText(ns.COLORS.chat .. ns.DISPLAY_NAME .. "|r")

		local hint = exportFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		hint:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 5, 0)
		hint:SetTextColor(63 / 255, 63 / 255, 70 / 255)
		hint:SetText(L["Select the text below, then press Ctrl-C to copy."])

		local close = CreateFrame("Button", nil, exportFrame, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", -15, -15)
		skinCloseButton(close)

		-- Recessed charcoal pane around the text box, like the main frame's panes.
		local pane = makePane(exportFrame)
		pane:SetPoint("TOPLEFT", 14, -42)
		pane:SetPoint("BOTTOMRIGHT", -14, 14)

		local scroll = CreateFrame("ScrollFrame", nil, pane, "ScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 6, -12)
		scroll:SetPoint("BOTTOMRIGHT", -26, 6)

		local edit = CreateFrame("EditBox", nil, scroll)
		edit:SetMultiLine(true)
		edit:SetFontObject("ChatFontNormal")
		edit:SetWidth(500)
		edit:SetTextColor(0.85, 0.85, 0.85)
		edit:SetAutoFocus(false)
		edit:SetScript("OnEscapePressed", edit.ClearFocus)
		scroll:SetScrollChild(edit)
		exportFrame.edit = edit
	end
	exportFrame.edit:SetText(text or "")
	exportFrame:Show()
	exportFrame.edit:HighlightText()
	exportFrame.edit:SetFocus()
end

-----------------------------------------------------------------------
-- Send dialog
-----------------------------------------------------------------------
local function getStaticPopupEditBox(popup)
	return popup.EditBox or popup.editBox
end

StaticPopupDialogs["SENTINEL_SEND"] = {
	text = L["Send the currently selected error to a player."],
	button1 = L["Send"],
	button2 = CLOSE,
	hasEditBox = true,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	enterClicksFirstButton = true,
	OnAccept = function(self)
		local editBox = getStaticPopupEditBox(self)
		local name = editBox and editBox:GetText() or ""
		Comm.SendError(name, state.selected)
	end,
	OnShow = function(self)
		local editBox = getStaticPopupEditBox(self)
		if editBox then
			editBox:SetText("")
		end
	end,
	preferredIndex = 3,
}

-----------------------------------------------------------------------
-- Build the window
-----------------------------------------------------------------------
local function makeActionButton(parent, text, width, onClick, tooltip)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	skinButton(b)
	if tooltip then
		setButtonTooltip(b, text, tooltip)
	end

	return b
end

-- Wrap a frame in Blizzard's ornate Maw / runecarving tooltip border,
-- exactly the way SharedTooltip_SetBackdropStyle dresses the "jailerstower" style
-- (layoutType = "TooltipMawLayout"), but intentionally omit the topper overlay.
-- We keep our own dark #121212 center fill and only borrow the edge art, and fall
-- back to the classic dialog border if the layout ever goes away.
function applyMawBorder(frame)
	local layout = NineSliceUtil and NineSliceUtil.GetLayout and NineSliceUtil.GetLayout("TooltipMawLayout")
	if layout then
		local nine = CreateFrame("Frame", nil, frame, "NineSlicePanelTemplate")
		nine:SetAllPoints(frame)
		if pcall(NineSliceUtil.ApplyLayout, nine, layout) then
			frame.NineSlice = nine
			-- The NineSlice is a child frame, so by default it (and its dark Center)
			-- render *above* the window's content. Drop it to the window's own frame
			-- level so the border + fill sit behind the title/tabs/panes, which live
			-- at level +1.
			nine:SetFrameLevel(frame:GetFrameLevel())
			-- Paint the layout's own center region with our flat dark fill. The
			-- NineSlice anchors Center *inside* the border art, so the background
			-- can never bleed past the edge (a full-rect backdrop fill did).
			if nine.Center then
				nine.Center:SetColorTexture(unpack(ns.THEME.window))
				nine.Center:SetAlpha(1)
			else
				-- No center piece: inset the backdrop fill so it stays inside the edge.
				frame:SetBackdrop({
					bgFile = "Interface\\Buttons\\WHITE8X8",
					insets = { left = 6, right = 6, top = 6, bottom = 6 },
				})
				frame:SetBackdropColor(unpack(ns.THEME.window))
			end
			return
		end
	end

	-- Fallback: classic gold dialog border.
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	frame:SetBackdropColor(unpack(ns.THEME.window))
	frame:SetBackdropBorderColor(unpack(ns.THEME.paneBorder))
end

-- A flat, charcoal panel with a hairline border (modern dark-mode look).
function makePane(parent)
	local p = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	p:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	p:SetBackdropColor(unpack(ns.THEME.pane))
	p:SetBackdropBorderColor(unpack(ns.THEME.paneBorder))
	return p
end

local function onTabClick(b)
	selectTab(b.tab)
end

local function makeTab(parent, text, tab, tooltip)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(120, 22)
	b:SetText(text)
	b.tab = tab
	b:SetScript("OnClick", onTabClick)
	skinButton(b)
	if tooltip then
		setButtonTooltip(b, text, tooltip)
	end

	-- Selected-tab highlight: Blizzard's auction-house nav "select" atlas is built
	-- for rectangular nav buttons, so it hugs the tab shape. Drawn on OVERLAY with
	-- additive blend and the theme cyan tint so it sits over the grey button art
	-- without hiding the bevel or label.
	local glow = b:CreateTexture(nil, "OVERLAY")
	glow:SetAtlas("auctionhouse-nav-button-secondary-select", false)
	glow:SetDesaturated(true)
	glow:SetVertexColor(BUTTON_REST_R, BUTTON_REST_G, BUTTON_REST_B)
	glow:SetBlendMode("ADD")
	glow:SetPoint("TOPLEFT", -0, 0)
	glow:SetPoint("BOTTOMRIGHT", 0, -0)
	glow:Hide()
	b.sentinelGlow = glow

	tabButtons[#tabButtons + 1] = b
	return b
end

local function Build()
	window = CreateFrame("Frame", "SentinelFrame", UIParent, "BackdropTemplate")
	window:SetSize(820, 500)
	window:SetPoint("CENTER")
	window:SetFrameStrata("DIALOG")
	window:SetToplevel(true)
	window:EnableMouse(true)
	window:SetMovable(true)
	window:SetClampedToScreen(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", window.StartMoving)
	window:SetScript("OnDragStop", window.StopMovingOrSizing)
	applyMawBorder(window)
	tinsert(UISpecialFrames, "SentinelFrame") -- closes on Escape

	local title = window:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText(ns.COLORS.chat .. ns.DISPLAY_NAME .. "|r")

	-- Version tag: two font sizes smaller than the title (Large -> Normal -> Small),
	-- Muted Charcoal (#3F3F46), baseline-aligned just to the right of the name.
	local version = window:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 5, 0)
	version:SetTextColor(63 / 255, 63 / 255, 70 / 255)
	version:SetText("v" .. ns.VERSION)

	countText = window:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	countText:SetPoint("LEFT", version, "RIGHT", 8, 2)

	local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -15, -15)
	skinCloseButton(close)

	-- Tabs
	local tabAll = makeTab(window, L["All bugs"], "all", L["Every error stored across every session, including reports received from other players."])
	tabAll:SetPoint("TOPLEFT", 14, -42)
	local tabSession = makeTab(window, L["This session"], "session", L["Errors caught since your last login or UI reload."])
	tabSession:SetPoint("LEFT", tabAll, "RIGHT", 4, 0)
	local tabPrev = makeTab(window, L["Previous session"], "previous", L["Errors caught during your previous play session."])
	tabPrev:SetPoint("LEFT", tabSession, "RIGHT", 4, 0)
	local tabRecv = makeTab(window, L["Received"], "received", L["Error reports other players have sent to you with Sentinel."])
	tabRecv:SetPoint("LEFT", tabPrev, "RIGHT", 4, 0)

	-- Search box
	searchBox = CreateFrame("EditBox", nil, window, "SearchBoxTemplate")
	searchBox:SetSize(200, 22)
	searchBox:SetPoint("TOPRIGHT", -16, -42)
	searchBox:SetAutoFocus(false)
	searchBox:SetScript("OnTextChanged", function(self)
		SearchBoxTemplate_OnTextChanged(self)
		local text = self:GetText()
		if text and text ~= "" and not text:find("^%s*$") then
			state.searchText = text
			state.tab = "search"
			state.selected = nil
			for _, b in pairs(tabButtons) do
				b.isActive = false
				applyButtonColors(b)
			end
			UI.Refresh()
		elseif state.tab == "search" then
			selectTab("session")
		end
	end)

	-- Header divider under the title/tabs
	local divider = window:CreateTexture(nil, "ARTWORK")
	divider:SetHeight(1)
	divider:SetPoint("TOPLEFT", 14, -70)
	divider:SetPoint("TOPRIGHT", -14, -70)
	divider:SetColorTexture(1, 1, 1, 0.10)

	-- Left: error list inside a flat charcoal pane
	local listInset = makePane(window)
	listInset:SetPoint("TOPLEFT", 14, -78)
	listInset:SetSize(288, 376)

	-- ScrollFrameTemplate (10.1+) is the modern replacement for the chunky
	-- UIPanelScrollFrameTemplate: it auto-creates a thin MinimalScrollBar and
	-- manages range + mouse wheel itself, so we no longer wire those by hand.
	listScroll = CreateFrame("ScrollFrame", nil, listInset, "ScrollFrameTemplate")
	listScroll:SetPoint("TOPLEFT", 6, -12)
	listScroll:SetPoint("BOTTOMRIGHT", -26, 6)
	listChild = CreateFrame("Frame", nil, listScroll)
	listChild:SetSize(262, 1)
	listScroll:SetScrollChild(listChild)

	listEmpty = listInset:CreateFontString(nil, "ARTWORK", "GameFontDisableLarge")
	listEmpty:SetPoint("CENTER", 0, 20)
	listEmpty:SetWidth(240)
	listEmpty:SetText(L["No errors caught \226\128\148 your UI is clean."])

	rowPool = CreateFramePool("Button", listChild)

	-- Right: detail pane inside a flat charcoal pane
	local detailInset = makePane(window)
	detailInset:SetPoint("TOPLEFT", listInset, "TOPRIGHT", 12, 0)
	detailInset:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -14, 44)

	detailScroll = CreateFrame("ScrollFrame", nil, detailInset, "ScrollFrameTemplate")
	detailScroll:SetPoint("TOPLEFT", 6, -12)
	detailScroll:SetPoint("BOTTOMRIGHT", -26, 6)

	-- FontString (not EditBox): read-only detail text with reliable per-token |c
	-- coloring. EditBox mishandles multiple inline color codes on a single line,
	-- which left locals looking monochromatic even when Format.lua painted each
	-- token. Copy/Export still use PlainError, so nothing is lost.
	detailChild = CreateFrame("Frame", nil, detailScroll)
	detailChild:SetSize(458, 1)
	detailText = detailChild:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
	detailText:SetPoint("TOPLEFT")
	detailText:SetWidth(458)
	detailText:SetJustifyH("LEFT")
	detailText:SetJustifyV("TOP")
	detailText:SetWordWrap(true)
	detailText:SetNonSpaceWrap(false)
	detailText:SetTextColor(ns.SYNTAX.stackText:GetRGB())
	detailScroll:SetScrollChild(detailChild)

	-- Bottom action buttons
	local copyBtn = makeActionButton(window, L["Copy"], 90, function()
		if state.selected then
			showExport(Format.PlainError(state.selected))
		end
	end, L["Copies the one error selected on the left. Opens a text box \226\128\148 select all and press Ctrl-C."])
	copyBtn:SetPoint("BOTTOMLEFT", 16, 14)

	local exportBtn = makeActionButton(window, L["Export"], 90, function()
		local parts = {}
		for i = 1, #state.list do
			parts[#parts + 1] = Format.PlainError(state.list[i])
		end
		showExport(table.concat(parts, "\n\n" .. ("-"):rep(40) .. "\n\n"))
	end, L["Exports every error in the current tab at once. Opens a text box \226\128\148 select all and press Ctrl-C."])
	exportBtn:SetPoint("LEFT", copyBtn, "RIGHT", 6, 0)

	if Comm.IsAvailable() then
		local sendBtn = makeActionButton(window, L["Send"], 90, function()
			if state.selected then
				StaticPopup_Show("SENTINEL_SEND")
			else
				ns.Print(L["Nothing selected to send."])
			end
		end, L["Send the selected error to another Sentinel user. Unavailable inside instances."])
		sendBtn:SetPoint("LEFT", exportBtn, "RIGHT", 6, 0)
	end

	local reloadBtn = makeActionButton(window, L["Reload UI"], 100, function()
		ReloadUI()
	end, L["Reload your interface \226\128\148 handy after disabling a broken addon."])
	reloadBtn:SetPoint("BOTTOMRIGHT", -16, 14)

	local clearBtn = makeActionButton(window, L["Clear"], 90, function()
		DB.Reset()
		state.selected = nil
		UI.Refresh()
		-- Refresh the minimap count directly. Do NOT fire Sentinel.ErrorCaptured here:
		-- that event also drives the new-error alert, so reusing it for a wipe would
		-- falsely announce "a new error was caught" right after clearing.
		if UI.UpdateMinimapCount then
			UI.UpdateMinimapCount()
		end
	end, L["Permanently delete every stored error from every session."])
	clearBtn:SetPoint("RIGHT", reloadBtn, "LEFT", -6, 0)

	window:SetScript("OnShow", function()
		-- Smart default on every open: show This session (most relevant to what you're
		-- doing now). If this session is clean but older bugs exist, fall back to All
		-- bugs so the window never opens to a confusingly empty list.
		local default = "session"
		if DB.SessionCount() == 0 and DB.Count() > 0 then
			default = "all"
		end
		selectTab(default)
	end)

	-- CreateFrame returns a frame that is already shown, so the first UI.Open()'s
	-- window:Show() would be a no-op that never fires OnShow (leaving no tab
	-- selected). Hide it now so the first open is a real hidden->shown transition.
	window:Hide()
end

-----------------------------------------------------------------------
-- Public API
-----------------------------------------------------------------------
function UI.IsShown()
	return window and window:IsShown()
end

function UI.Open()
	if not window then
		Build()
	end
	window:Show()
end

function UI.Close()
	if window then
		window:Hide()
	end
end

function UI.Toggle()
	if UI.IsShown() then
		UI.Close()
	else
		UI.Open()
	end
end

-- Refresh live whether a bug is caught locally or received from another player.
-- One shared named handler (no per-registration closure -- optimization guide
-- section 3) reused across both events. (Unique owner table: CallbackRegistryMixin
-- forbids one owner registering the *same* event twice, but distinct events are
-- fine, and other Sentinel files subscribe to these events with their own owners.)
local CB_OWNER = {}
local function onErrorEvent()
	UI.Refresh()
end
EventRegistry:RegisterCallback("Sentinel.ErrorCaptured", onErrorEvent, CB_OWNER)
EventRegistry:RegisterCallback("Sentinel.ErrorReceived", onErrorEvent, CB_OWNER)
