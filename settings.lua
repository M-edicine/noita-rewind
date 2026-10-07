--[[ Noita Rewind · 游戏内 Mod 设置
	引擎会自己加载本文件（同目录的 mod_id.txt 决定 mod id）。
	写法照抄游戏自带的 data/scripts/lib/mod_settings.lua 的约定，
	参考了工作区里的汉化 mod（1999805551）——它的设置能在【选项 → 模组设置】里正常显示。

	按键设置用自定义控件（setting.ui_fn）：
	  左键点一下 → 进入"等待输入"模式（按钮文字变成提示）→ 你按任意键 → 自动识别成键名并写回 → 退出等待
	  等待中：Esc 取消、右键恢复默认；点击别处/关闭菜单也会取消。
]]
pcall(dofile, "data/scripts/lib/mod_settings.lua")
if type(MOD_SETTING_SCOPE_RUNTIME) ~= "number" then MOD_SETTING_SCOPE_RUNTIME = 2 end
if type(MOD_SETTING_SCOPE_RUNTIME_RESTART) ~= "number" then MOD_SETTING_SCOPE_RUNTIME_RESTART = 1 end

local mod_id = "rewind_v5"
mod_settings_version = 1

-- 键名 ↔ SDL scancode（取自游戏自带的 data/scripts/debug/keycodes.lua，已核对）
local NAME_TO_CODE = {
	["A"]=4,["B"]=5,["C"]=6,["D"]=7,["E"]=8,["F"]=9,["G"]=10,["H"]=11,["I"]=12,["J"]=13,["K"]=14,["L"]=15,["M"]=16,
	["N"]=17,["O"]=18,["P"]=19,["Q"]=20,["R"]=21,["S"]=22,["T"]=23,["U"]=24,["V"]=25,["W"]=26,["X"]=27,["Y"]=28,["Z"]=29,
	["0"]=39,["1"]=30,["2"]=31,["3"]=32,["4"]=33,["5"]=34,["6"]=35,["7"]=36,["8"]=37,["9"]=38,
	["SPACE"]=44,["RETURN"]=40,["ENTER"]=40,["TAB"]=43,["ESCAPE"]=41,["BACKSPACE"]=42,["DELETE"]=76,["INSERT"]=73,
	["HOME"]=74,["END"]=77,["PAGEUP"]=75,["PAGEDOWN"]=78,["LEFT"]=80,["RIGHT"]=79,["UP"]=82,["DOWN"]=81,
	["MINUS"]=45,["EQUALS"]=46,["LEFTBRACKET"]=47,["RIGHTBRACKET"]=48,["BACKSLASH"]=49,["SEMICOLON"]=51,
	["APOSTROPHE"]=52,["COMMA"]=54,["PERIOD"]=55,["SLASH"]=56,["GRAVE"]=53,["CAPSLOCK"]=57,
	["F1"]=58,["F2"]=59,["F3"]=60,["F4"]=61,["F5"]=62,["F6"]=63,["F7"]=64,["F8"]=65,["F9"]=66,["F10"]=67,["F11"]=68,["F12"]=69,
}
local CODE_TO_NAME = {}
for name, code in pairs(NAME_TO_CODE) do
	if CODE_TO_NAME[code] == nil or #name < #CODE_TO_NAME[code] then CODE_TO_NAME[code] = name end
end
CODE_TO_NAME[40] = "RETURN"     -- ENTER/RETURN 同名，统一显示 RETURN
local MODIFIER_CODES = { 224, 228, 225, 229, 226, 230 }   -- Ctrl/Shift/Alt 左右各一
local SKIP_CODES = { [41] = true }                          -- Esc 用来取消，不当成绑定键

local function key_display(v)
	if v == nil or v == "" then return "（未设置）" end
	local t = tostring(v):upper():gsub("%s", "")
	local n = tonumber(t)
	if n then
		local nm = CODE_TO_NAME[math.floor(n)]
		if nm then return nm .. "（键码 " .. tostring(math.floor(n)) .. "）" end
		return "键码 " .. tostring(math.floor(n))
	end
	return t
end

local function setting_id_of(mod_id_arg, setting)
	if type(mod_setting_get_id) == "function" then
		local ok, v = pcall(mod_setting_get_id, mod_id_arg, setting)
		if ok and v then return v end
	end
	return tostring(mod_id_arg) .. "." .. tostring(setting.id)
end

-- 扫一遍键码，返回第一个"刚按下"的键码（跳过修饰键与 Esc）
local function poll_pressed_key()
	if type(InputIsKeyJustDown) ~= "function" then return nil end
	for code = 4, 230 do
		local skip = SKIP_CODES[code]
		if not skip then
			for _, m in ipairs(MODIFIER_CODES) do if code == m then skip = true end end
		end
		if not skip then
			local ok, d = pcall(InputIsKeyJustDown, code)
			if ok and d then return code end
		end
	end
	return nil
end

local function esc_just_down()
	if type(InputIsKeyJustDown) ~= "function" then return false end
	local ok, d = pcall(InputIsKeyJustDown, 41)
	return (ok and d) and true or false
