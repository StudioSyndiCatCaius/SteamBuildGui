package SteamBuildPusher

import "core:fmt"
import "core:hash"
import "core:math"
import os "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import rl "vendor:raylib"

APP_TITLE :: "SteamBuild"
MAX_HISTORY :: 50

Tab :: enum {
	Apps,
	Settings,
}

Confirm_Kind :: enum {
	None,
	Delete_App,
	Upload,
	Clear_History,
}

Toast_Kind :: enum {
	Info,
	Success,
	Error,
}

Tex_Entry :: struct {
	tex: rl.Texture2D,
	ok:  bool,
}

State :: struct {
	cfg:             Config,
	exe_dir:         string,
	tab:             Tab,
	sidebar_scroll:  Scroll,
	main_scroll:     Scroll,
	settings_scroll: Scroll,
	log_scroll:      Scroll,
	log_open:        bool,
	log_h:           f32,
	log_follow:      bool,
	log_drag:        bool,
	dirty:           bool,
	dirty_t:         f32,
	toast:           string,
	toast_kind:      Toast_Kind,
	toast_t:         f32,
	confirm:         Confirm_Kind,
	confirm_app:     int,
	drop_path:       string,
	drop_active:     bool,
	textures:        map[string]Tex_Entry,

	// Steam login (password lives in memory; saved only if "remember" is on, DPAPI-encrypted)
	password:        string,
	show_password:   bool, // not saved
	guard_code:      string, // single use, never saved
	guard_needed:    bool,
	login_status:    string,
	login_ok:        bool,

}

st: State
logo_tex: rl.Texture2D

main :: proc() {
	if len(os.args) >= 3 && os.args[1] == "--write-icon" {
		ok: bool
		if strings.has_suffix(os.args[2], ".png") { // preview
			px := icon_pixels(512)
			ok = rl.ExportImage(rl.Image{data = raw_data(px), width = 512, height = 512, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8}, cstr(os.args[2]))
		} else {
			ok = write_ico(os.args[2], {16, 20, 24, 32, 40, 48, 64, 128, 256})
		}
		fmt.println("wrote" if ok else "FAILED to write", os.args[2])
		return
	}

	// Windows: next to the exe. macOS: ~/Library/Application Support/SteamBuildGui
	// (an .app bundle must not be written into).
	exe_dir := app_data_dir()
	st.exe_dir = exe_dir
	st.cfg = config_load(exe_dir)
	if st.cfg.settings.remember_password {
		if pw, ok := secret_decrypt(st.cfg.settings.password_enc); ok do st.password = pw
	}
	st.log_h = 260
	st.log_follow = true

	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT, .VSYNC_HINT})
	rl.SetTraceLogLevel(.WARNING)
	rl.InitWindow(1280, 820, APP_TITLE + " - Steam build uploader")
	rl.SetWindowMinSize(960, 620)
	rl.SetExitKey(.KEY_NULL)
	rl.SetTargetFPS(60)
	load_fonts()

	// Window/taskbar icon + top bar logo, from the same procedural artwork as the .ico
	{
		px := icon_pixels(128, context.temp_allocator)
		img := rl.Image{data = raw_data(px), width = 128, height = 128, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8}
		rl.SetWindowIcon(img)
		logo_tex = rl.LoadTextureFromImage(img)
		rl.GenTextureMipmaps(&logo_tex)
		rl.SetTextureFilter(logo_tex, .TRILINEAR)
	}

	log_line("SteamBuildGui ready. Config: %s", config_path(exe_dir))

	// Dev aid: SBG_SCREENSHOT=<file.png> renders a few frames, saves a screenshot and exits.
	shot := os.get_env("SBG_SCREENSHOT", context.allocator)
	if shot != "" && os.get_env("SBG_TAB", context.temp_allocator) == "settings" do st.tab = .Settings
	if shot != "" && os.get_env("SBG_LOG", context.temp_allocator) != "" do st.log_open = true
	frames := 0

	for !rl.WindowShouldClose() {
		frame()
		free_all(context.temp_allocator)
		frames += 1
		if shot != "" && frames == 90 {
			rl.TakeScreenshot(cstr(shot))
			break
		}
	}

	// Don't leave a headless steamcmd running after the window is gone.
	if runner_busy() do runner_cancel()
	config_save(&st.cfg, st.exe_dir)
	rl.CloseWindow()
}

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------

frame :: proc() {
	dt := rl.GetFrameTime()

	if res, ok := runner_poll(); ok do handle_job_result(res)

	st.drop_active = false
	if rl.IsFileDropped() {
		files := rl.LoadDroppedFiles()
		if files.count > 0 {
			st.drop_path = strings.clone(string(files.paths[0]), context.temp_allocator)
			st.drop_active = true
		}
		rl.UnloadDroppedFiles(files)
	}

	ui_begin_frame()
	ui.blocked = st.confirm != .None

	ctrl := mod_key_down()
	if ctrl && rl.IsKeyPressed(.S) {
		save_now()
		show_toast("Saved", .Success)
	}

	rl.BeginDrawing()
	rl.ClearBackground(C_BG)

	W := f32(rl.GetScreenWidth())
	H := f32(rl.GetScreenHeight())
	full := Rect{0, 0, W, H}
	top := cut_top(&full, 54)
	status := cut_bottom(&full, 30)
	if st.log_open {
		st.log_h = clamp(st.log_h, 120, H * 0.7)
		draw_log(cut_bottom(&full, st.log_h), status.y)
	}

	switch st.tab {
	case .Apps: draw_apps_tab(full)
	case .Settings: draw_settings_tab(full)
	}
	draw_topbar(top)
	draw_statusbar(status)
	draw_toast(status.y, dt)

	if st.confirm != .None {
		ui.blocked = false
		draw_confirm()
	}

	ui_end_frame()
	rl.EndDrawing()

	if ui.changed {
		st.dirty = true
		st.dirty_t = 0
		ui.changed = false
	}
	if st.dirty {
		st.dirty_t += dt
		if st.dirty_t > 0.6 do save_now()
	}
}

save_now :: proc() {
	if !config_save(&st.cfg, st.exe_dir) do show_toast("Could not save config!", .Error)
	st.dirty = false
}

show_toast :: proc(msg: string, kind := Toast_Kind.Info) {
	set_str(&st.toast, msg)
	st.toast_kind = kind
	st.toast_t = 4.5
}

// ---------------------------------------------------------------------------
// Job results
// ---------------------------------------------------------------------------

handle_job_result :: proc(res: Job_Result) {
	res := res
	defer free_str(&res.app_id)

	switch res.kind {
	case .Build:
		target: ^App
		for &a in st.cfg.apps {
			if strings.trim_space(a.app_id) == res.app_id {
				target = &a
				break
			}
		}
		switch res.state {
		case .Succeeded:
			msg := "Preview build finished" if res.preview else "Upload finished"
			if res.build_id != "" do show_toast(fmt.tprintf("%s - BuildID %s", msg, res.build_id), .Success)
			else do show_toast(msg, .Success)
		case .Failed:
			switch {
			case res.bad_password:
				show_toast("Upload failed: Steam rejected the password (Settings > Steam account)", .Error)
			case res.needs_guard:
				st.guard_needed = true
				show_toast("Steam Guard code needed - enter it in Settings > Steam account and retry", .Error)
			case:
				show_toast("Build failed - see the output log", .Error)
			}
			st.log_open = true
		case .Cancelled:
			show_toast("Build cancelled", .Info)
		case .Idle, .Running:
		}
		if target != nil && res.state != .Cancelled {
			append(&target.history, Build_Record {
				time = local_time_string(),
				build_id = res.build_id,
				branch = res.branch,
				desc = res.desc,
				preview = res.preview,
				success = res.state == .Succeeded,
			})
			for len(target.history) > MAX_HISTORY {
				record_destroy(&target.history[0])
				ordered_remove(&target.history, 0)
			}
			ui.changed = true
		} else {
			free_str(&res.build_id)
			free_str(&res.branch)
			free_str(&res.desc)
		}
	case .Login_Check:
		switch res.state {
		case .Succeeded:
			set_str(&st.login_status, fmt.tprintf("Logged in as %s - this PC is remembered for uploads", strings.trim_space(st.cfg.settings.username)))
			st.login_ok = true
			show_toast("Steam login OK", .Success)
		case .Failed:
			st.login_ok = false
			switch {
			case res.bad_password: set_str(&st.login_status, "Wrong password")
			case res.needs_guard:
				set_str(&st.login_status, "Steam Guard code needed - check your email / Steam app, enter it, then Log in again")
				st.guard_needed = true
			case st.password == "": set_str(&st.login_status, "Not logged in on this PC yet - enter your password and Log in")
			case: set_str(&st.login_status, "Login failed - see the log")
			}
			show_toast("Steam login failed", .Error)
			st.log_open = true
		case .Cancelled, .Idle, .Running:
		}
	case .Install_SteamCMD:
		if res.state == .Succeeded {
			set_str(&st.cfg.settings.steamcmd_path, res.path)
			ui.changed = true
			show_toast("SteamCMD installed - now log in once under Steam account", .Success)
		} else if res.state == .Failed {
			show_toast("SteamCMD install failed - see the log", .Error)
			st.log_open = true
		}
	case .None:
	}
	free_str(&res.path)
}

