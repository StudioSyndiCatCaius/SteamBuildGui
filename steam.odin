package SteamBuildPusher

import "core:encoding/json"
import "core:fmt"
import os "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// ---------------------------------------------------------------------------
// VDF generation
// ---------------------------------------------------------------------------

vdf_escape :: proc(s: string) -> string {
	// steamcmd's KeyValues parser has no escape sequences: just never emit quotes / newlines.
	out, _ := strings.replace_all(s, "\"", "'", context.temp_allocator)
	out, _ = strings.replace_all(out, "\n", " ", context.temp_allocator)
	out, _ = strings.replace_all(out, "\r", "", context.temp_allocator)
	return out
}

win_path :: proc(p: string) -> string {
	out, _ := strings.replace_all(strings.trim_space(p), "/", "\\", context.temp_allocator)
	return strings.trim_right(out, "\\")
}

// ---------------------------------------------------------------------------
// Folder layout (one folder per app, keyed by App ID):
//
//   <work>\<AppID>\
//       <AppID>_header.jpg, <AppID>_details.json   store art / info
//       builds\<Depot>\                              files uploaded for each depot
//       scripts\                                     generated VDFs
//       output\                                      steamcmd build output
// ---------------------------------------------------------------------------

// Folder-safe version of a name ("Windows: x64?" -> "Windows x64").
sanitize_folder_name :: proc(name: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for r in strings.trim_space(name) {
		switch r {
		case '<', '>', ':', '"', '/', '\\', '|', '?', '*':
		case:
			if r >= 32 do strings.write_rune(&sb, r)
		}
	}
	return strings.trim(strings.to_string(sb), " .")
}

// "" when the app has no App ID yet (and no custom folder).
app_dir :: proc(s: ^Settings, a: ^App) -> string {
	if strings.trim_space(a.folder) != "" do return win_path(a.folder)
	id := strings.trim_space(a.app_id)
	if !is_numeric(id) do return ""
	return fmt.tprintf("%s\\%s", win_path(s.work_dir), id)
}
builds_dir :: proc(s: ^Settings, a: ^App) -> string {return fmt.tprintf("%s\\builds", app_dir(s, a))}
scripts_dir :: proc(s: ^Settings, a: ^App) -> string {return fmt.tprintf("%s\\scripts", app_dir(s, a))}
output_dir :: proc(s: ^Settings, a: ^App) -> string {return fmt.tprintf("%s\\output", app_dir(s, a))}

// Name of the depot's folder inside builds\ (its label, or its ID if unlabeled).
depot_folder_name :: proc(d: ^Depot) -> string {
	n := sanitize_folder_name(d.label)
	if n == "" do n = sanitize_folder_name(d.id)
	return n
}

// Where a depot's files come from: a custom path if set, otherwise builds\<label>.
depot_content_dir :: proc(s: ^Settings, a: ^App, d: ^Depot) -> string {
	if strings.trim_space(d.content_path) != "" do return win_path(d.content_path)
	if app_dir(s, a) == "" do return ""
	name := depot_folder_name(d)
	if name == "" do return ""
	return fmt.tprintf("%s\\%s", builds_dir(s, a), name)
}

// Creates <app>\builds\<depot> for every depot. Returns false on failure.
ensure_app_dir :: proc(s: ^Settings, a: ^App) -> bool {
	dir := app_dir(s, a)
	if dir == "" do return false
	if os.make_directory_all(dir) != nil && !os.is_dir(dir) do return false
	for &d in a.depots {
		if strings.trim_space(d.content_path) != "" do continue
		if p := depot_content_dir(s, a, &d); p != "" do os.make_directory_all(p)
	}
	return true
}

header_cache_file :: proc(s: ^Settings, app_id: string) -> string {
	return fmt.tprintf("%s\\%s\\%s_header.jpg", win_path(s.work_dir), app_id, app_id)
}
details_cache_file :: proc(s: ^Settings, app_id: string) -> string {
	return fmt.tprintf("%s\\%s\\%s_details.json", win_path(s.work_dir), app_id, app_id)
}

// --- Folder stats (cached; refreshed every few seconds) -----------------------

Dir_Stat :: struct {
	exists:  bool,
	files:   int,
	bytes:   i64,
	newest:  time.Time,
	checked: time.Time,
}

@(private = "file")
dir_stat_cache: map[string]Dir_Stat

