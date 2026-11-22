-- Sentinel: Format.lua
-- Turns stored error objects into pretty, syntax-highlighted text for the window
-- and into clean plaintext for export/copy.
--
-- Capture stores only plain strings: Secret messages, stacks and locals are replaced
-- with readable placeholders at the grab boundary. The type checks here therefore only
-- guard against corrupt or hand-edited SavedVariables rows, not secrets.

local _, ns = ...
local Format = ns.Format
local L = ns.L

-- Bare-name upvalue alias (optimization section 3). Skips the string metatable
-- __index lookup that c:byte() does on every matched byte.
local strbyte = string.byte

-- Escape non-printable bytes so a stray control character in an error message,
-- stack, or locals dump can't corrupt FontString or EditBox rendering, or worse,
-- truncate the visible text at a NUL where the C-string layer stops.
--
-- The client's own C_StringUtil.EscapeDecimalNonPrintables does exactly this. It
-- replaces ASCII control characters (keeping tab, newline, and carriage return so
-- the multi-line layout survives) and invalid UTF-8 bytes with decimal escapes,
-- while leaving valid accents and CJK intact. We prefer it and keep the Lua version
-- as a fallback for any client that lacks the API.
--
-- The fallback's character class is deliberately narrow, three disjoint ranges so the
-- gaps are obviously intentional and not a typo. Tab (\9), newline (\10), and carriage
-- return (\13) are preserved to drive the layout, bytes >= 128 are left alone so UTF-8
-- text is not shredded, and matching a class instead of "." means the C-level gsub only
-- calls back on the rare control byte (section 3). The type guard short-circuits
-- non-string rows, which only a corrupt SavedVariables entry can produce.
local nativeEscape = C_StringUtil and C_StringUtil.EscapeDecimalNonPrintables
local function EscapeDecimalNonPrintables(s)
	if type(s) ~= "string" then
		return s
	end
	if nativeEscape then
		return nativeEscape(s)
	end
	return (s:gsub("[%z\1-\8\11\12\14-\31\127]", function(c)
		return "\\" .. strbyte(c)
	end))
end

-- Trim a dangling partial UTF-8 sequence off the end of a byte-truncated string, so
-- cutting a message to a fixed byte length never leaves a broken glyph before the
-- ellipsis. Walks back to the last lead byte and drops it if its sequence runs past
-- the end.
local function trimPartialUTF8(s)
	local n = #s
	local i = n
	while i > 0 do
		local b = strbyte(s, i)
		-- Stop at an ASCII byte or a UTF-8 lead byte (continuation bytes are 0x80-0xBF).
		if b < 0x80 or b >= 0xC0 then
			break
		end
		i = i - 1
	end
	if i == 0 then
		return s
	end
	local lead = strbyte(s, i)
	local len = 1
	if lead >= 0xF0 then
		len = 4
	elseif lead >= 0xE0 then
		len = 3
	elseif lead >= 0xC0 then
		len = 2
	end
	if i + len - 1 > n then
		return s:sub(1, i - 1)
	end
	return s
end
-- Shared so the comm receive path can truncate wire strings on a character boundary too.
ns.TrimPartialUTF8 = trimPartialUTF8

