--[[ ==========================================================================
	Noita Rewind · Ctrl+S 记录存档点 / Ctrl+Z 回溯（死亡界面亦有按钮）
	============================================================================
	机制（每一步都有实机证据，见 docs\阶段二-设计方案.md §16）：

	  Ctrl+S（记录存档点）
	    ① 写跨进程标记 action=checkpoint
	    ② 调引擎读档动作体 FUN_006def70
	       ⇒ 引擎会**自动保存当前进度**，然后**干净重启进程**并回到世界（不回主菜单）
	    ③ 新进程的 mod 初始化阶段（世界加载之前，实测窗口约 3 秒）把该槽的**局内文件**
	       镜像到 <mod>\snap\  ⇒ 得到一份完整、一致的存档点
	    注：存档点语义 = "按下 Ctrl+S 那一刻的进度" ✓

	  Ctrl+Z（回溯）
	    ① 先把当前槽镜像到 <mod>\snap_auto\（保护点，防误操作）
	    ② 写跨进程标记 action=restore
	    ③ 调 FUN_006def70（请求引擎读档转场）
	    ④ 引擎自己立刻起新进程（默认不做任何干预；SPAWN_HOOK=on 时只在这一刻改正命令行）
	    ⑤ 新进程初始化阶段把 <mod>\snap\（或配置指定的目录）铺回槽
	    ⑥ 引擎读档读到我们铺的文件 ⇒ 世界回到存档点 ✓（不回菜单、不需任何点击）

	  ★ 自动重启状态
	    引擎的读档转场本来就是"旧进程立刻起一个新进程、新进程自己读档进世界" ⇒ 这一步不用改。
	    实测：本 mod 只要在**新进程进世界之前**多做一点点事（装钩子/跑自检），新进程就 100% 崩在
	    atioglxx.dll+0x00eae1ee；什么多做，就与可用的 rewind_v3restored 一样正常进世界。
	    所以现在 OnModPreInit 里只保留：init_win32 / init_paths / 日志 / load_config / GuiCreate /
	    handle_pending —— 与 rewind_v3restored 逐条一致；自检挪到进世界之后，钩子默认关
	    （SPAWN_HOOK=on 才在按下回溯那一刻装，用来兜住引擎偶尔拼出的 -gamemode 4294967295）。

	安全边界（都写进日志便于核对）
	  · 只动**局内文件**：player.xml / world_state.xml / world\**；
	    persistent\、stats\、session_numbers / mod_config / mod_settings **一个字节都不碰**
	  · 删除只限三种：槽里"快照没有的"多余区块、本 mod 自己的标记文件、旧快照（由用户手动清理）
	  · 引擎函数只调用 FUN_006def70（读档动作体）——不含任何代码补丁、不调用保存/序列化/清档函数
	  · 默认不碰任何导入表；SPAWN_HOOK=on 时才在回溯那一刻写 4 个字节，用完立刻还原
	  · 跨进程标记超过 STALE_MS 即判为陈旧并忽略（不做任何文件改动）
	  · 屏幕提示最多两行；不 spawn 任何自己的进程

	配置：<mod>\rewind_config.txt（首次运行自动生成）
	  ENABLE=on|off                  总开关
	  RESTORE_FROM=snap|snap_auto    Ctrl+Z 用哪个目录（改成 snap_auto 可撤销上一次回溯）
	  SNAP_DIR=snap / AUTO_DIR=snap_auto   目录名（相对 mod 目录）
	  DELAY_FRAMES=300               进世界后多少帧才接受按键/文件触发
	  GUI_X / GUI_Y                  死亡界面按钮位置
	  LOG_KEYS=on|off                记录按下的 scancode（排查键位，每键只记一次）
	  HEARTBEAT=on|off               转场后打印心跳（附 PID）
	  STALE_MS=180000                标记判陈旧的时限

	触发方式（两种，互为兜底）
	  · 按键：Ctrl+S / Ctrl+Z（Ctrl=224 或 228；S=22、Z=29）
	  · 文件：在 mod 目录新建 RUN_CHECKPOINT.txt / RUN_REWIND.txt（执行后自动删除）

	日志：<mod>\rewind_log.txt
	========================================================================== ]]

local io_lib, os_lib, ffi, bit
do
	local ok, m
	ok, m = pcall(require, "io");  if ok then io_lib = m end
	ok, m = pcall(require, "os");  if ok then os_lib = m end
	ok, m = pcall(require, "ffi"); if ok then ffi = m end
	ok, m = pcall(require, "bit"); if ok then bit = m end
end

local has_gameprint = (type(GamePrint) == "function")
local has_frame_api = (type(GameGetFrameNum) == "function")
local has_input     = (type(InputIsKeyDown) == "function") and (type(InputIsKeyJustDown) == "function")
local function frame_no()
	if has_frame_api then local ok, n = pcall(GameGetFrameNum); if ok and type(n) == "number" then return n end end
	return 0
end
local function PRINT(m) if has_gameprint then pcall(GamePrint, m) end end
local function PRINT_IMPORTANT(a, b) if type(GamePrintImportant) == "function" then pcall(GamePrintImportant, a, b) end end
-- 只弹"一行装饰框提示"：GamePrintImportant( title, description ) 里只有 title 带那个框，
-- description 是框外的普通文字。所以把信息本身当 title、description 留空 ⇒ 屏幕上只有一个框，框里就是信息。
local function NOTICE(msg)
	if type(GamePrintImportant) == "function" then pcall(GamePrintImportant, msg, "") end
end

-- ==========================================================================
-- Win32（只用文件与内存读取；不含任何代码补丁能力）
-- ==========================================================================
local k32
local INVALID_HANDLE = -1
local MEM_COMMIT, PAGE_NOACCESS, PAGE_GUARD = 0x1000, 0x01, 0x100
local READABLE_MASK = 0x02 + 0x04 + 0x08 + 0x20 + 0x40 + 0x80
local FILE_ATTRIBUTE_DIRECTORY, INVALID_ATTR = 0x10, 0xffffffff

local function init_win32()
	if not ffi then return false end
	local ok = pcall(function()
		ffi.cdef[[
			void*    __stdcall GetModuleHandleA(const char* lpModuleName);
			uint32_t __stdcall GetModuleFileNameA(void* hModule, char* lpFilename, uint32_t nSize);
			uint32_t __stdcall GetFileAttributesA(const char* lpFileName);
			uint32_t __stdcall GetCurrentProcessId(void);
			void*    __stdcall GetProcAddress(void* hModule, const char* lpProcName);
			const void* __stdcall GetCommandLineW(void);
			const char* __stdcall GetCommandLineA(void);
			uint32_t __stdcall GetTickCount(void);
			uint32_t __stdcall GetLastError(void);
			uint32_t __stdcall VirtualQuery(const void* lpAddress, void* lpBuffer, uintptr_t dwLength);
			int      __stdcall VirtualProtect(void* lpAddress, uintptr_t dwSize, uint32_t flNewProtect, uint32_t* lpflOldProtect);
void*    __stdcall VirtualAlloc(void* lpAddress, uintptr_t dwSize, uint32_t flAllocationType, uint32_t flProtect);
			int      __stdcall CloseHandle(void* hObject);
			/* 自动重启：延迟拉起新进程（见文件后半段『自动重启』一节） */
			typedef struct {
				uint32_t cb;
				char*    lpReserved; char* lpDesktop; char* lpTitle;
				uint32_t dwX; uint32_t dwY; uint32_t dwXSize; uint32_t dwYSize;
				uint32_t dwXCountChars; uint32_t dwYCountChars; uint32_t dwFillAttribute;
				uint32_t dwFlags; uint16_t wShowWindow; uint16_t cbReserved2;
				void*    lpReserved2;
				void*    hStdInput; void* hStdOutput; void* hStdError;
			} RW_STARTUPINFOA;
			typedef struct {
				void*    hProcess; void* hThread;
				uint32_t dwProcessId; uint32_t dwThreadId;
			} RW_PROCESS_INFORMATION;
			int      __stdcall CreateProcessA(const char* lpApplicationName, char* lpCommandLine,
			                                  void* lpProcessAttributes, void* lpThreadAttributes,
			                                  int bInheritHandles, uint32_t dwCreationFlags,
			                                  void* lpEnvironment, const char* lpCurrentDirectory,
			                                  RW_STARTUPINFOA* lpStartupInfo, RW_PROCESS_INFORMATION* lpProcessInformation);
			/* 只是为了让 ffi.load("kernel32") 能取到这个符号（我们用它做原样转发） */
			int      __stdcall CreateProcessW(const void* lpApplicationName, void* lpCommandLine,
			                                  void* lpProcessAttributes, void* lpThreadAttributes,
			                                  int bInheritHandles, uint32_t dwCreationFlags,
			                                  void* lpEnvironment, const void* lpCurrentDirectory,
			                                  void* lpStartupInfo, void* lpProcessInformation);
			int      __stdcall CreateDirectoryA(const char* lpPathName, void* lpSecurityAttributes);
			int      __stdcall RemoveDirectoryA(const char* lpPathName);
			int      __stdcall CopyFileA(const char* lpExistingFileName, const char* lpNewFileName, int bFailIfExists);
			void*    __stdcall FindFirstFileA(const char* lpFileName, void* lpFindFileData);
			int      __stdcall FindNextFileA(void* hFindFile, void* lpFindFileData);
			int      __stdcall FindClose(void* hFindFile);
			typedef struct {
				uint32_t dwFileAttributes;
				uint32_t ftCreationTime_lo;   uint32_t ftCreationTime_hi;
				uint32_t ftLastAccessTime_lo; uint32_t ftLastAccessTime_hi;
				uint32_t ftLastWriteTime_lo;  uint32_t ftLastWriteTime_hi;
				uint32_t nFileSizeHigh;       uint32_t nFileSizeLow;
				uint32_t dwReserved0;         uint32_t dwReserved1;
				char     cFileName[260];
				char     cAlternateFileName[14];
			} RW_FIND_DATAA;
			typedef struct {
				void*     BaseAddress;
				void*     AllocationBase;
				uint32_t  AllocationProtect;
				uintptr_t RegionSize;
				uint32_t  State;
				uint32_t  Protect;
				uint32_t  Type;
			} RW_MBI;
		]]
		k32 = ffi.load("kernel32")
	end)
	return ok and k32 ~= nil
end

local function band(a, b)
	if bit then return bit.band(tonumber(a) or 0, tonumber(b) or 0) end
	local res, w = 0, 1
	a, b = tonumber(a) or 0, tonumber(b) or 0
	for _ = 1, 32 do
		local x, y = a % 2, b % 2
		if x == 1 and y == 1 then res = res + w end
		a, b = (a - x) / 2, (b - y) / 2
		w = w * 2
		if a <= 0 and b <= 0 then break end
	end
	return res
end

local function pid()
	if k32 then local ok, v = pcall(function() return tonumber(k32.GetCurrentProcessId()) end); if ok and v then return v end end
	return -1
end
local function tickMs()
	if k32 then local ok, v = pcall(function() return tonumber(k32.GetTickCount()) end); if ok and v then return v end end
	return -1
end

local function readable(addr, len)
	if not (k32 and ffi) then return false end
	local a, remaining, guard = addr, len, 0
	while remaining > 0 do
		guard = guard + 1
		if guard > 64 then return false end
		local mbi = ffi.new("RW_MBI[1]")
		if tonumber(k32.VirtualQuery(ffi.cast("const void*", a), mbi, ffi.sizeof("RW_MBI"))) == 0 then return false end
		local m = mbi[0]
		if tonumber(m.State) ~= MEM_COMMIT then return false end
		local prot = tonumber(m.Protect)
		if prot == 0 or band(prot, PAGE_NOACCESS) ~= 0 or band(prot, PAGE_GUARD) ~= 0 then return false end
		if band(prot, READABLE_MASK) == 0 then return false end
		local base = tonumber(ffi.cast("uintptr_t", m.BaseAddress))
		local region = tonumber(m.RegionSize)
		if region <= 0 then return false end
		local step = base + region - a
		if step <= 0 then return false end
		remaining = remaining - step
		a = a + step
	end
	return true
end

local function rd8(a) if not readable(a, 1) then return nil end return tonumber(ffi.cast("uint8_t*", a)[0]) end
local function rd32(a) if not readable(a, 4) then return nil end return tonumber(ffi.cast("uint32_t*", a)[0]) end

local function attrs(p) if not (k32 and p) then return nil end local a = tonumber(k32.GetFileAttributesA(p)); if a == INVALID_ATTR then return nil end return a end
local function is_dir(p) local a = attrs(p); if not a then return false end return band(a, FILE_ATTRIBUTE_DIRECTORY) ~= 0 end
local function file_sig(p)
	if not (k32 and ffi and p) then return nil end
	local st = ffi.new("RW_FIND_DATAA[1]")
	local h = k32.FindFirstFileA(p, st[0])
	if tonumber(ffi.cast("intptr_t", h)) == INVALID_HANDLE then return nil end
	k32.FindClose(h)
	local d = st[0]
	return {
		size = tonumber(d.nFileSizeLow) + tonumber(d.nFileSizeHigh) * 4294967296,
		time = tonumber(d.ftLastWriteTime_hi) * 4294967296 + tonumber(d.ftLastWriteTime_lo),
	}
end
local function make_dir(p) if k32 and p then pcall(k32.CreateDirectoryA, p, nil) end end