@(private = "file")
MAX_STAT_FILES :: 50_000

@(private = "file")
walk_dir :: proc(path: string, st: ^Dir_Stat) {
	infos, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil do return
	for fi in infos {
		if st.files >= MAX_STAT_FILES do return
		if fi.type == .Directory {
			walk_dir(fi.fullpath, st)
		} else {
			st.files += 1
			st.bytes += fi.size
			if time.diff(st.newest, fi.modification_time) > 0 do st.newest = fi.modification_time
		}
	}
}

dir_stats :: proc(path: string) -> Dir_Stat {
	if path == "" do return {}
	if cached, found := dir_stat_cache[path]; found && time.since(cached.checked) < 3 * time.Second {
		return cached
	}
	st := Dir_Stat{checked = time.now()}
	if os.is_dir(path) {
		st.exists = true
		walk_dir(path, &st)
	}
	if path in dir_stat_cache {
		dir_stat_cache[path] = st
	} else {
		dir_stat_cache[strings.clone(path)] = st
	}
	return st
}

dir_stats_invalidate :: proc() {
	for k in dir_stat_cache do delete(k)
	clear(&dir_stat_cache)
}

fmt_bytes :: proc(b: i64) -> string {
	f := f64(b)
	switch {
	case b < 1024: return fmt.tprintf("%d B", b)
	case b < 1024 * 1024: return fmt.tprintf("%.1f KB", f / 1024)
	case b < 1024 * 1024 * 1024: return fmt.tprintf("%.1f MB", f / (1024 * 1024))
	case: return fmt.tprintf("%.2f GB", f / (1024 * 1024 * 1024))
	}
}

fmt_ago :: proc(t: time.Time) -> string {
	secs := time.duration_seconds(time.since(t))
	switch {
	case secs < 60: return "just now"
	case secs < 3600: return fmt.tprintf("%dm ago", int(secs / 60))
	case secs < 86400: return fmt.tprintf("%dh ago", int(secs / 3600))
	case: return fmt.tprintf("%dd ago", int(secs / 86400))
	}
}

// Subfolders of builds\ that no depot uses yet (temp allocated).
unused_build_folders :: proc(s: ^Settings, a: ^App) -> []string {
	if app_dir(s, a) == "" do return {}
	infos, err := os.read_all_directory_by_path(builds_dir(s, a), context.temp_allocator)
	if err != nil do return {}
	out := make([dynamic]string, context.temp_allocator)
	outer: for fi in infos {
		if fi.type != .Directory do continue
		for &d in a.depots {
			if strings.trim_space(d.content_path) == "" && strings.equal_fold(depot_folder_name(&d), fi.name) do continue outer
		}
		append(&out, fi.name)
	}
	return out[:]
}

is_numeric :: proc(s: string) -> bool {
	if len(s) == 0 do return false
	for c in s do if c < '0' || c > '9' do return false
	return true
}

// Returns a human readable problem, or "" if the app is ready to upload.
validate_app :: proc(s: ^Settings, a: ^App) -> string {
	if s.steamcmd_path == "" || !os.exists(s.steamcmd_path) do return "steamcmd.exe not found - install or locate it in Settings."
	if strings.trim_space(s.username) == "" do return "Steam username is not set - see Settings."
	if !is_numeric(strings.trim_space(a.app_id)) do return "App ID must be a number."
	n := 0
	for &d in a.depots {
		if !d.enabled do continue
		n += 1
		label := d.label if d.label != "" else d.id
		if !is_numeric(strings.trim_space(d.id)) do return fmt.tprintf("Depot '%s' needs a numeric Depot ID.", label)
		dir := depot_content_dir(s, a, &d)
		if dir == "" do return fmt.tprintf("Depot '%s' needs a label (used as its builds folder name).", label)
		ds := dir_stats(dir)
		if !ds.exists do return fmt.tprintf("Build folder for '%s' doesn't exist yet - click its Open button to create it.", label)
		if ds.files == 0 do return fmt.tprintf("Build folder for '%s' is empty - copy your build into it.", label)
	}
	if n == 0 do return "Enable at least one depot."
	return ""
}


