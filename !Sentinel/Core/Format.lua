-- Sentinel: Format.lua
-- Turns stored error objects into pretty, syntax-highlighted text for the window
-- and into clean plaintext for export/copy.
--
-- The Secret guards here cover the message, stack, and locals that the game also
-- treats as possibly secret (canaccessvalue on the log line). Capture already
-- refuses to store Secret messages and sanitizes stack and locals at grab time, so
-- these checks are the display-side failsafe for corrupt or legacy DB rows.

local _, ns = ...
local Format = ns.Format
local issecretvalue = ns.G.issecretvalue

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
-- non-strings, including rare Secret leftovers where type() is "secret".
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
	return countText .. " " .. open(escapePipes(stripAddonPath(path)), C_PATH) .. open(":", C_PUNCT) .. open(line, C_LINE) .. open(": ", C_PUNCT) .. open(highlightMessageVars(escapePipes(message)), C_MSG) .. R
end

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

local function paintLocal(name, value, valueColor)
	-- Discrete |c...|r per token. WoW's FontString parser is unreliable with chained
	-- inline spans on heavily-formatted, wrapping multiline text (the locals block),
	-- even though the same chaining works for the shorter headline.
	return C_VAR.code .. name .. R .. C_PUNCT.code .. "=" .. R .. valueColor.code .. value .. R
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

-- Colour one `name=value` locals line. Line-by-line parsing is more reliable than
-- newline-anchored gsub on the full blob (retail debuglocals is inconsistent).
local function colorLocalLine(line)
	-- Avoid parenthesis-heavy name patterns, since Lua counts `)` inside `[...]` as
	-- closing a capture. debuglocals lines are always `name=value`.
	local name, value = line:match("^%s*([^=]-)%s*=(.+)$")
	if not name then
		return line
	end
	name = name:match("^%s*(.-)%s*$") or name
	value = value:match("^%s*(.-)%s*$") or value
	if value:sub(1, 1) == '"' and value:sub(-1) == '"' then
		return paintLocal(name, value, C_STR)
	end
	if value == "nil" then
		return paintLocal(name, "nil", C_NIL)
	end
	if value == "true" then
		return paintLocal(name, "true", C_KEY)
	end
	if value == "false" then
		return paintLocal(name, "false", C_KEY)
	end
	if value:match("^%-?[%d%.]+$") then
		return paintLocal(name, value, C_NUM)
	end
	return line
end

local function colorLocalsText(locals)
	locals = escapePipes(normalizeLocals(locals))
	local out, n = {}, 0
	for line in locals:gmatch("[^\n]+") do
		n = n + 1
		out[n] = colorLocalLine(line)
	end
	return table.concat(out, "\n")
end

-----------------------------------------------------------------------
-- A short, single-line label for list rows.
-----------------------------------------------------------------------
function Format.ShortMessage(err)
	local msg = err.message
	if issecretvalue(msg) or type(msg) ~= "string" then
		return "<secret error>"
	end
	msg = EscapeDecimalNonPrintables(msg)
	-- First line only, trimmed to a sane length for the list.
	local firstLine = msg:match("^[^\n]*") or msg
	if #firstLine > 90 then
		firstLine = trimPartialUTF8(firstLine:sub(1, 90)) .. "..."
	end
	return colorStack(firstLine)
end

-----------------------------------------------------------------------
-- Full, colored detail body for the right-hand pane.
-----------------------------------------------------------------------
function Format.FormatError(err)
	local msg = err.message
	if issecretvalue(msg) or type(msg) ~= "string" then
		return ("%dx <secret error, cannot be displayed in an instance>"):format(err.counter or 1)
	end

	msg = EscapeDecimalNonPrintables(msg)
	local stack = (err.stack and not issecretvalue(err.stack)) and EscapeDecimalNonPrintables(err.stack) or ""

	local body = formatHeadline(err.counter or 1, msg)
	if stack ~= "" then
		body = body .. "\n" .. colorStack(stack)
	end

	if err.locals and not issecretvalue(err.locals) and err.locals ~= "" then
		body = body .. "\n\n" .. paint("Locals:", C_HDR) .. "\n" .. colorLocalsText(err.locals)
	end

	return body
end

-----------------------------------------------------------------------
-- Clean, uncolored plaintext for export / copy / sharing.
-----------------------------------------------------------------------
function Format.PlainError(err)
	local msg = err.message
	if issecretvalue(msg) or type(msg) ~= "string" then
		return "<secret error>"
	end

	msg = plainify(EscapeDecimalNonPrintables(msg))
	local parts = { ("%dx %s"):format(err.counter or 1, msg) }

	if err.stack and not issecretvalue(err.stack) and err.stack ~= "" then
		parts[#parts + 1] = plainify(EscapeDecimalNonPrintables(err.stack))
	end
	if err.locals and not issecretvalue(err.locals) and err.locals ~= "" then
		parts[#parts + 1] = "Locals:\n" .. plainify(normalizeLocals(EscapeDecimalNonPrintables(err.locals)))
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