end

local waiting = nil    -- 正在等待输入的设置 id

-- 本文件不依赖 init.lua 的内部变量，日志走 print（游戏控制台/日志）
local function LOG_SETTINGS(msg)
	print("[rewind_v5 设置] " .. tostring(msg))
end

function rewind_cancel_keybind_wait()
	waiting = nil
end

-- 自定义控件：点击进入等待输入模式，按任意键自动识别
function mod_setting_keybind( mod_id_arg, gui, in_main_menu, im_id, setting )
	local sid = setting_id_of(mod_id_arg, setting)
	local value = ModSettingGetNextValue(sid)
	if type(value) ~= "string" or value == "" then value = setting.value_default or "" end

	local is_waiting = (waiting == setting.id)
	local label
	if is_waiting then
		label = setting.ui_name .. "：请按下要绑定的按键Esc取消/右键恢复默认"
	else
		label = setting.ui_name .. "：" .. key_display(value)
	end

	local xoff = tonumber(mod_setting_group_x_offset) or 0     -- 库给的缩进（库缺失时兜底 0）
	local clicked, right_clicked = GuiButton( gui, im_id, xoff, 0, label )

	if is_waiting then
		if esc_just_down() then
			waiting = nil
			LOG_SETTINGS("改键已取消（Esc）")
		else
			local code = poll_pressed_key()
			if code then
				local name = CODE_TO_NAME[code] or tostring(code)
				ModSettingSetNextValue( sid, name, false )
				LOG_SETTINGS(string.format("改键完成：%s = %s（键码 %d）", tostring(setting.id), name, code))
				waiting = nil
			end
		end
	else
		if right_clicked and setting.value_default then
			ModSettingSetNextValue( sid, setting.value_default, false )
			LOG_SETTINGS(string.format("改键已恢复默认：%s = %s", tostring(setting.id), tostring(setting.value_default)))
		elseif clicked then
			waiting = setting.id
			LOG_SETTINGS(string.format("等待输入：%s", tostring(setting.id)))
		end
	end

	if type(mod_setting_tooltip) == "function" then
		pcall(mod_setting_tooltip, mod_id_arg, gui, in_main_menu, setting)
	elseif type(GuiTooltip) == "function" then
		local desc = setting.ui_description
		if type(desc) == "string" and desc ~= "" then
			pcall(GuiTooltip, gui, desc, "")
		end
	end
end

mod_settings = {
	{
		id = "enable",
		ui_name = "启用存档回溯",
		ui_description = "关闭后存档与回溯功能将不再起作用",
		value_default = true,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "key_save",
		ui_name = "存档按键",
		ui_description = "左键进入改键：按任意键绑定",
		value_default = "S",
		ui_fn = mod_setting_keybind,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "key_rewind",
		ui_name = "回溯按键",
		ui_description = "左键进入改键：按任意键绑定",
		value_default = "Z",
		ui_fn = mod_setting_keybind,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "key_mod",
		ui_name = "修饰键",
		ui_description = "默认Ctrl，左键点击切换，右键恢复默认",
		value_default = "ctrl",
		values = {
			{ "ctrl", "Ctrl" },
			{ "ctrl+shift", "Ctrl+Shift" },
			{ "shift", "Shift" },
			{ "alt", "Alt" },
			{ "none", "无" },
		},
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "same_run_only",
		ui_name = "只回溯本局",
		ui_description = "开启时：如果存档点属于上一局，结算界面的回溯按钮会被禁用。",
		value_default = true,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "banner",
		ui_name = "结算界面按钮样式",
		ui_description = "选择本局无有效存档点时结算界面按钮的样式",
		value_default = "dim",
		values = {
			{ "dim", "灰色" },
			{ "hide", "不显示" },
		},
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
}

-- init.lua 会读这个全局标记来丢弃自己缓存的热键（两个文件不保证是同一个 Lua state，
-- 所以 init.lua 另外还有 1 秒 TTL 兜底，改设置最迟 1 秒内生效）
function _rewind_mark_settings_dirty()
	_rewind_settings_dirty = (os.time and os.time() or 0)
end

function ModSettingsUpdate( init_scope )
	if type(mod_settings_update) == "function" then
		pcall(mod_settings_update, mod_id, mod_settings, init_scope)
	end
	_rewind_mark_settings_dirty()
end

function ModSettingsGuiCount()
	if type(mod_settings_gui_count) ~= "function" then return 0 end
	local ok, n = pcall(mod_settings_gui_count, mod_id, mod_settings)
	if ok and type(n) == "number" then return n end
	return 0
end

function ModSettingsGui( gui, in_main_menu )
	if type(mod_settings_gui) ~= "function" then return end
	pcall(mod_settings_gui, mod_id, mod_settings, gui, in_main_menu )
end

function OnModSettingsChanged()
	waiting = nil                     -- 菜单关闭/改动落地时退出等待输入
	_rewind_mark_settings_dirty()
end