// Writes app_build_<appid>.vdf + depot_build_<id>.vdf files. Returns path to the app build script.
write_build_scripts :: proc(s: ^Settings, a: ^App) -> (app_vdf: string, err_msg: string) {
	if !ensure_app_dir(s, a) do return "", fmt.tprintf("Could not create %s", app_dir(s, a))
	sdir := scripts_dir(s, a)
	app_id := strings.trim_space(a.app_id)
	odir := output_dir(s, a)
	if os.make_directory_all(sdir) != nil && !os.is_dir(sdir) do return "", fmt.tprintf("Could not create %s", sdir)
	if os.make_directory_all(odir) != nil && !os.is_dir(odir) do return "", fmt.tprintf("Could not create %s", odir)

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "\"AppBuild\"\n{\n")
	fmt.sbprintf(&sb, "\t\"AppID\" \"%s\"\n", app_id)
	fmt.sbprintf(&sb, "\t\"Desc\" \"%s\"\n", vdf_escape(a.description))
	fmt.sbprintf(&sb, "\t\"Preview\" \"%d\"\n", 1 if a.preview else 0)
	branch := strings.trim_space(a.branch)
	if branch != "" do fmt.sbprintf(&sb, "\t\"SetLive\" \"%s\"\n", vdf_escape(branch))
	fmt.sbprintf(&sb, "\t\"BuildOutput\" \"%s\\\"\n", odir)
	strings.write_string(&sb, "\t\"Depots\"\n\t{\n")

	for &d in a.depots {
		if !d.enabled do continue
		depot_id := strings.trim_space(d.id)
		depot_vdf := fmt.tprintf("%s\\depot_build_%s.vdf", sdir, depot_id)

		db := strings.builder_make(context.temp_allocator)
		strings.write_string(&db, "\"DepotBuildConfig\"\n{\n")
		fmt.sbprintf(&db, "\t\"DepotID\" \"%s\"\n", depot_id)
		fmt.sbprintf(&db, "\t\"ContentRoot\" \"%s\\\"\n", depot_content_dir(s, a, &d))
		strings.write_string(&db, "\t\"FileMapping\"\n\t{\n")
		strings.write_string(&db, "\t\t\"LocalPath\" \"*\"\n\t\t\"DepotPath\" \".\"\n\t\t\"recursive\" \"1\"\n\t}\n")
		for ex in strings.split(d.exclusions, ";", context.temp_allocator) {
			e := strings.trim_space(ex)
			if e != "" do fmt.sbprintf(&db, "\t\"FileExclusion\" \"%s\"\n", vdf_escape(e))
		}
		strings.write_string(&db, "}\n")
		if os.write_entire_file(depot_vdf, strings.to_string(db)) != nil {
			return "", fmt.tprintf("Could not write %s", depot_vdf)
		}
		fmt.sbprintf(&sb, "\t\t\"%s\" \"%s\"\n", depot_id, depot_vdf)
	}
	strings.write_string(&sb, "\t}\n}\n")

	app_vdf = fmt.tprintf("%s\\app_build_%s.vdf", sdir, app_id)
	if os.write_entire_file(app_vdf, strings.to_string(sb)) != nil {
		return "", fmt.tprintf("Could not write %s", app_vdf)
	}
	return app_vdf, ""
}

// ---------------------------------------------------------------------------
// steamcmd runner (one job at a time, output streamed into a log)
// ---------------------------------------------------------------------------

Job_Kind :: enum {
	None,
	Build,
	Login_Check,
	Install_SteamCMD,
}

Job_State :: enum {
	Idle,
	Running,
	Succeeded,
	Failed,
	Cancelled,
}

Job_Result :: struct {
	kind:     Job_Kind,
	state:    Job_State,
	app_id:   string,
	build_id: string,
	branch:   string,
	desc:     string,
	path:     string, // Install_SteamCMD: path of steamcmd.exe
	needs_guard:  bool, // login failed because a Steam Guard code is required
	bad_password: bool,
	preview:  bool,
}

Runner :: struct {
	mutex:       sync.Mutex,
	lines:       [dynamic]string,
	partial:     [dynamic]u8,
	state:       Job_State,
	kind:        Job_Kind,
	title:       string,
	started:     time.Time,
	child:       Child,
	cancel:      bool,
	result:      Job_Result,
	has_result:  bool, // set when job ends; consumed by main thread
	saw_success: bool,
	saw_error:   bool,
	needs_guard: bool,
	bad_password: bool,
	log_version: int,
}

runner: Runner

MAX_LOG_LINES :: 4000

