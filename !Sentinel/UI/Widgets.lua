-- Sentinel: Widgets.lua
-- The window's building blocks, drawn only from textures bundled in Media\Game (see
-- tools/gen_blizzard_media.py). Nothing here inherits a Blizzard template that brings its
-- own art, so a client patch that renames or drops an atlas cannot blank the window.
-- The look matches the game pieces the window used before: the Maw tooltip border, the
-- classic panel button, the red close button, the common search box and the thin scrollbar.

local _, ns = ...
local W = {}
ns.Widgets = W

local CreateFrame = CreateFrame
local math_max = math.max
local math_min = math.min
local math_floor = math.floor

local GAME_MEDIA = ns.MEDIA .. "Game\\"
local MEDIA_DATA = ns.MEDIA_DATA

-- Bundled path for a game texture name, so backdrops can reference it too.
function W.Path(name)
	local entry = MEDIA_DATA[name]
	return entry and (GAME_MEDIA .. entry.file .. ".tga")
end
local Path = W.Path

-- Points a texture at a bundled copy. Tiled pieces repeat instead of stretching, and
-- useSize sizes the region to the piece's display size like useAtlasSize does.
function W.SetTexture(texture, name, useSize)
	local entry = MEDIA_DATA[name]
	if not entry then
		return
	end
	local wrapH = entry.tileH and "REPEAT" or "CLAMP"
	local wrapV = entry.tileV and "REPEAT" or "CLAMP"
	texture:SetTexture(GAME_MEDIA .. entry.file .. ".tga", wrapH, wrapV)
	texture:SetHorizTile(entry.tileH)
	texture:SetVertTile(entry.tileV)
	if useSize then
		texture:SetSize(entry.w, entry.h)
	end
end
local SetTexture = W.SetTexture

-----------------------------------------------------------------------
-- Maw border with a flat fill
-----------------------------------------------------------------------
local MAW = "Tooltip-Maw-NineSlice-"

-- Corners are fixed squares and the edges tile between them. The fill sits inside the
-- edge art so it never bleeds past the border.
function W.ApplyMawBorder(frame, r, g, b, a)
	local tl = frame:CreateTexture(nil, "BORDER")
	SetTexture(tl, MAW .. "CornerTopLeft", true)
	tl:SetPoint("TOPLEFT")
	local tr = frame:CreateTexture(nil, "BORDER")
	SetTexture(tr, MAW .. "CornerTopRight", true)
	tr:SetPoint("TOPRIGHT")
	local bl = frame:CreateTexture(nil, "BORDER")
	SetTexture(bl, MAW .. "CornerBottomLeft", true)
	bl:SetPoint("BOTTOMLEFT")
	local br = frame:CreateTexture(nil, "BORDER")
	SetTexture(br, MAW .. "CornerBottomRight", true)
	br:SetPoint("BOTTOMRIGHT")

	local top = frame:CreateTexture(nil, "BORDER")
	SetTexture(top, "_" .. MAW .. "EdgeTop", true)
	top:SetPoint("TOPLEFT", tl, "TOPRIGHT")
	top:SetPoint("TOPRIGHT", tr, "TOPLEFT")
	local bottom = frame:CreateTexture(nil, "BORDER")
	SetTexture(bottom, "_" .. MAW .. "EdgeBottom", true)
	bottom:SetPoint("BOTTOMLEFT", bl, "BOTTOMRIGHT")
	bottom:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT")
	local left = frame:CreateTexture(nil, "BORDER")
	SetTexture(left, "!" .. MAW .. "EdgeLeft", true)
	left:SetPoint("TOPLEFT", tl, "BOTTOMLEFT")
	left:SetPoint("BOTTOMLEFT", bl, "TOPLEFT")
	local right = frame:CreateTexture(nil, "BORDER")
	SetTexture(right, "!" .. MAW .. "EdgeRight", true)
	right:SetPoint("TOPRIGHT", tr, "BOTTOMRIGHT")
	right:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT")

	local fill = frame:CreateTexture(nil, "BACKGROUND")
	fill:SetPoint("TOPLEFT", 6, -6)
	fill:SetPoint("BOTTOMRIGHT", -6, 6)
	fill:SetColorTexture(r, g, b, a)
	frame.SentinelFill = fill
