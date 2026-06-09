-- Sentinel: Format.lua
-- Turns stored error objects into pretty, syntax-highlighted text for the window
-- and into clean plaintext for export/copy.
--
-- Midnight note: every public function here first checks issecretvalue(). String
-- operations (gsub/find/format) on a Secret value throw an error, so if any field
-- is Secret we degrade gracefully instead of crashing (see Secret Values guide).

local _, ns = ...
local Format = ns.Format
local issecretvalue = ns.G.issecretvalue

local EscapeDecimalNonPrintables = (C_StringUtil and C_StringUtil.EscapeDecimalNonPrintables) or function(s)
	return s
end

-----------------------------------------------------------------------
-- Syntax highlighting (cyan/silver palette on our dark theme).
-- Discrete headline tokens use paint(); large stack/local text blobs stay on gsub
-- passes, which is cheaper than Lua-level tokenization and naturally falls back
-- to the edit box's light-silver base colour after each |r.
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
-- once. WoW FontStrings render stacked |c codes reliably this way; repeated |r
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

-- Drop the "Interface/AddOns/" boilerplate that every addon path carries -- the
-- user already knows it's an addon, and it just eats horizontal space.
local function stripAddonPath(s)
	s = s:gsub("[%.I][%.n][%.t][%.e][%.r]face[\\/]", "")
	s = s:gsub("%.?%.?%.?[\\/]?AddOns[\\/]", "")
	return s
end

local function formatHeadline(count, msg)
	-- Most Lua errors begin "path:line: message". Parse that shape so the headline
	-- can keep an IDE-like path/line/message hierarchy despite WoW's non-nesting
	-- color reset behavior. Synthetic warnings fall back to a clean white message.
	local path, line, message = msg:match("^(.+):(%d+):%s+(.*)$")
	local countText = paint((count or 1) .. "x", C_CNT)
	if not path then
		return countText .. " " .. paint(escapePipes(msg), C_MSG)
	end
	-- Chain path : line : message without |r between each token (see `open` above).
	return countText
		.. " "
		.. open(escapePipes(stripAddonPath(path)), C_PATH)
		.. open(":", C_PUNCT)
		.. open(line, C_LINE)
		.. open(": ", C_PUNCT)
		.. open(escapePipes(message), C_MSG)
		.. R
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
-- Use capture-free patterns only — Lua counts `)` inside `[...]` as closing a capture.
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
	-- Avoid parenthesis-heavy name patterns — Lua counts `)` inside `[...]` as
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
		firstLine = firstLine:sub(1, 90) .. "..."
	end
	return colorStack(firstLine)
end

-----------------------------------------------------------------------
-- Full, colored detail body for the right-hand pane.
-----------------------------------------------------------------------
function Format.FormatError(err)
	local msg = err.message
	if issecretvalue(msg) or type(msg) ~= "string" then
		return ("%dx <secret error \226\128\148 cannot be displayed in an instance>"):format(err.counter or 1)
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

	msg = EscapeDecimalNonPrintables(msg)
	local parts = { ("%dx %s"):format(err.counter or 1, msg) }

	if err.stack and not issecretvalue(err.stack) and err.stack ~= "" then
		parts[#parts + 1] = EscapeDecimalNonPrintables(err.stack)
	end
	if err.locals and not issecretvalue(err.locals) and err.locals ~= "" then
		parts[#parts + 1] = "Locals:\n" .. normalizeLocals(EscapeDecimalNonPrintables(err.locals))
	end

	return table.concat(parts, "\n")
end
