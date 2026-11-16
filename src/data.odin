package SteamBuildPusher

import "core:encoding/json"
import "core:fmt"
import os "core:os"
import "core:strings"

CONFIG_FILE :: "steambuildgui.json"

Depot :: struct {
	enabled:      bool,
	id:           string,
	label:        string, // e.g. "Windows", "Linux", "Soundtrack"
	content_path: string, // local folder that gets uploaded
	exclusions:   string, // semicolon separated wildcards, e.g. "*.pdb;*.log"
}

Build_Record :: struct {
	time:     string,
	build_id: string,
	branch:   string,
	desc:     string,
	preview:  bool,
	success:  bool,
}

App :: struct {
	name:         string,
	app_id:       string,
	description:  string, // build description shown in Steamworks
	branch:       string, // branch to set live after upload ("" = none)
	preview:      bool,   // preview mode: steamcmd only builds the manifest, no upload
	custom_image: string, // optional local header image override
	folder:       string, // per-app working folder (scripts, output). "" = auto from name until first build
	depots:       [dynamic]Depot,
	history:      [dynamic]Build_Record,
}

Settings :: struct {
	steamcmd_path:   string,
	username:        string,
	work_dir:        string, // where generated VDFs + build output/logs live
	auto_fetch_art:  bool,
	confirm_upload:  bool,
	show_log_on_run: bool,
	remember_password: bool,
	password_enc:    string, // DPAPI-encrypted (base64); only set when remember_password is on
}

Config :: struct {
	settings: Settings,
	apps:     [dynamic]App,
	selected: int,
}

// --- string ownership helpers ------------------------------------------------
// Every string stored in Config is heap-owned so it can be freed on edit.

set_str :: proc(dst: ^string, value: string) {
	old := dst^
	dst^ = strings.clone(value)
	if len(old) > 0 do delete(old)
}

free_str :: proc(s: ^string) {
	if len(s^) > 0 do delete(s^)
	s^ = ""
}

depot_make :: proc(id := "", label := "Windows") -> Depot {
	return Depot{enabled = true, id = strings.clone(id), label = strings.clone(label), exclusions = strings.clone("*.pdb")}
}

depot_destroy :: proc(d: ^Depot) {
	free_str(&d.id)
	free_str(&d.label)
	free_str(&d.content_path)
	free_str(&d.exclusions)
}

record_destroy :: proc(r: ^Build_Record) {
	free_str(&r.time)
	free_str(&r.build_id)
	free_str(&r.branch)
	free_str(&r.desc)
}

app_make :: proc() -> App {
	a := App {
		name        = strings.clone("New App"),
		description = strings.clone("Uploaded with SteamBuildGui"),
	}
	append(&a.depots, depot_make())
	return a
}

app_destroy :: proc(a: ^App) {
	free_str(&a.name)
	free_str(&a.app_id)
	free_str(&a.description)
	free_str(&a.branch)
	free_str(&a.custom_image)
	free_str(&a.folder)
	for &d in a.depots do depot_destroy(&d)
	delete(a.depots)
	for &r in a.history do record_destroy(&r)
	delete(a.history)
}

default_settings :: proc(exe_dir: string) -> Settings {
	s := Settings {
		auto_fetch_art  = true,
		confirm_upload  = true,
		show_log_on_run = true,
	}
	s.work_dir = strings.concatenate({exe_dir, "\\steam_build"})
	// Common steamcmd locations
	candidates := []string{
		"C:\\steamcmd\\steamcmd.exe",
		"C:\\SteamCMD\\steamcmd.exe",
		"C:\\Program Files\\steamcmd\\steamcmd.exe",
	}
	for c in candidates {
		if os.exists(c) {
			s.steamcmd_path = strings.clone(c)
			break
		}
	}
	return s
}

config_path :: proc(exe_dir: string) -> string {
	return fmt.tprintf("%s\\%s", exe_dir, CONFIG_FILE)
}

config_load :: proc(exe_dir: string) -> Config {
	cfg: Config
	data, err := os.read_entire_file(config_path(exe_dir), context.allocator)
	if err == nil {
		defer delete(data)
		if json.unmarshal(data, &cfg) == nil {
			if cfg.settings.work_dir == "" {
				cfg.settings.work_dir = strings.concatenate({exe_dir, "\\steam_build"})
			}
			cfg.selected = clamp(cfg.selected, 0, max(len(cfg.apps) - 1, 0))
			return cfg
		}
		// Corrupt config: keep a backup rather than overwrite silently.
		_ = os.write_entire_file(fmt.tprintf("%s.bak", config_path(exe_dir)), data)
		cfg = {}
	}
	cfg.settings = default_settings(exe_dir)
	return cfg
}

config_save :: proc(cfg: ^Config, exe_dir: string) -> bool {
	data, err := json.marshal(cfg^, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err != nil do return false
	return os.write_entire_file(config_path(exe_dir), data) == nil
}
