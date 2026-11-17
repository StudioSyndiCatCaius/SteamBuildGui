#+build darwin
package SteamBuildPusher

import "core:c"
import "core:fmt"
import os "core:os"
import "core:strings"
import "core:sys/posix"
import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// Platform constants
// ---------------------------------------------------------------------------

SEP :: "/"
OTHER_SEP :: "\\"
CURL :: "/usr/bin/curl"
STEAMCMD_EXE :: "steamcmd.sh"
STEAMCMD_HINT :: "~/steamcmd/steamcmd.sh"
MOD_KEY_NAME :: "Cmd"

FONTS_REGULAR := []cstring{"/System/Library/Fonts/Supplemental/Arial.ttf", "/Library/Fonts/Arial.ttf", "/System/Library/Fonts/Helvetica.ttc"}
FONTS_SEMIBOLD := []cstring{"/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/Library/Fonts/Arial Bold.ttf", "/System/Library/Fonts/Helvetica.ttc"}
FONTS_MONO := []cstring{"/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/Monaco.ttf", "/System/Library/Fonts/Supplemental/Courier New.ttf"}

// Cmd for shortcuts (Cmd+S/C/V/A); Option / Ctrl jump by word like other Mac apps.
mod_key_down :: proc() -> bool {
	return rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER) ||
		rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT) ||
		rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
}

home_dir :: proc() -> string {
	h := posix.getenv("HOME")
	return string(h) if h != nil else "/tmp"
}

// Inside an .app bundle the bundle itself must stay untouched (code signing,
// read-only installs), so data goes to ~/Library/Application Support.
// A loose binary (dev builds in bin/) keeps everything next to itself like on Windows.
app_data_dir :: proc() -> string {
	dir, err := os.get_executable_directory(context.allocator)
	if err != nil do dir = "."
	if strings.contains(dir, ".app/Contents/MacOS") {
		delete(dir)
		dir = strings.concatenate({home_dir(), "/Library/Application Support/SteamBuildGui"})
		os.make_directory_all(dir)
	}
	return dir
}

steamcmd_candidates :: proc() -> []string {
	paths := make([]string, 4, context.temp_allocator)
	paths[0] = fmt.tprintf("%s/steamcmd/steamcmd.sh", home_dir())
	paths[1] = fmt.tprintf("%s/Steam/steamcmd/steamcmd.sh", home_dir())
	paths[2] = "/opt/homebrew/bin/steamcmd"
	paths[3] = "/usr/local/bin/steamcmd"
	return paths
}

// Uses the curl + tar that ship with macOS.
steamcmd_install_steps :: proc(dir: string) -> (steps: []Job_Step, exe: string) {
	tgz := fmt.tprintf("%s/steamcmd_osx.tar.gz", dir)
	exe = fmt.tprintf("%s/steamcmd.sh", dir)
	steps = make([]Job_Step, 4, context.temp_allocator)
	steps[0] = {cmd = {CURL, "-f", "-L", "-sS", "--max-time", "120", "-o", tgz, "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz"}, workdir = dir, check_exit = true, note = "Downloading steamcmd_osx.tar.gz from Valve…"}
	steps[1] = {cmd = {"/usr/bin/tar", "-xzf", tgz, "-C", dir}, workdir = dir, check_exit = true, note = "Extracting…"}
	steps[2] = {cmd = {"/bin/rm", "-f", tgz}, workdir = dir}
	// First run downloads the rest of steamcmd; it often exits non-zero after updating, which is fine.
	steps[3] = {cmd = {exe, "+quit"}, workdir = dir, note = "First run: steamcmd updates itself (this can take a minute)…"}
	return
}

// ---------------------------------------------------------------------------
// AppleScript helpers
// ---------------------------------------------------------------------------

@(private = "file")
applescript_quote :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '"')
	for ch in s {
		if ch == '"' || ch == '\\' do strings.write_byte(&sb, '\\')
		strings.write_rune(&sb, ch)
	}
	strings.write_byte(&sb, '"')
	return strings.to_string(sb)
}

@(private = "file")
shell_quote :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "'", `'\''`, context.temp_allocator)
	return fmt.tprintf("'%s'", out)
}

// ---------------------------------------------------------------------------
// File / folder pickers (native NSOpenPanel via osascript)
// ---------------------------------------------------------------------------

// Returns an allocated (context.allocator) path, or "" + false if cancelled.
pick_path :: proc(pick_folder: bool, title: string, filter_name := "", filter_spec := "") -> (path: string, ok: bool) {
	script := fmt.tprintf(
		"POSIX path of (choose %s with prompt %s)",
		"folder" if pick_folder else "file",
		applescript_quote(title),
	)
	out, code, started := run_capture({"/usr/bin/osascript", "-e", script})
	if !started || code != 0 do return "", false
	p := strings.trim_space(out)
	if len(p) > 1 do p = strings.trim_right(p, "/")
	if p == "" do return "", false
	return strings.clone(p), true
}