@(private = "file")
push_line_locked :: proc(line: string) {
	r := &runner
	if len(r.lines) >= MAX_LOG_LINES {
		delete(r.lines[0])
		ordered_remove(&r.lines, 0)
	}
	append(&r.lines, strings.clone(line))
	r.log_version += 1

	if strings.contains(line, "Successfully finished AppID") || strings.contains(line, "Waiting for user info...OK") {
		r.saw_success = true
	}
	if idx := strings.index(line, "(BuildID "); idx >= 0 {
		rest := line[idx + len("(BuildID "):]
		end := strings.index_byte(rest, ')')
		if end > 0 {
			free_str(&r.result.build_id)
			r.result.build_id = strings.clone(rest[:end])
		}
	}
	upper := strings.to_upper(line, context.temp_allocator)
	if strings.contains(upper, "ERROR") || strings.contains(upper, "FAILED") {
		r.saw_error = true
	}
	if strings.contains(upper, "STEAM GUARD") || strings.contains(upper, "TWO-FACTOR") || strings.contains(upper, "TWO FACTOR") || strings.contains(upper, "ACCOUNT LOGON DENIED") {
		r.needs_guard = true
	}
	if strings.contains(upper, "INVALID PASSWORD") {
		r.bad_password = true
	}
}

log_line :: proc(format: string, args: ..any) {
	sync.mutex_lock(&runner.mutex)
	defer sync.mutex_unlock(&runner.mutex)
	push_line_locked(fmt.tprintf(format, ..args))
}

log_clear :: proc() {
	sync.mutex_lock(&runner.mutex)
	defer sync.mutex_unlock(&runner.mutex)
	for l in runner.lines do delete(l)
	clear(&runner.lines)
	runner.log_version += 1
}

runner_busy :: proc() -> bool {
	sync.mutex_lock(&runner.mutex)
	defer sync.mutex_unlock(&runner.mutex)
	return runner.state == .Running
}

runner_cancel :: proc() {
	sync.mutex_lock(&runner.mutex)
	defer sync.mutex_unlock(&runner.mutex)
	if runner.state == .Running {
		runner.cancel = true
		child_kill(&runner.child)
	}
}

Job_Step :: struct {
	cmd:        []string,
	workdir:    string,
	check_exit: bool, // abort the job if this step exits non-zero
	note:       string, // optional line logged before the step
	log_cmd:    string, // optional redacted command shown in the log instead of `cmd`
}

@(private = "file")
Job_Args :: struct {
	steps: []Job_Step,
}

// Runs one step, streaming output into the log. Returns exit code (-1 = could not start).
@(private = "file")
run_step :: proc(step: ^Job_Step) -> int {
	sync.mutex_lock(&runner.mutex)
	if step.note != "" do push_line_locked(step.note)
	push_line_locked(fmt.tprintf("> %s", step.log_cmd if step.log_cmd != "" else build_command_line(step.cmd)))
	sync.mutex_unlock(&runner.mutex)

	child, ok := child_start(step.cmd, step.workdir)
	sync.mutex_lock(&runner.mutex)
	if !ok {
		push_line_locked(fmt.tprintf("!! Failed to start %s", step.cmd[0]))
		sync.mutex_unlock(&runner.mutex)
		return -1
	}
	runner.child = child
	if runner.cancel do child_kill(&runner.child)
	sync.mutex_unlock(&runner.mutex)

	buf: [4096]u8
	for {
		n := child_read(&child, buf[:])
		if n <= 0 do break
		sync.mutex_lock(&runner.mutex)
		for b in buf[:n] {
			if b == '\n' || b == '\r' {
				if len(runner.partial) > 0 {
					push_line_locked(string(runner.partial[:]))
					clear(&runner.partial)
				}
			} else {
				append(&runner.partial, b)
			}
		}
		sync.mutex_unlock(&runner.mutex)
		free_all(context.temp_allocator)
	}
	code := child_wait(&child)

	sync.mutex_lock(&runner.mutex)
	if len(runner.partial) > 0 {
		push_line_locked(string(runner.partial[:]))
		clear(&runner.partial)
	}
	child_close(&runner.child)
	sync.mutex_unlock(&runner.mutex)
	return code
}

