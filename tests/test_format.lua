package.path = "tests/?.lua;" .. package.path
local T = require("support")
local eq = T.eq

local function freshFormat()
	local env = T.newEnv()
	local ns = {}
	T.loadBase(ns)
	T.load(ns, "Core/Format.lua")
	return ns, env
end

-- Text painted in one syntax colour, so tests can ask "what colour is this token".
local function painted(ns, key, text)
	return ns.SYNTAX[key].code .. text
end

print("format")

T.case("the culprit comes from the message, taint, blocked actions or the stack", function()
	local ns = freshFormat()
	local F = ns.Format
	eq(F.GetCulprit({ message = "Interface/AddOns/MyAddon/Core.lua:5: boom" }), "MyAddon", "message path")
	eq(F.GetCulprit({ message = "x.lua:1: secret test (execution tainted by 'Tainter')" }), "Tainter", "taint")
	eq(F.GetCulprit({ message = "x (execution tainted by '*** ForceTaint_Strong ***')" }), nil, "forced taint names nobody")
	eq(F.GetCulprit({ message = "[ADDON_ACTION_BLOCKED] AddOn 'Blocked' tried to call the protected function 'X()'." }), "Blocked", "blocked action")
	eq(F.GetCulprit({ message = '[string "print(1"]:1: x' }), "/run", "chat script")
	local viaStack = {
		message = "...terface/AddOns/Blizzard_Minimap/Minimap.lua:5: boom",
		stack = "[Interface/AddOns/Blizzard_Minimap/Minimap.lua]:5: in function <x>\n[Interface/AddOns/Hooker/Hook.lua]:9: in function 'Hook'",
	}
	eq(F.GetCulprit(viaStack), "Hooker", "first non-game frame in the stack")
	eq(F.GetCulprit({ message = "...terface/AddOns/Blizzard_Minimap/Minimap.lua:5: boom" }), nil, "game-only error has no culprit")
end)

T.case("game and engine frames are dimmed, addon frames show their owner", function()
	local ns = freshFormat()
	local text = ns.Format.FormatError({
		message = "Interface/AddOns/Owner/A.lua:1: boom",
		counter = 1,
		stack = "[Interface/AddOns/Owner/A.lua]:1: in function 'Run'\n[C]: in function 'pcall'\n[Interface/AddOns/Blizzard_X/B.lua]:2: in function <x>",
	})
	assert(text:find(painted(ns, "addon", "Owner") .. "|r", 1, true), "owner painted gold")
	assert(text:find(painted(ns, "funcName", "'Run'"), 1, true), "named function bright")
	assert(text:find(painted(ns, "dim", "Blizzard_X/B.lua"), 1, true), "game path dimmed")
	assert(text:find(painted(ns, "dim", "[C]: "), 1, true), "engine frame dimmed")
	assert(text:find(painted(ns, "dim", "AddOn: ") .. "|r" .. painted(ns, "addon", "Owner"), 1, true), "culprit line")
end)

T.case("nested locals keep their depth and colour by kind", function()
	local ns = freshFormat()
	local text = ns.Format.FormatError({
		message = "m",
		counter = 1,
		locals = 'self=Frame <T.xml:12>{\n inner="v"\n}\nflag=<secret boolean>\n(*temporary)=nil',
	})
	assert(text:find("\n   " .. painted(ns, "varName", "inner"), 1, true), "child indented")
	assert(text:find(painted(ns, "typeName", "Frame") .. "|r " .. painted(ns, "punct", "<T.xml:12>{"), 1, true), "widget reference")
	assert(text:find(painted(ns, "secret", "<secret boolean>"), 1, true), "secret placeholder")
	assert(text:find(painted(ns, "dim", "(*temporary)"), 1, true), "temporary slot dimmed")
end)

T.case("frames from our own capture path at the top of an old stack are hidden", function()
	local ns = freshFormat()
	local own = "[Interface/AddOns/" .. ns.ADDON_NAME .. "/Core/Capture.lua]:139: in function <x>"
	local text = ns.Format.FormatError({
		message = "m",
		counter = 1,
		stack = own .. "\n[C]: in function 'pcall'\n" .. own .. "\n[Interface/AddOns/Real/R.lua]:3: in function <y>",
		locals = "errorMessage=\"handler state\"",
	})
	eq(text:find("Capture.lua", 1, true), nil, "own frames dropped")
	assert(text:find(painted(ns, "addon", "Real"), 1, true), "real frame kept")
	eq(text:find("handler state", 1, true), nil, "handler locals hidden")
	assert(text:find("Not shown.", 1, true), "note explains the gap")
end)

T.case("list labels lead with the owner instead of the file path", function()
	local ns = freshFormat()
	local F = ns.Format
	local strip = function(s)
		return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
	end
	eq(strip(F.ShortMessage({ message = "Interface/AddOns/Owner/Deep/Path/File.lua:12: attempt to index a nil value" })), "Owner  attempt to index a nil value", "path dropped")
	eq(strip(F.ShortMessage({ message = "[ADDON_ACTION_BLOCKED] AddOn 'Owner' tried to call the protected function 'CastSpell()'." })), "Owner  blocked CastSpell()", "blocked action")
	eq(strip(F.ShortMessage({ message = "plain text with no owner" })), "plain text with no owner", "unchanged without an owner")
	assert(strip(F.MessageLine({ message = "Interface/AddOns/Owner/File.lua:12: boom" })):find("Owner/File.lua:12", 1, true), "tooltip line keeps the path")
end)

T.case("plain export names the culprit", function()
	local ns = freshFormat()
	local plain = ns.Format.PlainError({ message = "Interface/AddOns/MyAddon/Core.lua:5: boom", counter = 2 })
	eq(plain, "2x Interface/AddOns/MyAddon/Core.lua:5: boom\nAddOn: MyAddon", "plain text")
end)

T.finish()