// ---------------------------------------------------------------------------
// Shell helpers
// ---------------------------------------------------------------------------

shell_open :: proc(target: string) {
	run_quiet({"/usr/bin/open", target})
}

// Opens Terminal.app running the command (used for interactive steamcmd login).
launch_console :: proc(exe: string, args: string, workdir: string) -> bool {
	cmd := fmt.tprintf("%s %s", shell_quote(exe), args)
	if workdir != "" do cmd = fmt.tprintf("cd %s && %s", shell_quote(workdir), cmd)
	script := fmt.tprintf("tell application \"Terminal\"\nactivate\ndo script %s\nend tell", applescript_quote(cmd))
	code, ok := run_quiet({"/usr/bin/osascript", "-e", script})
	return ok && code == 0
}

// ---------------------------------------------------------------------------
// Child process with captured stdout+stderr
// ---------------------------------------------------------------------------

Child :: struct {
	pid:      posix.pid_t,
	out_read: posix.FD,
	open:     bool,
}

build_command_line :: proc(args: []string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for a, i in args {
		if i > 0 do strings.write_byte(&sb, ' ')
		if len(a) == 0 || strings.contains_any(a, " \t\"'$\\") {
			strings.write_string(&sb, shell_quote(a))
		} else {
			strings.write_string(&sb, a)
		}
	}
	return strings.to_string(sb)
}

child_start :: proc(args: []string, workdir: string) -> (ch: Child, ok: bool) {
	if len(args) == 0 do return {}, false
	// Everything the child needs is prepared before fork: no allocation afterwards.
	argv := make([]cstring, len(args) + 1, context.temp_allocator)
	for a, i in args do argv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	wd: cstring = strings.clone_to_cstring(workdir, context.temp_allocator) if workdir != "" else nil

	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK do return {}, false

	pid := posix.fork()
	if pid < 0 {
		posix.close(fds[0])
		posix.close(fds[1])
		return {}, false
	}
	if pid == 0 {
		// Own process group so cancel can kill steamcmd.sh *and* the steamcmd it spawns.
		posix.setpgid(0, 0)
		if wd != nil do posix.chdir(wd)
		devnull := posix.open("/dev/null", {})
		if devnull >= 0 do posix.dup2(devnull, 0)
		posix.dup2(fds[1], 1)
		posix.dup2(fds[1], 2)
		posix.close(fds[0])
		posix.close(fds[1])
		posix.execvp(argv[0], raw_data(argv))
		posix._exit(127)
	}
	posix.close(fds[1])
	return Child{pid = pid, out_read = fds[0], open = true}, true
}

// Blocking read. Returns 0 when the pipe is closed (child exited).
child_read :: proc(ch: ^Child, buf: []u8) -> int {
	for {
		n := posix.read(ch.out_read, raw_data(buf), c.size_t(len(buf)))
		if n < 0 && posix.errno() == .EINTR do continue
		return max(int(n), 0)
	}
}

child_wait :: proc(ch: ^Child) -> int {
	status: c.int
	for {
		r := posix.waitpid(ch.pid, &status, {})
		if r < 0 && posix.errno() == .EINTR do continue
		if r < 0 do return -1
		break
	}
	if posix.WIFEXITED(status) do return int(posix.WEXITSTATUS(status))
	return 128 + int(posix.WTERMSIG(status))
}

child_kill :: proc(ch: ^Child) {
	if ch.open && ch.pid > 0 do posix.killpg(ch.pid, .SIGKILL)
}

child_close :: proc(ch: ^Child) {
	if ch.open do posix.close(ch.out_read)
	ch^ = {}
}

// Run a short command synchronously (used by background helper threads).
run_quiet :: proc(args: []string, workdir := "") -> (exit_code: int, ok: bool) {
	ch := child_start(args, workdir) or_return
	buf: [4096]u8
	for child_read(&ch, buf[:]) > 0 {}
	code := child_wait(&ch)
	child_close(&ch)
	return code, true
}

// Like run_quiet but returns the output (temp allocated).
run_capture :: proc(args: []string, workdir := "") -> (output: string, exit_code: int, ok: bool) {
	ch := child_start(args, workdir) or_return
	out := make([dynamic]u8, context.temp_allocator)
	buf: [4096]u8
	for {
		n := child_read(&ch, buf[:])
		if n <= 0 do break
		append(&out, ..buf[:n])
	}
	code := child_wait(&ch)
	child_close(&ch)
	return string(out[:]), code, true
}

// ---------------------------------------------------------------------------
// Local time
// ---------------------------------------------------------------------------

// "2026-11-16 14:03", allocated with `allocator`.
local_time_string :: proc(allocator := context.allocator) -> string {
	now := posix.time(nil)
	t: posix.tm
	posix.localtime_r(&now, &t)
	return fmt.aprintf("%04d-%02d-%02d %02d:%02d", t.tm_year + 1900, t.tm_mon + 1, t.tm_mday, t.tm_hour, t.tm_min, allocator = allocator)
}

