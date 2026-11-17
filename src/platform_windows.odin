#+build windows
package SteamBuildPusher

import "core:fmt"
import os "core:os"
import "core:strings"
import win "core:sys/windows"
import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// Platform constants
// ---------------------------------------------------------------------------

SEP :: "\\"
OTHER_SEP :: "/"
CURL :: "curl.exe"
STEAMCMD_EXE :: "steamcmd.exe"
STEAMCMD_HINT :: `C:\steamcmd\steamcmd.exe`
MOD_KEY_NAME :: "Ctrl"

FONTS_REGULAR := []cstring{"C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/arial.ttf"}
FONTS_SEMIBOLD := []cstring{"C:/Windows/Fonts/seguisb.ttf", "C:/Windows/Fonts/segoeuib.ttf", "C:/Windows/Fonts/arialbd.ttf"}
FONTS_MONO := []cstring{"C:/Windows/Fonts/CascadiaMono.ttf", "C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/cour.ttf"}

mod_key_down :: proc() -> bool {
	return rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
}

// Config, steamcmd\ and steam_build\ live next to the exe.
app_data_dir :: proc() -> string {
	dir, err := os.get_executable_directory(context.allocator)
	return dir if err == nil else "."
}

steamcmd_candidates :: proc() -> []string {
	@(static) paths := [?]string{`C:\steamcmd\steamcmd.exe`, `C:\SteamCMD\steamcmd.exe`, `C:\Program Files\steamcmd\steamcmd.exe`}
	return paths[:]
}

// Uses curl.exe + tar.exe that ship with Windows 10/11.
steamcmd_install_steps :: proc(dir: string) -> (steps: []Job_Step, exe: string) {
	zip := fmt.tprintf(`%s\steamcmd.zip`, dir)
	exe = fmt.tprintf(`%s\steamcmd.exe`, dir)
	steps = make([]Job_Step, 4, context.temp_allocator)
	steps[0] = {cmd = {"curl.exe", "-f", "-L", "-sS", "--max-time", "120", "-o", zip, "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip"}, workdir = dir, check_exit = true, note = "Downloading steamcmd.zip from Valve…"}
	steps[1] = {cmd = {"tar.exe", "-xf", zip, "-C", dir}, workdir = dir, check_exit = true, note = "Extracting…"}
	steps[2] = {cmd = {"cmd.exe", "/c", "del", "/q", zip}, workdir = dir}
	// First run downloads the rest of steamcmd; it often exits with code 7 after updating, which is fine.
	steps[3] = {cmd = {exe, "+quit"}, workdir = dir, note = "First run: steamcmd updates itself (this can take a minute)…"}
	return
}

// ---------------------------------------------------------------------------
// File / folder pickers (modern IFileOpenDialog)
// ---------------------------------------------------------------------------

com_initialized := false

@(private = "file")
ensure_com :: proc() {
	if !com_initialized {
		win.CoInitializeEx(nil, .APARTMENTTHREADED)
		com_initialized = true
	}
}

// Returns an allocated (context.allocator) path, or "" + false if cancelled.
pick_path :: proc(pick_folder: bool, title: string, filter_name := "", filter_spec := "") -> (path: string, ok: bool) {
	ensure_com()

	dlg: ^win.IFileOpenDialog
	hr := win.CoCreateInstance(
		win.CLSID_FileOpenDialog, nil, win.CLSCTX_INPROC_SERVER,
		win.IID_IFileOpenDialog, cast(^win.LPVOID)&dlg,
	)
	if hr < 0 || dlg == nil do return "", false
	fd := cast(^win.IFileDialog)dlg
	defer dlg.Release(cast(^win.IUnknown)dlg)

	opts: win.FILEOPENDIALOGOPTIONS
	fd.GetOptions(fd, &opts)
	opts |= win.FOS_FORCEFILESYSTEM | win.FOS_PATHMUSTEXIST
	if pick_folder {
		opts |= win.FOS_PICKFOLDERS
	} else {
		opts |= win.FOS_FILEMUSTEXIST
	}
	fd.SetOptions(fd, opts)
	fd.SetTitle(fd, win.utf8_to_wstring(title))

	if !pick_folder && filter_spec != "" {
		specs := [2]win.COMDLG_FILTERSPEC{
			{win.utf8_to_wstring(filter_name), win.utf8_to_wstring(filter_spec)},
			{win.L("All files"), win.L("*.*")},
		}
		fd.SetFileTypes(fd, 2, &specs[0])
	}

	hr = fd.Show(cast(^win.IModalWindow)dlg, nil)
	if hr < 0 do return "", false

	item: ^win.IShellItem
	if fd.GetResult(fd, &item) < 0 || item == nil do return "", false
	defer item.Release(cast(^win.IUnknown)item)

	wpath: win.LPWSTR
	if item.GetDisplayName(item, .FILESYSPATH, &wpath) < 0 || wpath == nil do return "", false
	defer win.CoTaskMemFree(wpath)

	s, err := win.wstring_to_utf8_alloc(win.wstring(wpath), -1, context.allocator)
	if err != nil do return "", false
	return s, true
}

