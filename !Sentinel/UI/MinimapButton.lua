-- Sentinel: MinimapButton.lua
-- A self-contained minimap button (no LibDBIcon needed) plus a LibDataBroker-1.1
-- "data source" launcher. Shows a live error count, supports dragging around the
-- minimap, a rich tooltip, and the modern Addon Compartment.
--
-- The LDB object lets broker display addons (Titan Panel, ChocolateBar, Bazooka,
-- etc.) surface Sentinel on a bar instead of the minimap ring -- handy when the
-- minimap is already crowded. The object always registers (even if the minimap
-- button is hidden) so the two access points are independent.
--
-- It only runs an OnUpdate handler *while being dragged* -- never idle (see
-- optimization guide section 4 on avoiding always-on polling).

local _, ns = ...
local DB = ns.DB
local UI = ns.UI
local L = ns.L

local button
local iconNormal = ns.ICON
local iconAlert = ns.ICON_ALERT

-- LibDataBroker is embedded (Libs/embeds.xml); the silent flag means we degrade
-- gracefully to a minimap-only button if it ever fails to load.
local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
local dataObject

-----------------------------------------------------------------------
-- Position on the minimap ring
-----------------------------------------------------------------------
local function updatePosition()
	local angle = math.rad(SentinelCharDB.minimapAngle or 204)
	local x = math.cos(angle) * 80
	local y = math.sin(angle) * 80
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function onDragUpdate()
	local mx, my = Minimap:GetCenter()
	local scale = Minimap:GetEffectiveScale()
	local px, py = GetCursorPosition()
	px, py = px / scale, py / scale
	SentinelCharDB.minimapAngle = math.deg(math.atan2(py - my, px - mx))
	updatePosition()
end

-----------------------------------------------------------------------
-- Visuals
-----------------------------------------------------------------------
local function updateCount()
	local count = DB.SessionCount()
	-- Compute the badge text + icon once, then mirror them onto both the minimap
	-- button and the broker object (a broker display may be shown even when the
	-- minimap button is hidden, so the data source is updated independently).
	local countText = count > 0 and (count > 99 and "*" or tostring(count)) or ""
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
		DB.Reset()
		updateCount()
		UI.Refresh()
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
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetMovable(true)

	local overlay = button:CreateTexture(nil, "OVERLAY")
	overlay:SetSize(53, 53)
	overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	overlay:SetPoint("TOPLEFT")

	button.icon = button:CreateTexture(nil, "BACKGROUND")
	button.icon:SetSize(20, 20)
	button.icon:SetPoint("CENTER", -1, 1)

	button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	button.count:SetPoint("CENTER", 0, 1)
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
end

function ns.UI.SetMinimapShown(shown)
	if not button then
		return
	end
	button:SetShown(shown)
end

-----------------------------------------------------------------------
-- LibDataBroker data source (broker bars: Titan, ChocolateBar, Bazooka, ...)
-----------------------------------------------------------------------
-- The display addon owns the on-screen button and calls these handlers with that
-- button as `self`. OnClick/OnEnter map straight onto the same shared handlers the
-- minimap button uses, so behavior is identical across both access points.
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
-- Addon Compartment (modern Blizzard entry point)
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
	-- Register the broker first so Build()'s trailing updateCount() seeds the data
	-- source's text/icon in the same pass that paints the minimap badge.
	registerBroker()
	Build()
	registerCompartment()
end)

-- Keep the badge fresh for both locally caught and received bugs. updateCount is
-- already a file-scope function, so reuse the reference directly -- no closure
-- allocation (optimization guide section 3).
local CB_OWNER = {}
EventRegistry:RegisterCallback("Sentinel.ErrorCaptured", updateCount, CB_OWNER)
EventRegistry:RegisterCallback("Sentinel.ErrorReceived", updateCount, CB_OWNER)