-- debuglocals caps its output and can stop in the middle of a child entry, leaving a
-- dangling frame reference such as "75=MotionSicknessFrame <MotionSicknes". Only that
-- unmistakable shape is removed; complete lines are left alone. Returns the trimmed
-- text and whether anything was cut, so callers can choose the marker's styling.
local function TrimLocalsTail(s)
	if type(s) ~= "string" or s == "" then
		return s, false
	end
	local lastLine = s:match("([^\n]*)$")
	if not lastLine or lastLine == "" then
		return s, false
	end
	if lastLine:find("=", 1, true)
		and lastLine:find("<", 1, true)
		and not lastLine:find(">", 1, true)
		and not lastLine:find("[\"']") then
		return s:sub(1, #s - #lastLine), true
	end
	return s, false
end
ns.Format.TrimLocalsTail = TrimLocalsTail

-----------------------------------------------------------------------
-- Syntax highlighting (cyan/silver palette on our dark theme).
-- Discrete headline tokens use paint(), while large stack and locals text blobs stay
-- on gsub passes, which is cheaper than Lua-level tokenization and naturally falls
-- back to the edit box's light-silver base colour after each |r.
-----------------------------------------------------------------------
local S = ns.SYNTAX
local R = "|r"
local C_PATH = S.path
local C_LINE = S.line
local C_PUNCT = S.punct
local C_STR = S.string
local C_NUM = S.number
local C_VAR = S.varName
local C_MSG = S.message
local C_HDR = S.header
local C_CNT = S.counter
local C_NIL = S.nilValue
local C_KEY = S.keyword

local function paint(text, color)
	if text == nil or text == "" then
		return ""
	end
	return color.code .. tostring(text) .. R
end

-- Open a color span without closing it. Chain multiple segments, then end with |r
-- once. FontStrings render stacked |c codes reliably this way, whereas repeated |r
-- resets between short tokens on the same line often fall back to default white.
local function open(text, color)
	if text == nil or text == "" then
		return ""
	end
	return color.code .. tostring(text)
end

-- Escape stray pipes so user/error text can't smuggle in its own colour codes.
local function escapePipes(s)
	return (s:gsub("|([^chHr])", "||%1"):gsub("|$", "||"))
end

-- Copy and Export must be genuinely plain text. Captured data such as frame or POI
-- field dumps often embeds real colour escapes. Left in, they render as colour in
-- the export box and paste into Discord or pastebin as raw garbage. We strip the
-- colour codes while keeping the visible text. There are two colour-open forms.
--   - classic hex, |cAARRGGBB ... |r
--   - named (10.x and later), |cnCOLOR_NAME: ... |r, used heavily by POI and map data
-- plus the |r reset. Underscores in the named form mean we match [%w_], not just %x.
local function stripColorCodes(s)
	s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
	s = s:gsub("|c[nN][%w_]+:", "")
	s = s:gsub("|r", "")
	return s
end

-- Make captured text safe for the read-only EditBox used by Copy and Export. Beyond
-- colour codes, captured locals can contain other escape sequences, most notably the
-- Battle.net name token |K...|k and inline textures |T...|t. Fed raw into an EditBox,
-- an unresolved escape makes it render blank, so Copy looked broken on exactly the
-- errors whose coloured detail pane rendered fine. escapePipes doubles every pipe
-- that isn't part of a colour or hyperlink escape, so |K becomes ||K and renders as
-- literal text, then stripColorCodes removes the colour opens and closes. This
-- mirrors what FormatError does for the pane.
local function plainify(s)
	return stripColorCodes(escapePipes(s))
end

-- Drop the "Interface/AddOns/" boilerplate that every addon path carries. The user
-- already knows it's an addon, and it just eats horizontal space.
local function stripAddonPath(s)
	s = s:gsub("[%.I][%.n][%.t][%.e][%.r]face[\\/]", "")
	s = s:gsub("%.?%.?%.?[\\/]?AddOns[\\/]", "")
	return s
end

-- Lua runtime errors name the offending symbol in single quotes
-- ("attempt to index local 'victim' (a nil value)"). Lift that identifier into the
-- locals var colour so the culprit pops, then switch straight back to the message
-- colour with a fresh |c (not |r) to preserve the headline's single-reset chaining.
-- Apply this only after escapePipes, so our injected colour codes survive.
local function highlightMessageVars(message)
	return (message:gsub("'([%w_]+)'", C_VAR.code .. "'%1'" .. C_MSG.code))
end

local function formatHeadline(count, msg)
	-- Most Lua errors begin "path:line: message". Parse that shape so the headline
	-- can keep an IDE-like path/line/message hierarchy despite WoW's non-nesting
	-- color reset behavior. Synthetic warnings fall back to a clean white message.
	local path, line, message = msg:match("^(.+):(%d+):%s+(.*)$")
	local countText = paint((count or 1) .. "x", C_CNT)
	if not path then
		return countText .. " " .. paint(highlightMessageVars(escapePipes(msg)), C_MSG)
	end
	-- Chain the path, line, and message tokens (keeping the colons) with no |r between them (see `open` above).
	-- Owner folder in gold, the rest of the path in the path colour, all in one chain.
	path = escapePipes(stripAddonPath(path))
	local owner, rest
	if not path:find("^%[") then -- [string "..."] chunks have no owner folder
		owner, rest = path:match("^([^/\\]+)([/\\].*)$")
	end
	local pathText = owner and (open(owner, S.addon) .. open(rest, C_PATH)) or open(path, C_PATH)
	return countText .. " " .. pathText .. open(":", C_PUNCT) .. open(line, C_LINE) .. open(": ", C_PUNCT) .. open(highlightMessageVars(escapePipes(message)), C_MSG) .. R
end

-- Single-line colouring for list rows, where a message stands in for a stack line.
local function colorStack(ret)
	ret = stripAddonPath(ret)
	ret = ret:gsub("|([^chHr])", "||%1"):gsub("|$", "||") -- escape stray pipes
	ret = ret:gsub("<(.-)>", C_PUNCT.code .. "<%1>" .. R) -- <...>
	ret = ret:gsub("%[(.-)%]", C_PUNCT.code .. "[%1]" .. R) -- [...]
	ret = ret:gsub("([\"`'])(.-)([\"`'])", C_STR.code .. "%1%2%3" .. R) -- quotes
	ret = ret:gsub(":(%d+)([%S\n])", C_PUNCT.code .. ":" .. R .. C_LINE.code .. "%1" .. R .. C_PUNCT.code .. "%2" .. R) -- line numbers
	ret = ret:gsub("([^%s:]+%.lua)", C_PATH.code .. "%1" .. R) -- addon-relative lua paths
	return ret
end

-----------------------------------------------------------------------
-- Stack frames, one line at a time. Each debugstack line looks like
--   [Interface/AddOns/Owner/File.lua]:54: in function <Interface/AddOns/Owner/File.lua:49>
--   [C]: in function 'pcall'      [tail call]: ?
-- Frames from an addon show its folder in gold and stay bright. Game (Blizzard_*),
-- C and tail-call frames are dimmed, so the frames worth reading stand out.
-----------------------------------------------------------------------
local C_ADDON = S.addon
local C_DIM = S.dim
local C_FUNC = S.funcName

-- True for frames that belong to the game client rather than an addon.
-- debugstack shortens long paths with a leading "...", which can cut into the folder
-- name, so a shortened path counts as game code when any segment is a Blizzard_ one.
local function isGamePath(path)
	if path:find("^Blizzard_") or path:find("^FrameXML") or path:find("^SharedXML") then
		return true
	end
	return path:find("^%.%.%.") ~= nil and path:find("Blizzard_", 1, true) ~= nil
end

-- "Owner/sub/File.lua" -> gold owner, path-coloured remainder.
local function paintPath(path, dim)
	if dim then
		return C_DIM.code .. path .. R
	end
	local owner, rest = path:match("^([^/\\]+)([/\\].*)$")
	if owner and not path:find("^string ") then
		return C_ADDON.code .. owner .. R .. C_PATH.code .. rest .. R
	end
	return C_PATH.code .. path .. R
end

-- "in function 'Name'", "in function <File.lua:49>", "in main chunk", "?"
local function paintWhere(rest, dim)
	local name = rest:match("^in function '(.*)'$")
	if name then
		return C_DIM.code .. "in function " .. R .. (dim and C_DIM or C_FUNC).code .. "'" .. name .. "'" .. R
	end
	local ref = rest:match("^in function <(.*)>$")
	if ref then
		-- The defining location repeats the frame's own file most of the time, so keep it quiet.
		return C_DIM.code .. "in function <" .. stripAddonPath(ref) .. ">" .. R
	end
	return C_DIM.code .. rest .. R
end

local function colorStackLine(line)
	local lead, path, lineNo, rest = line:match("^(%.*)%[(.-)%]:(%d+):%s*(.*)$")
	if path then
		path = stripAddonPath(path)
		local dim = isGamePath(path)
		return (lead ~= "" and (C_DIM.code .. lead .. R) or "") .. C_PUNCT.code .. "[" .. R .. paintPath(path, dim) .. C_PUNCT.code .. "]:" .. R .. (dim and C_DIM or C_LINE).code .. lineNo .. R .. C_PUNCT.code .. ": " .. R .. paintWhere(rest, dim)
	end
	-- [C]: in function 'pcall', [tail call]: ?, and anything unrecognised stay muted.
	local engine, where = line:match("^(%[[^%]]+%]):%s*(.*)$")
	if engine then
		return C_DIM.code .. engine .. ": " .. R .. paintWhere(where, true)
	end
	return C_DIM.code .. line .. R
end

-- Errors captured by older builds could start inside our own capture path. Those
-- leading frames say nothing about the bug, so the pane skips them.
local OWN_CAPTURE_FRAME = "AddOns[/\\]" .. ns.ADDON_NAME:gsub("%p", "%%%0") .. "[/\\]Core[/\\]Capture%.lua"

-- When such a stack starts in our handler, its locals were read from the handler too
-- and describe Sentinel, not the bug, so they are replaced by a note.
local function capturedInsideHandler(err)
	local stack = err.stack
	if type(stack) ~= "string" then
		return false
	end
	local first = stack:match("^[^\n]*")
	return first:find(OWN_CAPTURE_FRAME) ~= nil
end

local function colorStackBlock(stack)
	stack = escapePipes(stack:gsub("\r\n", "\n"))
	local out, n = {}, 0
	local leading = true
	for line in stack:gmatch("[^\n]+") do
		local ownFrame = line:find(OWN_CAPTURE_FRAME) or line:find("^%[C%]: in function 'pcall'$")
		if not (leading and ownFrame) then
			leading = false
			n = n + 1
			out[n] = colorStackLine(line)
		end
	end
	return table.concat(out, "\n")
end

-----------------------------------------------------------------------
-- Culprit: the addon most likely responsible for an error.
-----------------------------------------------------------------------
-- Owner folder of the first addon frame in a block of text, skipping game frames and
-- Sentinel's own capture code (older captures could start inside it).
local function firstAddonIn(text)
	if type(text) ~= "string" then
		return nil
	end
	for owner, rest in text:gmatch("AddOns[/\\]([^/\\%]:]+)[/\\]([^%]:\n]*)") do
		if not owner:find("^Blizzard_") and not (owner == ns.ADDON_NAME and rest:find("Capture%.lua")) then
			return owner
		end
	end
	return nil
end

local culpritCache = setmetatable({}, { __mode = "k" })

-- Returns the addon folder name, or a short label for scripts typed into chat. nil when
-- nothing in the error points anywhere useful. Cached per error until its text changes.
function Format.GetCulprit(err)
	if type(err) ~= "table" then
		return nil
	end
	local msg, stack = err.message, err.stack
	local cached = culpritCache[err]
	if cached and cached.m == msg and cached.s == stack then
		return cached.name
	end
	local name
	if type(msg) == "string" then
		-- Blocked actions and taint name the addon outright.
		name = msg:match("AddOn '([^']+)' tried to call")
		if not name then
			local tainted = msg:match("execution tainted by '([^']+)'")
			if tainted and not tainted:find("^%*") then
				name = tainted
			end
		end
		name = name or firstAddonIn(msg)
		if not name and msg:find('^%[string "') then
			-- The slash command itself, short enough for a row and the same in every language.
			name = "/run"
		end
	end
	name = name or firstAddonIn(stack)
	culpritCache[err] = { m = msg, s = stack, name = name }
	return name
end

-----------------------------------------------------------------------
-- Locals. debuglocals prints `name=value`, nesting table and frame contents one
-- space deeper per level between `{` and `}` lines.
-----------------------------------------------------------------------
local C_SECRET = S.secret
local C_TYPE = S.typeName
local INDENT = "   "

local function paintValue(value)
	if value:sub(1, 1) == '"' then
		return C_STR.code .. value .. R
	end
	if value == "nil" then
		return C_NIL.code .. "nil" .. R
	end
	if value == "true" or value == "false" then
		return C_KEY.code .. value .. R
	end
	if value:match("^%-?[%d%.]+[eE]?[%-+]?%d*$") then
		return C_NUM.code .. value .. R
	end
	if value:find("^<secret") then
		return C_SECRET.code .. value .. R
	end
	-- <table>, <table>{, <function>
	local kind, brace = value:match("^(<%a+>)({?)$")
	if kind then
		return C_TYPE.code .. kind .. R .. (brace ~= "" and (C_PUNCT.code .. brace .. R) or "")
	end
	-- Widget reference: Name <File.xml:12> with an optional opening brace.
	local widget, where, opening = value:match("^(%S+) (<[^>]*>)({?)$")
	if widget then
		return C_TYPE.code .. widget .. R .. " " .. C_PUNCT.code .. where .. opening .. R
	end
	return value
end

local function colorLocalLineNested(line)
	local spaces, body = line:match("^( *)(.*)$")
	local indent = INDENT:rep(#spaces)
	if body == "}" then
		return indent .. C_PUNCT.code .. "}" .. R
	end
	local name, value = body:match("^([^=]-)=(.*)$")
	if not name or name == "" then
		return indent .. body
	end
	-- (*temporary) slots are engine scratch values, useful but not names you wrote.
	local nameColor = name:find("^%(%*") and C_DIM or C_VAR
	return indent .. nameColor.code .. name .. R .. C_PUNCT.code .. "=" .. R .. paintValue(value)
end

-- Retail debuglocals often emits one physical line (`victim=nil(*temporary)=nil...`).
-- Use capture-free patterns only, since Lua counts `)` inside `[...]` as closing a capture.
local function normalizeLocals(locals)
	locals = locals:gsub("\r\n", "\n"):gsub("\r", "")
	if not locals:find("\n", 1, true) then
		locals = locals:gsub("nil%(", "nil\n(")
		locals = locals:gsub("true%(", "true\n(")
		locals = locals:gsub("false%(", "false\n(")
		locals = locals:gsub('")%w', function(m)
			return '")\n' .. m:sub(3)
		end)
	end
	if locals:sub(-1) ~= "\n" then
		locals = locals .. "\n"
	end
	return locals
end

-- Colour the locals one line at a time, each token with its own |c...|r. The
-- FontString parser is unreliable with chained spans on long wrapping text, and
-- line-by-line parsing copes with debuglocals' inconsistent layout.
local function colorLocalsText(locals)
	locals = escapePipes(normalizeLocals(locals))
	local out, n = {}, 0
	for line in locals:gmatch("[^\n]+") do
		n = n + 1
		out[n] = colorLocalLineNested(line)
	end
	return table.concat(out, "\n")
end

-----------------------------------------------------------------------
-- A short, single-line label for list rows.
-----------------------------------------------------------------------
local SHORT_MAX = 90

local function clipShort(s, max)
	if #s > max then
		return trimPartialUTF8(s:sub(1, max)) .. "..."
	end
	return s
end

-- First line of the message with its path kept, for tooltips that have room to wrap.
function Format.MessageLine(err)
	local msg = err.message
	if type(msg) ~= "string" then
		return "<unreadable error>"
	end
	msg = EscapeDecimalNonPrintables(msg)
	return colorStack(clipShort(msg:match("^[^\n]*") or msg, SHORT_MAX))
end

-- Compact label for list rows and the minimap tooltip. A row is too narrow for the
-- file path that leads most messages, so when the owner is known it leads in gold and
-- the path is dropped: "KkthnxUI  attempt to index a nil value". The detail pane still
-- shows the full path and line.
function Format.ShortMessage(err)
	local msg = err.message
	if type(msg) ~= "string" then
		return "<unreadable error>"
	end
	msg = EscapeDecimalNonPrintables(msg)
	local firstLine = msg:match("^[^\n]*") or msg
	local culprit = Format.GetCulprit(err)
	if not culprit then
		-- Game-only errors blame nobody, but their folder still reads better than a path.
		local gameOwner = firstLine:match("AddOns[/\\](Blizzard_[^/\\]+)[/\\]")
		local text = gameOwner and firstLine:match("^.-:%d+:%s+(.+)$")
		if text then
			return C_DIM.code .. gameOwner .. R .. "  " .. C_MSG.code .. escapePipes(clipShort(text, SHORT_MAX - #gameOwner)) .. R
		end
	end
	if culprit then
		local text = firstLine:match("^.-:%d+:%s+(.+)$")
		if not text then
			-- Blocked actions: "[ADDON_ACTION_BLOCKED] AddOn 'X' tried to call the protected function 'F'."
			local func = firstLine:match("tried to call the protected function '(.-)'")
			text = func and L["blocked %s"]:format(func)
		end
		if text then
			return C_ADDON.code .. escapePipes(culprit) .. R .. "  " .. C_MSG.code .. escapePipes(clipShort(text, SHORT_MAX - #culprit)) .. R
		end
	end
	return colorStack(clipShort(firstLine, SHORT_MAX))
end

-----------------------------------------------------------------------
-- Full, colored detail body for the right-hand pane.
-----------------------------------------------------------------------
function Format.FormatError(err)
	local msg = err.message
	if type(msg) ~= "string" then
		return ("%dx <unreadable error>"):format(err.counter or 1)
	end

	msg = EscapeDecimalNonPrintables(msg)
	local stack = (err.stack and type(err.stack) == "string") and EscapeDecimalNonPrintables(err.stack) or ""

	local body = formatHeadline(err.counter or 1, msg)
	local culprit = Format.GetCulprit(err)
	if culprit then
		body = body .. "\n" .. C_DIM.code .. L["AddOn"] .. ": " .. R .. C_ADDON.code .. escapePipes(culprit) .. R
	end
	if stack ~= "" then
		body = body .. "\n\n" .. colorStackBlock(stack)
	end

	if capturedInsideHandler(err) then
		body = body .. "\n\n" .. paint("Locals:", C_HDR) .. "\n" .. paint(L["Not shown. An older Sentinel build read these from its own handler, not from the error."], C_DIM)
	elseif err.locals and type(err.locals) == "string" and err.locals ~= "" then
		local locals, truncated = TrimLocalsTail(EscapeDecimalNonPrintables(err.locals))
		if locals ~= "" then
			body = body .. "\n\n" .. paint("Locals:", C_HDR) .. "\n" .. colorLocalsText(locals)
			if truncated then
				body = body .. "\n" .. paint(L["(locals truncated)"], C_PUNCT)
			end
		end
	end

	return body
end

-----------------------------------------------------------------------
-- Clean, uncolored plaintext for export / copy / sharing.
-----------------------------------------------------------------------
function Format.PlainError(err)
	local msg = err.message
	if type(msg) ~= "string" then
		return "<unreadable error>"
	end

	msg = plainify(EscapeDecimalNonPrintables(msg))
	local parts = { ("%dx %s"):format(err.counter or 1, msg) }
	local culprit = Format.GetCulprit(err)
	if culprit then
		parts[#parts + 1] = L["AddOn"] .. ": " .. plainify(culprit)
	end

	if err.stack and type(err.stack) == "string" and err.stack ~= "" then
		parts[#parts + 1] = plainify(EscapeDecimalNonPrintables(err.stack))
	end
	if err.locals and type(err.locals) == "string" and err.locals ~= "" and not capturedInsideHandler(err) then
		local locals, truncated = TrimLocalsTail(EscapeDecimalNonPrintables(err.locals))
		if locals ~= "" then
			local block = "Locals:\n" .. plainify(normalizeLocals(locals))
			if truncated then
				block = block .. L["(locals truncated)"]
			end
			parts[#parts + 1] = block
		end
	end

	return table.concat(parts, "\n")
end

-----------------------------------------------------------------------
-- Chat hyperlink, a clickable "open this error" (LinkTypes.AddOn via EventRegistry).
-- Uses the stable err.id, since raw table-pointer identity does not survive /reload.
-----------------------------------------------------------------------
function Format.GetChatLink(err)
	local id = err and err.id
	if type(id) ~= "number" then
		return ""
	end
	local display = ("|cff00bfff[Error %d]|r"):format(id)
	-- |Haddon:sentinel:<id>|h...|h, where the addon link routes through SetItemRef.
	if LinkUtil and LinkUtil.FormatLink and LinkTypes and LinkTypes.AddOn then
		return LinkUtil.FormatLink(LinkTypes.AddOn, display, "sentinel", id)
	end
	return ("|Haddon:sentinel:%d|h%s|h"):format(id, display)
end