end

-- Flat panel with the hairline tooltip edge.
local PANE_BACKDROP
function W.CreatePane(parent, color, borderColor)
	if not PANE_BACKDROP then
		PANE_BACKDROP = {
			bgFile = Path("WHITE8X8"),
			edgeFile = Path("UI-Tooltip-Border"),
			edgeSize = 16,
			insets = { left = 4, right = 4, top = 4, bottom = 4 },
		}
	end
	local p = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	p:SetBackdrop(PANE_BACKDROP)
	p:SetBackdropColor(color[1], color[2], color[3], color[4])
	p:SetBackdropBorderColor(borderColor[1], borderColor[2], borderColor[3], borderColor[4])
	return p
end

-----------------------------------------------------------------------
-- Panel button (three-slice, swaps to the pressed art while held)
-----------------------------------------------------------------------
-- Left cap, stretchable middle and right cap of the 128x32 button sheet.
local BUTTON_LEFT = { 0, 0.09375, 0, 0.6875 }
local BUTTON_MIDDLE = { 0.09375, 0.53125, 0, 0.6875 }
local BUTTON_RIGHT = { 0.53125, 0.625, 0, 0.6875 }

local function setButtonArt(b, name)
	local path = Path(name)
	b.Left:SetTexture(path)
	b.Middle:SetTexture(path)
	b.Right:SetTexture(path)
end

local function onButtonMouseDown(b)
	if b:IsEnabled() then
		setButtonArt(b, "UI-Panel-Button-Down")
	end
end

local function onButtonMouseUp(b)
	if b:IsEnabled() then
		setButtonArt(b, "UI-Panel-Button-Up")
	end
end

local function onButtonEnable(b)
	setButtonArt(b, "UI-Panel-Button-Up")
end

local function onButtonDisable(b)
	setButtonArt(b, "UI-Panel-Button-Disabled")
end

local function sliceTexture(b, coords)
	local t = b:CreateTexture(nil, "BACKGROUND")
	t:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
	return t
end

function W.CreateButton(parent, text, width, height)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(width, height or 22)
	b.Left = sliceTexture(b, BUTTON_LEFT)
	b.Left:SetWidth(12)
	b.Left:SetPoint("TOPLEFT")
	b.Left:SetPoint("BOTTOMLEFT")
	b.Right = sliceTexture(b, BUTTON_RIGHT)
	b.Right:SetWidth(12)
	b.Right:SetPoint("TOPRIGHT")
	b.Right:SetPoint("BOTTOMRIGHT")
	b.Middle = sliceTexture(b, BUTTON_MIDDLE)
	b.Middle:SetPoint("TOPLEFT", b.Left, "TOPRIGHT")
	b.Middle:SetPoint("BOTTOMRIGHT", b.Right, "BOTTOMLEFT")
	setButtonArt(b, "UI-Panel-Button-Up")

	local highlight = b:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetTexture(Path("UI-Panel-Button-Highlight"))
	highlight:SetTexCoord(0, 0.625, 0, 0.6875)
	highlight:SetBlendMode("ADD")
	highlight:SetAllPoints()
	b:SetHighlightTexture(highlight)

	b:SetNormalFontObject("GameFontNormal")
	b:SetHighlightFontObject("GameFontHighlight")
	b:SetDisabledFontObject("GameFontDisable")
	b:SetText(text)

	b:SetScript("OnMouseDown", onButtonMouseDown)
	b:SetScript("OnMouseUp", onButtonMouseUp)
	-- A button hidden while held never sees its mouse-up, so reset on show.
	b:SetScript("OnShow", onButtonMouseUp)
	b:SetScript("OnEnable", onButtonEnable)
	b:SetScript("OnDisable", onButtonDisable)
	return b
end