@(private = "file")
job_thread :: proc(job: ^Job_Args) {
	defer {
		for &s in job.steps {
			for a in s.cmd do delete(a)
			delete(s.cmd)
			delete(s.workdir)
			delete(s.note)
			delete(s.log_cmd)
		}
		delete(job.steps)
		free(job)
	}

	code := 0
	for &step in job.steps {
		code = run_step(&step)
		if code == -1 || (step.check_exit && code != 0) do break
		if runner.cancel do break
	}

	sync.mutex_lock(&runner.mutex)
	defer sync.mutex_unlock(&runner.mutex)

	elapsed := time.duration_seconds(time.since(runner.started))
	switch {
	case runner.cancel:
		runner.state = .Cancelled
		push_line_locked("== Cancelled ==")
	case runner.kind == .Install_SteamCMD:
		if os.is_file(runner.result.path) {
			runner.state = .Succeeded
			push_line_locked(fmt.tprintf("== SteamCMD installed in %.0fs: %s ==", elapsed, runner.result.path))
		} else {
			runner.state = .Failed
			push_line_locked(fmt.tprintf("== SteamCMD install failed after %.0fs ==", elapsed))
		}
	case code == 0 && runner.saw_success:
		runner.state = .Succeeded
		push_line_locked(fmt.tprintf("== Finished successfully in %.0fs ==", elapsed))
	case code == 0 && !runner.saw_error && runner.kind != .Build:
		runner.state = .Succeeded
		push_line_locked(fmt.tprintf("== Done in %.0fs ==", elapsed))
	case:
		runner.state = .Failed
		push_line_locked(fmt.tprintf("== Failed (exit code %d) after %.0fs ==", code, elapsed))
		switch {
		case runner.bad_password: push_line_locked("Hint: Steam rejected the password - check it under Settings > Steam account.")
		case runner.needs_guard: push_line_locked("Hint: Steam Guard code required - enter the code from your email / Steam mobile app under Settings > Steam account and try again.")
		case: push_line_locked("Hint: if login failed, check your password or log in under Settings > Steam account.")
		}
	}
	runner.result.state = runner.state
	runner.result.needs_guard = runner.needs_guard
	runner.result.bad_password = runner.bad_password
	runner.has_result = true
	free_all(context.temp_allocator)
}

@(private = "file")
runner_start :: proc(kind: Job_Kind, title: string, cmd: []string, workdir: string, result: Job_Result) -> bool {
	return runner_start_steps(kind, title, {{cmd = cmd, workdir = workdir}}, result)
}

@(private = "file")
runner_start_steps :: proc(kind: Job_Kind, title: string, steps: []Job_Step, result: Job_Result) -> bool {
	sync.mutex_lock(&runner.mutex)
	defer sync.mutex_unlock(&runner.mutex)
	if runner.state == .Running do return false

	runner.state = .Running
	runner.kind = kind
	runner.cancel = false
	runner.saw_success = false
	runner.saw_error = false
	runner.needs_guard = false
	runner.bad_password = false
	runner.has_result = false
	runner.started = time.now()
	set_str(&runner.title, title)
	free_str(&runner.result.app_id)
	free_str(&runner.result.build_id)
	free_str(&runner.result.branch)
	free_str(&runner.result.desc)
	free_str(&runner.result.path)
	runner.result = result
	runner.result.kind = kind

	push_line_locked("")
	push_line_locked(fmt.tprintf("=== %s ===", title))

	// Deep-copy steps: the thread owns them. Passwords only appear in `cmd`, never in the log.
	job := new(Job_Args)
	job.steps = make([]Job_Step, len(steps))
	for s, i in steps {
		dst := &job.steps[i]
		dst.cmd = make([]string, len(s.cmd))
		for c, j in s.cmd do dst.cmd[j] = strings.clone(c)
		dst.workdir = strings.clone(s.workdir)
		dst.note = strings.clone(s.note)
		dst.log_cmd = strings.clone(s.log_cmd)
		dst.check_exit = s.check_exit
	}
	thread.create_and_start_with_poly_data(job, job_thread, self_cleanup = true)
	return true
}

STEAMCMD_ZIP_URL :: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip"