// ---------------------------------------------------------------------------
// Shell helpers
// ---------------------------------------------------------------------------

shell_open :: proc(target: string) {
	win.ShellExecuteW(nil, win.L("open"), win.utf8_to_wstring(target), nil, nil, win.SW_SHOWNORMAL)
}

// Launch an executable in its own visible console window (used for interactive steamcmd login).
launch_console :: proc(exe: string, args: string, workdir: string) -> bool {
	r := win.ShellExecuteW(
		nil, win.L("open"),
		win.utf8_to_wstring(exe),
		win.utf8_to_wstring(args),
		win.utf8_to_wstring(workdir) if workdir != "" else nil,
		win.SW_SHOWNORMAL,
	)
	return uintptr(r) > 32
}

// ---------------------------------------------------------------------------
// Child process with captured stdout+stderr, no console window
// ---------------------------------------------------------------------------

Child :: struct {
	process: win.HANDLE,
	out_read: win.HANDLE,
}

quote_arg :: proc(sb: ^strings.Builder, arg: string) {
	needs := len(arg) == 0 || strings.contains_any(arg, " \t\"")
	if !needs {
		strings.write_string(sb, arg)
		return
	}
	strings.write_byte(sb, '"')
	backslashes := 0
	for i in 0 ..< len(arg) {
		c := arg[i]
		if c == '\\' {
			backslashes += 1
			continue
		}
		if c == '"' {
			for _ in 0 ..< backslashes * 2 + 1 do strings.write_byte(sb, '\\')
		} else {
			for _ in 0 ..< backslashes do strings.write_byte(sb, '\\')
		}
		backslashes = 0
		strings.write_byte(sb, c)
	}
	for _ in 0 ..< backslashes * 2 do strings.write_byte(sb, '\\')
	strings.write_byte(sb, '"')
}

build_command_line :: proc(args: []string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for a, i in args {
		if i > 0 do strings.write_byte(&sb, ' ')
		quote_arg(&sb, a)
	}
	return strings.to_string(sb)
}

child_start :: proc(args: []string, workdir: string) -> (c: Child, ok: bool) {
	sa := win.SECURITY_ATTRIBUTES {
		nLength        = size_of(win.SECURITY_ATTRIBUTES),
		bInheritHandle = true,
	}
	r, w: win.HANDLE
	if !win.CreatePipe(&r, &w, &sa, 0) do return {}, false
	win.SetHandleInformation(r, win.HANDLE_FLAG_INHERIT, 0)

	nul := win.CreateFileW(
		win.L("NUL"), win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE,
		&sa, win.OPEN_EXISTING, 0, nil,
	)

	si := win.STARTUPINFOW {
		cb         = size_of(win.STARTUPINFOW),
		dwFlags    = win.STARTF_USESTDHANDLES,
		hStdInput  = nul,
		hStdOutput = w,
		hStdError  = w,
	}
	pi: win.PROCESS_INFORMATION

	cmdline := win.utf8_to_wstring(build_command_line(args))
	wd: win.LPCWSTR = win.utf8_to_wstring(workdir) if workdir != "" else nil

	created := win.CreateProcessW(
		nil, cmdline, nil, nil, true,
		win.CREATE_NO_WINDOW | win.CREATE_UNICODE_ENVIRONMENT,
		nil, wd, &si, &pi,
	)
	win.CloseHandle(w)
	if nul != win.INVALID_HANDLE_VALUE do win.CloseHandle(nul)

	if !created {
		win.CloseHandle(r)
		return {}, false
	}
	win.CloseHandle(pi.hThread)
	return Child{process = pi.hProcess, out_read = r}, true
}

// Blocking read. Returns 0 when the pipe is closed (child exited).
child_read :: proc(c: ^Child, buf: []u8) -> int {
	n: win.DWORD
	if !win.ReadFile(c.out_read, raw_data(buf), win.DWORD(len(buf)), &n, nil) do return 0
	return int(n)
}

child_wait :: proc(c: ^Child) -> int {
	win.WaitForSingleObject(c.process, win.INFINITE)
	code: win.DWORD
	win.GetExitCodeProcess(c.process, &code)
	return int(code)
}

child_kill :: proc(c: ^Child) {
	if c.process != nil do win.TerminateProcess(c.process, 1)
}