// ---------------------------------------------------------------------------
// Image decoding. raylib's bundled stb_image has no JPEG support, so macOS'
// `sips` converts Steam's header.jpg to a PNG next to it, which raylib loads.
// ---------------------------------------------------------------------------

// Returns tightly packed RGBA8 pixels allocated with `allocator`.
decode_image_file :: proc(path: string, allocator := context.allocator) -> (pixels: []u8, w, h: int, ok: bool) {
	src := path
	lower := strings.to_lower(path, context.temp_allocator)
	if !strings.has_suffix(lower, ".png") {
		png := fmt.tprintf("%s.decoded.png", path)
		code, started := run_quiet({"/usr/bin/sips", "-s", "format", "png", path, "--out", png})
		if !started || code != 0 do return
		src = png
	}
	img := rl.LoadImage(strings.clone_to_cstring(src, context.temp_allocator))
	if src != path do os.remove(src)
	if img.data == nil do return
	defer rl.UnloadImage(img)
	rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8)

	w, h = int(img.width), int(img.height)
	if w == 0 || h == 0 do return
	pixels = make([]u8, w * h * 4, allocator)
	copy(pixels, ([^]u8)(img.data)[:w * h * 4])
	return pixels, w, h, true
}

// ---------------------------------------------------------------------------
// Secrets: stored in the user's login Keychain (Security.framework). The config
// only records the marker below; the password itself never touches disk here.
// ---------------------------------------------------------------------------

foreign import security "system:Security.framework"
foreign import corefoundation "system:CoreFoundation.framework"

@(private = "file")
KEYCHAIN_SERVICE :: "SteamBuildGui"
@(private = "file")
KEYCHAIN_ACCOUNT :: "steam-login"
@(private = "file")
KEYCHAIN_MARKER :: "keychain"

@(default_calling_convention = "c")
@(private = "file")
foreign security {
	SecKeychainFindGenericPassword :: proc(keychain: rawptr, service_len: u32, service: cstring, account_len: u32, account: cstring, pw_len: ^u32, pw_data: ^rawptr, item: ^rawptr) -> i32 ---
	SecKeychainAddGenericPassword :: proc(keychain: rawptr, service_len: u32, service: cstring, account_len: u32, account: cstring, pw_len: u32, pw_data: rawptr, item: ^rawptr) -> i32 ---
	SecKeychainItemModifyAttributesAndData :: proc(item: rawptr, attrs: rawptr, length: u32, data: rawptr) -> i32 ---
	SecKeychainItemFreeContent :: proc(attrs: rawptr, data: rawptr) -> i32 ---
	SecKeychainItemDelete :: proc(item: rawptr) -> i32 ---
}

@(default_calling_convention = "c")
@(private = "file")
foreign corefoundation {
	CFRelease :: proc(cf: rawptr) ---
}

@(private = "file")
find_item :: proc() -> rawptr {
	item: rawptr
	SecKeychainFindGenericPassword(nil, u32(len(KEYCHAIN_SERVICE)), KEYCHAIN_SERVICE, u32(len(KEYCHAIN_ACCOUNT)), KEYCHAIN_ACCOUNT, nil, nil, &item)
	return item
}

// Stores the secret in the Keychain and returns the marker to save in the config
// ("" for empty input / failure; an empty input also removes the stored item).
secret_encrypt :: proc(plain: string, allocator := context.allocator) -> string {
	item := find_item()
	if plain == "" {
		if item != nil {
			SecKeychainItemDelete(item)
			CFRelease(item)
		}
		return ""
	}
	status: i32
	if item != nil {
		status = SecKeychainItemModifyAttributesAndData(item, nil, u32(len(plain)), raw_data(plain))
		CFRelease(item)
	} else {
		status = SecKeychainAddGenericPassword(nil, u32(len(KEYCHAIN_SERVICE)), KEYCHAIN_SERVICE, u32(len(KEYCHAIN_ACCOUNT)), KEYCHAIN_ACCOUNT, u32(len(plain)), raw_data(plain), nil)
	}
	if status != 0 do return ""
	return strings.clone(KEYCHAIN_MARKER, allocator)
}

secret_decrypt :: proc(enc: string, allocator := context.allocator) -> (plain: string, ok: bool) {
	if enc != KEYCHAIN_MARKER do return "", false
	n: u32
	data: rawptr
	if SecKeychainFindGenericPassword(nil, u32(len(KEYCHAIN_SERVICE)), KEYCHAIN_SERVICE, u32(len(KEYCHAIN_ACCOUNT)), KEYCHAIN_ACCOUNT, &n, &data, nil) != 0 || data == nil {
		return "", false
	}
	defer SecKeychainItemFreeContent(nil, data)
	buf := make([]u8, n, allocator)
	copy(buf, ([^]u8)(data)[:n])
	return string(buf), true
}