Runner_View :: struct {
	state:   Job_State,
	kind:    Job_Kind,
	title:   string,
	app_id:  string,
	elapsed: f64,
}

runner_view :: proc() -> Runner_View {
	sync.mutex_lock(&runner.mutex)
	defer sync.mutex_unlock(&runner.mutex)
	return Runner_View {
		state = runner.state,
		kind = runner.kind,
		title = strings.clone(runner.title, context.temp_allocator),
		app_id = strings.clone(runner.result.app_id, context.temp_allocator),
		elapsed = time.duration_seconds(time.since(runner.started)),
	}
}

fmt_elapsed :: proc(secs: f64) -> string {
	s := int(secs)
	return fmt.tprintf("%02d:%02d", s / 60, s % 60)
}

// Current Steam login for steamcmd. The Steam Guard code is single-use, so it's consumed here.
take_credentials :: proc() -> Credentials {
	c := Credentials {
		username   = st.cfg.settings.username,
		password   = strings.clone(st.password, context.temp_allocator),
		guard_code = strings.clone(strings.trim_space(st.guard_code), context.temp_allocator),
	}
	free_str(&st.guard_code)
	st.guard_needed = false
	return c
}

save_password :: proc() {
	enc := secret_encrypt(st.password, context.temp_allocator)
	set_str(&st.cfg.settings.password_enc, enc)
	ui.changed = true
}

do_upload :: proc(a: ^App) {
	if msg := start_upload(&st.cfg.settings, a, take_credentials()); msg != "" {
		show_toast(msg, .Error)
		return
	}
	if st.cfg.settings.show_log_on_run do st.log_open = true
	st.log_follow = true
}

// ---------------------------------------------------------------------------
// Art (Steam store header images)
// ---------------------------------------------------------------------------