local function enumerate_tree(root, rel, depth, out)
	depth = depth or 0
	rel = rel or ""
	out = out or {}
	if depth > 10 then return out end
	if not (k32 and ffi and root) then return out end
	local pattern = (rel == "") and (root .. "\\*") or (root .. "\\" .. rel .. "\\*")
	local st = ffi.new("RW_FIND_DATAA[1]")
	local h = k32.FindFirstFileA(pattern, st[0])
	if tonumber(ffi.cast("intptr_t", h)) == INVALID_HANDLE then return out end
	repeat
		local d = st[0]
		local name = ffi.string(d.cFileName)
		if name ~= "." and name ~= ".." then
			local child = (rel == "") and name or (rel .. "\\" .. name)
			local isdir = band(tonumber(d.dwFileAttributes), FILE_ATTRIBUTE_DIRECTORY) ~= 0
			out[#out + 1] = { rel = child, size = tonumber(d.nFileSizeLow) + tonumber(d.nFileSizeHigh) * 4294967296, dir = isdir }
			if isdir and #out < 8000 then enumerate_tree(root, child, depth + 1, out) end
		end
		if #out >= 8000 then break end
	until k32.FindNextFileA(h, st[0]) == 0
	k32.FindClose(h)
	return out
end

-- ==========================================================================
-- 路径 / 配置 / 日志
-- ==========================================================================
local BASE = 0x400000
local GAME_DIR, SAVE_ROOT, MOD_DIR, DATA_DIR, LOG_PATH, CFG_PATH
local PATH_NOTES = {}   -- init_paths 里攒下的说明（LOG 那时还没定义，见 OnModPreInit）

local function read_text(p)
	if not (io_lib and p) then return nil end
	local f = io_lib.open(p, "r"); if not f then return nil end
	local s = f:read("*a"); f:close(); return s
end
local function write_text(p, s)
	if not (io_lib and p) then return false end
	local f = io_lib.open(p, "w"); if not f then return false end
	f:write(s); f:close(); return true
end
local function remove_file(p)
	if os_lib and os_lib.remove and p then pcall(os_lib.remove, p) end
end

-- 把一个文件或整个目录搬到新位置（先复制、成功后再删源；返回 成功?, 失败原因）
local function move_path(src, dst)
	if not (k32 and ffi) then return false, "没有 ffi/k32" end
	if file_sig(src) then
		local ok = pcall(k32.CopyFileA, src, dst, 0)
		if not ok then return false, "复制文件失败" end
		if not file_sig(dst) then return false, "复制后目标不存在" end
		remove_file(src)
		return true, nil
	end
	if is_dir(src) then
		make_dir(dst)
		for _, f in ipairs(enumerate_tree(src, "", 0, {})) do
			if f.dir then
				make_dir(dst .. "\\" .. f.rel)
			else
				local ok = pcall(k32.CopyFileA, src .. "\\" .. f.rel, dst .. "\\" .. f.rel, 0)
				if not ok then return false, "复制 " .. tostring(f.rel) .. " 失败" end
			end
		end
		-- 复制完再删源目录（清空后删目录）
		for _, f in ipairs(enumerate_tree(src, "", 0, {})) do
			if not f.dir then remove_file(src .. "\\" .. f.rel) end
		end
		pcall(k32.RemoveDirectoryA, src)
		return true, nil
	end
	return false, "源不存在"
end

local function init_paths()
	if k32 and ffi then
		pcall(function()
			local buf = ffi.new("char[1024]")
			local n = tonumber(k32.GetModuleFileNameA(nil, buf, 1024))
			if n > 0 then GAME_DIR = ffi.string(buf, n):match("^(.*)\\[^\\]+$") end
		end)
	end
	if type(REWIND_TEST_ROOT) == "string" and REWIND_TEST_ROOT ~= "" then GAME_DIR = REWIND_TEST_ROOT end
	local home = os_lib and os_lib.getenv and os_lib.getenv("USERPROFILE")
	if home then SAVE_ROOT = home .. "\\AppData\\LocalLow\\Nolla_Games_Noita" end
	if GAME_DIR then
		local c = GAME_DIR .. "\\mods\\rewind_v5"
		if is_dir(c) then MOD_DIR = c else MOD_DIR = GAME_DIR end
	end
	-- ★★★ 运行期文件一律放在 mods\\ 之外 ★★★
	--   原因：引擎判断"模组被修改了"看的是模组目录里的内容。我们把快照/日志/标记写在
	--   mods\\rewind_v5\\ 里 ⇒ 引擎认为模组变了 ⇒ 红字"模组已被修改" + 强制重启（而"存档后重启"在这台机器上会 abort）。
	--   位置选在存档根目录下**与 save00..save06 并列**的一个文件夹：引擎不会去扫它，
	--   也不会像 save00\\world 那样被"未知文件清理"；数据不在槽里 ⇒ 不参与任何存档完整性检查。
	if SAVE_ROOT then
		DATA_DIR = SAVE_ROOT .. "\\noita_rewind_v5"
		make_dir(DATA_DIR)
		if not is_dir(DATA_DIR) then DATA_DIR = nil end          -- 建不出来就退回老位置
	end
	if not DATA_DIR then
		DATA_DIR = MOD_DIR
		PATH_NOTES[#PATH_NOTES + 1] = "★ 数据目录建不出来（存档根目录不可写？）⇒ 退回 mod 目录；这会让『模组被修改』的老问题回来"
	end
	if MOD_DIR and DATA_DIR ~= MOD_DIR then
		LOG_PATH = DATA_DIR .. "\\rewind_log.txt"
		CFG_PATH = DATA_DIR .. "\\rewind_config.txt"
		-- 首次运行：把老位置（mods\\rewind_v5\\）里的运行期文件搬到新位置，先复制成功再删旧的
		for _, name in ipairs({ "snap", "snap_auto", "pending.txt", "rewind_config.txt" }) do
			local old = MOD_DIR .. "\\" .. name
			local new = DATA_DIR .. "\\" .. name
			if (not file_sig(new)) and (not is_dir(new)) and (file_sig(old) or is_dir(old)) then
				local moved, why = move_path(old, new)
				PATH_NOTES[#PATH_NOTES + 1] = string.format("搬迁 %s → %s ：%s", old, new, moved and "成功 ✓" or ("失败（" .. tostring(why) .. "）"))
			end
		end
	else
		LOG_PATH = MOD_DIR .. "\\rewind_log.txt"
		CFG_PATH = MOD_DIR .. "\\rewind_config.txt"
	end
end

local log_fp
local function LOG(msg)
	local line = "[" .. tostring(frame_no()) .. "] " .. tostring(msg)
	if LOG_PATH and io_lib then
		if not log_fp then log_fp = io_lib.open(LOG_PATH, "a") end
		if log_fp then log_fp:write(line .. "\n"); log_fp:flush() end
	end
end

-- 构建标记：日志里会打出来，用来确认"游戏里跑的是哪一版"（mod 的 Lua 只在游戏启动时加载一次！）
local BUILD_TAG = "v7.6（区块加载改成『存档后等守卫 +0x458 非 0 再调 FUN_0073DAB0』，每帧重试最多 15 秒）"

local CFG = {
	ENABLE = "on", RESTORE_FROM = "snap", SNAP_DIR = "snap", AUTO_DIR = "snap_auto",
	DELAY_FRAMES = "300", GUI_X = "53.47", GUI_Y = "70.33", GUI_UNIT = "percent", GUI_ANCHOR = "center",
	GUI_SCALE = "auto", GUI_COLOR = "0.816,0.812,0.804,1", GUI_COLOR_HOVER = "0.996,0.992,0.678,1",
	GUI_MOUSE_UNITS = "auto", GUI_HIT_PAD = "0", GUI_HIT_W = "auto", GUI_SNAP = "gui",
	GUI_STEP = "1", GUI_STEP_COARSE = "4", GUI_STEP_UNIT = "gui",
	REQUIRE_SAME_RUN = "on", BANNER = "dim",
	MENU_BIND = "on", MENU_X = "45,55", MENU_Y = "72,75.8,78.5", MENU_H = "2.4", BIND_MODE = "row",
	KEY_SAVE = "S", KEY_REWIND = "Z", KEY_MOD = "ctrl",
	DEATH_SHOW_ON = "key", DEATH_SHOW_DELAY_MS = "250", DEBUG_MENU_STATE = "off", DEATH_EXEC_IN_PAUSE = "on", LOG_KEYS = "on", HEARTBEAT = "on",
	STALE_MS = "180000",
	SAVE_MODE = "xml", RELOAD_CHUNKS = "off", RELOAD_CHUNKS_MAX = "4", NUDGE_CAMERA = "off", RELOAD_STREAM = "off", SAVE_COOLDOWN_MS = "8000", NUDGE_PLAYER = "off", RELOAD_AREA = "off", PROBE_HOOKS = "off", PROBE_READ = "off", PROBE_DUMP = "off", PROBE_SCAN = "off",
	SPAWN_HOOK = "off",
}
local hotkey_cache = nil   -- 热键解析缓存（配置重读时清空）
local function load_config()
	if not CFG_PATH then return end
	hotkey_cache = nil
	local s = read_text(CFG_PATH)
	if not s then
		write_text(CFG_PATH, table.concat({
			"# Noita Rewind 配置（改完存盘；进世界时会重新读取）",
			"#",
			"# ENABLE=on|off   总开关",
			"ENABLE=on",
			"#",
			"# Ctrl+Z 用哪个目录回溯：snap=存档点；snap_auto=上一次动作前的保护点（可撤销一次错误的回溯）",
			"RESTORE_FROM=snap",
			"#",
			"# 目录名（相对 mod 目录）",
			"SNAP_DIR=snap",
			"AUTO_DIR=snap_auto",
			"#",
			"# 进世界后等多少帧才接受按键/文件触发",
			"DELAY_FRAMES=300",
			"#",
			"# 死亡界面『回溯』按钮位置（对齐引擎菜单项的竖列）",
			"#   2560x1440 截图实测：菜单项居中于 x=50%，『新游戏』文字顶边=72%，行距≈3.3%，",
			"#     菜单文字高 ≈ 34px = 屏幕高的 2.36%（我们的字号会自动对齐这个高度）",
			"#     ⇒ GUI_Y=68.5 正好是『新游戏』上面一行（GUI_Y=14 在 'Game Over' 标题上方）",
			"#   GUI_UNIT=percent：GUI_X/GUI_Y 是屏幕百分比（0-100）",
			"#   GUI_UNIT=pixel  ：按 GUI 像素（= GuiGetScreenDimensions 返回的坐标系，本机 640x360）",
			"#   GUI_ANCHOR=center：GUI_X 是文字水平中心（默认，你调好的那组值就是这个语义）；=left 时是左边缘",
			"#   GUI_SCALE=auto  ：自动按引擎菜单文字高度定字号；也可以直接写数字（如 1.2）",
			"#   GUI_COLOR=1,1,1,1：按钮文字颜色（RGBA 0-1）。引擎菜单项是亮白，默认灰会显得突兀。写 default 表示不改",
			"#   ★ 位置只用键盘调（没有鼠标拖动）：死亡界面按住 Ctrl + 方向键（左80 右79 上82 下81）",
			"#     ★ 引擎控件坐标有最小格：1 个 GUI 单位 = 4 屏幕像素（2560x1440）",
			"#     GUI_STEP=1 格（每按必动一格）、GUI_STEP_COARSE=4 格（加 Shift）",
			"GUI_X=53.47",
			"GUI_Y=70.33",
			"GUI_UNIT=percent",
			"GUI_ANCHOR=center",
			"GUI_SCALE=auto",
			"#   ★ 实测对齐：引擎菜单项的白色是 #d0cfcd（0.816,0.812,0.804），悬停高亮 #fefdad 是引擎自己叠的",
			"#     （本 mod 不再自己压暗/提亮，悬停高亮完全交给引擎 ⇒ 和旁边的菜单项同色）",
			"#   ★ 两档颜色由我们自己画（不依赖引擎高亮）：",
			"#     GUI_COLOR        = 未选中：默认 0.816,0.812,0.804 = #d0cfcd（引擎菜单项的白色）",
			"#     GUI_COLOR_HOVER  = 选中（鼠标压在上面）：默认 0.996,0.992,0.678 = #fefdad",
			"#     想微调就改这两行（RGBA，0-1；写 default 表示交给引擎默认）",
			"GUI_COLOR=0.816,0.812,0.804,1",
			"GUI_COLOR_HOVER=0.996,0.992,0.678,1",
			"GUI_STEP=1",
			"GUI_STEP_COARSE=4",
			"GUI_STEP_UNIT=gui",
			"#",
			"# ★ 存/读档按键：请用游戏内的【Mod 设置】界面修改（暂停菜单 → Mod 设置，或主菜单 Mods）",
			"#   下面这三个键只是『库/菜单不可用时的后备值』，正常情况会被 Mod 设置里的值覆盖。",
			"#   键名取自游戏自带的 data/scripts/debug/keycodes.lua（A-Z 0-9 SPACE RETURN TAB ESCAPE F1-F12 方向键…），",
			"#   也可以直接写键码数字（KEY_SAVE=22 就是 S）。",
			"KEY_SAVE=S",
			"KEY_REWIND=Z",
			"KEY_MOD=ctrl",
			"#",
			"# ★ 是否只允许回溯本局的存档点（防止回到上一局的位置）",
			"#   on  = 存档点建立时记下世界种子/区块清单，回溯前比对；不属于本局就无效（建议保持 on）",
			"#   off = 不检查（旧行为，可能回到上一局）",
			"REQUIRE_SAME_RUN=on",
			"# 本局没有有效存档点时，死亡界面按钮的样子：dim=灰色不可点 / hide=完全不显示",
			"BANNER=dim",
			"#",
			"# （以下 MENU_* 只在读不到引擎状态时才用）与结算界面同生共死：结算界面的菜单项只能用鼠标点，位置固定",
			"#   · 点那个翻页大按钮「你死掉了 - 点击此处查看统计」⇒ 回溯按钮跟着 收起⇄重新显示",
			"#   · 点『新游戏』『退出』                       ⇒ 收起回溯按钮",
			"#   · 点别处                                     ⇒ 不动",
			"# MENU_X/MENU_Y/MENU_H：三个菜单项的水平范围 / 各行文字顶边 / 行高，单位=屏幕百分比",
			"#   （默认值来自 2560x1440 截图实测：新游戏 72%、保存死亡回放 75.8%、退出 78.5%，行高 2.4%）",
			"# 如果你的分辨率/UI 缩放下点了没反应，就把这三项按实际位置改一改；MENU_BIND=off 可关闭此跟随",
			"# ★ 用引擎状态把『回溯』按钮和『那一排三个按钮』绑死（逆向 FUN_006e51e0）",
			"#   引擎状态：DAT_01207680=页面（0=第一屏『你死掉了-点击此处查看统计』，1=三按钮那一排所在页）",
			"#             DAT_0120767c=结算界面帧计数器（每画一帧 +1，界面关掉就停）",
			"#   BIND_MODE=row   ：那一排（新游戏 / 保存死亡回放 / 退出）在屏幕上时才显示『回溯』（默认，与它同生共死）",
			"#   BIND_MODE=always：结算界面还在画（任意一屏）就显示",
			"BIND_MODE=row",
			"# 诊断：把引擎里整块结算界面状态打日志（每 30 帧一行，排查哪一排对应哪个字段时可打开）",
			"DEBUG_MENU_STATE=off",
			"MENU_BIND=on",
			"MENU_X=45,55",
			"MENU_Y=72,75.8,78.5",
			"MENU_H=2.4",
			"#",
			"# 死亡界面按钮什么时候出现（**只在读不到引擎状态时**才用这两项）",
			"#   读得到引擎状态时，出现/消失完全由『那一排三个按钮』决定（BIND_MODE）。",
			"#   DEATH_SHOW_ON=key  ：等『死亡后的第一次输入』——引擎的死亡结算界面正是那时才弹出的，",
			"#                       这样按钮和结算界面同时出现（推荐）。",
			"#   DEATH_SHOW_ON=timer：死亡后固定等 DEATH_SHOW_DELAY_MS 毫秒（老行为）",
			"#   DEATH_SHOW_DELAY_MS：上面对应的延迟；key 模式下是『按键之后再等多少毫秒』",
			"DEATH_SHOW_ON=key",
			"DEATH_SHOW_DELAY_MS=250",
			"#",
			"# 鼠标坐标 → GUI 单位的换算（本机实测 InputGetMousePosOnScreen 给的是 1280x720，",
			"# GUI 视口 640x360 ⇒ 2）。用来判定『鼠标是不是压在按钮上』",
			"GUI_MOUSE_UNITS=auto",
			"# 点击判定框：GUI_HIT_W=auto 时按『文字高 × 字符数』估算宽度（'回溯' = 8.5×2 = 17 单位 ≈ 68px）",
			"#   ⚠ 不要直接用 GuiGetTextDimensions 的宽度：它对中文会报大约两倍（实测 2 字报 34 单位），热区会太宽",
			"#   想手动指定宽度就写数字（GUI 单位）；不想外扩就 GUI_HIT_PAD=0",
			"GUI_HIT_W=auto",
			"GUI_HIT_PAD=0",
			"# 键盘微调后是否把位置吸附到整数 GUI 单位（gui=吸附，可复现；off=不吸附）",
			"GUI_SNAP=gui",
			"#",
			"# 死亡界面若世界已停止更新（只剩暂停回调在跑），是否仍允许在暂停回调里执行回溯转场。",
			"# off = 只提示、不调用引擎转场（更保守）；on = 尽力完成回溯",
			"DEATH_EXEC_IN_PAUSE=on",
			"#",
			"# 记录按下的 scancode（排查键位用，每键只记一次）",
			"LOG_KEYS=on",
			"HEARTBEAT=on",
			"#",
			"# 跨进程标记超过多少毫秒即判为陈旧（忽略且不改文件）",
			"STALE_MS=180000",
			"#",
			"# ★ 存档方式（Ctrl+S 怎么把世界写进盘）：",
			"#   SAVE_MODE=xml（代码默认）：只写 world_state.xml + player.xml —— **引擎不会把 world 区块刷到盘上**，",
			"#                              所以快照里的世界仍是上一次落盘的样子（回溯后往往还是开局）。不重启。",
			"#   SAVE_MODE=restart        ：让引擎执行『保存并退出到主菜单』（暂停菜单里那一下）：",
			"#                              引擎完整存档（区块 + 两个 XML）→ 进程自己重启 → 新进程在世界加载前",
			"#                              把槽镜像成存档点。按一次 Ctrl+S 约 10–20 秒自动回来，不用点任何东西。",
			"#                              （2026-10-06 那次它把游戏关掉了，原因是引擎在『模组被修改』时会 abort；",
			"#                                v5.4 已把所有运行期文件搬出 mods\\ ⇒ 红字消失 ⇒ 条件已消除。）",
			"SAVE_MODE=xml",
			"#",
			"# ★ 写盘后是否请求重新加载屏幕内的区块（消除『存档后局部空白、移动才恢复』）",
			"#   RELOAD_CHUNKS=off（默认，先别开）：不做任何额外调用",
			"#   RELOAD_CHUNKS=on            ：写盘后调一次引擎的区块流式更新（0x9A4F50 → FUN_0073B040）",
			"#                                 如果开启后出现异常/崩溃，把它改回 off 即可",
			"RELOAD_CHUNKS=off",
			"#   上限（硬上限也是 4：屏幕里装不下更多区块）",
			"RELOAD_CHUNKS_MAX=4",
			"# ★ 写盘后用公开 API 把相机挪 1 个世界单位（引擎会重新评估屏幕内的区块 ⇒ 消除局部空白）",
			"#   只调官方 Lua API（GameGetCameraPos / GameSetCameraPos / GameGetCameraBounds），零崩溃风险",
			"NUDGE_CAMERA=off",
			"# ★ 写盘后立刻请求一次「流式窗口更新」（等价于引擎自己重新评估区块窗口），",
			"#   依据反汇编还原：vtable 0xFFE57C 的槽 0x9A4F50 → MOV ECX,[ECX+4] → JMP 0x73B040；",
			"#   全局单例 0x11D7530（校验 *(0x11D7530)==0xFFE57C），管理器 = *(0x11D7530+4)。",
			"#   只在写盘落定后调用一次；校验不过就只打日志不调用。",
			"RELOAD_STREAM=off",
			"# ★ 两次存档之间的最小间隔（毫秒）。落盘未结束就再存档会重叠写盘、写坏画面，",
			"#   所以这个值必须大于 settle 的上限（8000 ms）。",
			"SAVE_COOLDOWN_MS=8000",
			"# ★ 写盘后把玩家挪 1 个世界单位（肉眼不可见）。实测「相机微移」无效而「走动」有效，",
			"#   说明引擎重新请求区块的触发条件是玩家自身位置变化；只用官方 Lua API，零崩溃风险。",
			"NUDGE_PLAYER=off",
			"# ★ 写盘后调引擎自己的「按区域加载区块」入口 FUN_0073DAB0(*(session+0x10)+0x500, rect)，",
			"#   rect 是世界单位矩形（相机范围外扩 192）。已存在的区块只会打日志、不重建 ⇒ 幂等。",
			"RELOAD_AREA=off",
			"# ★ 探针：在 9 个调用点 + 1 个 vtable 槽上挂只计数的 14 字节跳板（不改行为）。",
			"#   用法：开 on → 按一次 Ctrl+S（基线）→ 走到空洞消失 → 再按一次 Ctrl+S（差值）。",
			"PROBE_HOOKS=off",
			"# ★ 只读探针：Ctrl+S 时读取 session→world→区块容器→槽表 这条链并列出候选区块对象，",
			"#   用来判断空洞是「区块对象没了」还是「对象在但数据空」。纯读取，零崩溃风险。",
			"PROBE_READ=off",
			"# ★ 只读内存转储：Ctrl+S 时打印 session / world / 区块容器 / *(容器+0x458) 的原始 dword，",
			"#   用来顺着指针找出真正的区块表，并确认 +0x458 何时非 0。纯读取，零崩溃风险。",
			"PROBE_DUMP=off",
			"# ★ 只读区块扫描：Ctrl+S 时列出 world 对象里所有区块对象（坐标+缓冲可读性），",
			"#   并指出玩家 3×3 邻域里哪几个没有区块对象（那就是空洞）。纯读取，零崩溃风险。",
			"PROBE_SCAN=off",
			"#",
			"# ★ 存档点怎么拿到正确的世界快照（Ctrl+S）：",
			"#   引擎只在自己存档时才把 world 区块（world_*.png_petri / entities_*.bin / area_*.bin）写到盘上；",
			"#   平时盘上只有十几个文件 = 上一次落盘的样子（通常就是开局），直接复制就会得到『开局世界』。",
			"#   所以本 mod 的顺序是：调引擎的两个写盘包装（它会连带把区块刷到盘上）",
			"#     → **等盘安静下来**（.autosave* 标记消失、区块文件数连续 0.4 秒不再变化，最多 8 秒）",
			"#     → 才开始镜像到 snap\\。",
			"#   日志里会打印『区块：保存前 N 个文件 → 保存后 M 个文件』：M 明显大于 N 才说明快照是对的。",
			"#",
			"# ★ 自动重启钩子（默认关，别乱开）：",
			"#   引擎的读档转场本来就是『旧进程立刻起一个新进程、新进程自己读档进世界』，这一步是好的；",
			"#   但引擎偶尔会拼出 -gamemode 4294967295（未初始化的值），那种命令行起的新进程必崩在 atioglxx.dll。",
			"#   SPAWN_HOOK=off（默认）：一个字都不动，完全照引擎原样 —— 与本机可用的 rewind_v3restored 行为一致（推荐）",
			"#   SPAWN_HOOK=on         ：在按下回溯、引擎即将起进程的那一刻装一个钩子，把 -gamemode/-save_slot",
			"#                           改正后再让引擎起进程（用来兜住上面那种坏参数；只在这一刻装，不影响新进程启动）",
			"SPAWN_HOOK=off",
			"",
		}, "\n"))
		LOG("已生成默认配置：" .. tostring(CFG_PATH))
		return s
	end
	-- 逐行解析并跳过注释行（这样注释里的 KEY=value 不会覆盖真值）
	for line in s:gmatch("[^\r\n]+") do
		local trimmed = line:gsub("^%s+", "")
		if not trimmed:match("^#") then
			local k, v = trimmed:match("([%w_]+)%s*=%s*([^#]*)")
			if k and CFG[k] ~= nil then CFG[k] = (v or ""):gsub("%s+$", "") end
		end
	end
	return s
end

local function slot_dir(i) if not SAVE_ROOT then return nil end return string.format("%s\\save%02d", SAVE_ROOT, i) end

-- ==========================================================================
-- 关键地址（阶段一规格，双证据）
-- ==========================================================================
local A_CUR_SLOT    = 0x1204bdc   -- 当前槽号（FUN_006b19d0 写入）
local A_ACTION_OBJ  = 0x122374c   -- obj：+0x60 目标槽、+0x68 待执行动作、+0x94 保存门
local A_DEATHMATCH  = 0x1204bc0   -- DeathMatch 实例（+0x58/+0x5c = 可保存对象容器）
local A_VTABLE      = 0x100cde0   -- DeathMatch 主 vtable（自检用）
local A_GATE_FLAG2  = 0x1206fa9   -- DAT_01206fa9（两个写入包装共用的门 2）
local A_GATE_STATE  = 0x1205010   -- DAT_01205010（门 3：世界/会话对象须非空）
local F_WRITE_WORLDSTATE = 0x6ac270   -- 写 world_state.xml 的包装（自带前置检查，无参数）
local F_WRITE_PLAYER     = 0x6ac0d0   -- 写 player.xml 的包装（自带前置检查，参数 = 玩家对象）
-- ==========================================================================
-- ★ v4 专有：清掉引擎的"模组集合已改动 ⇒ 需要重启"闩锁（0x01154D0C）
--   v3 与 v4 的差别只有这一处。依据（探针 rw_modlist_probe v1.7 实测 + 反编译 FUN_00838640）：
--     · "新游戏"面板判定"模组改了没" = （模组名单不一致）或（字节 [0x01154D0C] ≠ 0）
--     · 该字节在引擎自己的写盘动作之后**下一帧**才被置 1，此后整局保持 1
--     · 我们的原地存档并没有改变模组集合 ⇒ 这个闩锁本就不该被置起
--   所以：写完盘先清一次，再"看护"一小段时间，看护期内一见非 0 就清（并只在真的清到时记日志）。
--   注意：这里只在**世界里**执行（存档动作 / 世界更新回调），绝不放在新进程进世界之前。
-- ==========================================================================
local A_MODS_CHANGED_LATCH = 0x01154D0C
local LATCH_WATCH_FRAMES = 300        -- 约 5 秒
local latch_watch_until = -1

local function clear_mods_changed_latch(where, quiet_if_zero)
	if not ffi then return end
	if not readable(A_MODS_CHANGED_LATCH, 1) then
		if not quiet_if_zero then
			LOG(string.format("闩锁 0x%08X（%s）：地址不可读，跳过（不影响存档本身）",
				A_MODS_CHANGED_LATCH, tostring(where)))
		end
		return
	end
	local before = rd8(A_MODS_CHANGED_LATCH)
	if before == 0 and quiet_if_zero then return end
	local okw, errw = pcall(function() ffi.cast("uint8_t*", A_MODS_CHANGED_LATCH)[0] = 0 end)
	local after = rd8(A_MODS_CHANGED_LATCH)
	LOG(string.format("闩锁 0x%08X（%s）：清前=%s 清后=%s%s",
		A_MODS_CHANGED_LATCH, tostring(where), tostring(before), tostring(after),
		okw and "" or ("  ★写失败：" .. tostring(errw))))
end
local F_LOAD_ACTION      = 0x6def70   -- mode 1 读档动作体（仅 Ctrl+Z 使用）
-- ★ 引擎的『保存并退出到主菜单』入口（暂停菜单里那一下）——唯一会把 world 区块写进盘的入口。
--   反编译（work/ghidra_extra21/func_9a3c90.c）：
--       *(会话单例 0x122374C + 0x68) = 2;   -- 动作号 2 = 保存并退出
--       (**(code **)(DAT_01221bc0 + 8))();  -- 派发（与 FUN_006def70 同形，只是动作号不同）
--   引擎随后在退出过程里做完整存档，并照例重启进程（新进程自动重载世界）。
--   ⚠ 不要直接调 FUN_00742cc0（那是"上次存档没做完"的修复路径）：从 Lua 里同步调它会重建 mod 的 Lua state。
local F_SAVE_AND_QUIT    = 0x9a3c90
-- ★ "保存并退出"里被拆出来的"保存"零件（反编译 work/ghidra_save2/func_742cc0.c 的调用序列）
-- ★★ 实测确认：这一步才是"把 world 区块刷到盘上"的关键（用户机器探针：world 文件数 15 → 52、351KB → 1MB）
local F_WORLD_META       = 0x7422c0
-- 注：原来还试过 FUN_0056ccc0（我猜是"区块提交"）——它把游戏调崩了（noita.exe+0x42DD4），而且根本不需要，已删除。
-- ⚠ 已删除"直接调引擎存档函数"的两条路（FUN_00742cc0 / 0x9A3C90）：
--   · FUN_00742cc0 是"上次存档没做完"的修复路径，从 Lua 里同步调它会重建 mod 的 Lua state ⇒ 白屏卡死；
--   · 0x9A3C90 让引擎"保存并退出到主菜单"，存档是成功的，但进程退出后没有回来（游戏直接关掉）。
--   现在只用引擎本来就有的两个写盘包装（F_WRITE_WORLDSTATE / F_WRITE_PLAYER）+ 等盘写完再镜像。

local function base_ok()
	local h = k32 and k32.GetModuleHandleA(nil)
	if not h then return false end
	return tonumber(ffi.cast("uintptr_t", h)) == BASE
end

local function current_slot()
	if type(REWIND_TEST_SLOT) == "number" then return REWIND_TEST_SLOT, "测试挂钩" end
	local cur = base_ok() and rd32(BASE + (A_CUR_SLOT - 0x400000)) or nil
	if cur == nil or cur == 4294967295 or cur > 6 then
		local obj = base_ok() and rd32(BASE + (A_ACTION_OBJ - 0x400000)) or nil
		if obj and obj ~= 0 and readable(obj, 0x70) then
			local v = rd32(obj + 0x60)
			if v and v >= 0 and v <= 6 then return v, "obj+0x60(回退)" end
		end
		return nil, "读不到当前槽号"
	end
	return cur, "DAT_01204bdc"
end

-- ==========================================================================
-- 局内文件：镜像 / 铺档（persistent / stats / 设置永不触碰）
-- ==========================================================================
local IN_RUN_ROOT_FILES = { "player.xml", "world_state.xml" }

-- 引擎的 .autosave* 标记（"存档进行中"）：不能镜像进快照，也不能留在被复位后的槽里
local function is_engine_tmp(rel)
	local base = tostring(rel):match("([^\\]+)$") or tostring(rel)
	return base:sub(1, 9) == ".autosave"
end

-- 让引擎执行『保存并退出到主菜单』（它做完整存档 + 重启进程 + 新进程自动重载世界）
local function trigger_save_and_restart(what)
	if not (k32 and ffi) then return false, "没有 ffi/k32" end
	if not base_ok() then return false, "基址不符（不是 noita.exe 本体，已中止）" end
	LOG(string.format("调用引擎『保存并退出』入口 0x%X（%s）… tick=%d PID=%d",
		F_SAVE_AND_QUIT, tostring(what), tickMs(), pid()))
	local ok, err = pcall(function()
		ffi.cast("void(__fastcall*)(void*)", BASE + (F_SAVE_AND_QUIT - 0x400000))(nil)
	end)
	LOG(string.format("  调用结果 = %s%s", tostring(ok), ok and "" or ("  错误: " .. tostring(err))))
	return ok, err
end

-- 槽里 world 目录的规模（日志用：证明"这一次真的写盘了"）
local function world_files_stat(slotPath)
	local n, bytes = 0, 0
	for _, f in ipairs(enumerate_tree(slotPath .. "\\world", "", 0, {})) do
		if not f.dir then n = n + 1; bytes = bytes + f.size end
	end
	return n, bytes
end


-- 安全调用一个"无参数"的引擎函数，并打印调用前后 world 目录的规模（用来看出哪一步在刷区块）
local function call_save_piece(addr, name, slotPath)
	if not (k32 and ffi) then return end
	if not base_ok() then LOG("   · 跳过 " .. name .. "（基址不符）"); return end
	local n0, b0 = world_files_stat(slotPath)
	local ok, err = pcall(function()
		ffi.cast("void(__cdecl*)(void)", BASE + (addr - 0x400000))()
	end)
	local n1, b1 = world_files_stat(slotPath)
	LOG(string.format("   · %s(0x%X) 调用=%s%s ⇒ world 文件数 %d → %d（%d → %d 字节）%s",
		name, addr, tostring(ok), ok and "" or ("  错误: " .. tostring(err)), n0, n1, b0, b1,
		(n1 > n0) and " ★ 这一步在写区块" or ""))
end

local function mirror_in_run(srcSlot, dstRoot)
	local copied, failed, bytes, skipped = 0, 0, 0, 0
	local rels = {}          -- 世界区块的相对路径（用于 run.txt 的同局比对）
	make_dir(dstRoot)
	for _, name in ipairs(IN_RUN_ROOT_FILES) do
		local s = srcSlot .. "\\" .. name
		local sig = file_sig(s)
		if sig then
			local ok = pcall(k32.CopyFileA, s, dstRoot .. "\\" .. name, 0)
			if ok then copied = copied + 1; bytes = bytes + sig.size else failed = failed + 1 end
		end
	end
	local list = enumerate_tree(srcSlot .. "\\world", "", 0, {})
	make_dir(dstRoot .. "\\world")
	for _, f in ipairs(list) do
		if f.dir then
			make_dir(dstRoot .. "\\world\\" .. f.rel)
		else
			if is_engine_tmp(f.rel) then
				skipped = skipped + 1          -- 引擎的"存档进行中"标记：不镜像
			else
				local ok = pcall(k32.CopyFileA, srcSlot .. "\\world\\" .. f.rel, dstRoot .. "\\world\\" .. f.rel, 0)
				if ok then
					copied = copied + 1
					bytes = bytes + f.size
					rels[#rels + 1] = "world\\" .. f.rel
				else
					failed = failed + 1
				end
			end
		end
	end
	-- 抽样（最多 40 个）交给 run.txt：顺序取即可，够用来判断"世界是否被重新生成"
	local sample = {}
	for i = 1, math.min(#rels, 40) do sample[i] = rels[i] end
	return copied, failed, bytes, sample
end

local function stage_into_slot(snapRoot, slotPath)
	if not slotPath then return 0, 0, 0, 0 end
	local copied, failed, deleted, bytes = 0, 0, 0, 0
	for _, name in ipairs(IN_RUN_ROOT_FILES) do
		local s = snapRoot .. "\\" .. name
		local sig = file_sig(s)
		if sig then
			local ok = pcall(k32.CopyFileA, s, slotPath .. "\\" .. name, 0)
			if ok then copied = copied + 1; bytes = bytes + sig.size else failed = failed + 1 end
		end
	end
	-- 先清掉槽里 world\ 现有文件（"快照没有的"多余区块自然被移除），再铺快照
	local existing = enumerate_tree(slotPath .. "\\world", "", 0, {})
	for _, f in ipairs(existing) do
		if not f.dir then
			remove_file(slotPath .. "\\world\\" .. f.rel)
			deleted = deleted + 1
		end
	end
	local snap = enumerate_tree(snapRoot .. "\\world", "", 0, {})
	make_dir(slotPath .. "\\world")
	for _, f in ipairs(snap) do
		if f.dir then
			make_dir(slotPath .. "\\world\\" .. f.rel)
		else
			local ok = pcall(k32.CopyFileA, snapRoot .. "\\world\\" .. f.rel, slotPath .. "\\world\\" .. f.rel, 0)
			if ok then copied = copied + 1; bytes = bytes + f.size else failed = failed + 1 end
		end
	end
	-- ★ 复位之后槽里绝不能留下引擎的"存档进行中"标记
	local leftovers = enumerate_tree(slotPath .. "\\world", "", 0, {})
	for _, f in ipairs(leftovers) do
		if (not f.dir) and is_engine_tmp(f.rel) then
			remove_file(slotPath .. "\\world\\" .. f.rel)
			deleted = deleted + 1
		end
	end
	return copied, failed, deleted, bytes
end

-- ==========================================================================
-- 跨进程标记
-- ==========================================================================
local function marker_path() return (DATA_DIR or MOD_DIR) and ((DATA_DIR or MOD_DIR) .. "\\pending.txt") end
local function write_marker(t)
	local p = marker_path()
	if not p then return false end
	return write_text(p, table.concat({
		"action=" .. tostring(t.action or ""),
		"slot=" .. tostring(t.slot or ""),
		"dir=" .. tostring(t.dir or ""),
		"tick=" .. tostring(tickMs()),
		"pid=" .. tostring(pid()),
		"",
	}, "\n"))
end
local function read_marker()
	local p = marker_path()
	if not p or not file_sig(p) then return nil end
	local s = read_text(p)
	if not s then return nil end
	local t = {}
	for k, v in s:gmatch("([%w_]+)=([^\r\n]*)") do t[k] = v end
	if not t.action or t.action == "" then return nil end
	return t
end

-- ==========================================================================
-- 自动重启：默认什么都不做（和 rewind_v3restored 一样），钩子只在"真要回溯"时才装
-- ==========================================================================
-- 实机对比（同一场游戏、同一天，PID 与日志逐条可查）：
--   ✓ rewind_v3restored（OnModPreInit 里只做 load_config → GuiCreate → handle_pending）
--     ⇒ 引擎自己立刻起的新进程：铺档成功 → OnWorldInitialized → 回到存档点
--   ✗ 本 mod 的 2026-10-07-1/2（OnModPreInit 里多装了钩子、多跑了自检）
--     ⇒ 引擎自己立刻起的新进程：铺档成功 → 5 秒后崩在 atioglxx.dll+0x00eae1ee
--   两者的新进程命令行**完全相同**（`-gamemode 0 … -save_slot 0`），Steam 覆盖层的日志也显示
--   旧进程的覆盖层已先卸载、新进程才开始初始化 GL ⇒ 时间差/重叠都不是原因。
--   唯一剩下的差别就是"新进程进世界之前，mod 自己多做了什么"。
--   ⇒ 所以：OnModPreInit 里**只保留与可用版一模一样的动作**，
--      自检挪到进世界之后，钩子挪到"按下回溯、引擎即将起进程"的那一刻，且默认关闭。
--
-- 钩子（SPAWN_HOOK=on 时才启用，默认 off）做的是：在引擎真正起进程前把命令行里
--   `-gamemode 4294967295`（未初始化的值，实测这种命令行新进程必崩）改成 `0`，
--   并保证有合法的 `-save_slot`（引擎解析器只在 -gamemode 分支里读它）。
--   任何一步失败 ⇒ 原样转发给真正的 CreateProcessW，绝不吞掉启动。
-- ==========================================================================
local A_IAT_CREATEPROCESSW = 0x00f07050   -- noita.exe：call dword ptr [0x00f07050] @ 0x84dff0

local spawn_hook = {
	state = "未安装",
	slot  = nil,
	real  = nil,
	cb    = nil,
	blocked = 0,
	forwarded = 0,
	last_cmdline = "",
}

local function wide_to_ascii(p, maxchars)
	if p == nil or not ffi then return nil end
	local addr = tonumber(ffi.cast("uintptr_t", p))
	if addr == 0 or not readable(addr, 2) then return nil end
	local out = {}
	for i = 0, (maxchars or 2048) - 1 do
		if not readable(addr + i * 2, 2) then break end
		local c = tonumber(ffi.cast("uint16_t*", addr + i * 2)[0])
		if c == nil or c == 0 then break end
		out[#out + 1] = (c >= 32 and c < 127) and string.char(c) or "?"
	end
	return table.concat(out)
end

-- 往 IAT 槽里写 4 字节（v = 函数地址）。用来装钩子，也用来还原。
local function spawn_hook_write_ptr(v, why)
	if not (k32 and ffi) then return false, "没有 k32/ffi" end
	local old = ffi.new("uint32_t[1]")
	local okp = pcall(function()
		return tonumber(k32.VirtualProtect(ffi.cast("void*", A_IAT_CREATEPROCESSW), 4, 0x04, old))  -- 0x04 = PAGE_READWRITE
	end)
	if not okp or okp == 0 then return false, "VirtualProtect 失败" end
	ffi.cast("uint32_t*", A_IAT_CREATEPROCESSW)[0] = v
	pcall(k32.VirtualProtect, ffi.cast("void*", A_IAT_CREATEPROCESSW), 4, tonumber(old[0]), old)
	local now = rd32(A_IAT_CREATEPROCESSW)
	if now ~= v then return false, string.format("回读不符（写 %s，读 %s）", tostring(v), tostring(now)) end
	return true, tostring(why or "")
end

-- 真正的 CreateProcessW 地址：用 GetProcAddress 取，不靠猜（也不是 k32 那个符号对象）
local function real_createprocessw_addr()
	if not (k32 and ffi) then return nil end
	local ok, a = pcall(function()
		local h = k32.GetModuleHandleA("kernel32.dll")
		local p = k32.GetProcAddress(h, "CreateProcessW")
		return tonumber(ffi.cast("uintptr_t", p))
	end)
	if ok and a and a ~= 0 then return a end
	return nil
end

local function spawn_hook_unpatch(why)
	if not spawn_hook.realaddr then return end
	local ok, err = spawn_hook_write_ptr(spawn_hook.realaddr, why)
	spawn_hook.patched = false
	LOG(string.format("钩子已还原成真正的 CreateProcessW：%s %s", tostring(ok), tostring(err)))
end

local function ascii_to_wide(s)
	local buf = ffi.new("uint16_t[?]", #s + 1)
	for i = 1, #s do buf[i - 1] = s:byte(i) end
	buf[#s] = 0
	return buf
end

-- 只改正引擎重启命令里的两个参数，其余**原样照用**：
--   -gamemode <n>   n 不是 0..99（实测见过 4294967295 = 未初始化）⇒ 改成 0；整个参数缺失 ⇒ 补 0
--                   （引擎的解析器只在 -gamemode 分支里读 -save_slot，缺了就不会自动读档）
--   -save_slot <n>  缺失/非法 ⇒ 补成当前槽号
local function normalize_relaunch_cmdline(text, slot)
	local fixed, notes = text, {}
	local has_g = fixed:find("-gamemode", 1, true) ~= nil          -- 注意：plain 查找不要写 %-
	local gnum = fixed:match("%-gamemode%s+(%d+)")
	if not has_g then
		fixed = fixed .. " -gamemode 0"
		notes[#notes + 1] = "补上 -gamemode 0（原来没有 ⇒ 引擎不会自动读档）"
	elseif gnum and (tonumber(gnum) or 0) > 99 then
		fixed = fixed:gsub("%-gamemode%s+%d+", "-gamemode 0", 1)
		notes[#notes + 1] = "-gamemode " .. gnum .. " → 0（未初始化的值；实测这种命令行新进程必崩）"
	end
	local snum = fixed:match("%-save_slot%s+(%d+)")
	if not fixed:find("-save_slot", 1, true) then
		fixed = fixed .. " -save_slot " .. tostring(slot or 0)
		notes[#notes + 1] = "补上 -save_slot " .. tostring(slot or 0)
	elseif (not snum) or (tonumber(snum) or 99) > 6 then
		fixed = fixed:gsub("%-save_slot%s+%S+", "-save_slot " .. tostring(slot or 0), 1)
		notes[#notes + 1] = "-save_slot " .. tostring(snum or "?") .. " → " .. tostring(slot or 0)
	end
	return fixed, notes
end

-- 按引擎原本的时机立刻起进程（只改正命令行里的参数，见小节开头说明）
local function spawn_hook_forward(app, cmdline, pa, ta, inherit, flags, env, cwd, si, pi, why)
	if not spawn_hook.real then
		LOG("   ★ 无法原样转发（没有真正的 CreateProcessW：" .. tostring(why) .. "）⇒ 返回失败")
		return 0
	end
	-- 转发也要留痕：排查"新进程启动过程中被我们插了一手"时全靠这行
	spawn_hook.forwarded = spawn_hook.forwarded + 1
	LOG(string.format("   · 原样转发一次 CreateProcessW（%s）：%s", tostring(why),
		tostring(wide_to_ascii(cmdline, 1024) or wide_to_ascii(app, 512) or "?")))
	return tonumber(spawn_hook.real(app, cmdline, pa, ta, inherit, flags, env, cwd, si, pi)) or 0
end

local function spawn_hook_body(app, cmdline, pa, ta, inherit, flags, env, cwd, si, pi)
	local text = wide_to_ascii(cmdline, 4096) or ""
	local appname = wide_to_ascii(app, 512)
	local lower = ((appname or "") .. " " .. text):lower()
	if not lower:find("noita", 1, true) then
		return spawn_hook_forward(app, cmdline, pa, ta, inherit, flags, env, cwd, si, pi, "非 noita 进程")
	end
	local slot = current_slot() or 0
	local fixed, notes = normalize_relaunch_cmdline(text, slot)
	spawn_hook.last_cmdline = fixed
	LOG("")
	LOG("★★ 拦到引擎重启（按引擎原样立刻起进程，只改正参数）")
	LOG("   程序名 = " .. tostring(appname))
	LOG("   引擎原命令行 = " .. text)
	if #notes > 0 then
		for _, n in ipairs(notes) do LOG("   已改正：" .. n) end
		LOG("   实际使用命令行 = " .. fixed)
	else
		LOG("   命令行无需改正（原样使用）")
	end
	local wbuf = ascii_to_wide(fixed)
	local ok, r = pcall(function()
		return tonumber(spawn_hook.real(app, wbuf, pa, ta, inherit, flags, env, cwd, si, pi)) or 0
	end)
	if not ok or not r or r == 0 then
		LOG("   ★ 修正后的 CreateProcessW 调用失败（" .. tostring(r) .. "）⇒ 用引擎原命令行再试一次")
		return spawn_hook_forward(app, cmdline, pa, ta, inherit, flags, env, cwd, si, pi, "修正后调用失败")
	end
	spawn_hook.blocked = spawn_hook.blocked + 1
	LOG("   ✓ 新进程已由引擎原来的方式立刻拉起（CreateProcessW 返回 " .. tostring(r) .. "）")
	spawn_hook_unpatch("用掉后立刻还原，避免 Lua state 重建后跳进无效地址")
	return r
end

local function spawn_hook_callback(app, cmdline, pa, ta, inherit, flags, env, cwd, si, pi)
	local ok, ret = pcall(spawn_hook_body, app, cmdline, pa, ta, inherit, flags, env, cwd, si, pi)
	if not ok then
		LOG("★ 重启钩子回调出错（改为原样转发）：" .. tostring(ret))
		local ok2, r2 = pcall(spawn_hook_forward, app, cmdline, pa, ta, inherit, flags, env, cwd, si, pi, tostring(ret))
		if ok2 then return r2 end
		return 0
	end
	return ret
end

-- 干跑专用：把字符串当命令行，走一遍真正的拦截回调（REWIND_TEST_SPAWN 只在测试脚本里设置）
local function spawn_hook_selftest(cmdline_text)
	local function widen(s)
		local buf = ffi.new("uint16_t[?]", #s + 1)
		for i = 1, #s do buf[i - 1] = s:byte(i) end
		buf[#s] = 0
		return buf
	end
	local ok1, r1 = pcall(spawn_hook_callback, widen("noita.exe"), widen(cmdline_text), nil, nil, 0, 0, nil, nil, nil, nil)
	LOG(string.format("干跑 1/2：模拟『引擎请求重启』⇒ 回调返回 %s（干跑不许真起进程，所以应为 0=转发失败）", tostring(r1)))
	local fixed, notes = normalize_relaunch_cmdline(cmdline_text, 0)
	LOG("干跑 2/2：改参数结果 = " .. fixed .. "（改动 " .. tostring(#notes) .. " 处：" .. table.concat(notes, "；") .. "）")
	return ok1, r1, fixed, notes
end

-- 安装：把 IAT 槽里的 4 字节换成我们的回调（返回 true/false，失败原因写进 spawn_hook.state）
--   注意：游戏重载世界时会重建 mod 的 Lua state，上一代回调的内存会被回收；
--   若槽里还留着旧回调，引擎下一次调用就会跳进无效地址（实测崩在未知模块 0x2CC40000）。
--   所以：装之前先把槽还原成真正的 CreateProcessW，用完立刻再还原一次。
local function install_spawn_hook()
	if CFG.SPAWN_HOOK ~= "on" then spawn_hook.state = "配置 SPAWN_HOOK=off ⇒ 不装"; return false end
	if not (k32 and ffi) then spawn_hook.state = "没有 ffi/k32 ⇒ 不装"; return false end
	if REWIND_TEST_NO_SPAWN == true then spawn_hook.state = "干跑模式 ⇒ 不装"; return false end
	if not readable(A_IAT_CREATEPROCESSW, 4) then
		spawn_hook.state = string.format("IAT 槽 0x%08X 不可读 ⇒ 不装", A_IAT_CREATEPROCESSW)
		return false
	end
	local realaddr = real_createprocessw_addr()
	if not realaddr then spawn_hook.state = "取不到真正的 CreateProcessW 地址 ⇒ 不装"; return false end
	spawn_hook.realaddr = realaddr
	local cur = rd32(A_IAT_CREATEPROCESSW)
	if not cur or cur == 0 then spawn_hook.state = "IAT 槽为空 ⇒ 不装"; return false end
	if cur ~= realaddr then
		local okr, errr = spawn_hook_write_ptr(realaddr, "还原")
		LOG(string.format("★ IAT 槽里不是真正的 CreateProcessW（%s ≠ %s）⇒ 先还原：%s %s",
			tostring(cur), tostring(realaddr), tostring(okr), tostring(errr)))
		if not okr then spawn_hook.state = "槽里是别的指针且还原失败 ⇒ 不装"; return false end
		cur = rd32(A_IAT_CREATEPROCESSW)
		if cur ~= realaddr then spawn_hook.state = "还原后回读仍不对 ⇒ 不装"; return false end
	end
	spawn_hook.real = k32.CreateProcessW
	if not spawn_hook.real then spawn_hook.state = "取不到真正的 CreateProcessW ⇒ 不装"; return false end
	local ok, cb = pcall(function()
		return ffi.cast("int (__stdcall*)(const void*, void*, void*, void*, int, uint32_t, void*, const void*, void*, void*)",
			spawn_hook_callback)
	end)
	if not ok or cb == nil then spawn_hook.state = "建回调失败：" .. tostring(cb); return false end
	local cbaddr = tonumber(ffi.cast("uintptr_t", cb))
	local okw, errw = spawn_hook_write_ptr(cbaddr, "装钩子")
	if not okw then spawn_hook.state = "写 IAT 失败：" .. tostring(errw); return false end
	spawn_hook.slot = A_IAT_CREATEPROCESSW
	spawn_hook.cb = cb
	spawn_hook.patched = true
	spawn_hook.state = string.format("已安装（槽 0x%08X：%s → %s）", A_IAT_CREATEPROCESSW, tostring(realaddr), tostring(cbaddr))
	return true
end

local function spawn_hook_report(tag)
	LOG(string.format("%s：%s；已拦截改正 %d 次、原样转发 %d 次", tag, spawn_hook.state, spawn_hook.blocked, spawn_hook.forwarded))
end

local function has_hook_slot() return spawn_hook.patched == true end

-- ==========================================================================
-- 两个动作
-- ==========================================================================
-- ==========================================================================
-- 游戏内 Mod 设置（值来自同目录的 settings.lua + 引擎的 ModSettingGet）
--   设置界面本身由 settings.lua 定义、引擎在【选项 → 模组设置】里绘制。
--   这里只负责"读值"：优先 ModSettingGet，取不到才回落到 rewind_config.txt 的后备值。
--   mod id 由同目录 mod_id.txt 决定（= rewind_v5），设置 id 形如 rewind_v5.key_save。
-- ==========================================================================
local MOD_ID = "rewind_v5"
local SETTINGS_TTL_MS = 1000     -- 设置值缓存 1 秒：即使两个文件不在同一个 Lua state，改完最迟 1 秒生效
local settings_cache = { t = -100000, vals = {} }

local function settings_refresh()
	local now = tickMs()
	if (now - settings_cache.t) < SETTINGS_TTL_MS then return end
	settings_cache.t = now
	settings_cache.vals = {}
	if type(ModSettingGet) ~= "function" then return end
	for _, id in ipairs({ "enable", "key_save", "key_rewind", "key_mod", "same_run_only", "banner" }) do
		local ok, v = pcall(ModSettingGet, MOD_ID .. "." .. id)
		if ok then settings_cache.vals[id] = v end
	end
end

local function setting_raw(id)
	settings_refresh()
	return settings_cache.vals[id]
end

local function setting_str(id, fallback)
	local v = setting_raw(id)
	if type(v) == "string" and v ~= "" then return v end
	return fallback
end

local function setting_bool(id, fallback)
	local v = setting_raw(id)
	if type(v) == "boolean" then return v end
	return fallback
end

-- 总开关：游戏内 Mod 设置优先，其次 rewind_config.txt 的 ENABLE
local function mod_enabled()
	return setting_bool("enable", CFG.ENABLE == "on")
end

-- ==========================================================================
-- "这个存档点属于哪一局" —— 防止把上一局的存档点用在死亡界面
--   ★ 主判据（可靠）：引擎的"本局标记"（GameAddFlagRun / GameHasFlagRun）
--     它存在 world_state.xml 的 <flags> 里、跟着本局存档走：
--       · 记录存档点时打上标记 ⇒ 本局之内（含死亡界面）恒为真 ✓
--       · 回滚到该存档点（快照里带着标记）⇒ 载入后仍为真 ✓
--       · 开新局 ⇒ 新局没有这个标记 ⇒ 为假 ⇒ 判定为"上一局的存档点" ✓
--     （之前用世界种子 + 区块文件名判定都不可靠：本机 MagicNumbersGetValue("WORLD_SEED") 恒为 0，
--       区块文件名是按坐标生成的、新局会重名，而且回溯本身会把快照铺回槽里，自我满足。）
--   备用判据（只在标记 API 不可用时）：槽号 + 区块清单。
-- ==========================================================================
local RUN_FLAG = "rewind_v5_checkpoint"

local function flag_run_add()
	if type(GameAddFlagRun) ~= "function" then return false end
	local ok = pcall(GameAddFlagRun, RUN_FLAG)
	LOG("已给本局打上存档点标记 GameAddFlagRun(\"" .. RUN_FLAG .. "\") = " .. tostring(ok))
	return ok
end

-- 返回 true / false / nil（nil = API 不可用，需要走备用判据）
local function flag_run_has()
	if type(GameHasFlagRun) ~= "function" then return nil end
	local ok, v = pcall(GameHasFlagRun, RUN_FLAG)
	if ok and type(v) == "boolean" then return v end
	return nil
end

local function world_seed_str()
	if type(MagicNumbersGetValue) ~= "function" then return nil end
	local ok, v = pcall(MagicNumbersGetValue, "WORLD_SEED")
	if ok and v ~= nil then
		local s = tostring(v)
		if s ~= "" and s ~= "nil" then return s end
	end
	return nil
end

local function write_run_info(snapRoot, slot, chunkList)
	if not snapRoot then return end
	local seed = world_seed_str()
	local lines = {
		"seed=" .. tostring(seed or "-"),
		"slot=" .. tostring(slot or -1),
		"tick=" .. tostring(tickMs()),
		"chunks=" .. tostring(#(chunkList or {})),
	}
	for _, rel in ipairs(chunkList or {}) do
		lines[#lines + 1] = "chunk=" .. rel
	end
	write_text(snapRoot .. "\\run.txt", table.concat(lines, "\n") .. "\n")
	LOG(string.format("已写入本局标识 run.txt：seed=%s slot=%s 抽样区块 %d 个",
		tostring(seed or "-"), tostring(slot), #(chunkList or {})))
end

local function read_run_info(dir)
	local s = read_text(dir .. "\\run.txt")
	if not s then return nil end
	local info = { chunks = {} }
	for line in s:gmatch("[^\r\n]+") do
		local k, v = line:match("^(%w+)=(.*)$")
		if k == "seed" then info.seed = v
		elseif k == "slot" then info.slot = tonumber(v)
		elseif k == "tick" then info.tick = tonumber(v)
		elseif k == "chunk" then info.chunks[#info.chunks + 1] = v end
	end
	return info
end

-- 种子是否"可信"：实测本机 MagicNumbersGetValue("WORLD_SEED") 恒返回 0 ⇒ 0/空/nil 都不能当依据
local function seed_usable(s)
	if type(s) ~= "string" then return false end
	local t = s:gsub("%s", "")
	if t == "" or t == "-" or t == "nil" then return false end
	if tonumber(t) == 0 then return false end
	return true
end

-- 返回 (是否属于本局, 原因说明)
-- 判定顺序：① 本局标记（最可靠）→ ② 槽号一致 → ③ 可信世界种子（两边都是非零）→ ④ 抽样区块清单
local function snapshot_run_ok(dir)
	if CFG.REQUIRE_SAME_RUN ~= "on" then return true, "REQUIRE_SAME_RUN=off（不做同局检查）" end
	local info = read_run_info(dir)
	if not info then
		-- 没有 run.txt：仍然允许用"本局标记"判断（标记为真说明本局确实记过存档点）
		local flagged = flag_run_has()
		if flagged == true then return true, "run.txt 缺失，但本局标记为真 ⇒ 判为同一局" end
		return false, "快照里没有 run.txt、本局标记也不为真 ⇒ 无法确认属于哪一局（按不安全处理）"
	end

	-- ① 本局标记（存在 world_state.xml 的 <flags> 里，跟本局存档走）
	local flagged = flag_run_has()
	if flagged == false then
		return false, string.format("本局没有存档点标记（GameHasFlagRun(\"%s\")=false）⇒ 存档点属于上一局", RUN_FLAG)
	end
	if flagged == true then
		return true, string.format("本局标记存在（GameHasFlagRun(\"%s\")=true）⇒ 判为同一局", RUN_FLAG)
	end

	-- ② 槽号
	local slotNow = current_slot()
	if slotNow and info.slot and info.slot >= 0 and info.slot ~= slotNow then
		return false, string.format("存档点记的是槽 %d、现在是槽 %d ⇒ 属于别的存档位", info.slot, slotNow)
	end

	-- ② 世界种子（只有两边都是像样的非零种子才采信；本机 WORLD_SEED 恒为 0，所以实际靠第 ③ 步）
	local seed_now = world_seed_str()
	if seed_usable(info.seed) and seed_usable(seed_now) then
		if info.seed == seed_now then
			return true, string.format("世界种子一致（%s）", seed_now)
		end
		return false, string.format("世界种子不同（存档点 %s、本局 %s）⇒ 存档点属于上一局", info.seed, seed_now)
	end

	-- ③ 抽样区块：同局继续玩时这些文件都还在；新局会重新生成世界 ⇒ 文件消失
	local slot = info.slot
	if slot == nil or slot < 0 then return false, "run.txt 里没有槽号" end
	local sd = slot_dir(slot)
	if not sd then return false, "拿不到槽目录" end
	local total, hit = 0, 0
	for _, rel in ipairs(info.chunks) do
		total = total + 1
		if total > 40 then break end
		if file_sig(sd .. "\\" .. rel) then hit = hit + 1 end
	end
	if total == 0 then return false, "run.txt 里没有抽样区块，无法比对" end
	local ratio = hit / total
	if ratio >= 0.8 then
		return true, string.format("抽样区块仍在当前槽（%d/%d = %.0f%%）⇒ 判为同一局", hit, total, ratio * 100)
	end
	return false, string.format("抽样区块只剩 %d/%d = %.0f%%（新局会重新生成世界）⇒ 判为上一局", hit, total, ratio * 100)
end

local run_check_cache = nil
local function invalidate_run_check() run_check_cache = nil end
local function current_run_check()
	if CFG.REQUIRE_SAME_RUN ~= "on" then return true, "REQUIRE_SAME_RUN=off" end
	if run_check_cache then return run_check_cache.ok, run_check_cache.why end
	-- 这里不用 dir_of（它定义在本段之后），直接拼目录
	local sub = (CFG.RESTORE_FROM == "snap_auto") and CFG.AUTO_DIR or CFG.SNAP_DIR
	local dir = MOD_DIR and (MOD_DIR .. "\\" .. tostring(sub)) or nil
	local ok, why = snapshot_run_ok(dir)
	run_check_cache = { ok = ok, why = why, dir = dir }
	LOG(string.format("存档点同局检查：%s ⇒ %s（%s）", tostring(dir), ok and "有效 ✓" or "无效 ✗", tostring(why)))
	return ok, why
end

local busy = false
local heartbeat_until, heartbeat_next = -1, 0

local function guards()
	if not mod_enabled() then
		LOG("未启用（游戏内 Mod 设置的『启用』关掉了，或 ENABLE ~= on）⇒ 什么都不做")
		NOTICE("mod 未启用（游戏内 Mod 设置 / rewind_config.txt）")
		return nil
	end
	if not (ffi and k32) then LOG("中止：FFI/kernel32 不可用"); return nil end
	if not base_ok() then LOG("中止：模块基址不是 0x400000"); NOTICE("基址不符，已中止"); return nil end
	local obj = rd32(BASE + (A_ACTION_OBJ - 0x400000))
	local dm  = rd32(BASE + (A_DEATHMATCH - 0x400000))
	if not obj or obj == 0 or not readable(obj, 0x70) then LOG("中止：obj 不可用"); return nil end
	if not dm or dm == 0 or not readable(dm, 0x8) then LOG("中止：DeathMatch 实例不可用"); return nil end
	local vtp = rd32(dm)
	if vtp ~= A_VTABLE then
		LOG(string.format("中止：DeathMatch vtable = 0x%s（期望 0x%x），版本不符以免误调",
			vtp and string.format("%x", vtp) or "nil", A_VTABLE))
		return nil
	end
	local slot, how = current_slot()
	if not slot then LOG("中止：" .. tostring(how)); return nil end
	return slot, how
end

-- 两个写入包装共用的前置门（不满足时它们会空转，所以我们要自己先判断）
local function save_gates_ok()
	local obj, g2, g3 = nil, nil, nil
	if not mod_enabled() or not (ffi and k32) or not base_ok() then return false, nil, nil, nil end
	obj = rd32(BASE + (A_ACTION_OBJ - 0x400000))
	g2 = rd8(BASE + (A_GATE_FLAG2 - 0x400000))
	g3 = rd32(BASE + (A_GATE_STATE - 0x400000))
	local g1 = (obj and obj ~= 0) and rd8(obj + 0x94) or nil
	local ok = (g1 == 0) and (g2 == 0) and (g3 ~= nil) and (g3 ~= 0)
	return ok, g1, g2, g3
end

-- 玩家实体 id 的来源，按可靠性排序：
--   1) OnPlayerSpawned( entity ) 回调给的值（实测日志：player_entity=161 ✓）
--   2) GameGetPlayerStatsEntity()
--   3) EntityGetWithTag("player_unit") / ("player")（你机器上实测拿不到，保留当兜底）
local player_entity_cached = nil

local function player_id_candidates()
	local list = {}
	if player_entity_cached then
		list[#list + 1] = { "OnPlayerSpawned 缓存", player_entity_cached }
	end
	if type(GameGetPlayerStatsEntity) == "function" then
		local okg, e = pcall(GameGetPlayerStatsEntity)
		if okg and tonumber(e) then list[#list + 1] = { "GameGetPlayerStatsEntity()", tonumber(e) } end
	end
	if type(EntityGetWithTag) == "function" then
		for _, tag in ipairs({ "player_unit", "player" }) do
			local okt, ids = pcall(EntityGetWithTag, tag)
			if okt and type(ids) == "table" then
				local cnt = 0
				for _, v in pairs(ids) do
					if tonumber(v) then
						cnt = cnt + 1
						if cnt <= 3 then list[#list + 1] = { string.format('EntityGetWithTag("%s")', tag), tonumber(v) } end
					end
				end
			elseif not okt then
				LOG(string.format('  EntityGetWithTag("%s") 调用失败：%s', tag, tostring(ids)))
			end
		end
	else
		LOG("  EntityGetWithTag 类型 = " .. type(EntityGetWithTag) .. "（不是函数）")
	end
	return list
end

-- 从 [DeathMatch+0x58 .. +0x5c) 容器里认出玩家对象：
--   判据：对象首字段（+0x0）== 玩家实体 id（阶段一实测）
local function identify_player_object()
	local dm = base_ok() and rd32(BASE + (A_DEATHMATCH - 0x400000)) or nil
	if not dm or dm == 0 or not readable(dm + 0x58, 8) then return nil, "DeathMatch 不可读" end
	local b, e = rd32(dm + 0x58), rd32(dm + 0x5c)
	if not b or not e or e <= b or (e - b) > 4 * 256 then return nil, "容器范围不合理" end
	local cands = player_id_candidates()
	if #cands == 0 then return nil, "拿不到玩家实体 id（所有来源都失败，见上面诊断行）" end
	local n = math.min(math.floor((e - b) / 4), 32)
	local heads = {}
	for i = 0, n - 1 do
		local p = rd32(b + i * 4)
		if p and p ~= 0 and readable(p, 8) then heads[i] = { p = p, head = rd32(p) } end
	end
	for _, c in ipairs(cands) do
		for i = 0, n - 1 do
			local h = heads[i]
			if h and h.head == c[2] then
				return h.p, string.format("容器[%d] 首字段=%d == %s（偏移 +0x0）", i, c[2], c[1])
			end
		end
		LOG(string.format("  候选 id %d（%s）在容器里找不到首字段相等的对象", c[2], c[1]))
	end
	local parts = {}
	for i = 0, math.min(n, 8) - 1 do
		local h = heads[i]
		parts[#parts + 1] = string.format("[%d]=%s", i, h and tostring(h.head) or "-")
	end
	LOG("  容器前 8 个对象首字段：" .. table.concat(parts, " "))
	return nil, "容器里没有首字段匹配任何候选 id 的对象"
end

-- 触发一次引擎读档转场（仅 Ctrl+Z 使用）
local function trigger_load_transition(what)
	LOG(string.format("调用引擎读档动作体 FUN_006def70（%s）… tick=%d PID=%d", what, tickMs(), pid()))
	local ok, err = pcall(function()
		ffi.cast("void(*)(void)", BASE + (F_LOAD_ACTION - 0x400000))()
	end)
	LOG(string.format("  调用结果 = %s%s（tick=%d PID=%d）", tostring(ok), ok and "" or (" 错误: " .. tostring(err)), tickMs(), pid()))
	return ok
end

local function dir_of(name)
	local root = DATA_DIR or MOD_DIR
	if not root then return nil end
	local n = (name == nil or name == "") and "snap" or tostring(name)
	return root .. "\\" .. n
end

local function fmt_sig(s)
	if not s then return "不存在" end
	return string.format("%dB/t=%s", s.size, tostring(s.time))
end

local function diff_sig(before, after)
	if before == nil and after ~= nil then return "true（之前不存在）" end
	if before ~= nil and after == nil then return "★false（反而没了）" end
	if before and after then return tostring(before.size ~= after.size or before.time ~= after.time) end
	return "n/a"
end

-- 存档点最后一步：把槽里（已经真正落盘的）局内文件镜像到快照目录
local function finish_checkpoint_mirror(slot, slotPath, t0, marker_still_there)
	if marker_still_there then
		LOG("   ★ 等标记超时（.autosave 5 秒内没消失）⇒ 仍按现状镜像（这次快照可能不完整）")
	end
	LOG("步骤2：把局内文件（含刚写出的 XML 与 world 区块）镜像到存档点目录")
	local c, f, b, chunkSample = mirror_in_run(slotPath, dir_of(CFG.SNAP_DIR))
	LOG(string.format("  镜像完成：%d 文件/%d 字节，失败 %d，总耗时 %d ms（PID=%d）",
		c, b, f, tickMs() - t0, pid()))
	write_run_info(dir_of(CFG.SNAP_DIR), slot, chunkSample)   -- 记下"这一局"的标识
	invalidate_run_check()
	LOG("存档点已更新 ✓（未重启、未转场、未动局外文件）")
	NOTICE("已存档")
end

-- ★ v7.1 区块探针：在可疑调用点上挂 14 字节跳板，只计数不改行为；Ctrl+S 时转储。
--   跳板：pushfd; inc [ctr]; popfd; call 原函数; ret   （寄存器/标志位透明）
--   目的：用户"走近未加载区块"时，看到底是哪条路径把区块装回来的。
PROBE_SITES = {
	{ 0x73DC7F, 0x73C220, "CreateNewChunk(0x73C220) ← 0x73DC7F" },
	{ 0x73E292, 0x73DAB0, "load-area 0x73DAB0 ← 0x73E292" },
	{ 0x73DE65, 0x73DAB0, "load-area 0x73DAB0 ← 0x73DE65" },
}
PROBE_VT = { 0xFFE584, 0x9A4F50, "vtable 槽 0xFFE584 → 0x9A4F50（每区块更新）" }

probe_bytes_call = function(siteVA, origVA, stubVA, ctrVA)
	local b = {}
	local function push(v) b[#b + 1] = v end
	local function push32(v) push(v % 256); push(math.floor(v / 256) % 256); push(math.floor(v / 65536) % 256); push(math.floor(v / 16777216) % 256) end
	push(0x9C); push(0xFF); push(0x05); push32(ctrVA); push(0x9D)
	push(0xE8); push32((origVA - (stubVA + 13)) % 4294967296)
	push(0xC3)
	return b
end

probe_bytes_jmp = function(slotVA, origVA, stubVA, ctrVA)
	local b = {}
	local function push(v) b[#b + 1] = v end
	local function push32(v) push(v % 256); push(math.floor(v / 256) % 256); push(math.floor(v / 65536) % 256); push(math.floor(v / 16777216) % 256) end
	push(0x9C); push(0xFF); push(0x05); push32(ctrVA); push(0x9D)
	push(0xE9); push32((origVA - (stubVA + 13)) % 4294967296)
	return b
end

probe_setup = function()
	if CFG._probe_page then return true end
	if not k32 then LOG("   · 探针：没有 kernel32 绑定"); return false end
	local okA, page = pcall(function() return k32.VirtualAlloc(nil, 0x1000, 0x3000, 0x40) end)
	if not okA or page == nil then LOG("   · 探针：VirtualAlloc 调用失败：" .. tostring(page)); return false end
	if tonumber(ffi.cast("uintptr_t", page)) == 0 then LOG("   · 探针：VirtualAlloc 返回 0"); return false end
	local pv = tonumber(ffi.cast("uintptr_t", page))
	-- ★ v7.2 自检一：VirtualQuery 确认页可执行（纯读取，零风险）
	do
		local mbi = ffi.new("RW_MBI")
		if tonumber(k32.VirtualQuery(ffi.cast("const void*", page), mbi, ffi.sizeof("RW_MBI"))) ~= 0 then
			local pr = tonumber(mbi.Protect)
			LOG(string.format("   · 探针自检：页 0x%X 权限=0x%X（0x10/0x20/0x40/0x80 为可执行）", pv, pr))
			if not (pr == 0x10 or pr == 0x20 or pr == 0x40 or pr == 0x80) then
				LOG("   · 探针自检未通过：页不可执行 ⇒ 不挂钩")
				return false
			end
		end
	end
	-- ★ v7.2 自检二：写 mov eax,0x1234; ret 并执行一次，确认能写能跑（返回值必须是 4660）
	do
		local b = ffi.cast("uint8_t*", pv + 0xF00)
		b[0] = 0xB8; b[1] = 0x34; b[2] = 0x12; b[3] = 0x00; b[4] = 0x00; b[5] = 0xC3
		local okS, r = pcall(function() return tonumber(ffi.cast("int(__cdecl*)(void)", pv + 0xF00)()) end)
		LOG(string.format("   · 探针自检：执行自写机器码 ⇒ ok=%s 返回=%s（期望 4660）", tostring(okS), tostring(r)))
		if not okS or tonumber(r) ~= 4660 then
			LOG("   · 探针自检未通过 ⇒ 不挂钩（避免再次崩溃）")
			return false
		end
	end
	CFG._probe_page = pv
	CFG._probe_ctr = pv + 0x800          -- 计数器区（20 个 dword）
	CFG._probe_stub = pv + 0x100         -- 跳板区
	CFG._probe_old = tonumber(CFG._probe_old or 0)
	local old = ffi.new("uint32_t[1]")
	local nstub, nctr = 0, 0
	local function install(siteVA, origVA, name)
		local stubVA = CFG._probe_stub + nstub * 64
		local ctrVA = CFG._probe_ctr + nctr * 4
		local bytes = probe_bytes_call(siteVA, origVA, stubVA, ctrVA)
		local dst = ffi.cast("uint8_t*", stubVA)
		for i = 1, #bytes do dst[i - 1] = bytes[i] end
		if tonumber(k32.VirtualProtect(ffi.cast("void*", siteVA), 8, 0x40, old)) == 0 then return false end
		local site = ffi.cast("uint8_t*", siteVA)
		site[0] = 0xE8
		local rel = (stubVA - (siteVA + 5)) % 4294967296
		site[1] = rel % 256; site[2] = math.floor(rel / 256) % 256
		site[3] = math.floor(rel / 65536) % 256; site[4] = math.floor(rel / 16777216) % 256
		k32.VirtualProtect(ffi.cast("void*", siteVA), 8, tonumber(old[0]), old)
		-- ★ v7.2 回读校验：跳板 14 字节 + 调用点 5 字节都必须和写入的一致，否则判定失败、不上钩
		local okStub = true
		for i = 1, #bytes do
			if ffi.cast("uint8_t*", stubVA)[i - 1] ~= bytes[i] then okStub = false end
		end
		local okSite = (site[0] == 0xE8 and site[1] == rel % 256)
		if not (okStub and okSite) then
			LOG(string.format("   · 探针：%s 回读校验失败（跳板=%s 调用点=%s）⇒ 放弃这个点", name, tostring(okStub), tostring(okSite)))
			return false
		end
		nstub = nstub + 1; nctr = nctr + 1
		LOG(string.format("   · 探针挂钩：%s（调用点 0x%X ← 跳板 0x%X）回读校验通过 ✓", name, siteVA, stubVA))
		return true
	end
	for i = 1, #PROBE_SITES do
		local t = PROBE_SITES[i]
		install(BASE + (t[1] - 0x400000), BASE + (t[2] - 0x400000), t[3])
	end
	-- vtable 槽：v7.2 暂不挂钩（等三条调用点验证通过再加），保留代码备查
	if false then
		local slotVA = BASE + (PROBE_VT[1] - 0x400000)
		local origVA = BASE + (PROBE_VT[2] - 0x400000)
		local stubVA = CFG._probe_stub + nstub * 64
		local ctrVA = CFG._probe_ctr + nctr * 4
		local bytes = probe_bytes_jmp(slotVA, origVA, stubVA, ctrVA)
		local dst = ffi.cast("uint8_t*", stubVA)
		for i = 1, #bytes do dst[i - 1] = bytes[i] end
		if tonumber(k32.VirtualProtect(ffi.cast("void*", slotVA), 4, 0x40, old)) ~= 0 then
			ffi.cast("uint32_t*", slotVA)[0] = stubVA
			k32.VirtualProtect(ffi.cast("void*", slotVA), 4, tonumber(old[0]), old)
			nctr = nctr + 1
			LOG(string.format("   · 探针挂钩：%s（槽 0x%X ← 跳板 0x%X）", PROBE_VT[3], slotVA, stubVA))
		end
	end
	CFG._probe_n = nctr
	return true
end

global_probe_dump = function(tag)
	if CFG.PROBE_HOOKS ~= "on" then return end
	if not base_ok() then return end
	if not probe_setup() then LOG("   · 探针：初始化失败（拿不到可执行内存）"); return end
	local ctr = CFG._probe_ctr
	local parts = {}
	for i = 1, #PROBE_SITES do
		parts[#parts + 1] = string.format("%d", rd32(ctr + (i - 1) * 4) or -1)
	end
	parts[#parts + 1] = string.format("%d", rd32(ctr + #PROBE_SITES * 4) or -1)
	local okp, px, py = pcall(GameGetCameraPos)
	LOG(string.format("   · 探针[%s] 计数（顺序：CreateNewChunk / load-area×8 / vtable 每区块更新）= %s；相机=%s,%s",
		tostring(tag), table.concat(parts, " "), tostring(px), tostring(py)))
end

-- ★ v7.3 只读探针：只读内存，不写代码、不调引擎函数（零崩溃风险）。
global_probe_read = function(tag)
	if CFG.PROBE_READ ~= "on" then return end
	if not base_ok() then LOG("   · 探针(读)：基址不符 ⇒ 跳过"); return end
	local session = rd32(BASE + (0x122374C - 0x400000))
	if session == nil or session == 0 or not readable(session, 0x98) then
		LOG("   · 探针(读)：session(0x122374C) 不可读 ⇒ 跳过"); return
	end
	local world = rd32(session + 0x10)
	if world == nil or world == 0 or not readable(world, 0x504) then
		LOG(string.format("   · 探针(读)：session=0x%X，但 +0x10 的世界对象不可读 ⇒ 跳过", session)); return
	end
	local cont = world + 0x500
	local lvl = rd32(cont + 0x458)
	local okp, px, py = pcall(GameGetCameraPos)
	local pcx = (okp and type(px) == "number") and math.floor(px / 512) or -99999
	local pcy = (okp and type(py) == "number") and math.floor(py / 512) or -99999
	LOG(string.format("   · 探针(读)[%s]：session=0x%X world=0x%X 容器=0x%X +0x458=0x%s 玩家区块=%d,%d 相机=%s,%s",
		tostring(tag), session, world, cont, lvl and string.format("%X", lvl) or "nil", pcx, pcy,
		tostring(px), tostring(py)))
	-- 在容器/槽表附近找"区块数据对象"（校验 +0x28/+0x2c == 0x200，再读 +0x58/+0x5c 当区块坐标）
	local hits = {}
	local function scan(startVA, span, why)
		for off = 0, span - 4, 4 do
			local p = rd32(startVA + off)
			if p ~= nil and p > 0x10000 and readable(p, 0x64)
				and rd32(p + 0x28) == 0x200 and rd32(p + 0x2c) == 0x200 then
				local cx, cy, lv, buf = rd32(p + 0x58), rd32(p + 0x5c), rd32(p + 0x60), rd32(p + 0x30)
				local bufok = (buf ~= nil and buf ~= 0 and readable(buf, 0x1000))
				hits[#hits + 1] = string.format("[%s+0x%X→0x%X 区块=%s,%s 层=%s 缓冲=%s]",
					why, off, p, tostring(cx), tostring(cy), tostring(lv), bufok and "可读" or "空/坏")
				if #hits >= 10 then return true end
			end
		end
		return false
	end
	if lvl ~= nil and lvl ~= 0 and readable(lvl, 0x400) then scan(lvl, 0x400, "lvl") end
	if readable(cont, 0x1000) then scan(cont, 0x1000, "cont") end
	LOG(string.format("   · 探针(读)：候选区块对象 %d 个 %s", #hits,
		(#hits == 0) and "（没有找到：说明这条链上的槽表结构和我推断的不同）" or table.concat(hits, " ")))
end

-- ★ v7.4 只读内存转储（PROBE_DUMP=on）：纯读取，不写代码、不调引擎函数。
global_probe_dumpmem = function(tag)
	if CFG.PROBE_DUMP ~= "on" then return end
	if not base_ok() then LOG("   · 转储：基址不符 ⇒ 跳过"); return end
	local session = rd32(BASE + (0x122374C - 0x400000))
	if session == nil or session == 0 or not readable(session, 0x100) then
		LOG("   · 转储：session 不可读 ⇒ 跳过"); return
	end
	local function dump(va, n, name)
		if va == nil or va == 0 or not readable(va, n) then
			LOG(string.format("   · 转储[%s]：地址 0x%s 不可读/%s", name, va and string.format("%X", va) or "nil", "跳过"))
			return
		end
		local line = {}
		for i = 0, n / 4 - 1 do
			line[#line + 1] = string.format("%08X", rd32(va + i * 4) or 0)
			if (#line == 8) or (i == n / 4 - 1) then
				LOG(string.format("   · 转储[%s] 0x%X+0x%03X: %s", name, va, (i + 1) * 4 - #line * 4, table.concat(line, " ")))
				line = {}
			end
		end
	end
	LOG(string.format("   · 转储[%s]：session=0x%X", tostring(tag), session))
	dump(session, 0x40, "session")
	local world = rd32(session + 0x10)
	dump(world, 0x100, "world")
	if world ~= nil and world ~= 0 then
		local cont = world + 0x500
		dump(cont, 0x200, "容器")
		local lvl = rd32(cont + 0x458)
		LOG(string.format("   · 转储：容器+0x458 = 0x%s", lvl and string.format("%X", lvl) or "nil"))
		if lvl ~= nil and lvl ~= 0 then dump(lvl, 0x100, "lvl(+0x458)") end
	end
end

-- ★ v7.5 只读扫描：列出所有区块对象 + 玩家 3×3 邻域里缺哪几个（纯读取，零风险）
global_probe_scan = function(tag)
	if CFG.PROBE_SCAN ~= "on" then return end
	if not base_ok() then LOG("   · 扫描：基址不符 ⇒ 跳过"); return end
	local session = rd32(BASE + (0x122374C - 0x400000))
	if session == nil or session == 0 or not readable(session, 0x100) then
		LOG("   · 扫描：session 不可读 ⇒ 跳过"); return
	end
	local world = rd32(session + 0x10)
	if world == nil or world == 0 or not readable(world, 0x4000) then
		LOG("   · 扫描：world 不可读 ⇒ 跳过"); return
	end
	local seen, list, ntotal, ndist = {}, {}, 0, 0
	local function scanRange(baseVA, span, why)
		local n = 0
		for off = 0, span - 4, 4 do
			local va = baseVA + off
			if rd32(va + 0x28) == 0x200 then
				local ox, oy = rd32(va + 0x20), rd32(va + 0x24)
				if ox ~= nil and oy ~= nil and ox % 512 == 0 and oy % 512 == 0 then
					local cx, cy = math.floor(ox / 512), math.floor(oy / 512)
					if math.abs(cx) <= 1024 and math.abs(cy) <= 1024 then
						local buf = rd32(va + 0x30)
						local bufi = (buf ~= nil and buf ~= 0 and readable(buf, 0x1000))
						n = n + 1
						local key = cx .. "," .. cy
						if not seen[key] then
							seen[key] = true
							ndist = ndist + 1
							if #list < 16 then
								list[#list + 1] = string.format("%s+0x%X 区块=%s(%d,%d) 缓冲=%s", why, off, key, cx, cy, bufi and "可读" or "空/坏")
							end
						end
					end
				end
			end
		end
		return n
	end
	ntotal = ntotal + scanRange(world, 0x4000, "world")
	for i = 0, 0x200 - 4, 4 do
		local p = rd32(world + i)
		if p ~= nil and p > 0x10000 and readable(p, 0x800) then
			ntotal = ntotal + scanRange(p, 0x800, string.format("w+0x%X→", i))
		end
	end
	LOG(string.format("   · 扫描[%s]：命中 %d 处、不重复区块 %d 个：%s", tostring(tag), ntotal,
		ndist, (#list > 0) and table.concat(list, " | ") or "无"))
	local okp, px, py = pcall(GameGetCameraPos)
	if okp and type(px) == "number" and type(py) == "number" then
		local pcx, pcy = math.floor(px / 512), math.floor(py / 512)
		local miss = {}
		for dx = -1, 1 do
			for dy = -1, 1 do
				local k = (pcx + dx) .. "," .. (pcy + dy)
				if not seen[k] then miss[#miss + 1] = k end
			end
		end
		LOG(string.format("   · 扫描[%s]：玩家区块=%d,%d；3×3 邻域里【没有区块对象】的是：%s", tostring(tag),
			pcx, pcy, (#miss > 0) and table.concat(miss, " ") or "无（9 个都在）"))
	end
end

local pending_checkpoint = nil

local function do_checkpoint()
	pcall(global_probe_dump, "Ctrl+S 前")   -- ★ v7.1 挂钩探针转储（PROBE_HOOKS=on 时才动手）
	pcall(global_probe_read, "Ctrl+S")     -- ★ v7.3 只读探针转储（PROBE_READ=on 时才动手）
	pcall(global_probe_dumpmem, "Ctrl+S")  -- ★ v7.4 只读内存转储（PROBE_DUMP=on 时才动手）
	pcall(global_probe_scan, "Ctrl+S")     -- ★ v7.5 只读区块扫描（PROBE_SCAN=on 时才动手）
	if busy then return end
	-- ★ v6.8 闸门一：上一次存档还在落盘/镜像阶段时，绝不允许再写一次（重叠写盘会写坏画面）
	if pending_checkpoint ~= nil then
		LOG("★ 上一次存档还在落盘/镜像中（pending_checkpoint 未清）⇒ 本次 Ctrl+S 忽略")
		NOTICE("上一次存档还没完成")
		return
	end
	-- ★ v6.8 闸门二：最小间隔（默认 8000 ms，比 settle 上限 8 秒略长）
	local cd = tonumber(CFG.SAVE_COOLDOWN_MS) or 8000
	if CFG._last_save_ms and (tickMs() - CFG._last_save_ms) < cd then
		LOG(string.format("★ 距上次写盘仅 %d ms（最小间隔 %d ms）⇒ 本次 Ctrl+S 忽略",
			tickMs() - CFG._last_save_ms, cd))
		NOTICE("存档太频繁，稍等一会")
		return
	end
	busy = true
	LOG("")
	LOG("==================== Ctrl+S：记录存档点（不重启、不转场） ====================")
	local slot, how = guards()
	if not slot then busy = false; return end
	local slotPath = slot_dir(slot)
	local gateOk, g1, g2, g3 = save_gates_ok()
	LOG(string.format("当前槽=%d（来源 %s）；前置门：obj+0x94=%s DAT_01206fa9=%s DAT_01205010=%s ⇒ %s",
		slot, tostring(how), tostring(g1), tostring(g2),
		g3 and string.format("0x%x", g3) or "nil", gateOk and "满足 ✓" or "不满足 ⇒ 中止（不改任何文件）"))
	if not gateOk then
		NOTICE("现在无法记录存档点（世界状态未就绪，见日志）")
		busy = false; return
	end
	CFG._last_save_ms = tickMs()   -- ★ v6.8：记下本次写盘时刻，用于最小间隔

	local wsPath, pjPath = slotPath .. "\\world_state.xml", slotPath .. "\\player.xml"
	local wsB, pjB = file_sig(wsPath), file_sig(pjPath)
	local t0 = tickMs()

	-- ① 先给"本局"打上标记（存在 world_state.xml 的 <flags> 里，跟本局存档走）
	--    必须在写 world_state.xml 之前打，这样写出的文件里就带着它 ⇒ 回滚后本局仍有标记 ✓
	flag_run_add()

	-- （原 SAVE_MODE=restart 分支已删除：它会让游戏"保存并退出"、然后不回来。存档改回"写盘 + 等落完 + 镜像"。）

	-- ★ SAVE_MODE=restart：让引擎自己"保存并退出到主菜单"（它才会写 world 区块），
	--   然后新进程在世界加载前把槽镜像成存档点（跨进程标记 action=checkpoint，见 handle_pending）
	if CFG.SAVE_MODE == "restart" then
		local wn, wb = world_files_stat(slotPath)
		LOG(string.format("② SAVE_MODE=restart：请引擎『保存并退出』（当前槽 %d：world 里 %d 个文件/%d 字节）", slot, wn, wb))
		LOG("   引擎会在退出过程里完整存档（world 区块 + world_state.xml + player.xml），然后重启进程自动重载世界；")
		LOG("   本 mod 已写好跨进程标记 action=checkpoint ⇒ 新进程会在世界加载之前把槽镜像到快照 ✓")
		local okm = write_marker({ action = "checkpoint", slot = slot, dir = dir_of(CFG.SNAP_DIR) })
		LOG("   标记写入 = " .. tostring(okm))
		if okm then
			local oks, errs = trigger_save_and_restart("Ctrl+S 存档点")
			if oks then
				LOG("   ✓ 已交给引擎：本进程即将退出并被自动重载，不需要任何人工操作")
				busy = false
				return
			end
			LOG("   ★ 调用失败 ⇒ 删除标记，退回 xml 方式")
			remove_file(marker_path())
		else
			LOG("   ★ 标记写不进去 ⇒ 退回 xml 方式")
		end
	end

	-- ②③ 老方式（下面这行记录写盘前的区块规模）
	local ok1, err1, ok2, err2, needFallback = false, "", false, "", false
	local function xml_writers()
		LOG("② world_state.xml（包装自带前置检查，无参数）")
		local o1, e1 = pcall(function()
			ffi.cast("void(*)(void)", BASE + (F_WRITE_WORLDSTATE - 0x400000))()
		end)
		local playerObj, howId = identify_player_object()
		local o2, e2 = false, "未认出玩家对象（" .. tostring(howId) .. "）"
		if playerObj then
			LOG("  玩家对象 = 0x" .. string.format("%x", playerObj) .. "（" .. tostring(howId) .. "）")
			o2, e2 = pcall(function()
				ffi.cast("void(__thiscall*)(void*)", BASE + (F_WRITE_PLAYER - 0x400000))(ffi.cast("void*", playerObj))
			end)
		else
			LOG("  ★" .. tostring(e2))
		end
		return o1, e1, o2, e2
	end
	LOG("② SAVE_MODE=xml：按引擎保存序列逐件调用（拆解版；②mod 集合重建已被我们跳过）")
	local wn0, wb0 = world_files_stat(slotPath)     -- 写盘前的区块规模（用来证明"这次真的写盘了"）
	ok1, err1, ok2, err2 = xml_writers()
	-- ★★ 关键一步：让引擎把 world 区块刷到盘上（引擎自己存档时走的也是这个函数）
	call_save_piece(F_WORLD_META, "世界写盘(0x7422C0：区块 + stream_info/pixel_scenes/tree/sim)", slotPath)
	-- ★（废弃）写盘后把屏幕内的区块重新请求进来：逐个区块、最多 4 个
	--   （上一版整体调 0x9A4F50/FUN_0073B040 会扫整个网格 ⇒ 崩；这里只调单区块入口 FUN_0073E950）
	-- ★ 已永久废弃：直接调引擎区块函数必崩（实测崩溃点 noita.exe+0x33E989 = FUN_0073E950 内部）
	--   ⇒ 这条分支永远不可达，只是留着记录我们试过什么。
	if false and CFG.RELOAD_CHUNKS == "on" and base_ok() then
		local maxn = tonumber(CFG.RELOAD_CHUNKS_MAX) or 4
		if maxn > 4 then maxn = 4 end     -- 硬上限：屏幕里装不下更多区块
		local px, py
		if type(EntityGetTransform) == "function" and player_entity_cached then
			local okt, x, y = pcall(EntityGetTransform, player_entity_cached)
			if okt and type(x) == "number" then px, py = x, y end
		end
		if not px then
			LOG("   · 拿不到玩家坐标 ⇒ 跳过区块重载")
		else
			-- 区块 = 512×512 世界单位（反编译：网格 512×512、<<9 缩放；文件名都是 512 的倍数）
			-- 取"以玩家为中心的那个 2×2 区块块"⇒ 无论玩家站在自己格子的哪个角落，屏幕(≤640×360)都被覆盖
			local cx = math.floor((px - 256) / 512) + 256
			local cy = math.floor((py - 256) / 512) + 256
			LOG(string.format("   · 写盘后请求重载区块：玩家 (%d,%d) ⇒ 区块 (%d,%d)，最多 %d 个（FUN_0073E950，索引=CX*512+CY）",
				math.floor(px), math.floor(py), cx, cy, maxn))
			local off = { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }   -- 玩家所在格 + 右/下/右下
			for i = 1, maxn do
				local idx = (cx + off[i][1]) * 512 + (cy + off[i][2])
				local okc, errc = pcall(function()
					ffi.cast("void(__fastcall*)(int)", BASE + (0x73e950 - 0x400000))(idx)
				end)
				LOG(string.format("   · 区块重载[%d/%d] 索引=%d ⇒ %s%s", i, maxn, idx,
					tostring(okc), okc and "" or ("  错误: " .. tostring(errc))))
				if not okc then break end
			end
		end
	end

	-- ★ 相机微移（公开 API）：写盘后把相机挪 1 个世界单位 ⇒ 引擎的区块流式加载会重新评估屏幕内的区块
	if CFG.NUDGE_CAMERA == "on" and type(GameGetCameraPos) == "function" and type(GameSetCameraPos) == "function" then
		local okg, gx, gy = pcall(GameGetCameraPos)
		local okb, bx, by, bw, bh = pcall(GameGetCameraBounds)
		LOG(string.format("   · 相机：位置=(%s,%s) 屏幕范围=(%s,%s %sx%s)%s",
			tostring(gx), tostring(gy), tostring(bx), tostring(by), tostring(bw), tostring(bh),
			(bw and bh) and string.format(" ⇒ 区块 512 世界单位 ⇒ 屏幕最多跨 %d×%d 格", math.ceil(bw / 512), math.ceil(bh / 512)) or ""))
		if okg and type(gx) == "number" and type(gy) == "number" then
			local okn, errn = pcall(GameSetCameraPos, gx + 1, gy)
			LOG(string.format("   · 已把相机设为 (%s,%s)（下一帧游戏自己的跟随逻辑会接管）⇒ %s%s",
				tostring(gx + 1), tostring(gy), tostring(okn), okn and "" or ("  错误: " .. tostring(errn))))
		else
			LOG("   · 读不到相机位置 ⇒ 跳过相机微移")
		end
	end

	-- ★ v7.0 申请区块加载：调引擎自己的「按区域加载区块」入口，把相机范围外扩后交给它。
	--   入口：FUN_0073DAB0(this=*(session+0x10)+0x500, rect)；rect 是世界单位 {x,y,w,h}（内部 >>9 换成区块号）。
	--   已存在的区块只打日志不重建 ⇒ 幂等、安全；四处校验任一不过就不调用。
	if CFG.RELOAD_AREA == "on" and base_ok() then
		local session = rd32(BASE + (0x122374C - 0x400000))
		if session ~= nil and session ~= 0 and readable(session, 0x98) then
			local world = rd32(session + 0x10)
			if world ~= nil and world ~= 0 and readable(world, 0x504) then
				local obj = world + 0x500
				local guard = rd32(obj + 0x458)
				local okb, bx, by, bw, bh = pcall(GameGetCameraBounds)
				if okb and type(bx) == "number" and type(by) == "number"
					and type(bw) == "number" and type(bh) == "number" then
					local pad = 192
					local rect = ffi.new("int[4]", {
						math.floor(bx - pad), math.floor(by - pad),
						math.floor(bw + pad * 2), math.floor(bh + pad * 2) })
					LOG(string.format("   · 区块加载：session=0x%X world=0x%X obj=0x%X 守卫(+0x458)=0x%X 矩形=%d,%d %dx%d",
						session, world, obj, guard, rect[0], rect[1], rect[2], rect[3]))
					if guard ~= 0 and rect[2] >= 256 and rect[2] <= 8192 and rect[3] >= 256 and rect[3] <= 8192 then
						local okc, errc = pcall(function()
							ffi.cast("void(__fastcall*)(void*, int, int*)", BASE + (0x73DAB0 - 0x400000))(
								ffi.cast("void*", obj), 0, rect)
						end)
						LOG(string.format("   · 已把该矩形交给引擎加载区块 ⇒ %s%s",
							tostring(okc), okc and "" or ("  错误: " .. tostring(errc))))
					else
						LOG("   · 守卫字段为 0 或矩形尺寸不合理 ⇒ 不调用（不冒险）")
					end
				else
					LOG("   · 读不到相机范围 ⇒ 跳过区块加载")
				end
			else
				LOG("   · session+0x10（世界对象）不可用 ⇒ 跳过区块加载")
			end
		else
			LOG("   · 读不到 session 单例（0x122374C）⇒ 跳过区块加载")
		end
	end

	-- ★ v7.6 待命：记下相机矩形，等 *(world+0x500+0x458) 非 0 时再调 FUN_0073DAB0
	if CFG.RELOAD_AREA == "on" then
		local okb2, bx2, by2, bw2, bh2 = pcall(GameGetCameraBounds)
		if okb2 and type(bx2) == "number" and type(by2) == "number"
			and type(bw2) == "number" and type(bh2) == "number" then
			CFG._ra_rect = { math.floor(bx2 - 192), math.floor(by2 - 192),
				math.floor(bw2 + 384), math.floor(bh2 + 384) }
			CFG._ra_until = tickMs() + 15000
			CFG._ra_tries = 0
			LOG(string.format("   · 区块加载：已待命，等守卫非 0 时调用 FUN_0073DAB0；矩形=%d,%d %dx%d（最多等 15 秒）",
				CFG._ra_rect[1], CFG._ra_rect[2], CFG._ra_rect[3], CFG._ra_rect[4]))
		else
			LOG("   · 区块加载：读不到相机范围 ⇒ 不待命")
		end
	end

	-- ★ v6.9 玩家微移（公开 API）：实测「相机微移」无效、而「走动」有效 ⇒ 触发条件是玩家自身位置，
	--   所以把玩家挪 1 个世界单位（肉眼不可见），让引擎重新评估并把屏幕内缺失的区块读回来。
	if CFG.NUDGE_PLAYER == "on" and type(EntityGetWithTag) == "function"
		and type(EntityGetTransform) == "function" and type(EntitySetTransform) == "function" then
		local okp, list = pcall(EntityGetWithTag, "player_unit")
		local pe = (okp and type(list) == "table" and list[1]) or nil
		if pe then
			local okg, px, py, pr = pcall(EntityGetTransform, pe)
			if okg and type(px) == "number" and type(py) == "number" then
				local okn, errn = pcall(EntitySetTransform, pe, px + 1, py, pr)
				local ok2, nx, ny = pcall(EntityGetTransform, pe)
				LOG(string.format("   · 玩家微移：实体=%s (%s,%s) → 设为 (%s,%s) ⇒ %s%s；读回 (%s,%s)",
					tostring(pe), tostring(px), tostring(py), tostring(px + 1), tostring(py),
					tostring(okn), okn and "" or ("  错误: " .. tostring(errn)),
					tostring(nx), tostring(ny)))
			else
				LOG("   · 读不到玩家位置 ⇒ 跳过玩家微移")
			end
		else
			LOG("   · 找不到 player_unit 实体 ⇒ 跳过玩家微移")
		end
	end

	-- ★ v6.7 申请区块加载：按反汇编还原引擎自己的路径（vtable 0xFFE57C 的槽 0x9A4F50）：
	--   ECX=this → MOV ECX,[ECX+4] → JMP 0x73B040 ⇒ 管理器 = *(全局单例 0x11D7530 + 4)
	--   0x73B040 = 流式窗口更新（引擎在玩家跨区块、窗口需要重新评估时走的那条路，也是「走一步就恢复」的原因）
	if CFG.RELOAD_STREAM == "on" and base_ok() then
		local sing = BASE + (0x11D7530 - 0x400000)
		local vt = rd32(sing)
		local mgr = rd32(sing + 4)
		if vt == 0xFFE57C and mgr ~= nil and mgr ~= 0 and mgr ~= 4294967295 and readable(mgr, 0xa0) then
			local winx, winy = rd32(mgr + 0x20), rd32(mgr + 0x24)
			local ww, wh = rd32(mgr + 0x28), rd32(mgr + 0x2c)
			local grid, mp, h8 = rd32(mgr + 0x30), rd32(mgr + 0x7c), rd32(mgr + 0xc8)
			local okp, px = pcall(GameGetCameraPos)
			local pcx = (okp and type(px) == "number") and math.floor(px / 512) or -99999
			LOG(string.format("   · 流式管理器=0x%X（vtable=0x%X ✓）窗口原点=%d,%d 窗口=%dx%d grid=0x%X map=0x%X 脏标志=%s 玩家区块=%d",
				mgr, vt, winx, winy, ww, wh, grid, mp, tostring(h8), pcx))
			local sane = (ww >= 4 and ww <= 4096 and wh >= 4 and wh <= 4096 and grid ~= 0 and readable(grid, 8))
			if not sane then
				LOG("   · 参数不自洽（窗口尺寸或 grid 指针异常）⇒ 不调用，避免上次那种崩溃")
			else
				local okc, errc = pcall(function()
					ffi.cast("void(__fastcall*)(void*)", BASE + (0x73B040 - 0x400000))(ffi.cast("void*", mgr))
				end)
				LOG(string.format("   · 已请求流式窗口更新（等价于引擎自己重新评估一次）⇒ %s%s",
					tostring(okc), okc and "" or ("  错误: " .. tostring(errc))))
			end
		else
			LOG(string.format("   · 没找到预期的流式单例（0x11D7530: vtable=0x%s mgr=0x%s）⇒ 跳过区块重载",
				vt and string.format("%X", vt) or "nil", mgr and string.format("%X", mgr) or "nil"))
		end
	end

	-- ★ v4：两次引擎写盘调用会把"模组已改动"闩锁位置 1（下一帧才置）⇒ 先清一次，再启动看护
	clear_mods_changed_latch("存档动作后")
	latch_watch_until = frame_no() + LATCH_WATCH_FRAMES
	LOG(string.format("闩锁看护已启动：接下来 %d 帧内一见到非 0 就清（frame=%d）",
		LATCH_WATCH_FRAMES, frame_no()))

	local wsA, pjA = file_sig(wsPath), file_sig(pjPath)
	LOG(string.format("② world_state.xml 调用=%s%s", tostring(ok1), ok1 and "" or ("  错误: " .. tostring(err1))))
	LOG(string.format("   %s → %s   变化 = %s", fmt_sig(wsB), fmt_sig(wsA), diff_sig(wsB, wsA)))
	LOG(string.format("③ player.xml     调用=%s%s", tostring(ok2), ok2 and "" or ("  错误: " .. tostring(err2))))
	LOG(string.format("   %s → %s   变化 = %s", fmt_sig(pjB), fmt_sig(pjA), diff_sig(pjB, pjA)))

	local wsOk = (diff_sig(wsB, wsA) == "true") or (diff_sig(wsB, wsA) == "true（之前不存在）")
	local pjOk = (diff_sig(pjB, pjA) == "true") or (diff_sig(pjB, pjA) == "true（之前不存在）")
	if not (wsOk and pjOk) then
		LOG("★两个文件没有都写成功 ⇒ 不更新存档点（保留上一个快照），也不改任何其他文件")
		NOTICE("存档点未更新（写入未全部成功，见日志）")
		busy = false; return
	end

	local wn1, wb1 = world_files_stat(slotPath)
	LOG(string.format("   区块：保存前 %d 个文件/%d 字节 → 保存后 %d 个文件/%d 字节%s",
		wn0, wb0, wn1, wb1, wn1 > wn0 and " ⇒ 区块已随这次写盘落到盘上 ✓" or "（没有变多：这次可能没刷区块）"))
	-- ★ 关键：写盘是异步的（同时会落下 .autosave* 标记）。**等盘安静下来再镜像**：
	--   标记消失 且 区块文件数连续一小段时间不再变化 ⇒ 才开始镜像。
	pending_checkpoint = { slot = slot, slotPath = slotPath, t0 = t0,
		deadline = tickMs() + 8000, settle_until = tickMs() + 400, last_count = wn1 }
	LOG("   已安排：等写盘落完（.autosave 标记消失、区块文件数不再变）后立刻镜像，最多等 8 秒")
	-- 注意：这里必须直接 return（busy 保持 true，直到镜像做完）；Lua 的 return 之后不能再跟语句
	return
end

-- 按 Ctrl+方向键在死亡界面微调按钮位置，并写回配置（这样你不用猜坐标）
-- 键码用 SDL scancode（本机实测：方向键 左80 右79 上82 下81，Shift 225/229）
local function round1(v)
	return math.floor(v * 10 + 0.5) / 10
end

local function round2(v)
	return math.floor(v * 100 + 0.5) / 100
end

local function clamp100(v)
	if v < 0 then return 0 elseif v > 100 then return 100 end
	return v
end

-- 把 CFG 里的按钮位置写回配置文件（微调与鼠标拖动结束时都用它）⇒ 位置被"记忆"
local function save_xy_to_config()
	if not CFG_PATH then return end
	local s = read_text(CFG_PATH) or ""
	-- 注意：Lua 模式没有 (?m)，^/$ 只作用于整串 ⇒ 必须逐行处理，否则会不断追加重复键
	local function setkv(text, key, val)
		local out, done = {}, false
		for line in (text .. "\n"):gmatch("([^\n]*)\n") do
			if (not done) and line:match("^%s*" .. key .. "%s*=") then
				out[#out + 1] = key .. "=" .. val
				done = true
			else
				out[#out + 1] = line
			end
		end
		if not done then out[#out + 1] = key .. "=" .. val end
		return table.concat(out, "\n")
	end
	s = setkv(s, "GUI_X", CFG.GUI_X)
	s = setkv(s, "GUI_Y", CFG.GUI_Y)
	write_text(CFG_PATH, s)
	-- 明确写出"存到哪个文件、存了什么"，方便随时查看或手改
	-- （这里不调用 screen_dims()：它定义在文件后半段，本函数运行时它还不可见）
	LOG(string.format("按钮位置已记忆：GUI_X=%s  GUI_Y=%s（单位 %s）", CFG.GUI_X, CFG.GUI_Y, CFG.GUI_UNIT))
	LOG("  已写回配置文件：" .. tostring(CFG_PATH) .. "（手改这两行也行）")
end

-- dx/dy 直接就是"配置单位"的位移（percent 时是百分比，pixel 时是 GUI 像素）
-- 步长由 GUI_STEP（默认 0.1）与 GUI_STEP_COARSE（按 Shift，默认 1）决定 ⇒ 0.1% 竖约 1.4px，够对齐用
local function update_config_xy(dx, dy)
	local x = (tonumber(CFG.GUI_X) or 50) + dx
	local y = (tonumber(CFG.GUI_Y) or 68.5) + dy
	if CFG.GUI_UNIT ~= "pixel" then
		x, y = clamp100(x), clamp100(y)
	end
	CFG.GUI_X = tostring(round2(x))
	CFG.GUI_Y = tostring(round2(y))
	LOG(string.format("  位置已更新：GUI_X=%s GUI_Y=%s（位移 x=%s y=%s）",
		CFG.GUI_X, CFG.GUI_Y, string.format("%.4f", dx), string.format("%.4f", dy)))
	save_xy_to_config()   -- 不再弹屏幕提示（只写日志），避免提示框挡视线
end

-- 先提示"准备回溯"，等一小会儿（让提示看得见）再真正执行转场
-- 两个门槛都记：世界更新时用帧号；死亡界面世界可能停更，那时用墙钟兜底
local rewind_pending_frame = 0
local rewind_pending_ms = 0

local function execute_rewind(where)
	rewind_pending_frame = 0
	rewind_pending_ms = 0
	local slot, how = guards()
	if not slot then return end
	local restoreFrom = (CFG.RESTORE_FROM == "snap_auto") and dir_of(CFG.AUTO_DIR) or dir_of(CFG.SNAP_DIR)
	LOG(string.format("执行回溯（由%s触发）：当前槽=%d（来源 %s）；回溯到 %s（RESTORE_FROM=%s）",
		tostring(where), slot, tostring(how), tostring(restoreFrom), CFG.RESTORE_FROM))
	if not file_sig(restoreFrom .. "\\player.xml") then
		LOG("中止：该目录里没有 player.xml（还没记录过存档点？）")
		NOTICE("本局还没有存档点")
		return
	end
	-- ★ 同局检查：绝不用上一局的存档点
	local runOk, runWhy = snapshot_run_ok(restoreFrom)
	LOG(string.format("同局检查（%s）：%s（%s）", tostring(restoreFrom), runOk and "有效 ✓" or "无效 ✗", tostring(runWhy)))
	if not runOk then
		NOTICE("本局还没有存档点（这个存档点属于上一局）")
		return
	end
	LOG("步骤1：把当前槽镜像到保护点目录（可用于撤销本次回溯）")
	local t0 = tickMs()
	local c1, f1, b1, sample1 = mirror_in_run(slot_dir(slot), dir_of(CFG.AUTO_DIR))
	LOG(string.format("  保护点完成：%d 文件/%d 字节，失败 %d，耗时 %d ms", c1, b1, f1, tickMs() - t0))
	write_run_info(dir_of(CFG.AUTO_DIR), slot, sample1)   -- 保护点也记上本局标识（撤销时才合法）
	invalidate_run_check()
	LOG("步骤2：写跨进程标记 action=restore")
	local okm = write_marker({ action = "restore", slot = slot, dir = restoreFrom })
	LOG("  标记写入 = " .. tostring(okm))
	if not okm then return end
	LOG("步骤3：触发引擎读档转场（引擎自己起新进程）")
	-- ★ 重启钩子**只在这一刻装**：装早了会跟着新进程一起启动（实测那种进程 100% 崩在 atioglxx），
	--   到这里才装 ⇒ 新进程的启动路径与本机可用的 rewind_v3restored 完全一致。
	if CFG.SPAWN_HOOK == "on" and not has_hook_slot() then
		local okh, errh = pcall(install_spawn_hook)
		if not hook_install_tried then
			hook_install_tried = true
			LOG("  （首次）安装重启钩子：" .. tostring(okh) .. " " .. tostring(errh))
		end
		spawn_hook_report("  钩子状态")
	elseif CFG.SPAWN_HOOK ~= "on" then
		LOG("  SPAWN_HOOK=off ⇒ 完全照引擎原样（不碰导入表）")
	end
	local ok = trigger_load_transition("rewind")
	if ok then
		LOG("  预期：新进程读到铺好的槽 ⇒ 世界回到存档点 ✓")
	else
		LOG("  调用未成功 ⇒ 删除标记（保护点仍在）")
		remove_file(marker_path())
		NOTICE("回溯失败（见日志）")
	end
	if CFG.HEARTBEAT == "on" then heartbeat_until = frame_no() + 600; heartbeat_next = frame_no() + 60 end
end

local function do_rewind()
	if busy or rewind_pending_frame > 0 then return end
	busy = true
	LOG("")
	LOG("==================== Ctrl+Z：回溯到存档点 ====================")
	local slot, how = guards()
	if not slot then busy = false; return end
	local restoreFrom = (CFG.RESTORE_FROM == "snap_auto") and dir_of(CFG.AUTO_DIR) or dir_of(CFG.SNAP_DIR)
	if not file_sig(restoreFrom .. "\\player.xml") then
		LOG("中止：该目录里没有 player.xml（还没记录过存档点？）")
		NOTICE("本局还没有存档点")
		busy = false; return
	end
	-- ★ 同局检查：本局没记过存档点就不允许回溯（否则会回到上一局的位置）
	local runOk, runWhy = current_run_check()
	LOG(string.format("同局检查：%s（%s）", runOk and "有效 ✓" or "无效 ✗", tostring(runWhy)))
	if not runOk then
		LOG("拒绝回溯：" .. tostring(runWhy))
		NOTICE("本局还没有存档点（这个存档点属于上一局）")
		busy = false; return
	end
	LOG(string.format("当前槽=%d（来源 %s）；将回溯到 %s", slot, tostring(how), tostring(restoreFrom)))
	NOTICE("准备回溯")
	rewind_pending_frame = frame_no() + 45     -- 约 0.75 秒后再执行，让提示看得见
	rewind_pending_ms = tickMs() + 800         -- 世界若停更（死亡界面）由墙钟兜底
	LOG(string.format("已提示『准备回溯』；将于第 %d 帧或 %d ms 后执行转场",
		rewind_pending_frame, rewind_pending_ms))
	busy = false
end

-- ==========================================================================
-- 新进程初始化阶段：处理跨进程标记（世界加载之前，实测窗口约 3 秒）
-- ==========================================================================
local function handle_pending()
	local m = read_marker()
	if not m then return end
	local p = marker_path()
	local t0 = tickMs()
	local age = t0 - (tonumber(m.tick) or 0)
	local staleMs = tonumber(CFG.STALE_MS) or 180000
	LOG("")
	LOG(string.format("★ 发现跨进程标记：action=%s slot=%s dir=%s（距今 %d ms，写入者 PID=%s，本进程 PID=%d）",
		tostring(m.action), tostring(m.slot), tostring(m.dir), age, tostring(m.pid), pid()))
	-- ★ 只处理"别的进程"写的标记：引擎做完整存档时会重建 mod 的 Lua state（init.lua 被重跑一次），
	--   那次重生的自己如果把标记消费掉，真正的新进程就拿不到了。
	if tonumber(m.pid) == pid() then
		LOG("   ⇒ 这个标记是本进程自己写的（引擎存档过程中重建过 mod 的 Lua state）⇒ 跳过，留给新进程处理")
		return
	end
	local slotIdx = tonumber(m.slot)
	if (not slotIdx) or slotIdx < 0 or slotIdx > 6 then
		LOG("  槽号非法 ⇒ 忽略并删除标记（不做任何文件改动）")
	elseif age > staleMs then
		LOG(string.format("  标记过旧（>%d ms）⇒ 判为陈旧，忽略并删除（不做任何文件改动）", staleMs))
	else
		local slotPath = slot_dir(slotIdx)
		if m.action == "checkpoint" then
			LOG(string.format("  动作=checkpoint：把槽 %d 的局内文件镜像到 %s", slotIdx, tostring(m.dir)))
			local c, f, b, cs = mirror_in_run(slotPath, m.dir)
			write_run_info(m.dir, slotIdx, cs)     -- 跨进程路径也要记本局标识
			invalidate_run_check()
			local wn, wb = world_files_stat(slotPath)
			LOG(string.format("  存档点建立完成：%d 文件/%d 字节，失败 %d，耗时 %d ms ✓", c, b, f, tickMs() - t0))
			LOG(string.format("  （这一刀的世界：world 目录 %d 个文件/%d 字节；world_state.xml=%s player.xml=%s）",
				wn, wb, fmt_sig(file_sig(slotPath .. "\\world_state.xml")), fmt_sig(file_sig(slotPath .. "\\player.xml"))))
		elseif m.action == "restore" then
			LOG(string.format("  动作=restore：把 %s 铺回槽 %d（%s）", tostring(m.dir), slotIdx, tostring(slotPath)))
			local c, f, d, b = stage_into_slot(m.dir, slotPath)
			LOG(string.format("  铺档完成：%d 文件/%d 字节，清理 %d 个多余文件，失败 %d，耗时 %d ms ✓",
				c, b, d, f, tickMs() - t0))
			LOG("  引擎随后的读档会读到铺好的文件 ⇒ 世界回到存档点")
		else
			LOG("  未知动作 ⇒ 忽略（不做任何文件改动）")
		end
	end
	remove_file(p)
	LOG("  已删除跨进程标记")
end

-- ==========================================================================
-- 死亡界面按钮（只用游戏脚本里确认存在的 GUI 接口）
-- ==========================================================================
local gui, died = nil, false
local death_draw_logged = false
local hover_logged = nil     -- 悬停状态（只用于日志，翻转时才写）
local death_world_frames = 0
local death_pause_frames = 0
local death_ctx_logged = false
local death_draw_frames = 0
local death_ms = 0
local gui_drawn_ms = -100000
local gui_drawn_frame = -1

local function on_death_button_click()
	LOG("死亡界面：点了『回溯』按钮（按钮继续显示，不再消失）")
	do_rewind()      -- 注意：不再把 died 置 false ⇒ 按钮保持可见
end

-- ==========================================================================
-- 界面坐标换算辅助
-- ==========================================================================

local function screen_dims()
	if not gui then return nil end
	local oks, sw, sh = pcall(GuiGetScreenDimensions, gui)
	if oks and tonumber(sw) and tonumber(sh) and tonumber(sw) > 0 then return tonumber(sw), tonumber(sh) end
	return nil
end

local function mouse_pos()
	if type(InputGetMousePosOnScreen) ~= "function" then return nil end
	local okm, mx, my = pcall(InputGetMousePosOnScreen)
	if okm and tonumber(mx) and tonumber(my) then return tonumber(mx), tonumber(my) end
	return nil
end

local function in_rect(px, py, x, y, w, h)
	return px >= x and px <= (x + w) and py >= y and py <= (y + h)
end

-- 让『回溯』的文字大小与引擎死亡菜单项一致：菜单文字高 ≈ 屏幕高的 2.36%（2560x1440 实测 34px）
-- GUI 坐标的百分比与屏幕一致 ⇒ 目标 GUI 高度 = 0.0236 × GUI 视口高，再按 scale=1 时的实测字高换算。
-- 同时把文字宽度量出来 —— 水平居中要靠它自己算：
-- 实测 GUI_OPTION.Align_HorizontalCenter(16) 对我们的控件没生效（文字左边缘贴在 GUI_X 上，看起来是左对齐）。
local GUI_MENU_TEXT_H_RATIO = 0.0236
local text_metrics_cache = nil
local function text_metrics(sh)
	if text_metrics_cache then return text_metrics_cache end
	local m = { scale = tonumber(CFG.GUI_SCALE) or 1, w = nil, h = nil }
	if type(GuiGetTextDimensions) == "function" then
		local okt, tw, th = pcall(GuiGetTextDimensions, gui, "回溯", 1)
		if okt and tonumber(tw) and tonumber(th) and tonumber(th) > 0 then
			local base_w, base_h = tonumber(tw), tonumber(th)
			if CFG.GUI_SCALE == "auto" then
				local target = GUI_MENU_TEXT_H_RATIO * (tonumber(sh) or 360)
				local s = target / base_h
				if s < 0.4 then s = 0.4 elseif s > 3 then s = 3 end
				m.scale = s
				LOG(string.format("按钮字号：scale=1 实测 宽%.2f 高%.2f GUI 单位，目标高=%.2f（=屏幕高 2.36%%）⇒ scale=%.3f",
					base_w, base_h, target, s))
			end
			m.w, m.h = base_w * m.scale, base_h * m.scale
			text_metrics_cache = m
			return m
		end
	end
	LOG("按钮字号：取不到 GuiGetTextDimensions ⇒ 用 scale=1（居中也只能靠 GUI_OPTION 的选项）")
	text_metrics_cache = m
	return m
end

-- GUI_COLOR=1,1,1,1 （0-1 浮点，RGBA）；写 default 表示不设置颜色（用引擎默认灰）
local function parse_color(s)
	if not s or s == "" or s == "default" then return nil end
	s = tostring(s)
	-- 先按 4 段（R,G,B,A）解析；只写了 3 段时 alpha 默认 1（手改配置时更省事）
	local r, g, b, a = s:match("^%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)%s*$")
	if r then return tonumber(r), tonumber(g), tonumber(b), tonumber(a) end
	r, g, b = s:match("^%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)%s*$")
	if r then return tonumber(r), tonumber(g), tonumber(b), 1 end
	return nil
end

-- ==========================================================================
-- 死亡界面按钮：绝对坐标（GuiText）+ 自己判定悬停/点击
--   为什么不用 GuiButton：它在布局里会被**拉伸成整条**，判定框远大于文字（点哪儿都算点中），
--   而且自带内边距、锚点和引擎菜单项不一致，没法逐格对齐。
--   GuiText 没有判定框、锚点就是文字左上角 ⇒ 位置可预测；悬停/点击我们用鼠标坐标自己算。
-- ==========================================================================

-- 鼠标坐标 → GUI 单位：本机实测 InputGetMousePosOnScreen() 给的是 1280x720，
-- 而 GUI 视口是 640x360 ⇒ 2 个鼠标单位 = 1 个 GUI 单位（= 4 屏幕像素 @2560x1440）；y 方向一致（都向下）
local mouse_ratio_logged = nil
local function mouse_to_gui(mx, my)
	local u = tonumber(CFG.GUI_MOUSE_UNITS)
	if (not u) or u <= 0 then
		-- auto：鼠标坐标系（本机实测宽 1280）× 与 GUI 视口宽的比例
		-- （视口 640x360 ⇒ 系数 2；视口 1280x720 ⇒ 系数 1）
		local sw = screen_dims()
		u = 1280 / ((sw and sw > 0) and sw or 640)
	end
	if mouse_ratio_logged ~= u then
		mouse_ratio_logged = u
		local sw, sh = screen_dims()
		LOG(string.format("鼠标坐标换算：%s（GUI 视口 %sx%s ⇒ 鼠标单位 ÷ %.3f = GUI 单位）",
			(tonumber(CFG.GUI_MOUSE_UNITS) and "来自配置") or "auto", tostring(sw), tostring(sh), u))
	end
	return mx / u, my / u
end

-- 配置位置 → GUI 单位。GUI_ANCHOR=left 时 x 是文字左边缘，=center 时是文字水平中心；y 都是文字顶边
local function hit_width(tm, text)
	-- 判定框宽度：GUI_HIT_W=auto 时按『文字高 × 字符数』估算。
	-- 因为 GuiGetTextDimensions 对中文给的宽度偏大（实测"回溯"报 34 单位，而实际渲染约 17 单位 = 2×8.5），
	-- 直接用它会得到一个差不多两倍宽的热区（用户反馈"横向检测框太大"就是这个原因）。
	if CFG.GUI_HIT_W ~= "auto" then
		local n = tonumber(CFG.GUI_HIT_W)
		if n and n > 0 then return n end
	end
	local chars = 0
	for _ in tostring(text or "回溯"):gmatch("[^\128-\191]") do chars = chars + 1 end
	return (tm.h or 9) * math.max(1, chars)
end

local function button_rect(sw, sh, tm, text)
	local vw, vh = sw or 640, sh or 360
	local x = tonumber(CFG.GUI_X) or 50
	local y = tonumber(CFG.GUI_Y) or 70.33
	if CFG.GUI_UNIT ~= "pixel" then
		x = x / 100 * vw
		y = y / 100 * vh
	end
	local h = tm.h or 9
	-- 绘制用的宽度：沿用上一版（GuiGetTextDimensions 的值）⇒ 显示位置与你调好的那一帧完全一致
	local w_draw = tm.w or hit_width(tm, text)
	-- 判定框宽度：中文宽度被引擎报成大约两倍，这里按『字高 × 字符数』收窄（否则热区太宽）
	local w_hit = hit_width(tm, text)
	if CFG.GUI_ANCHOR == "center" then x = x - w_draw / 2 end
	return x, y, w_hit, h, (tonumber(CFG.GUI_HIT_PAD) or 0)
end

-- 显示时机：默认等"死亡后的第一次输入"——引擎的死亡结算界面正是那时才弹出的，
-- 这样按钮和结算界面同时出现（比按固定毫秒猜要准）。DEATH_SHOW_ON=timer 可改回固定延迟。
local key_seen_ms = 0
local death_button_gone = false     -- 当前是否藏着（点结算界面的菜单项时切换）
local death_button_shown_ms = 0

-- ==========================================================================
-- （兜底，只在读不到引擎状态时才用）与结算界面"同生共死"：
-- 结算界面是 C++ 画的、Lua 看不到它，但它的菜单项**只能用鼠标点**，位置固定
-- （2560x1440 截图实测同一列：新游戏 / 保存死亡回放 / 退出）。所以：
--   · 点那个翻页大按钮「你死掉了 - 点击此处查看统计」⇒ 我们的按钮跟着 收起⇄显示 切换
--   · 点『新游戏』『退出』 ⇒ 收起（这时结算界面要走了）
--   · 点别处 ⇒ 不动
-- 位置可在配置里微调：MENU_X / MENU_Y / MENU_H（屏幕百分比）
-- ==========================================================================
local function parse_pct_list(s)
	local t = {}
	for piece in tostring(s or ""):gmatch("[^,]+") do
		local n = tonumber((piece:gsub("%s", "")))
		if n then t[#t + 1] = n end
	end
	return t
end

-- ==========================================================================
-- ★ 强绑定（唯一判据）：直接读引擎里"结算界面当前是哪个页面"的状态变量
--   逆向依据（Ghidra 反编译 noita.exe，函数 FUN_006e51e0 @ 0x006e51e0 = 结算界面绘制函数）：
--     · L231  if (DAT_01207680 == '\0')  → 第一屏：死因 + 一个大按钮 $menugameover_nextbutton
--                                            （汉化词条 = 「你死掉了 - 点击此处查看统计」）
--     · L313  if (DAT_01207680 != '\0') goto …（跳过上面那个大按钮）
--     · L367  DAT_01207680 = '\x01';     → 翻到统计页（玩家按键后引擎自己就会翻，见 L294..L310）
--     · L370+（非 0 分支）L683 / L708 / L734 才画出那一排：
--              $menugameover_newgame = 新游戏 / _savereplay = 保存死亡回放 / _quit = 退出
--     · L163  DAT_0120767c = DAT_0120767c + 1 → 界面每画一帧 +1，界面关掉后停住
--   ⇒ 「那一排三个按钮在屏幕上」== DAT_01207680 != 0 **且** DAT_0120767c 还在动
--     （DAT_01207678 是结算界面 GUI 对象，一并记录下来做诊断）
--   证据：汉化词条取自 1999805551\common_base.csv；日志实测 页面 773 帧=0 → 803 帧=1，
--         帧计数 170/200/230 严格 +1/帧。
-- ==========================================================================
local A_MENU_PAGE = 0x1207680    -- 1 字节：0=第一屏（只有『你死掉了 - 点击此处查看统计』），1=统计页（三按钮那一排）
local A_MENU_GUI  = 0x1207678    -- 4 字节：结算界面 GUI 对象
local A_MENU_TICK = 0x120767c    -- 4 字节：结算界面帧计数器（反编译 L163 每画一帧 +1，开界面时归零）

-- 返回 (page, gui, tick) 或 nil（读不到时）
local function menu_state()
	if REWIND_TEST_MENU_PAGE ~= nil then           -- 干跑用的注入点
		local t = REWIND_TEST_MENU_TICK
		if t == nil then t = (tonumber(REWIND_TEST_MENU_PAGE) == 0) and 0 or 100 end
		return tonumber(REWIND_TEST_MENU_PAGE) or 0, 1, tonumber(t) or 0
	end
	if not (ffi and base_ok()) then return nil end
	local p = BASE + (A_MENU_PAGE - 0x400000)
	local q = BASE + (A_MENU_TICK - 0x400000)
	if not (readable(p, 8) and readable(q, 4)) then return nil end
	local page = ffi.cast("uint8_t*", p)[0]
	local gui = rd32(BASE + (A_MENU_GUI - 0x400000))
	local tick = rd32(q)
	return page, gui, tick
end

-- ★ 结算界面"还在不在"：帧计数器每帧 +1（反编译 L163），界面关掉后它就停住不动了。
--   用它当"那一排三个按钮还在屏幕上"的生命信号：玩家点『新游戏』『退出』离开结算界面后，
--   即使页面字节还没被清零，按钮也不会赖在屏幕上（这才叫同生共死）。
local menu_tick_prev, menu_tick_seen_at, menu_tick_frames = nil, 0, 0
local function menu_tick_alive(tick)
	menu_tick_frames = menu_tick_frames + 1
	if menu_tick_prev == nil or tick ~= menu_tick_prev then
		menu_tick_prev, menu_tick_seen_at = tick, menu_tick_frames
	end
	-- 8 次绘制（约 1/8 秒）内动过就算"还在画"：容错我们的回调与引擎绘制的前后顺序
	return (menu_tick_frames - menu_tick_seen_at) <= 8
end

local menu_page_logged = nil
local function menu_page_now(page, gui, tick)
	if page == nil then
		page, gui, tick = menu_state()
		if page == nil then return nil end
	end
	if menu_page_logged ~= page then
		menu_page_logged = page
		LOG(string.format("★结算界面状态变化：DAT_01207680=%d（0=第一屏，1=三按钮那一排所在的统计页）；DAT_01207678=%s；帧计数=%s",
			page, gui and string.format("0x%x", gui) or "nil", tostring(tick)))
	end
	return page
end

-- ==========================================================================
-- 诊断：把引擎里整块"结算界面状态"打出来（只在死亡界面、每 30 帧一行）
--   序列化块（0x6e9c06 起）把 DeathMatch+0x98… 拷到 0x1207670…，所以两边都看：
--     [A] 0x1207670 .. 0x1207688（全局镜像，FUN_006e51e0 直接读写）
--     [B] DeathMatch+0x98 .. +0xC0（权威状态，结构体里那份）
--   拿几次采样对照"那一排三个按钮在/不在"，就能锁定真正跟随它的字段。
-- ==========================================================================
local function menu_state_dump()
	if CFG.DEBUG_MENU_STATE ~= "on" then return end
	if not (ffi and k32 and base_ok()) then return end
	local function hexat(addr, n)
		if not readable(addr, n) then return "(不可读)" end
		local out = {}
		for i = 0, n - 1 do out[#out + 1] = string.format("%02x", ffi.cast("uint8_t*", addr + i)[0]) end
		return table.concat(out, " ")
	end
	local a1 = hexat(BASE + (0x12075f0 - 0x400000), 0x50)
	local a2 = hexat(BASE + (0x1207640 - 0x400000), 0x50)
	local dm = rd32(BASE + (A_DEATHMATCH - 0x400000))
	local b = "(DeathMatch 不可读)"
	if dm and dm ~= 0 then b = hexat(dm + 0x90, 0x38) end
	LOG("[状态转储] A 0x12075f0.. = " .. a1)
	LOG("[状态转储] A 0x1207640.. = " .. a2)
	LOG("[状态转储] B DM+0x90..  = " .. b)
end

-- 鼠标(GUI 单位)是否落在结算界面的菜单栏上（新游戏 / 保存死亡回放 / 退出那一列）
-- 默认范围（2560x1440 截图实测）：x 45%~55%，y 71%~82%（三行文字 + 行高都在里面）
local function in_menu_column(cx, cy)
	if CFG.MENU_BIND ~= "on" then return false end
	local sw, sh = screen_dims()
	local vw, vh = sw or 640, sh or 360
	local xs = parse_pct_list(CFG.MENU_X)
	local ys = parse_pct_list(CFG.MENU_Y)
	local rh = tonumber(CFG.MENU_H) or 2.4
	if #xs < 2 or #ys < 1 then return false end
	if cx < xs[1] / 100 * vw or cx > xs[2] / 100 * vw then return false end
	local yTop = ys[1] / 100 * vh
	local yBot = (ys[#ys] + rh) / 100 * vh
	return cy >= yTop and cy <= yBot
end

local function any_input_just_down()
	if type(InputIsKeyJustDown) == "function" then
		for code = 4, 230 do
			local ok, d = pcall(InputIsKeyJustDown, code)
			if ok and d then return "键 " .. tostring(code) end
		end
	end
	if type(InputIsMouseButtonJustDown) == "function" then
		for b = 1, 3 do
			local ok, d = pcall(InputIsMouseButtonJustDown, b)
			if ok and d then return "鼠标键 " .. tostring(b) end
		end
	end
	return nil
end

local function death_button_visible()
	if CFG.DEATH_SHOW_ON == "timer" then
		return (tickMs() - death_ms) >= (tonumber(CFG.DEATH_SHOW_DELAY_MS) or 1500)
	end
	if key_seen_ms == 0 then
		local what = any_input_just_down()
		if not what then return false end
		key_seen_ms = tickMs()
		LOG(string.format("死亡后第一次输入（%s）⇒ 引擎的死亡结算界面此时才弹出，按钮跟着一起出现", what))
	end
	return (tickMs() - key_seen_ms) >= (tonumber(CFG.DEATH_SHOW_DELAY_MS) or 250)
end

-- ==========================================================================
-- 可配置的存/读档按键
--   键名 → SDL scancode 的表取自游戏自带的 data/scripts/debug/keycodes.lua（241 个键里挑常用 81 个）
-- ==========================================================================
local KEYCODE_NAMES = {
	["A"]=4,["B"]=5,["C"]=6,["D"]=7,["E"]=8,["F"]=9,["G"]=10,["H"]=11,["I"]=12,["J"]=13,["K"]=14,["L"]=15,["M"]=16,
	["N"]=17,["O"]=18,["P"]=19,["Q"]=20,["R"]=21,["S"]=22,["T"]=23,["U"]=24,["V"]=25,["W"]=26,["X"]=27,["Y"]=28,["Z"]=29,
	["0"]=39,["1"]=30,["2"]=31,["3"]=32,["4"]=33,["5"]=34,["6"]=35,["7"]=36,["8"]=37,["9"]=38,
	["SPACE"]=44,["RETURN"]=40,["ENTER"]=40,["TAB"]=43,["ESCAPE"]=41,["BACKSPACE"]=42,["DELETE"]=76,["INSERT"]=73,
	["HOME"]=74,["END"]=77,["PAGEUP"]=75,["PAGEDOWN"]=78,["LEFT"]=80,["RIGHT"]=79,["UP"]=82,["DOWN"]=81,
	["MINUS"]=45,["EQUALS"]=46,["LEFTBRACKET"]=47,["RIGHTBRACKET"]=48,["BACKSLASH"]=49,["SEMICOLON"]=51,
	["APOSTROPHE"]=52,["COMMA"]=54,["PERIOD"]=55,["SLASH"]=56,["GRAVE"]=53,["CAPSLOCK"]=57,
	["LCTRL"]=224,["RCTRL"]=228,["LSHIFT"]=225,["RSHIFT"]=229,["LALT"]=226,["RALT"]=230,
	["F1"]=58,["F2"]=59,["F3"]=60,["F4"]=61,["F5"]=62,["F6"]=63,["F7"]=64,["F8"]=65,["F9"]=66,["F10"]=67,["F11"]=68,["F12"]=69,
}

local function key_code(s)
	if not s or s == "" then return nil end
	local t = tostring(s):gsub("%s", ""):upper()
	if t == "" or t == "NONE" or t == "OFF" then return nil end
	local n = tonumber(t)
	if n then return math.floor(n) end
	return KEYCODE_NAMES[t]
end

local function key_mod_set(s)
	local m = { ctrl = false, shift = false, alt = false }
	local t = tostring(s or "ctrl"):lower():gsub("%s", "")
	if t == "" or t == "none" then return m end
	for part in t:gmatch("[^+]+") do
		if part == "ctrl" or part == "control" then m.ctrl = true
		elseif part == "shift" then m.shift = true
		elseif part == "alt" then m.alt = true
		end
	end
	return m
end

local hotkey_cache = nil
local hotkey_cache_ms = -100000

local function hotkeys()
	-- 1 秒 TTL：settings.lua 与 init.lua 不保证同一个 Lua state，
	-- 所以不依赖回调，靠定时重读保证"改完最多 1 秒生效"
	if hotkey_cache and (tickMs() - hotkey_cache_ms) < SETTINGS_TTL_MS then return hotkey_cache end
	-- 优先用游戏内 Mod 设置里的值；取不到才回落到 rewind_config.txt 的 KEY_* 后备值
	local saveS, rewindS, modS = CFG.KEY_SAVE, CFG.KEY_REWIND, CFG.KEY_MOD
	local src = "配置文件(后备)"
	local v_save = setting_raw("key_save")
	local v_rew = setting_raw("key_rewind")
	local v_mod = setting_raw("key_mod")
	if type(v_save) == "string" and v_save ~= "" then saveS = v_save end
	if type(v_rew) == "string" and v_rew ~= "" then rewindS = v_rew end
	if type(v_mod) == "string" and v_mod ~= "" then modS = v_mod end
	if type(v_save) == "string" or type(v_rew) == "string" or type(v_mod) == "string" then
		src = "游戏内 Mod 设置"
	end
	local h = {
		save = key_code(saveS) or KEYCODE_NAMES["S"],
		rewind = key_code(rewindS) or KEYCODE_NAMES["Z"],
		mods = key_mod_set(modS),
		save_raw = tostring(saveS), rewind_raw = tostring(rewindS), mod_raw = tostring(modS), src = src,
	}
	hotkey_cache, hotkey_cache_ms = h, tickMs()
	LOG(string.format("热键已生效（来源：%s）：%s（+%s）记录存档点 / %s（+%s）回溯 ⇒ 键码 %d / %d；修饰键 ctrl=%s shift=%s alt=%s",
		h.src, h.save_raw, h.mod_raw, h.rewind_raw, h.mod_raw, h.save, h.rewind,
		tostring(h.mods.ctrl), tostring(h.mods.shift), tostring(h.mods.alt)))
	if h.mods.ctrl == false and h.mods.shift == false and h.mods.alt == false then
		LOG("  ⚠修饰键设成了 none：这两个键会直接生效，注意别和游戏本身的操作冲突")
	end
	return h
end

local function mods_down(m)
	if m.ctrl and not (InputIsKeyDown(224) or InputIsKeyDown(228)) then return false end
	if m.shift and not (InputIsKeyDown(225) or InputIsKeyDown(229)) then return false end
	if m.alt and not (InputIsKeyDown(226) or InputIsKeyDown(230)) then return false end
	return true
end

local function death_ctx_note(where)
	if where == "world" then death_world_frames = death_world_frames + 1
	else death_pause_frames = death_pause_frames + 1 end
	if death_ctx_logged then return end
	if death_world_frames >= 3 or death_pause_frames >= 3 then
		death_ctx_logged = true
		LOG(string.format("死亡后回调诊断：世界更新回调 %d 帧 / 暂停回调 %d 次 ⇒ %s",
			death_world_frames, death_pause_frames,
			(death_world_frames >= 3) and "世界仍在更新（死亡界面没有停世界）"
				or "世界已停更（只有暂停回调在跑）"))
	end
end

local function draw_death_button(where)
	if not (died and mod_enabled()) then return end

	-- ★★★ 强绑定（唯一判据）：直接读引擎状态，跟着「新游戏 / 保存死亡回放 / 退出」那一排走
	--     逆向依据（Ghidra 反编译 noita.exe，FUN_006e51e0 = 结算界面绘制函数）：
	--       · L231  if (DAT_01207680 == '\0') → 第一屏：死因 + 一个大按钮
	--                 $menugameover_nextbutton（中文「你死掉了 - 点击此处查看统计」），**没有那一排**
	--       · L313  if (DAT_01207680 != '\0') goto …（跳过上面那个大按钮）
	--       · L367  DAT_01207680 = '\x01'       → 翻到统计页
	--       · L370+（非 0 分支）的 L683 / L708 / L734 才画出
	--                 $menugameover_newgame（新游戏）/ _savereplay（保存死亡回放）/ _quit（退出）
	--       · L163  DAT_0120767c = DAT_0120767c + 1 → 界面每画一帧 +1，界面关掉后停住
	--     ⇒ 「那一排三个按钮在屏幕上」== 页面字节非 0 **且** 帧计数器还在动。
	--       读得到引擎状态时，"等第一次输入 + 延迟"和"按点击位置猜"这些兜底判据一律不参与，
	--       按钮的出现/消失与那一排严格同一帧（这才叫强绑定）。
	local page, menu_gui, menu_tick = menu_state()
	local engine_bound = false
	if page ~= nil then
		engine_bound = true
		menu_page_now(page, menu_gui, menu_tick)
		local alive = true
		if menu_tick ~= nil then alive = menu_tick_alive(menu_tick) end
		local want_hidden
		if CFG.BIND_MODE == "always" then
			want_hidden = not alive
		else
			want_hidden = (page == 0) or (not alive)
		end
		if want_hidden ~= death_button_gone then
			death_button_gone = want_hidden
			LOG(string.format("结算界面状态 DAT_01207680=%d（帧计数=%s，还在画=%s）⇒ %s『回溯』按钮（%s）",
				page, tostring(menu_tick), alive and "是" or "否",
				want_hidden and "收起" or "显示",
				want_hidden and ((not alive) and "结算界面已经不在画了" or "三按钮那一排还没出现/已消失")
					or "三按钮那一排在屏幕上"))
		end
		if death_button_gone then return end
	else
		-- 读不到引擎状态时的兜底：等死亡后的第一次输入 + 延迟
		if not death_button_visible() then return end
	end
	if not gui then
		local okg, g = pcall(GuiCreate)
		if okg and g then gui = g; LOG("GUI 句柄在世界里补建成功（死亡界面按钮）") end
	end
	if not gui then return end
	-- 同一帧里两个回调都可能被调用，避免同一帧里 GuiStartFrame 两次。
	-- 判据必须同时满足"帧号相同"且"落在同一个 GetTickCount tick（~15.6ms 粒度）"。
	local now, fnow = tickMs(), frame_no()
	if fnow == gui_drawn_frame and now == gui_drawn_ms then return end
	gui_drawn_frame, gui_drawn_ms = fnow, now

	local sw, sh = screen_dims()
	local tm = text_metrics(sh)
	local xu, yu, w, h, pad = button_rect(sw, sh, tm, "回溯")

	-- 自己判定悬停/点击：判定框 = 文字矩形 ±GUI_HIT_PAD 个 GUI 单位（默认 1 单位 = 4px，很小）
	local over, clicked = false, false
	local mx, my = mouse_pos()
	local click_just = false
	if type(InputIsMouseButtonJustDown) == "function" then
		local okj, jd = pcall(InputIsMouseButtonJustDown, 1)
		click_just = (okj and jd) and true or false
	end
	local cx, cy = nil, nil
	if mx then
		cx, cy = mouse_to_gui(mx, my)
		over = (cx >= xu - pad) and (cx <= xu + w + pad) and (cy >= yu - pad) and (cy <= yu + h + pad)
		if over and click_just then clicked = true end
	end

	-- 兜底判据（只在读不到引擎状态时用）：那一排只能用鼠标点，点了就切一次
	if (not engine_bound) and click_just and (not over) and cx and death_draw_frames > 0
		and (tickMs() - death_button_shown_ms) > 400 and in_menu_column(cx, cy) then
		death_button_gone = not death_button_gone
		LOG("（兜底）点击了结算界面的菜单栏 ⇒ 『回溯』按钮" ..
			(death_button_gone and "跟着收起" or "跟着重新显示"))
	end

	if death_button_gone then return end     -- 与结算界面一起藏起来

	-- ★ 本局有没有有效存档点：没有就按设置变灰/隐藏（绝不让它回溯到上一局）
	local runOk, runWhy = current_run_check()
	local dimmed = not runOk
	if dimmed and CFG.BANNER == "hide" then
		if not death_draw_logged then
			death_draw_logged = true
			LOG("本局没有存档点 ⇒ 按钮不显示（banner=hide）：" .. tostring(runWhy))
		end
		return
	end

	local cr, cg, cb, ca = parse_color(CFG.GUI_COLOR)
	local ok, err = pcall(function()
		GuiStartFrame(gui)
		if cr then
			if dimmed then
				-- 无效化：压暗成灰色，且不接受点击
				pcall(GuiColorSetForNextWidget, gui, cr * 0.45, cg * 0.45, cb * 0.45, ca * 0.8)
			else
				-- ★ 悬停状态翻转时记一行（排查"命中框对不对"用；只翻转时写，不刷屏）
				if hover_logged ~= over then
					hover_logged = over
					LOG(string.format("按钮悬停状态：over=%s（鼠标 GUI=(%s,%s)；按钮矩形 x=%s..%s y=%s..%s pad=%s）",
						tostring(over), tostring(cx and round2(cx) or "?"), tostring(cy and round2(cy) or "?"),
						tostring(round2(xu)), tostring(round2(xu + w)), tostring(round2(yu)), tostring(round2(yu + h)), tostring(pad)))
				end
				-- ★ 两档颜色由我们自己切（不依赖引擎的高亮）：
				--   未选中 = GUI_COLOR（默认 #d0cfcd，引擎菜单项同色）
				--   选中   = GUI_COLOR_HOVER（默认 #fefdad）
				local hr, hg, hb, ha = parse_color(CFG.GUI_COLOR_HOVER)
				if over and hr then
					pcall(GuiColorSetForNextWidget, gui, hr, hg, hb, ha)
				else
					pcall(GuiColorSetForNextWidget, gui, cr, cg, cb, ca)
				end
			end
		end
		GuiText(gui, xu, yu, "回溯", tm.scale)
	end)
	if not ok then
		if not death_draw_logged then
			death_draw_logged = true
			LOG("★死亡界面按钮绘制失败：" .. tostring(err))
		end
		return
	end
	death_ctx_note(where)
	if death_draw_frames % 30 == 0 then menu_state_dump() end

	if clicked and not dimmed then on_death_button_click() end

	if death_draw_frames == 0 then death_button_shown_ms = tickMs() end
	death_draw_frames = death_draw_frames + 1
	if death_draw_frames % 300 == 0 then
		LOG(string.format("死亡界面按钮仍在绘制（第 %d 次，帧 %d，GUI_X=%s%% GUI_Y=%s%%）",
			death_draw_frames, fnow, tostring(CFG.GUI_X), tostring(CFG.GUI_Y)))
	end

	if not death_draw_logged then
		death_draw_logged = true
		LOG(string.format("死亡界面按钮『回溯』已绘制（GuiText 绝对坐标）：GUI 单位 x=%.2f y=%.2f 判定框宽%.1f 高%.1f 字号%.3f 回调=%s",
			xu, yu, w, h, tm.scale, where))
		LOG(string.format("   GUI_X=%s%%（锚点 %s）GUI_Y=%s%% ⇒ 文字左边缘 x=%.2f 单位、顶边 y=%.2f 单位；判定框再外扩 %s 单位（%s px）",
			tostring(CFG.GUI_X), CFG.GUI_ANCHOR, tostring(CFG.GUI_Y), xu, yu, tostring(pad), tostring(pad * 4)))
		LOG("   引擎菜单项是 C++ 画的（无 Lua 布局可加入），但同一套 GUI 单位 + 像素字体 ⇒ 对齐到整数单位就等于对齐它")
	end
end

-- 键盘微调的步长按"引擎最小格"来算：
--   引擎的控件坐标是 GUI 单位（本机视口 640x360），1 单位 = 4 屏幕像素（2560x1440）；
--   比 1 单位更小的位移**渲染不出来**（会累积几次才跳一格，手感很怪）。
--   GUI_STEP_UNIT=gui 时 GUI_STEP 表示"多少个 GUI 单位"（默认 1 = 每按必动一格，这也是最细）；
--   GUI_STEP_UNIT=percent 时 GUI_STEP 直接当百分比用（老行为）。
local function nudge_units()
	if InputIsKeyDown(225) or InputIsKeyDown(229) then
		return tonumber(CFG.GUI_STEP_COARSE) or 4
	end
	return tonumber(CFG.GUI_STEP) or 1
end

-- 把"多少个 GUI 单位"换算成当前配置单位下的位移（percent 模式要按视口宽/高换算，两轴不同）
local function step_delta(units, horizontal)
	if CFG.GUI_STEP_UNIT == "percent" then return units end
	if CFG.GUI_UNIT == "pixel" then return units end
	local sw, sh = screen_dims()
	local vpix = horizontal and (sw or 640) or (sh or 360)
	return units * 100 / vpix
end

local function nudge(axis_x, sign)
	local units = nudge_units()
	local d = step_delta(units, axis_x) * sign
	local nx = (tonumber(CFG.GUI_X) or 50) + (axis_x and d or 0)
	local ny = (tonumber(CFG.GUI_Y) or 68.5) + (axis_x and 0 or d)
	-- 吸附到整数 GUI 单位：这样每次按键都落在引擎格子上，位置可预测、可复现、也方便我们写死默认值
	local snapped = "off"
	if CFG.GUI_SNAP == "gui" then
		local sw, sh = screen_dims()
		local vw, vh = sw or 640, sh or 360
		if CFG.GUI_UNIT == "pixel" then
			nx, ny = math.floor(nx + 0.5), math.floor(ny + 0.5)
		else
			nx = math.floor(nx / 100 * vw + 0.5) / vw * 100
			ny = math.floor(ny / 100 * vh + 0.5) / vh * 100
		end
		snapped = "gui"
	end
	LOG(string.format("键盘微调：%s %s 个 GUI 单位（吸附=%s）⇒ GUI_X=%s GUI_Y=%s",
		axis_x and "左右" or "上下", tostring(units), snapped,
		tostring(round2(nx)), tostring(round2(ny))))
	update_config_xy(nx - (tonumber(CFG.GUI_X) or 50), ny - (tonumber(CFG.GUI_Y) or 68.5))
end


-- ==========================================================================
-- 文件触发（兜底）
-- ==========================================================================
local function file_marker_trigger()
	-- 触发文件放在新数据目录里；老的 mods\\ 位置仍然认（兼容）
	for _, root in ipairs({ DATA_DIR, MOD_DIR }) do
		if root then
			if file_sig(root .. "\\RUN_REWIND.txt") then return "rewind", root .. "\\RUN_REWIND.txt" end
			if file_sig(root .. "\\RUN_CHECKPOINT.txt") then return "checkpoint", root .. "\\RUN_CHECKPOINT.txt" end
		end
	end
	return nil
end

-- ==========================================================================
-- 回调
-- ==========================================================================
local last_frame = -1
local ready_frame = 0
local seen_keys = {}
local announced_ready = false
local self_test_pending = false   -- 自检延后到世界起来之后跑（见 run_deferred_self_test）
local hook_install_tried = false  -- 重启钩子改成"要回溯时才装"（见 execute_rewind）

-- ==========================================================================
-- 开机自检：把所有"跨函数调用"的路径都空跑一遍。
-- 起因：Lua 的 local function 必须"先声明后使用"，否则运行时会被当成全局 nil
-- （本项目已经栽过两次：dir_of / screen_dims 被定义在其调用点之后）。
-- ==========================================================================
local function self_test()
	local checks = {
		{ "mod_enabled", function() return mod_enabled() end },
		{ "world_seed_str", function() return world_seed_str() end },
		{ "dir_of", function() return dir_of(CFG.SNAP_DIR) end },
		{ "read_run_info", function() return read_run_info(".") end },
		{ "snapshot_run_ok", function() return snapshot_run_ok(".") end },
		{ "current_run_check", function() return current_run_check() end },
		{ "hotkeys", function() return hotkeys() end },
		{ "mods_down", function() return mods_down(hotkeys().mods) end },
		{ "screen_dims", function() return screen_dims() end },
		{ "text_metrics", function() local ok2, m = pcall(text_metrics, 360); return m end },
		{ "button_rect", function() local ok2, m = pcall(text_metrics, 360); return button_rect(640, 360, m or {}, "回溯") end },
		{ "mouse_to_gui", function() return mouse_to_gui(100, 100) end },
		{ "save_xy_to_config(空跑)", function()
			local old = CFG_PATH
			CFG_PATH = nil
			save_xy_to_config()
			CFG_PATH = old
		end },
	}
	local bad = 0
	for _, c in ipairs(checks) do
		local ok, err = pcall(c[2])
		if not ok then
			bad = bad + 1
			LOG("★自检失败：" .. c[1] .. " ⇒ " .. tostring(err))
		end
	end
	LOG(string.format("自检完成：%d 项，失败 %d 项", #checks, bad))
	return bad
end

function OnModPreInit()
	init_win32()
	init_paths()
	-- 干跑挂钩：只读测试用（正常游戏里 REWIND_TEST_LATCH 为 nil，不会执行；只是比一个全局变量）
	if REWIND_TEST_LATCH == true then
		clear_mods_changed_latch("干跑")
		latch_watch_until = frame_no() + 10
	end
	LOG("")
	LOG("=== Noita Rewind 载入 === PID=" .. tostring(pid()) .. " 墙钟 ms=" .. tostring(tickMs()))
	LOG("本进程命令行 = " .. tostring(wide_to_ascii(k32 and k32.GetCommandLineW and k32.GetCommandLineW(), 4096) or "?"))
	LOG("io=" .. tostring(io_lib ~= nil) .. " ffi=" .. tostring(ffi ~= nil) .. " bit=" .. tostring(bit ~= nil)
		.. " | API: frame=" .. tostring(has_frame_api) .. " print=" .. tostring(has_gameprint) .. " input=" .. tostring(has_input))
	LOG("API 诊断：EntityGetWithTag=" .. type(EntityGetWithTag)
		.. "  GameGetPlayerStatsEntity=" .. type(GameGetPlayerStatsEntity)
		.. "  GuiCreate=" .. type(GuiCreate) .. "  GuiGetScreenDimensions=" .. type(GuiGetScreenDimensions))
	LOG("GAME_DIR=" .. tostring(GAME_DIR) .. "  MOD_DIR=" .. tostring(MOD_DIR) .. "  SAVE_ROOT=" .. tostring(SAVE_ROOT))
	LOG("★ 按钮位置就存在这个文件里： " .. tostring(CFG_PATH) .. "  （键名 GUI_X / GUI_Y）")
	load_config()
	LOG("构建标记 = " .. BUILD_TAG)
	LOG(string.format("生效中的界面设置：GUI_X=%s%%（锚点 %s）GUI_Y=%s%% 单位=%s 字号=%s 颜色=%s",
		CFG.GUI_X, CFG.GUI_ANCHOR, CFG.GUI_Y, CFG.GUI_UNIT, CFG.GUI_SCALE, CFG.GUI_COLOR))
	LOG(string.format("                   键盘步长=%s 格／粗调 %s 格 出现=%s（延迟 %s ms）",
		CFG.GUI_STEP, CFG.GUI_STEP_COARSE, CFG.DEATH_SHOW_ON, CFG.DEATH_SHOW_DELAY_MS))
	LOG(string.format("                   鼠标单位换算=%s 点击框外扩=%s 点击框宽度=%s 吸附=%s",
		CFG.GUI_MOUSE_UNITS, CFG.GUI_HIT_PAD, CFG.GUI_HIT_W, CFG.GUI_SNAP))
	LOG("配置：ENABLE=" .. CFG.ENABLE .. " RESTORE_FROM=" .. CFG.RESTORE_FROM
		.. " SNAP_DIR=" .. CFG.SNAP_DIR .. " AUTO_DIR=" .. CFG.AUTO_DIR)
	pcall(function() gui = GuiCreate() end)
	LOG("死亡界面按钮 GUI = " .. tostring(gui ~= nil))
	if type(REWIND_TEST_SPAWN) == "string" then spawn_hook_selftest(REWIND_TEST_SPAWN) end   -- 干跑专用
	-- ★ 这里**只做**和 rewind_v3restored 一模一样的事（load_config → GuiCreate → handle_pending）。
	--   自检和重启钩子都挪到世界起来之后 / 真正要回溯的那一刻才做：
	--   他们是"新进程铺档进世界"之前唯一多出来的动作，而实测 v3 的新进程必崩、restored 的不崩，
	--   所以先把这两个动作从"进世界之前"挪走，让新进程的启动路径与可用版完全一致。
	handle_pending()   -- ★ 关键：在世界加载之前处理跨进程标记（必须留在最前面）
end

function OnWorldInitialized()
	LOG("=== OnWorldInitialized ===  PID=" .. tostring(pid()) .. " 墙钟 ms=" .. tostring(tickMs()))
	load_config()
	died = false
	self_test_pending = true     -- 自检改到世界起来之后跑（见 OnWorldPostUpdate）
end

-- 世界起来之后的第一次更新里做自检（原来是 mod 初始化时做，新进程进世界之前做会碰 GUI 接口）
local function run_deferred_self_test()
	if not self_test_pending then return end
	self_test_pending = false
	self_test()
end

function OnPlayerSpawned(entity)
	local delay = tonumber(CFG.DELAY_FRAMES) or 300
	ready_frame = frame_no() + delay
	announced_ready = false
	died = false
	player_entity_cached = tonumber(entity) or player_entity_cached
	LOG("玩家实体 = " .. tostring(entity) .. " 墙钟 ms=" .. tostring(tickMs())
		.. string.format("；按键/文件触发门槛 = 第 %d 帧", ready_frame))
	-- 进入世界时不弹提示（你要求：安静启动）
end

function OnPlayerDied(entity)
	LOG("★ 玩家死亡 player_entity=" .. tostring(entity) .. "（死亡界面按钮已就绪）")
	died = true
	death_ms = tickMs()
	key_seen_ms = 0
	death_button_gone = false
	death_button_shown_ms = 0
	death_draw_logged = false
	death_ctx_logged = false
	death_draw_frames = 0
	death_world_frames = 0
	death_pause_frames = 0
	gui_drawn_ms = -100000
	gui_drawn_frame = -1
	invalidate_run_check()     -- 死亡时重新判定"这个存档点是不是本局的"
end

-- 世界停更时（死亡界面/暂停）这个回调仍会被调用；只做两件事：
--   1) 画『回溯』按钮（GUI 绘制在暂停时是引擎允许的：模组设置界面就画在暂停菜单里）
--   2) 读按键（微调位置 / Ctrl+Z）
-- 引擎转场只有在 DEATH_EXEC_IN_PAUSE=on 且世界确实停更时才在这里兜底调用
function OnPausePreUpdate()
	if not died then return end
	local ok_draw, err_draw = pcall(draw_death_button, "pause")
	if not ok_draw then LOG("★死亡界面按钮绘制出错（已忽略，不影响游戏）：" .. tostring(err_draw)) end

	if rewind_pending_frame > 0 then
		if CFG.DEATH_EXEC_IN_PAUSE ~= "on" then
			LOG("★世界已停更（只有暂停回调）：DEATH_EXEC_IN_PAUSE=off ⇒ 不在这里调用引擎转场")
			rewind_pending_frame = 0
			rewind_pending_ms = 0
			NOTICE("世界已暂停，无法回溯（DEATH_EXEC_IN_PAUSE=off）")
		elseif tickMs() >= rewind_pending_ms + 1500 then
			LOG("★世界已停更（未收到世界更新回调）⇒ 在暂停回调里执行回溯转场")
			execute_rewind("暂停回调（死亡界面）")
		end
	end

	if not has_input then return end
	local ok, err = pcall(function()
		local hk = hotkeys()
		if not mods_down(hk.mods) then return end
		if InputIsKeyJustDown(80) then nudge(true, -1)
		elseif InputIsKeyJustDown(79) then nudge(true, 1)
		elseif InputIsKeyJustDown(82) then nudge(false, -1)
		elseif InputIsKeyJustDown(81) then nudge(false, 1)
		elseif hk.save > 0 and InputIsKeyJustDown(hk.save) then do_checkpoint()
		elseif hk.rewind > 0 and InputIsKeyJustDown(hk.rewind) then do_rewind()
		end
	end)
	if not ok then LOG("★暂停回调里的按键处理出错（已忽略）：" .. tostring(err)) end
end

function OnWorldPostUpdate()
	local f = frame_no()
	if f == last_frame then return end
	last_frame = f

	-- ★ v7.6 区块加载重试：守住 +0x458，一旦非 0 就调 FUN_0073DAB0(obj=*(session+0x10)+0x500, 矩形)
	if CFG._ra_until ~= nil and CFG._ra_until > 0 then
		if tickMs() > CFG._ra_until then
			LOG(string.format("   · 区块加载重试：超时（试了 %d 帧，守卫始终为 0）⇒ 放弃", CFG._ra_tries or 0))
			CFG._ra_until = 0
		elseif base_ok() then
			local s2 = rd32(BASE + (0x122374C - 0x400000))
			local w2 = (s2 ~= nil and s2 ~= 0 and readable(s2, 0x98)) and rd32(s2 + 0x10) or nil
			local o2 = (w2 ~= nil and w2 ~= 0 and readable(w2, 0x504)) and (w2 + 0x500) or nil
			if o2 ~= nil then
				local g2 = rd32(o2 + 0x458)
				CFG._ra_tries = (CFG._ra_tries or 0) + 1
				if (CFG._ra_tries <= 3) or (CFG._ra_tries % 120 == 0) then
					LOG(string.format("   · 区块加载重试[%d]：obj=0x%X 守卫(+0x458)=0x%s",
						CFG._ra_tries, o2, g2 and string.format("%X", g2) or "nil"))
				end
				if g2 ~= nil and g2 ~= 0 then
					local r2 = CFG._ra_rect
					local rect2 = ffi.new("int[4]", { r2[1], r2[2], r2[3], r2[4] })
					local okc2, errc2 = pcall(function()
						ffi.cast("void(__fastcall*)(void*, int, int*)", BASE + (0x73DAB0 - 0x400000))(
							ffi.cast("void*", o2), 0, rect2)
					end)
					LOG(string.format("   · 区块加载重试[%d]：守卫=0x%X 非 0 ⇒ 已调用 FUN_0073DAB0(obj=0x%X, 矩形=%d,%d %dx%d) ⇒ %s%s",
						CFG._ra_tries, g2, o2, rect2[0], rect2[1], rect2[2], rect2[3],
						tostring(okc2), okc2 and "" or ("  错误: " .. tostring(errc2))))
					CFG._ra_until = 0
				end
			end
		end
	end

	-- ★ v4：存档后看护（引擎在写盘返回后的下一帧才置闩锁，所以要看护一小段时间）
	if latch_watch_until > 0 then
		if f <= latch_watch_until then
			clear_mods_changed_latch("存档后看护", true)
		else
			latch_watch_until = -1
			LOG(string.format("闩锁看护结束（frame=%d）", f))
		end
	end

	if heartbeat_until > 0 and f >= heartbeat_next and f <= heartbeat_until then
		heartbeat_next = f + 60
		LOG(string.format("心跳：世界仍在运行 frame=%d PID=%d", f, pid()))
		if f >= heartbeat_until then LOG("心跳结束") end
	end

	local ok_draw, err_draw = pcall(draw_death_button, "world")
	if not ok_draw then LOG("★死亡界面按钮绘制出错（已忽略，不影响游戏）：" .. tostring(err_draw)) end

	run_deferred_self_test()   -- 世界已经起来 ⇒ 这里跑自检（含 GUI 接口探测）

	-- ★ 存档点的镜像：等写盘落完（.autosave* 消失 + 区块文件数不再变）后立刻镜像
	if pending_checkpoint then
		local p = pending_checkpoint
		local n = world_files_stat(p.slotPath)
		local marker = file_sig(p.slotPath .. "\\world\\.autosave") ~= nil
		if marker or n ~= p.last_count then
			p.last_count = n                      -- 还在写：把"安静截止时间"往后推
			p.settle_until = tickMs() + 400
		end
		if tickMs() >= p.settle_until or tickMs() >= p.deadline then
			local timed_out = (tickMs() >= p.deadline) and (tickMs() < p.settle_until)
			pending_checkpoint = nil
			finish_checkpoint_mirror(p.slot, p.slotPath, p.t0, timed_out)
			busy = false
		end
	end

	-- "准备回溯"提示之后等待约 0.75 秒，再真正执行转场
	if rewind_pending_frame > 0 and (f >= rewind_pending_frame or tickMs() >= rewind_pending_ms) then
		execute_rewind("世界更新回调")
	end

	if f < ready_frame then return end
	if not announced_ready then
		announced_ready = true
		local hk = hotkeys()
		LOG(string.format("已达门槛：可按 %s+%s 记录存档点 / %s+%s 回溯，或在 mod 目录放 RUN_CHECKPOINT.txt / RUN_REWIND.txt",
			tostring(CFG.KEY_MOD), hk.save_raw, tostring(CFG.KEY_MOD), hk.rewind_raw))
	end

	local kind, path = file_marker_trigger()
	if kind then
		LOG("检测到文件触发：" .. tostring(path) .. " ⇒ 执行 " .. kind)
		remove_file(path)
		if kind == "rewind" then do_rewind() else do_checkpoint() end
		return
	end

	if not has_input then return end
	local ok, err = pcall(function()
		local hk = hotkeys()
		local mods = mods_down(hk.mods)
		if mods and hk.save > 0 and InputIsKeyJustDown(hk.save) then
			do_checkpoint()
		elseif mods and hk.rewind > 0 and InputIsKeyJustDown(hk.rewind) then
			do_rewind()
		elseif died and mods then
			-- 死亡界面：用 Ctrl+方向键微调『回溯』按钮位置（左80 右79 上82 下81）
			-- 步长 = GUI_STEP 个 GUI 单位（引擎最小格）；加 Shift 用 GUI_STEP_COARSE
			if InputIsKeyJustDown(80) then nudge(true, -1)
			elseif InputIsKeyJustDown(79) then nudge(true, 1)
			elseif InputIsKeyJustDown(82) then nudge(false, -1)
			elseif InputIsKeyJustDown(81) then nudge(false, 1)
			end
		end
		if CFG.LOG_KEYS == "on" then
			for code = 1, 88 do
				if not seen_keys[code] and InputIsKeyJustDown(code) then
					seen_keys[code] = true
					LOG(string.format("键位诊断：收到 scancode=%d（Ctrl 是否按下=%s）", code, tostring(ctrl)))
				end
			end
		end
	end)
	if not ok then
		has_input = false
		LOG("★输入 API 调用失败，已停用按键（文件触发仍可用）：" .. tostring(err))
	end
end














