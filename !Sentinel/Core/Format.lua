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

local EscapeDecimalNonPrintables = (C_StringUtil and C_StringUtil.EscapeDecimalNonPrintables)
	or function(s)
		return s
	end

-----------------------------------------------------------------------
-- Syntax highlighting (adapted from BugSack, with a Sentinel palette)
-----------------------------------------------------------------------
local function colorStack(ret)
	ret = ret:gsub("[%.I][%.n][%.t][%.e][%.r]face[\\/]", "")
	ret = ret:gsub("%.?%.?%.?[\\/]?AddOns[\\/]", "")
	ret = ret:gsub("|([^chHr])", "||%1"):gsub("|$", "||") -- escape stray pipes
	ret = ret:gsub("<(.-)>", "|cffffea00<%1>|r") -- <...>
	ret = ret:gsub("%[(.-)%]", "|cffffea00[%1]|r") -- [...]
	ret = ret:gsub("([\"`'])(.-)([\"`'])", "|cff8888ff%1%2%3|r") -- quotes
	ret = ret:gsub(":(%d+)([%S\n])", ":|cff33ff99%1|r%2") -- line numbers
	ret = ret:gsub("([^\\/]+%.lua)", "|cffffffff%1|r") -- lua files
	return ret
end

local function colorLocals(ret)
	ret = ret:gsub("[%.I][%.n][%.t][%.e][%.r]face[\\/]", "")
	ret = ret:gsub("%.?%.?%.?[\\/]?AddOns[\\/]", "")
	ret = ret:gsub("|(%a)", "||%1"):gsub("|$", "||")
	ret = ret:gsub("> %@(.-):(%d+)", "> @|cffeda55f%1|r:|cff33ff99%2|r")
	ret = ret:gsub("(%s-)([%a_%(][%a_%d%*%)]+) = ", "%1|cffffff80%2|r = ")
	ret = ret:gsub("= (%-?[%d%p]+)\n", "= |cffff7fff%1|r\n")
	ret = ret:gsub("= nil\n", "= |cffff7f7fnil|r\n")
	ret = ret:gsub("= true\n", "= |cff44ff44true|r\n")
	ret = ret:gsub("= false\n", "= |cffff9100false|r\n")
	return ret
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

	local body = colorStack(msg .. "\n" .. stack)

	if err.locals and not issecretvalue(err.locals) and err.locals ~= "" then
		body = body .. "\n\n|cffffea00Locals:|r\n" .. colorLocals(EscapeDecimalNonPrintables(err.locals))
	end

	return ("|cffff4411%dx|r %s"):format(err.counter or 1, body)
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
		parts[#parts + 1] = "Locals:\n" .. EscapeDecimalNonPrintables(err.locals)
	end

	return table.concat(parts, "\n")
end