child_close :: proc(c: ^Child) {
	if c.out_read != nil do win.CloseHandle(c.out_read)
	if c.process != nil do win.CloseHandle(c.process)
	c^ = {}
}

// Run a short command synchronously (used by background helper threads).
run_quiet :: proc(args: []string, workdir := "") -> (exit_code: int, ok: bool) {
	c := child_start(args, workdir) or_return
	buf: [4096]u8
	for child_read(&c, buf[:]) > 0 {}
	code := child_wait(&c)
	child_close(&c)
	return code, true
}

// ---------------------------------------------------------------------------
// Local time
// ---------------------------------------------------------------------------

foreign import kernel32_extra "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32_extra {
	GetLocalTime :: proc(st: ^win.SYSTEMTIME) ---
}

// "2026-11-16 14:03", allocated with `allocator`.
local_time_string :: proc(allocator := context.allocator) -> string {
	st: win.SYSTEMTIME
	GetLocalTime(&st)
	return fmt.aprintf("%04d-%02d-%02d %02d:%02d", st.year, st.month, st.day, st.hour, st.minute, allocator = allocator)
}

// ---------------------------------------------------------------------------
// Image decoding via GDI+ (JPG/PNG/BMP/GIF). raylib's bundled stb_image is
// built without JPEG support, so we let Windows decode Steam's header.jpg.
// ---------------------------------------------------------------------------

foreign import gdiplus "system:Gdiplus.lib"

@(private = "file")
GdiplusStartupInput :: struct {
	GdiplusVersion:           u32,
	DebugEventCallback:       rawptr,
	SuppressBackgroundThread: win.BOOL,
	SuppressExternalCodecs:   win.BOOL,
}

@(private = "file")
GpRect :: struct {
	x, y, w, h: i32,
}

@(private = "file")
GpBitmapData :: struct {
	Width:       u32,
	Height:      u32,
	Stride:      i32,
	PixelFormat: i32,
	Scan0:       rawptr,
	Reserved:    uintptr,
}

@(private = "file")
PixelFormat32bppARGB :: 0x26200A

@(default_calling_convention = "system")
@(private = "file")
foreign gdiplus {
	GdiplusStartup :: proc(token: ^uintptr, input: ^GdiplusStartupInput, output: rawptr) -> i32 ---
	GdipCreateBitmapFromFile :: proc(filename: win.wstring, bitmap: ^rawptr) -> i32 ---
	GdipGetImageWidth :: proc(image: rawptr, w: ^u32) -> i32 ---
	GdipGetImageHeight :: proc(image: rawptr, h: ^u32) -> i32 ---
	GdipBitmapLockBits :: proc(bitmap: rawptr, rect: ^GpRect, flags: u32, format: i32, data: ^GpBitmapData) -> i32 ---
	GdipBitmapUnlockBits :: proc(bitmap: rawptr, data: ^GpBitmapData) -> i32 ---
	GdipDisposeImage :: proc(image: rawptr) -> i32 ---
}

@(private = "file")
gdiplus_token: uintptr

// Returns tightly packed RGBA8 pixels allocated with `allocator`.
decode_image_file :: proc(path: string, allocator := context.allocator) -> (pixels: []u8, w, h: int, ok: bool) {
	if gdiplus_token == 0 {
		input := GdiplusStartupInput{GdiplusVersion = 1}
		if GdiplusStartup(&gdiplus_token, &input, nil) != 0 do return
	}
	bmp: rawptr
	if GdipCreateBitmapFromFile(win.utf8_to_wstring(path), &bmp) != 0 || bmp == nil do return
	defer GdipDisposeImage(bmp)

	uw, uh: u32
	GdipGetImageWidth(bmp, &uw)
	GdipGetImageHeight(bmp, &uh)
	if uw == 0 || uh == 0 do return

	rect := GpRect{0, 0, i32(uw), i32(uh)}
	data: GpBitmapData
	if GdipBitmapLockBits(bmp, &rect, 1 /* ImageLockModeRead */, PixelFormat32bppARGB, &data) != 0 do return
	defer GdipBitmapUnlockBits(bmp, &data)

	w, h = int(uw), int(uh)
	pixels = make([]u8, w * h * 4, allocator)
	for y in 0 ..< h {
		row := ([^]u8)(uintptr(data.Scan0) + uintptr(int(data.Stride) * y))
		for x in 0 ..< w {
			s := row[x * 4:]
			d := pixels[(y * w + x) * 4:]
			d[0], d[1], d[2], d[3] = s[2], s[1], s[0], s[3] // BGRA -> RGBA
		}
	}
	return pixels, w, h, true
}