-----------------------------------------------------------------------
-- Close button
-----------------------------------------------------------------------
function W.CreateCloseButton(parent, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(24, 24)
	local normal = b:CreateTexture(nil, "ARTWORK")
	SetTexture(normal, "RedButton-Exit")
	normal:SetAllPoints()
	b:SetNormalTexture(normal)
	local pushed = b:CreateTexture(nil, "ARTWORK")
	SetTexture(pushed, "RedButton-exit-pressed")
	pushed:SetAllPoints()
	b:SetPushedTexture(pushed)
	local disabled = b:CreateTexture(nil, "ARTWORK")
	SetTexture(disabled, "RedButton-Exit-Disabled")
	disabled:SetAllPoints()
	b:SetDisabledTexture(disabled)
	local highlight = b:CreateTexture(nil, "HIGHLIGHT")
	SetTexture(highlight, "RedButton-Highlight")
	highlight:SetAllPoints()
	highlight:SetBlendMode("ADD")
	b:SetHighlightTexture(highlight)
	b:SetScript("OnClick", onClick or function(self)
		self:GetParent():Hide()
	end)
	return b
end

-----------------------------------------------------------------------
-- Search box
-----------------------------------------------------------------------
local function updateSearchChrome(box)
	local hasText = box:GetText() ~= ""
	box.Instructions:SetShown(not hasText)
	box.ClearButton:SetShown(hasText)
	local focused = box:HasFocus()
	local shade = (focused or hasText) and 1 or 0.6
	box.SearchIcon:SetVertexColor(shade, shade, shade)
end

function W.CreateSearchBox(parent, width, placeholder)
	local box = CreateFrame("EditBox", nil, parent)
	box:SetSize(width, 20)
	box:SetAutoFocus(false)
	box:SetFontObject("GameFontHighlightSmall")
	box:SetTextInsets(16, 20, 0, 0)

	local left = box:CreateTexture(nil, "BACKGROUND")
	SetTexture(left, "common-search-border-left")
	left:SetSize(8, 20)
	left:SetPoint("LEFT", -5, 0)
	local right = box:CreateTexture(nil, "BACKGROUND")
	SetTexture(right, "common-search-border-right")
	right:SetSize(8, 20)
	right:SetPoint("RIGHT")
	local middle = box:CreateTexture(nil, "BACKGROUND")
	SetTexture(middle, "common-search-border-middle")
	middle:SetHeight(20)
	middle:SetPoint("LEFT", left, "RIGHT")
	middle:SetPoint("RIGHT", right, "LEFT")

	box.SearchIcon = box:CreateTexture(nil, "OVERLAY")
	SetTexture(box.SearchIcon, "common-search-magnifyingglass")
	box.SearchIcon:SetSize(10, 10)
	box.SearchIcon:SetPoint("LEFT", 1, -1)

	box.Instructions = box:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	box.Instructions:SetPoint("LEFT", 16, 0)
	box.Instructions:SetPoint("RIGHT", -20, 0)
	box.Instructions:SetJustifyH("LEFT")
	box.Instructions:SetText(placeholder or SEARCH or "Search")

	local clear = CreateFrame("Button", nil, box)
	clear:SetSize(17, 17)
	clear:SetPoint("RIGHT", -3, 0)
	local clearIcon = clear:CreateTexture(nil, "ARTWORK")
	SetTexture(clearIcon, "common-search-clearbutton")
	clearIcon:SetSize(10, 10)
	clearIcon:SetPoint("TOPLEFT", 3, -3)
	clearIcon:SetAlpha(0.5)
	clear:SetScript("OnEnter", function()
		clearIcon:SetAlpha(1)
	end)
	clear:SetScript("OnLeave", function()
		clearIcon:SetAlpha(0.5)
	end)
	clear:SetScript("OnClick", function()
		box:SetText("")
		box:ClearFocus()
	end)
	clear:Hide()
	box.ClearButton = clear

	box:SetScript("OnEscapePressed", box.ClearFocus)
	box:SetScript("OnEnterPressed", box.ClearFocus)
	box:SetScript("OnEditFocusGained", updateSearchChrome)
	box:SetScript("OnEditFocusLost", updateSearchChrome)
	-- Callers hook OnTextChanged for their own filtering, this keeps the chrome current.
	box:SetScript("OnTextChanged", updateSearchChrome)
	updateSearchChrome(box)
	return box
end

-----------------------------------------------------------------------
-- Scroll frame with a thin scrollbar
-----------------------------------------------------------------------
-- A plain ScrollFrame plus a Slider. The slider's own thumb texture is invisible and
-- only sizes the hit area; the three-piece thumb art is anchored to it, so dragging and
-- track clicks use the slider's native behaviour.
local THUMB_MIN = 23
local BAR_WIDTH = 8
local ARROW_GAP = 19

local THUMB_STATES = {
	up = { "minimal-scrollbar-small-thumb-top", "minimal-scrollbar-small-thumb-middle", "minimal-scrollbar-small-thumb-bottom" },
	over = { "minimal-scrollbar-small-thumb-top-over", "minimal-scrollbar-small-thumb-middle-over", "minimal-scrollbar-small-thumb-bottom-over" },
	down = { "minimal-scrollbar-small-thumb-top-down", "minimal-scrollbar-small-thumb-middle-down", "minimal-scrollbar-small-thumb-bottom-down" },
}

local function setThumbState(bar, stateName)
	if bar.thumbState == stateName then
		return
	end
	bar.thumbState = stateName
	local names = THUMB_STATES[stateName]
	SetTexture(bar.ThumbBegin, names[1])
	SetTexture(bar.ThumbMiddle, names[2])
	SetTexture(bar.ThumbEnd, names[3])
end

local function refreshThumbState(bar)
	if bar.dragging then
		setThumbState(bar, "down")
	elseif bar:IsMouseOver() then
		setThumbState(bar, "over")
	else
		setThumbState(bar, "up")
	end
end

-- Size the thumb to the visible share of the content and show the bar only when the
-- content actually overflows.
local function syncBar(scroll)
	local bar = scroll.ScrollBar
	local range = scroll:GetVerticalScrollRange() or 0
	if range <= 0 then
		scroll.ScrollBarFrame:Hide()
		return
	end
	scroll.ScrollBarFrame:Show()
	local view = scroll:GetHeight() or 0
	local track = bar:GetHeight() or 0
	local thumb = track
	if view + range > 0 then
		thumb = math_floor(track * view / (view + range))
	end
	thumb = math_max(THUMB_MIN, math_min(track, thumb))
	bar.ThumbHit:SetHeight(thumb)
	bar.syncing = true
	bar:SetMinMaxValues(0, range)
	bar:SetValue(math_min(scroll:GetVerticalScroll() or 0, range))
	bar.syncing = false
end

local function makeArrow(scroll, normal, over, down, delta)
	local b = CreateFrame("Button", nil, scroll.ScrollBarFrame)
	b:SetSize(17, 11)
	local t = b:CreateTexture(nil, "BACKGROUND")
	t:SetAllPoints()
	SetTexture(t, normal)
	b:SetScript("OnEnter", function()
		SetTexture(t, over)
	end)
	b:SetScript("OnLeave", function()
		SetTexture(t, normal)
	end)
	b:SetScript("OnMouseDown", function()
		SetTexture(t, down)
	end)
	b:SetScript("OnMouseUp", function(self)
		SetTexture(t, self:IsMouseOver() and over or normal)
	end)
	b:SetScript("OnClick", function()
		W.ScrollBy(scroll, delta * (scroll.panExtent or 30))
	end)
	return b
end

function W.ScrollBy(scroll, delta)
	local range = scroll:GetVerticalScrollRange() or 0
	local target = math_max(0, math_min(range, (scroll:GetVerticalScroll() or 0) + delta))
	scroll:SetVerticalScroll(target)
end

function W.CreateScrollFrame(parent)
	local scroll = CreateFrame("ScrollFrame", nil, parent)
	scroll.panExtent = 30
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		W.ScrollBy(self, -delta * self.panExtent)
	end)

	-- Holds the arrows and slider, anchored in the 26px gutter callers leave on the right.
	local holder = CreateFrame("Frame", nil, scroll)
	holder:SetWidth(17)
	holder:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 5, 0)
	holder:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 5, 0)
	scroll.ScrollBarFrame = holder

	local bar = CreateFrame("Slider", nil, holder)
	bar:SetWidth(BAR_WIDTH)
	bar:SetPoint("TOP", 0, -ARROW_GAP)
	bar:SetPoint("BOTTOM", 0, ARROW_GAP)
	bar:SetOrientation("VERTICAL")
	bar:SetObeyStepOnDrag(false)
	bar:SetValueStep(1)
	scroll.ScrollBar = bar

	-- Track art.
	local trackTop = bar:CreateTexture(nil, "BACKGROUND")
	SetTexture(trackTop, "minimal-scrollbar-track-top", true)
	trackTop:SetPoint("TOPLEFT")
	local trackBottom = bar:CreateTexture(nil, "BACKGROUND")
	SetTexture(trackBottom, "minimal-scrollbar-track-bottom", true)
	trackBottom:SetPoint("BOTTOMLEFT")
	local trackMiddle = bar:CreateTexture(nil, "BACKGROUND")
	SetTexture(trackMiddle, "!minimal-scrollbar-track-middle")
	trackMiddle:SetPoint("TOPLEFT", trackTop, "BOTTOMLEFT")
	trackMiddle:SetPoint("BOTTOMRIGHT", trackBottom, "TOPRIGHT")

	-- Invisible slider thumb that defines the draggable area.
	local hit = bar:CreateTexture(nil, "ARTWORK")
	hit:SetColorTexture(1, 1, 1, 0)
	hit:SetSize(BAR_WIDTH, THUMB_MIN)
	bar:SetThumbTexture(hit)
	bar.ThumbHit = hit

	bar.ThumbBegin = bar:CreateTexture(nil, "OVERLAY")
	bar.ThumbBegin:SetSize(BAR_WIDTH, 8)
	bar.ThumbBegin:SetPoint("TOP", hit, "TOP")
	bar.ThumbEnd = bar:CreateTexture(nil, "OVERLAY")
	bar.ThumbEnd:SetSize(BAR_WIDTH, 8)
	bar.ThumbEnd:SetPoint("BOTTOM", hit, "BOTTOM")
	bar.ThumbMiddle = bar:CreateTexture(nil, "OVERLAY")
	bar.ThumbMiddle:SetPoint("TOPLEFT", bar.ThumbBegin, "BOTTOMLEFT")
	bar.ThumbMiddle:SetPoint("BOTTOMRIGHT", bar.ThumbEnd, "TOPRIGHT")
	setThumbState(bar, "up")

	bar:SetScript("OnValueChanged", function(self, value)
		if not self.syncing then
			scroll:SetVerticalScroll(value)
		end
	end)
	bar:SetScript("OnEnter", refreshThumbState)
	bar:SetScript("OnLeave", refreshThumbState)
	bar:SetScript("OnMouseDown", function(self)
		self.dragging = true
		refreshThumbState(self)
	end)
	bar:SetScript("OnMouseUp", function(self)
		self.dragging = false
		refreshThumbState(self)
	end)
	bar:EnableMouseWheel(true)
	bar:SetScript("OnMouseWheel", function(_, delta)
		W.ScrollBy(scroll, -delta * scroll.panExtent)
	end)

	local up = makeArrow(scroll, "minimal-scrollbar-arrow-top", "minimal-scrollbar-arrow-top-over", "minimal-scrollbar-arrow-top-down", -1)
	up:SetPoint("TOP")
	local down = makeArrow(scroll, "minimal-scrollbar-arrow-bottom", "minimal-scrollbar-arrow-bottom-over", "minimal-scrollbar-arrow-bottom-down", 1)
	down:SetPoint("BOTTOM")

	-- The bar and its arrows hide when nothing overflows.
	holder:Hide()

	scroll:HookScript("OnScrollRangeChanged", syncBar)
	scroll:HookScript("OnVerticalScroll", syncBar)
	scroll:HookScript("OnSizeChanged", syncBar)
	return scroll
end
