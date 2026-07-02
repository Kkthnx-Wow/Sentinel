-- Sentinel: MinimapButton.lua
-- A self-contained minimap button (no LibDBIcon needed) plus a LibDataBroker-1.1
-- "data source" launcher. Shows a live error count, supports dragging around the
-- minimap, a rich tooltip, and the modern Addon Compartment.
--
-- Positioning follows LibDBIcon-1.0 (minimap shape quads + half-width radius) so
-- the tracking ring sits on the orbit outside the minimap disc, not on top of it.

local _, ns = ...
local DB = ns.DB
local UI = ns.UI
local L = ns.L

local Minimap = Minimap
local CreateFrame = CreateFrame
local GetMinimapShape = GetMinimapShape
local math_rad = math.rad
local math_deg = math.deg
local math_cos = math.cos
local math_sin = math.sin
local math_sqrt = math.sqrt
local math_max = math.max
local math_min = math.min
local math_atan2 = math.atan2

local button
local iconNormal = ns.ICON
local iconAlert = ns.ICON_ALERT

-- Indicator-Green/Red ship with generous transparent padding; crop so the orb
-- reads clearly inside the tracking ring.
local ICON_TEXCOORD = { 0.16, 0.84, 0.16, 0.84 }

local isMainline = WOW_PROJECT_ID == WOW_PROJECT_MAINLINE
local BUTTON_RADIUS = 5 -- extra pixels past the minimap edge (LibDBIcon default)

local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
local dataObject