load_texture_file :: proc(path: string) -> (rl.Texture2D, bool) {
	pixels, w, h, ok := decode_image_file(path, context.temp_allocator)
	if !ok do return {}, false
	img := rl.Image {
		data    = raw_data(pixels),
		width   = i32(w),
		height  = i32(h),
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	tex := rl.LoadTextureFromImage(img)
	if tex.id == 0 do return {}, false
	rl.GenTextureMipmaps(&tex)
	rl.SetTextureFilter(tex, .TRILINEAR)
	return tex, true
}

get_texture :: proc(path: string) -> (rl.Texture2D, bool) {
	if e, found := st.textures[path]; found do return e.tex, e.ok
	tex, ok := load_texture_file(path)
	st.textures[strings.clone(path)] = {tex, ok}
	return tex, ok
}

invalidate_texture :: proc(path: string) {
	if path in st.textures {
		k, v := delete_key(&st.textures, path)
		if v.ok do rl.UnloadTexture(v.tex)
		delete(k)
	}
}

apply_store_name :: proc(a: ^App, app_id: string) {
	if a.name != "" && a.name != "New App" do return
	if name, ok := read_store_name(&st.cfg.settings, app_id); ok && name != "" {
		set_str(&a.name, name)
		ui.changed = true
	}
}

app_art :: proc(a: ^App) -> (rl.Texture2D, bool) {
	if a.custom_image != "" && os.is_file(a.custom_image) do return get_texture(a.custom_image)
	id := strings.trim_space(a.app_id)
	if !is_numeric(id) do return {}, false
	path := header_cache_file(&st.cfg.settings, id)

	switch fetch_state(id) {
	case .None:
		if os.is_file(path) {
			set_fetch_state(id, .Ready)
			return get_texture(path)
		}
		// Don't fetch while the user is still typing the App ID.
		if st.cfg.settings.auto_fetch_art && ui.focus != rawptr(&a.app_id) {
			start_store_fetch(&st.cfg.settings, id)
		}
	case .Downloaded:
		invalidate_texture(path)
		apply_store_name(a, id)
		set_fetch_state(id, .Ready)
		return get_texture(path)
	case .Missing_Fresh:
		apply_store_name(a, id)
		set_fetch_state(id, .Missing)
	case .Ready:
		return get_texture(path)
	case .Fetching, .Missing:
	}
	return {}, false
}

draw_art :: proc(r: Rect, a: ^App, big := false) {
	tex, ok := app_art(a)
	if ok {
		ta := f32(tex.width) / f32(tex.height)
		ra := r.width / r.height
		src := Rect{0, 0, f32(tex.width), f32(tex.height)}
		if ta > ra {
			w := f32(tex.height) * ra
			src.x = (f32(tex.width) - w) / 2
			src.width = w
		} else {
			h := f32(tex.width) / ra
			src.y = (f32(tex.height) - h) / 2
			src.height = h
		}
		rl.DrawTexturePro(tex, src, r, {}, 0, rl.WHITE)
		outline(r, 4 if big else 3, 1, with_alpha(C_BORDER, 0.8))
		return
	}

	// Placeholder: tinted gradient + initials
	hue := f32(hash.fnv32a(transmute([]u8)a.name) % 360)
	c1 := rl.ColorFromHSV(hue, 0.45, 0.42)
	c2 := rl.ColorFromHSV(math.mod(hue + 40, 360), 0.5, 0.25)
	rl.DrawRectangleGradientEx(r, c1, c2, c2, c1)
	initials := app_initials(a.name)
	kind := Font_Kind.Title if big else Font_Kind.Bold
	label(r, initials, kind, with_alpha(rl.WHITE, 0.85), .Center)
	if fetch_state(strings.trim_space(a.app_id)) == .Fetching {
		spinner({r.x + r.width - 12, r.y + 12}, 6, with_alpha(rl.WHITE, 0.8))
	}
}

app_initials :: proc(name: string) -> string {
	words := strings.fields(name, context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	for w, i in words {
		if i >= 2 do break
		for r in w {
			strings.write_rune(&sb, r)
			break
		}
	}
	if strings.builder_len(sb) == 0 do return "?"
	return strings.to_upper(strings.to_string(sb), context.temp_allocator)
}

spinner :: proc(c: Vec2, r: f32, col: Color) {
	a := math.mod(ui.time * 360, 360)
	rl.DrawRing(c, r - 2, r, a, a + 270, 24, col)
}

// ---------------------------------------------------------------------------
// Shared bits
// ---------------------------------------------------------------------------

card :: proc(x, y, w, h: f32, title: string, subtitle := "") -> Rect {
	r := Rect{x, y, w, h}
	fill(r, 10, C_PANEL)
	outline(r, 10, 1, C_BORDER)
	draw_text(title, x + 22, y + 18, .Heading, C_TEXT)
	if subtitle != "" {
		tw := measure(title, .Heading)
		draw_text(fit_text(subtitle, .Small, w - tw - 60), x + 22 + tw + 12, y + 23, .Small, C_TEXT_FAINT)
	}
	return Rect{x + 22, y + 56, w - 44, h - 76}
}

FIELD_ROW :: 72 // label + field + spacing

// Label above a field. Returns the field rect.
form_field :: proc(x, y, w: f32, text: string, hint := "") -> Rect {
	field_label(Rect{x, y, w, 18}, text, hint)
	return Rect{x, y + 22, w, 36}
}

// Text field + browse button. Also accepts files/folders dropped from Explorer.
path_field :: proc(r: Rect, s: ^string, placeholder: string, folder: bool, title: string, filter_name := "", filter_spec := "") -> bool {
	rr := r
	btn := cut_right(&rr, 38)
	rr.width -= 6
	changed := text_field(rr, s, placeholder)

	if s^ != "" && ui.focus != rawptr(s) {
		exists := os.is_dir(s^) if folder else os.is_file(s^)
		if !exists do outline(rr, 6, 1, with_alpha(C_ERROR, 0.7))
	}

	if icon_button(btn, .Folder, .Default) {
		if p, ok := pick_path(folder, title, filter_name, filter_spec); ok {
			set_str(s, p)
			delete(p)
			ui.changed = true
			changed = true
		}
	}

	if st.drop_active && !ui.blocked && point_in(ui.mouse, r) {
		p := st.drop_path
		if folder && !os.is_dir(p) do p = os.dir(p)
		if folder || os.is_file(p) {
			set_str(s, p)
			ui.changed = true
			changed = true
			st.drop_active = false
		}
	}
	if st.drop_active == false && changed && ui.focus == rawptr(s) do ui.focus = nil
	return changed
}

chip :: proc(x, y: f32, text: string, c: Color) -> f32 {
	w := measure(text, .Small) + 18
	r := Rect{x, y, w, 22}
	fill(r, 11, with_alpha(c, 0.14))
	draw_text(text, x + 9, y + 3, .Small, c)
	return w
}

status_dot :: proc(c: Vec2, col: Color) {
	rl.DrawCircleV(c, 4, col)
}

// ---------------------------------------------------------------------------
// Top bar / status bar / toast
// ---------------------------------------------------------------------------

draw_topbar :: proc(r: Rect) {
	fill(r, 0, C_SIDEBAR)
	hline(r.x, r.x + r.width, r.y + r.height - 1, C_BORDER)

	// Logo
	rl.DrawTexturePro(logo_tex, {0, 0, 128, 128}, {r.x + 16, r.y + (r.height - 32) / 2, 32, 32}, {}, 0, rl.WHITE)
	draw_text(APP_TITLE, r.x + 56, r.y + (r.height - font_size[.Heading]) / 2 - 1, .Heading, C_TEXT)

	x := r.x + 220
	if tab(Rect{x, r.y, 116, r.height}, "Apps", st.tab == .Apps, .Grid) do st.tab = .Apps
	if tab(Rect{x + 120, r.y, 130, r.height}, "Settings", st.tab == .Settings, .Gear) do st.tab = .Settings

	// Right side: log toggle
	rr := r
	cut_right(&rr, 14)
	btn := cut_right(&rr, 110)
	btn = inset(btn, 0, 10)
	if button(btn, "Hide log" if st.log_open else "Show log", .Ghost, .Terminal) {
		st.log_open = !st.log_open
	}

	rv := runner_view()
	if rv.state == .Running {
		cut_right(&rr, 10)
		pill := cut_right(&rr, min(360, rr.width - 480))
		pill = inset(pill, 0, 11)
		if pill.width > 120 {
			fill(pill, 16, with_alpha(C_ACCENT_BG, 0.25))
			spinner({pill.x + 18, pill.y + pill.height / 2}, 7, C_ACCENT)
			label(Rect{pill.x + 34, pill.y, pill.width - 90, pill.height}, rv.title, .Small, C_TEXT)
			label(Rect{pill.x, pill.y, pill.width - 14, pill.height}, fmt_elapsed(rv.elapsed), .Small, C_ACCENT, .Right)
		}
	}
}

draw_statusbar :: proc(r: Rect) {
	fill(r, 0, C_SIDEBAR)
	hline(r.x, r.x + r.width, r.y, C_BORDER)
	rv := runner_view()
	rr := inset(r, 14, 0)

	text: string
	col := C_TEXT_DIM
	switch rv.state {
	case .Idle: text = "Ready"
	case .Running:
		text = fmt.tprintf("%s  ·  %s", rv.title, fmt_elapsed(rv.elapsed))
		col = C_ACCENT
	case .Succeeded:
		text = "Last job finished successfully"
		col = C_SUCCESS
	case .Failed:
		text = "Last job failed - check the log"
		col = C_ERROR
	case .Cancelled: text = "Last job was cancelled"
	}

	if rv.state == .Running {
		spinner({rr.x + 7, rr.y + rr.height / 2}, 6, C_ACCENT)
	} else {
		status_dot({rr.x + 6, rr.y + rr.height / 2}, col)
	}
	cut_left(&rr, 20)

	if rv.state == .Running {
		cbtn := cut_right(&rr, 80)
		if button(inset(cbtn, 0, 3), "Cancel", .Subtle_Danger, .Close) do runner_cancel()
	}
	right := fmt.tprintf("%d app%s  ·  %s", len(st.cfg.apps), "" if len(st.cfg.apps) == 1 else "s", "saving…" if st.dirty else "saved")
	rw := measure(right, .Small)
	rt := cut_right(&rr, rw + 16)
	label(rt, right, .Small, C_TEXT_FAINT, .Right)
	label(rr, text, .Small, col)
}

draw_toast :: proc(bottom_y: f32, dt: f32) {
	if st.toast_t <= 0 || st.toast == "" do return
	st.toast_t -= dt
	alpha := clamp(st.toast_t / 0.4, 0, 1)
	col := C_ACCENT
	switch st.toast_kind {
	case .Info: col = C_ACCENT
	case .Success: col = C_SUCCESS
	case .Error: col = C_ERROR
	}
	W := f32(rl.GetScreenWidth())
	w := min(measure(st.toast, .Body) + 56, W - 40)
	r := Rect{W - w - 20, bottom_y - 64, w, 44}
	if st.log_open do r.y -= st.log_h
	rl.DrawRectangleRounded(Rect{r.x + 2, r.y + 4, r.width, r.height}, 0.4, 8, with_alpha(rl.BLACK, 0.35 * alpha))
	fill(r, 8, with_alpha(C_PANEL_HI, alpha))
	outline(r, 8, 1, with_alpha(C_BORDER_HI, alpha))
	fill(Rect{r.x, r.y + 8, 3, r.height - 16}, 1.5, with_alpha(col, alpha))
	label(Rect{r.x + 20, r.y, r.width - 30, r.height}, st.toast, .Body, with_alpha(C_TEXT, alpha))
}

// ---------------------------------------------------------------------------
// Log drawer
// ---------------------------------------------------------------------------

log_line_color :: proc(line: string) -> Color {
	if strings.has_prefix(line, "===") || strings.has_prefix(line, "==") {
		if strings.contains(line, "Failed") do return C_ERROR
		if strings.contains(line, "success") || strings.contains(line, "Done") || strings.contains(line, "installed") do return C_SUCCESS
		return C_ACCENT
	}
	if strings.has_prefix(line, "> ") do return C_TEXT_FAINT
	upper := strings.to_upper(line, context.temp_allocator)
	if strings.contains(upper, "ERROR") || strings.contains(upper, "FAILED") || strings.has_prefix(line, "!!") do return C_ERROR
	if strings.contains(upper, "WARNING") do return C_WARN
	if strings.contains(line, "Successfully") || strings.contains(line, "...OK") do return C_SUCCESS
	if strings.has_prefix(line, "Hint:") do return C_WARN
	return C_TEXT_DIM
}

draw_log :: proc(r: Rect, status_y: f32) {
	fill(r, 0, Color{16, 19, 26, 255})
	hline(r.x, r.x + r.width, r.y, C_BORDER)

	// Resize handle
	handle := Rect{r.x, r.y - 3, r.width, 7}
	if hovered(handle) {
		ui.cursor = .RESIZE_NS
		if ui.pressed {
			st.log_drag = true
			ui.pressed = false
		}
	}
	if st.log_drag {
		if ui.down {
			st.log_h = status_y - ui.mouse.y
			ui.cursor = .RESIZE_NS
		} else {
			st.log_drag = false
		}
	}

	rr := r
	header := inset(cut_top(&rr, 38), 14, 0)
	draw_icon(.Terminal, {header.x + 8, header.y + header.height / 2}, 15, C_TEXT_DIM)
	label(Rect{header.x + 26, header.y, 200, header.height}, "steamcmd output", .Bold, C_TEXT_DIM)

	hb := header
	if icon_button(inset(cut_right(&hb, 30), 0, 5), .Close) do st.log_open = false
	cut_right(&hb, 6)
	if button(inset(cut_right(&hb, 72), 0, 5), "Clear", .Ghost) do log_clear()
	cut_right(&hb, 4)
	if button(inset(cut_right(&hb, 72), 0, 5), "Copy", .Ghost) {
		sync.mutex_lock(&runner.mutex)
		all := strings.join(runner.lines[:], "\r\n", context.temp_allocator)
		sync.mutex_unlock(&runner.mutex)
		rl.SetClipboardText(cstr(all))
		show_toast("Log copied to clipboard")
	}
	cut_right(&hb, 4)
	if button(inset(cut_right(&hb, 148), 0, 5), "Apps folder", .Ghost, .Folder) {
		d := native_path(st.cfg.settings.work_dir)
		os.make_directory_all(d)
		shell_open(d)
	}

	body := inset(rr, 0, 0)
	body.height -= 4
	lh: f32 = 19
	pad: f32 = 6

	sync.mutex_lock(&runner.mutex)
	defer sync.mutex_unlock(&runner.mutex)
	n := len(runner.lines)
	total := f32(n) * lh + pad * 2

	sc := &st.log_scroll
	if st.log_follow {
		sc.content_h = total
		sc.target = max(total - body.height, 0)
	}
	y0 := scroll_begin(sc, body)
	first := max(int((body.y - y0 - pad) / lh), 0)
	last := min(first + int(body.height / lh) + 2, n)
	for i in first ..< last {
		line := runner.lines[i]
		draw_text(line, body.x + 16, y0 + pad + f32(i) * lh, .Mono, log_line_color(line))
	}
	scroll_end(sc, body, y0 + total)
	st.log_follow = sc.target >= sc.content_h - body.height - 2
}

// ---------------------------------------------------------------------------
// Apps tab
// ---------------------------------------------------------------------------

add_app :: proc() {
	append(&st.cfg.apps, app_make())
	st.cfg.selected = len(st.cfg.apps) - 1
	st.tab = .Apps
	st.main_scroll = {}
	ui.focus = nil
	ui.changed = true
}

draw_apps_tab :: proc(r: Rect) {
	rr := r
	side := cut_left(&rr, 272)
	draw_sidebar(side)
	if len(st.cfg.apps) == 0 {
		draw_empty_state(rr)
	} else {
		st.cfg.selected = clamp(st.cfg.selected, 0, len(st.cfg.apps) - 1)
		draw_app_page(rr, &st.cfg.apps[st.cfg.selected])
	}
}

draw_sidebar :: proc(r: Rect) {
	fill(r, 0, C_SIDEBAR)
	rl.DrawRectangleRec(Rect{r.x + r.width - 1, r.y, 1, r.height}, C_BORDER)

	rr := r
	rr.width -= 1
	header := inset(cut_top(&rr, 48), 18, 0)
	draw_text("YOUR APPS", header.x, header.y + 18, .Small, C_TEXT_FAINT)
	if len(st.cfg.apps) > 0 {
		cnt := fmt.tprintf("%d", len(st.cfg.apps))
		draw_text(cnt, header.x + measure("YOUR APPS", .Small) + 8, header.y + 18, .Small, C_TEXT_FAINT)
	}
	if icon_button(Rect{header.x + header.width - 28, header.y + 12, 28, 28}, .Plus) do add_app()

	footer := inset(cut_bottom(&rr, 60), 14, 12)
	if button(footer, "Add app", .Default, .Plus) do add_app()

	rv := runner_view()
	item_h: f32 = 64
	y := scroll_begin(&st.sidebar_scroll, rr)
	for &a, i in st.cfg.apps {
		item := Rect{rr.x + 8, y, rr.width - 16, item_h}
		selected := i == st.cfg.selected
		hot := hovered(item)
		if selected {
			fill(item, 8, C_PANEL_HI)
			fill(Rect{item.x, item.y + 14, 3, item.height - 28}, 1.5, C_ACCENT)
		} else if hot {
			fill(item, 8, C_PANEL)
		}
		if hot do ui.cursor = .POINTING_HAND

		thumb := Rect{item.x + 12, item.y + (item_h - 40) / 2, 86, 40}
		draw_art(thumb, &a)

		tx := thumb.x + thumb.width + 12
		tw := item.x + item.width - tx - 10
		name := a.name if a.name != "" else "Untitled"
		draw_text(fit_text(name, .Bold, tw), tx, item.y + 13, .Bold, C_TEXT if selected else Color{205, 211, 222, 255})

		id := strings.trim_space(a.app_id)
		sub := fmt.tprintf("App %s", id) if id != "" else "No App ID yet"
		sub_col := C_TEXT_FAINT
		uploading := rv.state == .Running && rv.kind == .Build && rv.app_id == id && id != ""
		if uploading {
			sub = "Uploading…"
			sub_col = C_ACCENT
		} else if len(a.history) > 0 {
			last := a.history[len(a.history) - 1]
			status_dot({tx + 4, item.y + 42}, C_SUCCESS if last.success else C_ERROR)
			draw_text(fit_text(sub, .Small, tw - 14), tx + 13, item.y + 34, .Small, sub_col)
			sub = ""
		}
		if sub != "" do draw_text(fit_text(sub, .Small, tw), tx, item.y + 34, .Small, sub_col)
		if uploading do spinner({item.x + item.width - 16, item.y + item_h / 2}, 6, C_ACCENT)

		if clicked(item) && st.cfg.selected != i {
			st.cfg.selected = i
			st.main_scroll = {}
			ui.focus = nil
			ui.changed = true
		}
		y += item_h + 4
	}
	scroll_end(&st.sidebar_scroll, rr, y + 8)
}

draw_empty_state :: proc(r: Rect) {
	cx := r.x + r.width / 2
	cy := r.y + r.height / 2 - 40
	rl.DrawCircleV({cx, cy - 40}, 36, with_alpha(C_ACCENT_BG, 0.3))
	draw_icon(.Upload, {cx, cy - 40}, 30, C_ACCENT)
	label(Rect{r.x, cy + 10, r.width, 30}, "No apps yet", .Title, C_TEXT, .Center)
	label(Rect{r.x, cy + 48, r.width, 22}, "Add a game or app to start pushing builds to Steam.", .Body, C_TEXT_DIM, .Center)
	if button(Rect{cx - 100, cy + 90, 200, 42}, "Add your first app", .Primary, .Plus) do add_app()
}

draw_app_page :: proc(r: Rect, a: ^App) {
	s := &st.cfg.settings
	cw := min(r.width - 56, 1000)
	x := r.x + (r.width - cw) / 2
	y := scroll_begin(&st.main_scroll, r) + 24

	y = draw_hero(x, y, cw, a) + 18
	y = draw_details_card(x, y, cw, a) + 18
	y = draw_depots_card(x, y, cw, a) + 18
	y = draw_upload_card(x, y, cw, a, s) + 18
	y = draw_history_card(x, y, cw, a) + 18

	if button(Rect{x + cw - 150, y, 150, 36}, "Remove app", .Subtle_Danger, .Trash) {
		st.confirm = .Delete_App
		st.confirm_app = st.cfg.selected
	}
	y += 36 + 32
	scroll_end(&st.main_scroll, r, y)
}

draw_hero :: proc(x, y, w: f32, a: ^App) -> f32 {
	h: f32 = 190
	r := Rect{x, y, w, h}
	fill(r, 10, C_PANEL)
	outline(r, 10, 1, C_BORDER)

	img_w := clamp(w * 0.38, 220, 340)
	img := Rect{x + 18, y + 18, img_w, img_w / (460.0 / 215.0)}
	img.y = y + (h - img.height) / 2
	draw_art(img, a, true)

	cx := img.x + img.width + 26
	cw := x + w - 22 - cx
	name := a.name if a.name != "" else "Untitled"
	draw_text(fit_text(name, .Title, cw), cx, y + 22, .Title, C_TEXT)

	id := strings.trim_space(a.app_id)
	chip_x := cx
	chip_x += chip(chip_x, y + 66, fmt.tprintf("App ID %s", id) if id != "" else "No App ID", C_ACCENT if id != "" else C_WARN) + 8
	enabled := 0
	for d in a.depots do if d.enabled do enabled += 1
	chip_x += chip(chip_x, y + 66, fmt.tprintf("%d depot%s", enabled, "" if enabled == 1 else "s"), C_TEXT_DIM) + 8
	if b := strings.trim_space(a.branch); b != "" {
		chip_x += chip(chip_x, y + 66, fmt.tprintf("→ %s", b), C_SUCCESS) + 8
	}
	if a.preview do chip(chip_x, y + 66, "preview", C_WARN)

	ly := y + 102
	if len(a.history) > 0 {
		last := a.history[len(a.history) - 1]
		status_dot({cx + 4, ly + 9}, C_SUCCESS if last.success else C_ERROR)
		txt := fmt.tprintf("Last upload %s%s%s", last.time,
			fmt.tprintf("  ·  BuildID %s", last.build_id) if last.build_id != "" else "",
			"" if last.success else "  ·  failed")
		draw_text(fit_text(txt, .Small, cw - 14), cx + 14, ly + 1, .Small, C_TEXT_DIM)
	} else {
		draw_text("Never uploaded from here", cx, ly + 1, .Small, C_TEXT_FAINT)
	}

	by := y + h - 18 - 34
	bx := cx
	has_id := is_numeric(id)
	if button(Rect{bx, by, 96, 34}, "Store", .Default, .External, has_id) {
		shell_open(fmt.tprintf("https://store.steampowered.com/app/%s/", id))
	}
	bx += 104
	if button(Rect{bx, by, 132, 34}, "Steamworks", .Default, .External, has_id) {
		shell_open(fmt.tprintf("https://partner.steamgames.com/apps/builds/%s", id))
	}
	bx += 140
	fetching := fetch_state(id) == .Fetching
	if button(Rect{bx, by, 34, 34}, "", .Default, .Refresh, has_id && !fetching) {
		set_fetch_state(id, .None)
		invalidate_texture(header_cache_file(&st.cfg.settings, id))
		start_store_fetch(&st.cfg.settings, id)
	}
	if fetching {
		spinner({bx + 52, by + 17}, 7, C_ACCENT)
		draw_text("Fetching store info…", bx + 66, by + 9, .Small, C_TEXT_DIM)
	} else if fetch_state(id) == .Missing && a.custom_image == "" {
		draw_text(fit_text("No public store art (unreleased?)", .Small, x + w - bx - 60), bx + 46, by + 9, .Small, C_TEXT_FAINT)
	}
	return y + h
}

draw_details_card :: proc(x, y, w: f32, a: ^App) -> f32 {
	h: f32 = 56 + FIELD_ROW * 3 + 6
	in_r := card(x, y, w, h, "App details")
	gap: f32 = 16
	col1 := (in_r.width - gap) * 0.62
	col2 := in_r.width - gap - col1

	text_field(form_field(in_r.x, in_r.y, col1, "Name"), &a.name, "My Game")
	id_r := form_field(in_r.x + col1 + gap, in_r.y, col2, "App ID", "from Steamworks")
	if text_field(id_r, &a.app_id, "e.g. 1234560") do dir_stats_invalidate()

	ry := in_r.y + FIELD_ROW
	path_field(
		form_field(in_r.x, ry, in_r.width, "Header image", "optional - defaults to the Steam store header"),
		&a.custom_image, "Use Steam store art", false, "Choose header image", "Images", "*.png;*.jpg;*.jpeg",
	)

	ry += FIELD_ROW
	s := &st.cfg.settings
	default_dir := path_join(native_path(s.work_dir), strings.trim_space(a.app_id)) if is_numeric(strings.trim_space(a.app_id)) else "set the App ID first"
	fr := form_field(in_r.x, ry, in_r.width, "App folder", "holds builds, scripts, output and store art - leave empty for the default")
	open_r := cut_right(&fr, 96)
	fr.width -= 8
	if path_field(fr, &a.folder, default_dir, true, "Choose app folder") do dir_stats_invalidate()
	if button(open_r, "Open", .Default, .External, app_dir(s, a) != "") do open_app_folder(s, a)
	return y + h
}

open_app_folder :: proc(s: ^Settings, a: ^App) {
	if app_dir(s, a) == "" {
		show_toast("Set the App ID first", .Error)
		return
	}
	if !ensure_app_dir(s, a) {
		show_toast(fmt.tprintf("Could not create %s", app_dir(s, a)), .Error)
		return
	}
	dir_stats_invalidate()
	shell_open(app_dir(s, a))
}

chip_button :: proc(x, y: f32, text: string, icon := Icon.None) -> (clicked_it: bool, width: f32) {
	isz: f32 = 10 if icon != .None else 0
	w := measure(text, .Small) + 18 + (isz + 5 if icon != .None else 0)
	r := Rect{x, y, w, 24}
	hot := hovered(r)
	if hot do ui.cursor = .POINTING_HAND
	fill(r, 12, with_alpha(C_ACCENT, 0.24 if hot else 0.13))
	tx := x + 9
	if icon != .None {
		draw_icon(icon, {tx + isz / 2, y + 12}, isz, C_ACCENT)
		tx += isz + 5
	}
	draw_text(text, tx, y + 3, .Small, C_TEXT if hot else C_ACCENT)
	return clicked(r), w
}

next_depot_id :: proc(a: ^App) -> string {
	id := strings.trim_space(a.app_id)
	if !is_numeric(id) do return ""
	base := 0
	for c in id do base = base * 10 + int(c - '0')
	// Next id after the highest existing depot id (Steam numbers depots app_id+1, +2, ...).
	best := base
	for &d in a.depots {
		did := strings.trim_space(d.id)
		if !is_numeric(did) || len(did) > 12 do continue
		v := 0
		for c in did do v = v * 10 + int(c - '0')
		best = max(best, v)
	}
	return fmt.tprintf("%d", best + 1)
}

draw_depots_card :: proc(x, y, w: f32, a: ^App) -> f32 {
	s := &st.cfg.settings
	row_h: f32 = 68
	n := f32(len(a.depots))
	unused := unused_build_folders(s, a)
	has_app_dir := app_dir(s, a) != ""
	h: f32 = 56 + 24 + n * row_h + 6 + (34 if len(unused) > 0 else 0) + 34 + 22
	subtitle := fmt.tprintf("put each depot's files in builds%s<label> inside the app folder", SEP)
	in_r := card(x, y, w, h, "Depots", subtitle)

	gap: f32 = 8
	iw := in_r.width
	w_chk: f32 = 26
	w_id := clamp(iw * 0.12, 80, 110)
	w_label := clamp(iw * 0.15, 90, 140)
	w_excl := clamp(iw * 0.17, 100, 170)
	w_del: f32 = 34
	w_path := iw - (w_chk + w_id + w_label + w_excl + w_del + gap * 5)

	// Column headers
	hx := in_r.x + w_chk + gap
	draw_text("Depot ID", hx, in_r.y, .Small, C_TEXT_FAINT); hx += w_id + gap
	draw_text("Label", hx, in_r.y, .Small, C_TEXT_FAINT); hx += w_label + gap
	draw_text("Build folder", hx, in_r.y, .Small, C_TEXT_FAINT); hx += w_path + gap
	draw_text("Exclude (; separated)", hx, in_r.y, .Small, C_TEXT_FAINT)

	ry := in_r.y + 24
	remove_idx := -1
	for &d, i in a.depots {
		rr := Rect{in_r.x, ry, iw, 36}
		if i > 0 do hline(in_r.x, in_r.x + iw, ry - 8, with_alpha(C_BORDER, 0.6))
		c := cut_left(&rr, w_chk)
		checkbox(Rect{c.x + 2, c.y, 22, c.height}, &d.enabled, "")
		cut_left(&rr, gap)
		text_field(cut_left(&rr, w_id), &d.id, "1234561")
		cut_left(&rr, gap)
		if text_field(cut_left(&rr, w_label), &d.label, "Windows") do dir_stats_invalidate()
		cut_left(&rr, gap)
		draw_build_folder_cell(cut_left(&rr, w_path), s, a, &d)
		cut_left(&rr, gap)
		text_field(cut_left(&rr, w_excl), &d.exclusions, "*.pdb;*.log")
		cut_left(&rr, gap)
		if icon_button(cut_left(&rr, w_del), .Trash, .Subtle_Danger) do remove_idx = i
		ry += row_h
	}
	if remove_idx >= 0 {
		depot_destroy(&a.depots[remove_idx])
		ordered_remove(&a.depots, remove_idx)
		ui.focus = nil
		ui.changed = true
	}
	ry += 6

	// Folders that exist in builds\ but have no depot yet
	if len(unused) > 0 {
		cx := in_r.x
		lbl := "Found in builds:"
		draw_text(lbl, cx, ry + 4, .Small, C_TEXT_DIM)
		cx += measure(lbl, .Small) + 10
		for name in unused {
			hit, cw := chip_button(cx, ry, name, .Plus)
			if cx + cw > in_r.x + iw do break
			if hit {
				d := depot_make(next_depot_id(a), name)
				free_str(&d.exclusions)
				d.exclusions = strings.clone("*.pdb")
				append(&a.depots, d)
				dir_stats_invalidate()
				ui.changed = true
			}
			cx += cw + 6
		}
		ry += 34
	}

	if button(Rect{in_r.x, ry, 136, 34}, "Add depot", .Default, .Plus) {
		label := "Windows" if len(a.depots) == 0 else fmt.tprintf("Depot %d", len(a.depots) + 1)
		append(&a.depots, depot_make(next_depot_id(a), label))
		if has_app_dir do ensure_app_dir(s, a)
		dir_stats_invalidate()
		ui.changed = true
	}
	if button(Rect{in_r.x + 144, ry, 170, 34}, "Open builds folder", .Ghost, .Folder, has_app_dir) {
		ensure_app_dir(s, a)
		os.make_directory_all(builds_dir(s, a))
		dir_stats_invalidate()
		shell_open(builds_dir(s, a))
	}
	tip_x := in_r.x + 330
	tip := "Tip: create a folder in builds and it shows up here as a new depot." if has_app_dir else "Set the App ID to create the app's builds folder."
	draw_text(fit_text(tip, .Small, in_r.x + iw - tip_x), tip_x, ry + 9, .Small, C_TEXT_FAINT)
	return y + h
}

// Shows where a depot's files come from (builds\<label> by default) with live
// folder stats, an Open button and an optional custom-folder override.
draw_build_folder_cell :: proc(r: Rect, s: ^Settings, a: ^App, d: ^Depot) {
	rr := r
	custom := strings.trim_space(d.content_path) != ""
	reset_r: Rect
	if custom do reset_r = cut_right(&rr, 34)
	browse_r := cut_right(&rr, 34)
	open_r := cut_right(&rr, 34)
	rr.width -= 6
	dir := depot_content_dir(s, a, d)

	// Path box
	fill(rr, 6, C_INPUT)
	outline(rr, 6, 1, C_BORDER)
	inner := inset(rr, 10, 0)
	shown: string
	col := C_TEXT
	switch {
	case dir == "":
		shown = "set App ID + label first"
		col = C_TEXT_FAINT
	case custom:
		shown = dir
	case:
		shown = path_join("builds", depot_folder_name(d))
	}
	label(inner, shown, .Body, col)

	// Drop a folder on it -> custom location
	if st.drop_active && !ui.blocked && point_in(ui.mouse, r) {
		p := st.drop_path
		if !os.is_dir(p) do p = os.dir(p)
		set_str(&d.content_path, p)
		st.drop_active = false
		dir_stats_invalidate()
		ui.changed = true
	}

	if icon_button(open_r, .Folder, .Default, dir != "") {
		os.make_directory_all(dir)
		dir_stats_invalidate()
		shell_open(dir)
	}
	if button(browse_r, "…", .Ghost) {
		if p, ok := pick_path(true, "Use a different folder for this depot"); ok {
			set_str(&d.content_path, p)
			delete(p)
			dir_stats_invalidate()
			ui.changed = true
		}
	}
	if custom && icon_button(reset_r, .Close, .Ghost) {
		free_str(&d.content_path)
		dir_stats_invalidate()
		ui.changed = true
	}

	// Status line under the row
	sy := r.y + r.height + 4
	if dir == "" do return
	ds := dir_stats(dir)
	txt: string
	scol: Color
	switch {
	case !ds.exists:
		txt = "not created yet - click the folder button"
		scol = C_TEXT_FAINT
	case ds.files == 0:
		txt = "empty - copy this depot's build files here"
		scol = C_WARN
	case:
		txt = fmt.tprintf("%d file%s  ·  %s  ·  updated %s", ds.files, "" if ds.files == 1 else "s", fmt_bytes(ds.bytes), fmt_ago(ds.newest))
		scol = C_SUCCESS
	}
	if custom do txt = fmt.tprintf("%s  ·  custom folder", txt)
	status_dot({r.x + 4, sy + 9}, scol)
	draw_text(fit_text(txt, .Small, r.width - 14), r.x + 13, sy + 1, .Small, scol if ds.files > 0 || !ds.exists else C_WARN)
}


draw_upload_card :: proc(x, y, w: f32, a: ^App, s: ^Settings) -> f32 {
	h: f32 = 56 + FIELD_ROW * 2 + 30 + 46 + 4
	in_r := card(x, y, w, h, "Upload")

	text_field(form_field(in_r.x, in_r.y, in_r.width, "Build description", "shown in the Steamworks build list"), &a.description, "v1.2.3 - bug fixes")

	ry := in_r.y + FIELD_ROW
	bw := min(300, in_r.width * 0.45)
	text_field(form_field(in_r.x, ry, bw, "Set live on branch", "optional"), &a.branch, "none - just upload (e.g. beta)")
	cb_w: f32 = 230
	checkbox(Rect{in_r.x + bw + 24, ry + 22, cb_w, 36}, &a.preview, "Preview only (no upload)")
	ry += FIELD_ROW
	msg := validate_app(s, a)
	rv := runner_view()
	busy := rv.state == .Running
	this_running := busy && rv.kind == .Build && rv.app_id == strings.trim_space(a.app_id)

	branch := strings.to_lower(strings.trim_space(a.branch), context.temp_allocator)
	if msg != "" {
		draw_icon(.Close, {in_r.x + 7, ry + 9}, 12, C_WARN)
		draw_text(fit_text(msg, .Small, in_r.width - 20), in_r.x + 20, ry + 1, .Small, C_WARN)
	} else if branch == "default" {
		draw_text(fit_text("Note: steamcmd can't set the default branch live on released apps - do that in Steamworks.", .Small, in_r.width), in_r.x, ry + 1, .Small, C_WARN)
	} else {
		enabled := 0
		for d in a.depots do if d.enabled do enabled += 1
		draw_icon(.Check, {in_r.x + 7, ry + 9}, 12, C_SUCCESS)
		txt := fmt.tprintf("Ready: %d depot%s as '%s'%s", enabled, "" if enabled == 1 else "s", strings.trim_space(s.username),
			fmt.tprintf(", then set live on '%s'", strings.trim_space(a.branch)) if branch != "" else "")
		draw_text(fit_text(txt, .Small, in_r.width - 20), in_r.x + 20, ry + 1, .Small, C_SUCCESS)
	}

	ry += 30
	bx := in_r.x
	if this_running {
		spinner({bx + 16, ry + 21}, 8, C_ACCENT)
		draw_text(fmt.tprintf("Uploading…  %s", fmt_elapsed(rv.elapsed)), bx + 34, ry + 12, .Bold, C_ACCENT)
		bx += 150
		if button(Rect{bx, ry, 120, 42}, "Cancel", .Danger, .Close) do runner_cancel()
		bx += 128
	} else {
		label_txt := "Run preview" if a.preview else "Upload build"
		if button(Rect{bx, ry, 180, 42}, label_txt, .Primary, .Upload, msg == "" && !busy) {
			if s.confirm_upload {
				st.confirm = .Upload
				st.confirm_app = st.cfg.selected
			} else {
				do_upload(a)
			}
		}
		bx += 188
	}
	if button(Rect{bx, ry + 4, 160, 34}, "Generate scripts", .Default, .File, msg == "") {
		path, err := write_build_scripts(s, a)
		if err != "" do show_toast(err, .Error)
		else do show_toast(fmt.tprintf("Wrote %s", os.base(path)), .Success)
	}
	bx += 168
	if button(Rect{bx, ry + 4, 150, 34}, "App folder", .Ghost, .Folder) do open_app_folder(s, a)
	return y + h
}

draw_history_card :: proc(x, y, w: f32, a: ^App) -> f32 {
	row_h: f32 = 34
	shown := min(len(a.history), 10)
	h: f32 = 56 + 30 + 10 if shown == 0 else 56 + 22 + f32(shown) * row_h + 8
	in_r := card(x, y, w, h, "Recent uploads", fmt.tprintf("%d total", len(a.history)) if len(a.history) > 0 else "")

	if shown == 0 {
		draw_text("No uploads yet. Your builds will show up here.", in_r.x, in_r.y + 2, .Body, C_TEXT_FAINT)
		return y + h
	}
	if button(Rect{x + w - 22 - 70, y + 14, 70, 30}, "Clear", .Ghost) {
		st.confirm = .Clear_History
		st.confirm_app = st.cfg.selected
	}

	iw := in_r.width
	c_when := in_r.x + 18
	c_build := c_when + 150
	c_branch := c_build + 120
	c_desc := c_branch + 120
	draw_text("When", c_when, in_r.y, .Small, C_TEXT_FAINT)
	draw_text("BuildID", c_build, in_r.y, .Small, C_TEXT_FAINT)
	draw_text("Branch", c_branch, in_r.y, .Small, C_TEXT_FAINT)
	draw_text("Description", c_desc, in_r.y, .Small, C_TEXT_FAINT)

	ry := in_r.y + 22
	for k in 0 ..< shown {
		rec := a.history[len(a.history) - 1 - k]
		row := Rect{in_r.x - 8, ry, iw + 16, row_h}
		if k % 2 == 0 do fill(row, 6, with_alpha(C_PANEL_HI, 0.5))
		ty := ry + (row_h - font_size[.Body]) / 2 - 1
		status_dot({in_r.x + 4, ry + row_h / 2}, C_SUCCESS if rec.success else C_ERROR)
		draw_text(rec.time, c_when, ty, .Body, C_TEXT)
		bid := rec.build_id if rec.build_id != "" else ("preview" if rec.preview else "-")
		draw_text(bid, c_build, ty, .Body, C_TEXT_DIM if rec.build_id == "" else C_ACCENT)
		draw_text(fit_text(rec.branch if rec.branch != "" else "-", .Body, 110), c_branch, ty, .Body, C_TEXT_DIM)
		desc := rec.desc if rec.success else fmt.tprintf("FAILED  ·  %s", rec.desc)
		draw_text(fit_text(desc, .Body, in_r.x + iw - c_desc), c_desc, ty, .Body, C_TEXT_DIM if rec.success else C_ERROR)
		ry += row_h
	}
	return y + h
}

// ---------------------------------------------------------------------------
// Settings tab
// ---------------------------------------------------------------------------

draw_settings_tab :: proc(r: Rect) {
	s := &st.cfg.settings
	cw := min(r.width - 56, 780)
	x := r.x + (r.width - cw) / 2
	y := scroll_begin(&st.settings_scroll, r) + 28

	draw_text("Settings", x, y, .Title, C_TEXT)
	y += 52

	// --- SteamCMD
	{
		h: f32 = 56 + FIELD_ROW + 28 + 40 + 4
		in_r := card(x, y, cw, h, "SteamCMD", "Valve's command line tool that performs the upload")
		path_field(form_field(in_r.x, in_r.y, in_r.width, "steamcmd location"), &s.steamcmd_path,
			STEAMCMD_HINT, false, "Locate " + STEAMCMD_EXE, "steamcmd", STEAMCMD_EXE)
		ry := in_r.y + FIELD_ROW
		found := s.steamcmd_path != "" && os.is_file(s.steamcmd_path)
		if found {
			draw_icon(.Check, {in_r.x + 7, ry + 9}, 12, C_SUCCESS)
			draw_text("steamcmd found", in_r.x + 20, ry + 1, .Small, C_SUCCESS)
		} else {
			draw_icon(.Close, {in_r.x + 7, ry + 9}, 12, C_WARN)
			draw_text("Not found - click Install for a one-click download from Valve, or browse to an existing steamcmd.", in_r.x + 20, ry + 1, .Small, C_WARN)
		}
		ry += 28
		rv := runner_view()
		installing := rv.state == .Running && rv.kind == .Install_SteamCMD
		bx := in_r.x
		if installing {
			spinner({bx + 14, ry + 17}, 8, C_ACCENT)
			draw_text(fmt.tprintf("Installing SteamCMD…  %s", fmt_elapsed(rv.elapsed)), bx + 32, ry + 8, .Bold, C_ACCENT)
			bx += 260
		} else {
			install_dir := path_join(st.exe_dir, "steamcmd")
			label_txt := "Reinstall SteamCMD" if found else "Install SteamCMD"
			if button(Rect{bx, ry, 200, 34}, label_txt, .Default if found else .Primary, .Upload, rv.state != .Running) {
				if msg := start_install_steamcmd(install_dir); msg != "" do show_toast(msg, .Error)
				else do st.log_open = true
			}
			bx += 208
		}
		if button(Rect{bx, ry, 150, 34}, "Open folder", .Ghost, .Folder, found) {
			shell_open(os.dir(native_path(s.steamcmd_path)))
		}
		bx += 158
		if button(Rect{bx, ry, 120, 34}, "Docs", .Ghost, .External) {
			shell_open("https://developer.valvesoftware.com/wiki/SteamCMD#" + ODIN_OS_STRING)
		}
		if !installing && !found {
			draw_text(fit_text(fmt.tprintf("installs to %s", path_join(st.exe_dir, "steamcmd")), .Small, in_r.x + in_r.width - bx - 130), bx + 130, ry + 9, .Small, C_TEXT_FAINT)
		}
		y += h + 18
	}

	// --- Account
	{
		info := "The Steam account that uploads builds needs access to the app in Steamworks (Edit App Metadata + Publish App Changes To Steam). " +
			"After one successful login steamcmd remembers this PC, so later uploads usually don't need the password or a code. " +
			"If Steam asks for a Steam Guard code, enter the one from your email or the Steam mobile app and log in again. " +
			"The password is handed to steamcmd when it runs and never written to the log."
		ph := paragraph(0, 0, cw - 44, info, .Small, C_TEXT_DIM, false)
		h: f32 = 56 + FIELD_ROW * 2 + 28 + ph + 12 + 40 + 4
		in_r := card(x, y, cw, h, "Steam account", "the login used to upload builds")
		gap: f32 = 16
		col := (in_r.width - gap) / 2

		// Row 1: username | password + show/hide
		ry := in_r.y
		text_field(form_field(in_r.x, ry, col, "Username"), &s.username, "Steam account name")
		pr := form_field(in_r.x + col + gap, ry, col, "Password", "optional if already logged in")
		toggle := cut_right(&pr, 70)
		pr.width -= 6
		if text_field(pr, &st.password, "Steam password", mask = !st.show_password) {
			if s.remember_password do save_password()
			st.login_ok = false
		}
		if button(toggle, "Hide" if st.show_password else "Show", .Default) do st.show_password = !st.show_password

		// Row 2: Steam Guard code | remember password
		ry += FIELD_ROW
		gr := form_field(in_r.x, ry, col, "Steam Guard code", "only when Steam asks for one")
		text_field(gr, &st.guard_code, "e.g. 7KD2X")
		if st.guard_needed && st.guard_code == "" do outline(gr, 6, 1.5, C_WARN)
		if checkbox(Rect{in_r.x + col + gap, ry + 22, col, 36}, &s.remember_password, "Remember password on this PC (encrypted)") {
			if s.remember_password do save_password()
			else {
				secret_encrypt("") // macOS: removes the Keychain item
				free_str(&s.password_enc)
			}
		}

		// Status
		ry += FIELD_ROW
		rv := runner_view()
		logging_in := rv.state == .Running && rv.kind == .Login_Check
		switch {
		case logging_in:
			spinner({in_r.x + 7, ry + 9}, 6, C_ACCENT)
			draw_text("Logging in to Steam…", in_r.x + 20, ry + 1, .Small, C_ACCENT)
		case st.login_status != "":
			col_s := C_SUCCESS if st.login_ok else C_ERROR
			draw_icon(.Check if st.login_ok else .Close, {in_r.x + 7, ry + 9}, 12, col_s)
			draw_text(fit_text(st.login_status, .Small, in_r.width - 20), in_r.x + 20, ry + 1, .Small, col_s)
		case:
			draw_text("Not checked yet", in_r.x, ry + 1, .Small, C_TEXT_FAINT)
		}
		ry += 28

		paragraph(in_r.x, ry, in_r.width, info, .Small, C_TEXT_DIM)
		ry += ph + 12

		has := strings.trim_space(s.username) != "" && os.is_file(s.steamcmd_path)
		busy := rv.state == .Running
		if button(Rect{in_r.x, ry, 170, 36}, "Log in", .Primary, .Check, has && !busy) {
			if msg := start_login_check(s, take_credentials()); msg != "" do show_toast(msg, .Error)
		}
		if button(Rect{in_r.x + 178, ry, 230, 36}, "Log in via console…", .Default, .Terminal, has) {
			if msg := open_login_console(s); msg != "" do show_toast(msg, .Error)
		}
		if !has {
			hint := "Install SteamCMD first" if !os.is_file(s.steamcmd_path) else "Enter your username first"
			draw_text(hint, in_r.x + 422, ry + 10, .Small, C_TEXT_FAINT)
		}
		y += h + 18
	}

	// --- Workspace
	{
		h: f32 = 56 + FIELD_ROW + 26 + 40 + 4
		in_r := card(x, y, cw, h, "Workspace")
		wf := form_field(in_r.x, in_r.y, in_r.width, "Working folder", "contains one folder per app")
		if path_field(wf, &s.work_dir, "folder for your apps", true, "Choose working folder") do dir_stats_invalidate()
		ry := in_r.y + FIELD_ROW
		draw_text(fit_text(fmt.tprintf("Layout: %s  (+ scripts, output, store art)", path_join(native_path(s.work_dir), "<AppID>", "builds", "<Depot>")), .Small, in_r.width), in_r.x, ry, .Small, C_TEXT_FAINT)
		ry += 26
		if button(Rect{in_r.x, ry, 150, 34}, "Open folder", .Default, .Folder) {
			d := native_path(s.work_dir)
			os.make_directory_all(d)
			shell_open(d)
		}
		if button(Rect{in_r.x + 158, ry, 180, 34}, "Clear art cache", .Ghost, .Refresh) {
			clear_art_cache()
		}
		y += h + 18
	}

	// --- Preferences
	{
		h: f32 = 56 + 36 * 3 + 6
		in_r := card(x, y, cw, h, "Preferences")
		checkbox(Rect{in_r.x, in_r.y, in_r.width, 32}, &s.auto_fetch_art, "Fetch header art and names from the Steam store automatically")
		checkbox(Rect{in_r.x, in_r.y + 36, in_r.width, 32}, &s.confirm_upload, "Ask for confirmation before uploading")
		checkbox(Rect{in_r.x, in_r.y + 72, in_r.width, 32}, &s.show_log_on_run, "Open the output log when a build starts")
		y += h + 18
	}

	draw_text(fit_text(fmt.tprintf("Config file: %s   ·   %s+S to save (autosaves anyway)", config_path(st.exe_dir), MOD_KEY_NAME), .Small, cw), x, y, .Small, C_TEXT_FAINT)
	y += 50
	scroll_end(&st.settings_scroll, r, y)
}

clear_art_cache :: proc() {
	for k, v in st.textures {
		if v.ok do rl.UnloadTexture(v.tex)
		delete(k)
	}
	clear(&st.textures)
	sync.mutex_lock(&store_fetch.mutex)
	for k in store_fetch.pending do delete(k)
	clear(&store_fetch.pending)
	sync.mutex_unlock(&store_fetch.mutex)
	for &a in st.cfg.apps {
		id := strings.trim_space(a.app_id)
		if !is_numeric(id) do continue
		os.remove(header_cache_file(&st.cfg.settings, id))
		os.remove(details_cache_file(&st.cfg.settings, id))
	}
	show_toast("Art cache cleared")
}

// ---------------------------------------------------------------------------
// Confirm modal
// ---------------------------------------------------------------------------

draw_confirm :: proc() {
	W := f32(rl.GetScreenWidth())
	H := f32(rl.GetScreenHeight())
	rl.DrawRectangleRec(Rect{0, 0, W, H}, with_alpha(rl.BLACK, 0.55))

	if st.confirm_app < 0 || st.confirm_app >= len(st.cfg.apps) {
		st.confirm = .None
		return
	}
	a := &st.cfg.apps[st.confirm_app]
	s := &st.cfg.settings

	title, msg, ok_label: string
	style := Button_Style.Primary
	switch st.confirm {
	case .None: return
	case .Delete_App:
		title = fmt.tprintf("Remove '%s'?", a.name)
		msg = "This only removes the app from SteamBuildGui. Nothing on Steam changes and your build folders stay on disk."
		ok_label = "Remove"
		style = .Danger
	case .Upload:
		enabled := 0
		for d in a.depots do if d.enabled do enabled += 1
		b := strings.trim_space(a.branch)
		title = "Run preview build?" if a.preview else "Upload build to Steam?"
		msg = fmt.tprintf("%s (App %s): %d depot%s as '%s'. %s",
			a.name, strings.trim_space(a.app_id), enabled, "" if enabled == 1 else "s", strings.trim_space(s.username),
			fmt.tprintf("The build will be set live on branch '%s'.", b) if b != "" else "The build will not be set live on any branch.")
		ok_label = "Preview" if a.preview else "Upload"
	case .Clear_History:
		title = "Clear upload history?"
		msg = fmt.tprintf("Removes the local history of %d upload(s) for %s. Builds on Steam are unaffected.", len(a.history), a.name)
		ok_label = "Clear"
		style = .Danger
	}

	bw: f32 = 480
	ph := paragraph(0, 0, bw - 56, msg, .Body, C_TEXT_DIM, false)
	bh := 28 + 30 + 14 + ph + 24 + 40 + 24
	box := Rect{(W - bw) / 2, (H - bh) / 2 - 20, bw, bh}
	rl.DrawRectangleRounded(Rect{box.x, box.y + 8, box.width, box.height}, 0.08, 8, with_alpha(rl.BLACK, 0.4))
	fill(box, 12, C_PANEL)
	outline(box, 12, 1, C_BORDER_HI)
	draw_text(fit_text(title, .Heading, bw - 56), box.x + 28, box.y + 28, .Heading, C_TEXT)
	paragraph(box.x + 28, box.y + 72, bw - 56, msg, .Body, C_TEXT_DIM)

	by := box.y + box.height - 24 - 40
	ok_r := Rect{box.x + box.width - 28 - 130, by, 130, 40}
	cancel_r := Rect{ok_r.x - 8 - 110, by, 110, 40}

	cancel := button(cancel_r, "Cancel", .Default) || rl.IsKeyPressed(.ESCAPE)
	confirm := button(ok_r, ok_label, style) || rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER)
	if ui.pressed && !point_in(ui.mouse, box) do cancel = true

	if confirm {
		kind := st.confirm
		st.confirm = .None
		switch kind {
		case .None:
		case .Upload: do_upload(a)
		case .Delete_App:
			app_destroy(a)
			ordered_remove(&st.cfg.apps, st.confirm_app)
			st.cfg.selected = clamp(st.cfg.selected, 0, max(len(st.cfg.apps) - 1, 0))
			st.main_scroll = {}
			ui.changed = true
		case .Clear_History:
			for &rec in a.history do record_destroy(&rec)
			clear(&a.history)
			ui.changed = true
		}
	} else if cancel {
		st.confirm = .None
	}
}

