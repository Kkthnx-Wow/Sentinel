-- Sentinel: MinimapButton.lua
-- A self-contained minimap button that needs no icon library, plus a
-- LibDataBroker-1.1 "data source" launcher. Shows a live error count, supports
-- dragging around the minimap, a rich tooltip, and the modern Addon Compartment.
--
-- Positioning uses the standard minimap-shape quadrant table and a half-width
-- radius, so the tracking ring sits on the orbit outside the minimap disc rather
-- than on top of it.

local _, ns = ...
local DB = ns.DB
local UI = ns.UI
local L = ns.L

local Minimap = Minimap
local CreateFrame = CreateFrame
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

-- Bundled art (see tools/gen_media.py). One disc-and-ring texture replaces the old
-- three minimap fileIDs, and a matching glow handles hover.
local BUTTON_ART = ns.MEDIA .. "MinimapButton.tga"
local BUTTON_GLOW = ns.MEDIA .. "MinimapButton-Highlight.tga"

local BUTTON_RADIUS = 5 -- extra pixels past the minimap edge

local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
local dataObject

-----------------------------------------------------------------------
-- Position on the minimap ring
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
	-- Read at call time. Minimap addons define GetMinimapShape after we load, so a
	-- load-time local would be nil and a square minimap would get a round orbit.
	local getShape = _G.GetMinimapShape
	local minimapShape = (getShape and getShape()) or "ROUND"
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
-- Last applied label, so a burst of repeats doesn't re-set the same texture and text.
local appliedText

local function updateCount()
	local count = DB.SessionCount()
	local countText = count > 0 and (count > 99 and "*" or tostring(count)) or ""
	if countText == appliedText then
		return
	end
	appliedText = countText
	local icon = count > 0 and iconAlert or iconNormal
	if button then
		button.count:SetText(countText)
		button.icon:SetTexture(icon)
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
	-- Skip in instance combat, where tooltip APIs can trip secret or taint noise.
	if InCombatLockdown() then
		local _, instanceType = IsInInstance()
		if instanceType == "raid" or instanceType == "party" or instanceType == "pvp" or instanceType == "arena" then
			return
		end
	end
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine(ns.DISPLAY_NAME, ns.SYNTAX.counter:GetRGB())
	local errs = DB.GetBySession(DB.GetSessionId())
	local n = #errs
	if n == 0 then
		GameTooltip:AddLine(L["No errors caught, your UI is clean."], 0.6, 0.6, 0.6, true)
	else
		for i = n, math.max(1, n - 7), -1 do
			local e = errs[i]
			GameTooltip:AddLine(("%dx %s"):format(e.counter or 1, ns.Format.ShortMessage(e)), 0.8, 0.8, 0.8, true)
		end
	end
	if DB.config.capturePaused then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(L["Error capture is paused."], 1, 0.25, 0.25, true)
	elseif ns.IsFloodPaused() then
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
	button:SetHighlightTexture(BUTTON_GLOW, "ADD")

	local art = button:CreateTexture(nil, "BACKGROUND")
	art:SetTexture(BUTTON_ART)
	art:SetAllPoints(button)

	button.icon = button:CreateTexture(nil, "ARTWORK")
	button.icon:SetSize(18, 18)
	button.icon:SetPoint("CENTER", button, "CENTER")

	button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	button.count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
	button.count:SetTextColor(1, 0.3, 0.3)

	-- A drag release also fires OnClick on the same mouse-up, which would toggle the
	-- window every time the button is repositioned. dragging suppresses that one click.
	local dragging = false
	button:SetScript("OnClick", function(_, btn)
		if dragging then
			return
		end
		handleClick(btn)
	end)
	button:SetScript("OnEnter", onTooltip)
	button:SetScript("OnLeave", GameTooltip_Hide)
	button:SetScript("OnDragStart", function(self)
		dragging = true
		self:SetScript("OnUpdate", onDragUpdate)
		GameTooltip:Hide()
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
		-- Clear next frame, after the release click has been evaluated, so a drag that
		-- produces no click cannot swallow the next real one.
		C_Timer.After(0, function()
			dragging = false
		end)
	end)

	updatePosition()
	-- Errors captured before login never reached a widget, so force the first paint.
	appliedText = nil
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
			-- RegisterAddon calls func(button, menuInputData, menu). The clicked mouse
			-- button lives in menuInputData, not in a positional arg, so read it there
			-- or every compartment click would be treated as a left click.
			func = function(_, menuInputData)
				handleClick(menuInputData and menuInputData.buttonName or "LeftButton")
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