// Downloads steamcmd.zip, extracts it into `install_dir` and runs it once so it
// self-updates. Uses curl.exe + tar.exe that ship with Windows 10/11.
start_install_steamcmd :: proc(install_dir: string) -> string {
	dir := win_path(install_dir)
	if os.make_directory_all(dir) != nil && !os.is_dir(dir) do return fmt.tprintf("Could not create %s", dir)
	zip := fmt.tprintf("%s\\steamcmd.zip", dir)
	exe := fmt.tprintf("%s\\steamcmd.exe", dir)
	steps := []Job_Step {
		{cmd = {"curl.exe", "-f", "-L", "-sS", "--max-time", "120", "-o", zip, STEAMCMD_ZIP_URL}, workdir = dir, check_exit = true, note = "Downloading steamcmd.zip from Valve…"},
		{cmd = {"tar.exe", "-xf", zip, "-C", dir}, workdir = dir, check_exit = true, note = "Extracting…"},
		{cmd = {"cmd.exe", "/c", "del", "/q", zip}, workdir = dir},
		// First run downloads the rest of steamcmd; it often exits with code 7 after updating, which is fine.
		{cmd = {exe, "+quit"}, workdir = dir, note = "First run: steamcmd updates itself (this can take a minute)…"},
	}
	if !runner_start_steps(.Install_SteamCMD, "Installing SteamCMD", steps, {path = strings.clone(exe)}) {
		return "Another job is already running."
	}
	return ""
}

// Steam account credentials for steamcmd's `login <user> [<password>] [<Steam Guard code>]`.
// Password/code are optional: without them steamcmd uses its cached login.
Credentials :: struct {
	username:   string,
	password:   string,
	guard_code: string,
}

// Builds `steamcmd +login ... <rest>` plus a redacted copy for the log.
@(private = "file")
login_command :: proc(steamcmd: string, c: Credentials, rest: ..string) -> (cmd: []string, shown: string) {
	args := make([dynamic]string, context.temp_allocator)
	log := make([dynamic]string, context.temp_allocator)
	append(&args, steamcmd, "+login", strings.trim_space(c.username))
	append(&log, steamcmd, "+login", strings.trim_space(c.username))
	if c.password != "" {
		append(&args, c.password)
		append(&log, "********")
		if code := strings.trim_space(c.guard_code); code != "" {
			append(&args, code)
			append(&log, "<guard-code>")
		}
	}
	append(&args, ..rest)
	append(&log, ..rest)
	return args[:], build_command_line(log[:])
}

start_upload :: proc(s: ^Settings, a: ^App, creds: Credentials) -> string {
	if msg := validate_app(s, a); msg != "" do return msg
	vdf, err := write_build_scripts(s, a)
	if err != "" do return err

	steamcmd := win_path(s.steamcmd_path)
	cmd, shown := login_command(steamcmd, creds, "+run_app_build", vdf, "+quit")
	title := fmt.tprintf("%s %s (%s)", "Preview build" if a.preview else "Uploading", a.name, strings.trim_space(a.app_id))
	res := Job_Result {
		app_id  = strings.clone(strings.trim_space(a.app_id)),
		branch  = strings.clone(strings.trim_space(a.branch)),
		desc    = strings.clone(a.description),
		preview = a.preview,
	}
	if !runner_start_steps(.Build, title, {{cmd = cmd, workdir = os.dir(steamcmd), log_cmd = shown}}, res) do return "Another job is already running."
	return ""
}

start_login_check :: proc(s: ^Settings, creds: Credentials) -> string {
	if s.steamcmd_path == "" || !os.exists(s.steamcmd_path) do return "steamcmd.exe not found."
	if strings.trim_space(s.username) == "" do return "Set your Steam username first."
	steamcmd := win_path(s.steamcmd_path)
	cmd, shown := login_command(steamcmd, creds, "+quit")
	title := "Logging in to Steam" if creds.password != "" else "Checking cached Steam login"
	if !runner_start_steps(.Login_Check, title, {{cmd = cmd, workdir = os.dir(steamcmd), log_cmd = shown}}, {}) do return "Another job is already running."
	return ""
}

// Opens a real console so the user can type password + Steam Guard code once;
// steamcmd then caches the credentials for future non-interactive builds.
open_login_console :: proc(s: ^Settings) -> string {
	if s.steamcmd_path == "" || !os.exists(s.steamcmd_path) do return "steamcmd.exe not found."
	if strings.trim_space(s.username) == "" do return "Set your Steam username first."
	steamcmd := win_path(s.steamcmd_path)
	if !launch_console(steamcmd, fmt.tprintf("+login %s", strings.trim_space(s.username)), os.dir(steamcmd)) {
		return "Could not launch steamcmd."
	}
	return ""
}