-----------------------------------------------------------------------
-- Position on the minimap ring (LibDBIcon-1.0 updatePosition)
-----------------------------------------------------------------------
local minimapShapes = {
	["ROUND"] = { true, true, true, true },
	["SQUARE"] = { false, false, false, false },
	["CORNER-TOPLEFT"] = { false, false, false, true },
	["CORNER-TOPRIGHT"] = { false, false, true, false },
	["CORNER-BOTTOMLEFT"] = { false, true, false, false },
	["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
	["SIDE-LEFT"] = { false, true, false, true },
	["SIDE-RIGHT"] = { true, false, true, false },
	["SIDE-TOP"] = { false, false, true, true },
	["SIDE-BOTTOM"] = { true, true, false, false },
	["TRICORNER-TOPLEFT"] = { false, true, true, true },
	["TRICORNER-TOPRIGHT"] = { true, false, true, true },
	["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
	["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

local function getSavedAngle()
	local angle = SentinelCharDB and SentinelCharDB.minimapAngle
	if type(angle) ~= "number" then
		return 204
	end
	return angle % 360
end

local function updatePosition()
	if not button then
		return
	end
	local position = getSavedAngle()
	local angle = math_rad(position)
	local x, y, q = math_cos(angle), math_sin(angle), 1
	if x < 0 then
		q = q + 1
	end
	if y > 0 then
		q = q + 2
	end
	local minimapShape = (GetMinimapShape and GetMinimapShape()) or "ROUND"
	local quadTable = minimapShapes[minimapShape] or minimapShapes["ROUND"]
	local w = (Minimap:GetWidth() / 2) + BUTTON_RADIUS
	local h = (Minimap:GetHeight() / 2) + BUTTON_RADIUS
	if quadTable[q] then
		x, y = x * w, y * h
	else
		local diagRadiusW = math_sqrt(2 * (w * w)) - 10
		local diagRadiusH = math_sqrt(2 * (h * h)) - 10
		x = math_max(-w, math_min(x * diagRadiusW, w))
		y = math_max(-h, math_min(y * diagRadiusH, h))
	end
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function onDragUpdate()
	local mx, my = Minimap:GetCenter()
	local scale = Minimap:GetEffectiveScale()
	local px, py = GetCursorPosition()
	px, py = px / scale, py / scale
	SentinelCharDB.minimapAngle = math_deg(math_atan2(py - my, px - mx)) % 360
	updatePosition()
end

-----------------------------------------------------------------------
-- Visuals
-----------------------------------------------------------------------
local function updateCount()
	local count = DB.SessionCount()
	local countText = count > 0 and (count > 99 and "*" or tostring(count)) or ""
	local icon = count > 0 and iconAlert or iconNormal
	if button then
		button.count:SetText(countText)
		button.icon:SetTexture(icon)
		button.icon:SetTexCoord(ICON_TEXCOORD[1], ICON_TEXCOORD[2], ICON_TEXCOORD[3], ICON_TEXCOORD[4])
	end
	if dataObject then
		dataObject.text = countText
		dataObject.icon = icon
	end
end
ns.UI.UpdateMinimapCount = updateCount

-----------------------------------------------------------------------
-- Tooltip
-----------------------------------------------------------------------
local function onTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine(ns.DISPLAY_NAME, ns.SYNTAX.counter:GetRGB())
	local errs = DB.GetBySession(DB.GetSessionId())
	local n = #errs
	if n == 0 then
		GameTooltip:AddLine(L["No errors caught \226\128\148 your UI is clean."], 0.6, 0.6, 0.6, true)
	else
		for i = n, math.max(1, n - 7), -1 do
			local e = errs[i]
			GameTooltip:AddLine(("%dx %s"):format(e.counter or 1, ns.Format.ShortMessage(e)), 0.8, 0.8, 0.8, true)
		end
	end
	if DB.config.capturePaused then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(L["Error capture is paused."], 1, 0.25, 0.25, true)
	elseif ns.State.paused then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(L["Capture paused: too many errors per second (automatic)."], 1, 0.5, 0.25, true)
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine(L["Left-click: open the error window"], ns.SYNTAX.path:GetRGB())
	GameTooltip:AddLine(L["Right-click: open settings"], ns.SYNTAX.path:GetRGB())
	GameTooltip:AddLine(L["Shift-click: reload the UI"], ns.SYNTAX.path:GetRGB())
	GameTooltip:AddLine(L["Alt-click: wipe all errors"], ns.SYNTAX.path:GetRGB())
	GameTooltip:Show()
end

-----------------------------------------------------------------------
-- Click handling (shared by the button and the Addon Compartment)
-----------------------------------------------------------------------
local function handleClick(buttonName)
	if buttonName == "RightButton" then
		ns.Config.Open()
	elseif IsShiftKeyDown() then
		ReloadUI()
	elseif IsAltKeyDown() then
		UI.ConfirmWipe()
	else
		UI.Toggle()
	end
end
ns.UI.HandleCompartmentClick = function(_, buttonName)
	handleClick(buttonName)
end

-----------------------------------------------------------------------
-- Build
-----------------------------------------------------------------------
local function Build()
	button = CreateFrame("Button", "SentinelMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	if button.SetFixedFrameStrata then
		button:SetFixedFrameStrata(true)
	end
	button:SetFrameLevel(8)
	if button.SetFixedFrameLevel then
		button:SetFixedFrameLevel(true)
	end
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetMovable(true)
	button:SetHighlightTexture(136477) -- Interface\Minimap\UI-Minimap-ZoomButton-Highlight
	button:GetHighlightTexture():SetBlendMode("ADD")

	local overlay = button:CreateTexture(nil, "OVERLAY")
	overlay:SetTexture(136430) -- Interface\Minimap\MiniMap-TrackingBorder

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetTexture(136467) -- Interface\Minimap\UI-Minimap-Background

	button.icon = button:CreateTexture(nil, "ARTWORK")

	if isMainline then
		overlay:SetSize(50, 50)
		overlay:SetPoint("TOPLEFT", button, "TOPLEFT")
		background:SetSize(24, 24)
		background:SetPoint("CENTER", button, "CENTER")
		button.icon:SetSize(18, 18)
		button.icon:SetPoint("CENTER", button, "CENTER")
	else
		overlay:SetSize(53, 53)
		overlay:SetPoint("TOPLEFT", button, "TOPLEFT")
		background:SetSize(20, 20)
		background:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -5)
		button.icon:SetSize(17, 17)
		button.icon:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -6)
	end

	button.icon:SetTexCoord(ICON_TEXCOORD[1], ICON_TEXCOORD[2], ICON_TEXCOORD[3], ICON_TEXCOORD[4])

	button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	button.count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
	button.count:SetTextColor(1, 0.3, 0.3)

	button:SetScript("OnClick", function(_, btn)
		handleClick(btn)
	end)
	button:SetScript("OnEnter", onTooltip)
	button:SetScript("OnLeave", GameTooltip_Hide)
	button:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", onDragUpdate)
		GameTooltip:Hide()
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)

	updatePosition()
	updateCount()

	if not DB.config.minimap then
		button:Hide()
	end

	-- Edit Mode / UI scale can resize the minimap after login.
	if hooksecurefunc and not button._sentinelMinimapHooked then
		button._sentinelMinimapHooked = true
		hooksecurefunc(Minimap, "SetSize", updatePosition)
		if Minimap.SetWidth then
			hooksecurefunc(Minimap, "SetWidth", updatePosition)
		end
		if Minimap.SetHeight then
			hooksecurefunc(Minimap, "SetHeight", updatePosition)
		end
	end
end

function ns.UI.SetMinimapShown(shown)
	if not button then
		return
	end
	button:SetShown(shown)
end

-----------------------------------------------------------------------
-- LibDataBroker data source
-----------------------------------------------------------------------
local function registerBroker()
	if not LDB then
		return
	end
	dataObject = LDB:NewDataObject(ns.DISPLAY_NAME, {
		type = "data source",
		label = ns.DISPLAY_NAME,
		icon = iconNormal,
		text = "",
		OnClick = function(_, mouseButton)
			handleClick(mouseButton)
		end,
		OnEnter = onTooltip,
		OnLeave = GameTooltip_Hide,
	})
end

-----------------------------------------------------------------------
-- Addon Compartment
-----------------------------------------------------------------------
local function registerCompartment()
	if AddonCompartmentFrame and AddonCompartmentFrame.RegisterAddon then
		AddonCompartmentFrame:RegisterAddon({
			text = ns.DISPLAY_NAME,
			icon = ns.ICON,
			notCheckable = true,
			func = function(_, _, _, _, mouseButton)
				handleClick(mouseButton or "LeftButton")
			end,
			funcOnEnter = function(self)
				onTooltip(self)
			end,
			funcOnLeave = GameTooltip_Hide,
		})
	end
end

-----------------------------------------------------------------------
-- Init on login + keep count fresh
-----------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self)
	self:UnregisterEvent("PLAYER_LOGIN")
	registerBroker()
	Build()
	registerCompartment()
end)

local CB_OWNER = {}
EventRegistry:RegisterCallback("Sentinel.ErrorCaptured", updateCount, CB_OWNER)
EventRegistry:RegisterCallback("Sentinel.ErrorReceived", updateCount, CB_OWNER)