// Called once per frame by the UI. Returns a finished job result exactly once.
runner_poll :: proc() -> (res: Job_Result, ok: bool) {
	sync.mutex_lock(&runner.mutex)
	defer sync.mutex_unlock(&runner.mutex)
	if !runner.has_result do return {}, false
	runner.has_result = false
	res = runner.result
	runner.result = {} // ownership moves to the caller
	return res, true
}

// ---------------------------------------------------------------------------
// Steam store art + name fetching (background, via Windows' bundled curl.exe)
// ---------------------------------------------------------------------------

Art_State :: enum {
	None,
	Fetching,
	Downloaded, // file on disk, texture not yet uploaded (main thread does that)
	Ready,
	Missing_Fresh, // download failed; main thread has not processed it yet
	Missing,
}

Store_Fetch :: struct {
	mutex:   sync.Mutex,
	pending: map[string]Art_State, // app_id -> state of the download
}

store_fetch: Store_Fetch


@(private = "file")
Fetch_Args :: struct {
	app_id:       string,
	header_path:  string,
	details_path: string,
}

@(private = "file")
fetch_thread :: proc(f: ^Fetch_Args) {
	defer {
		delete(f.app_id)
		delete(f.header_path)
		delete(f.details_path)
		free(f)
	}
	header_url := fmt.tprintf("https://cdn.cloudflare.steamstatic.com/steam/apps/%s/header.jpg", f.app_id)
	code, ok := run_quiet({"curl.exe", "-f", "-s", "-L", "--max-time", "20", "-o", f.header_path, header_url})
	got_header := ok && code == 0 && os.exists(f.header_path)

	details_url := fmt.tprintf("https://store.steampowered.com/api/appdetails?appids=%s&filters=basic", f.app_id)
	run_quiet({"curl.exe", "-f", "-s", "-L", "--max-time", "20", "-o", f.details_path, details_url})

	sync.mutex_lock(&store_fetch.mutex)
	store_fetch.pending[f.app_id] = .Downloaded if got_header else .Missing_Fresh
	sync.mutex_unlock(&store_fetch.mutex)
	free_all(context.temp_allocator)
}

start_store_fetch :: proc(s: ^Settings, app_id: string) {
	if !is_numeric(app_id) do return
	sync.mutex_lock(&store_fetch.mutex)
	defer sync.mutex_unlock(&store_fetch.mutex)
	if store_fetch.pending[app_id] == .Fetching do return
	if _, exists := store_fetch.pending[app_id]; !exists {
		store_fetch.pending[strings.clone(app_id)] = .Fetching
	} else {
		store_fetch.pending[app_id] = .Fetching
	}
	os.make_directory_all(fmt.tprintf("%s\\%s", win_path(s.work_dir), app_id))

	f := new(Fetch_Args)
	f.app_id = strings.clone(app_id)
	f.header_path = strings.clone(header_cache_file(s, app_id))
	f.details_path = strings.clone(details_cache_file(s, app_id))
	thread.create_and_start_with_poly_data(f, fetch_thread, self_cleanup = true)
}

fetch_state :: proc(app_id: string) -> Art_State {
	sync.mutex_lock(&store_fetch.mutex)
	defer sync.mutex_unlock(&store_fetch.mutex)
	return store_fetch.pending[app_id]
}

set_fetch_state :: proc(app_id: string, st: Art_State) {
	sync.mutex_lock(&store_fetch.mutex)
	defer sync.mutex_unlock(&store_fetch.mutex)
	if _, exists := store_fetch.pending[app_id]; !exists {
		store_fetch.pending[strings.clone(app_id)] = st
	} else {
		store_fetch.pending[app_id] = st
	}
}

// Reads the cached appdetails JSON and returns the store name (temp allocated) if present.
read_store_name :: proc(s: ^Settings, app_id: string) -> (name: string, ok: bool) {
	data, err := os.read_entire_file(details_cache_file(s, app_id), context.temp_allocator)
	if err != nil do return "", false
	v, perr := json.parse(data, allocator = context.temp_allocator)
	if perr != nil do return "", false
	root := v.(json.Object) or_return
	entry := root[app_id].(json.Object) or_return
	success := entry["success"].(json.Boolean) or_return
	if !success do return "", false
	d := entry["data"].(json.Object) or_return
	n := d["name"].(json.String) or_return
	return string(n), true
}
