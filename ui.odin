package SteamBuildPusher

import "core:math"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

Rect :: rl.Rectangle
Vec2 :: rl.Vector2
Color :: rl.Color

// ---------------------------------------------------------------------------
// Theme (dark slate / Steam-ish blue, soft contrast)
// ---------------------------------------------------------------------------

C_BG :: Color{19, 23, 31, 255}
C_SIDEBAR :: Color{24, 29, 39, 255}
C_PANEL :: Color{30, 36, 48, 255}
C_PANEL_HI :: Color{37, 44, 58, 255}
C_INPUT :: Color{21, 25, 34, 255}
C_BORDER :: Color{54, 63, 81, 255}
C_BORDER_HI :: Color{80, 92, 116, 255}
C_TEXT :: Color{238, 241, 246, 255}
C_TEXT_DIM :: Color{172, 181, 197, 255}
C_TEXT_FAINT :: Color{128, 138, 156, 255}
C_ACCENT :: Color{118, 202, 250, 255}
C_ACCENT_BG :: Color{38, 120, 178, 255}
C_ACCENT_BG_HI :: Color{52, 140, 200, 255}
C_SUCCESS :: Color{132, 210, 104, 255}
C_WARN :: Color{230, 184, 82, 255}
C_ERROR :: Color{244, 112, 112, 255}
C_ERROR_BG :: Color{150, 52, 52, 255}

Font_Kind :: enum {
	Small,
	Body,
	Bold,
	Heading,
	Title,
	Mono,
}

fonts: [Font_Kind]rl.Font
font_size: [Font_Kind]f32 = {
	.Small   = 14,
	.Body    = 16,
	.Bold    = 16,
	.Heading = 20,
	.Title   = 30,
	.Mono    = 15,
}

load_fonts :: proc() {
	// Latin-1 + a few punctuation glyphs.
	cps := make([dynamic]rune, context.temp_allocator)
	for c in rune(32) ..= rune(255) do append(&cps, c)
	for c in ([]rune{'•', '…', '—', '–', '→', '←', '↑', '↓', '·'}) do append(&cps, c)

	load :: proc(paths: []cstring, size: f32, cps: []rune) -> rl.Font {
		for p in paths {
			if rl.FileExists(p) {
				f := rl.LoadFontEx(p, i32(size), raw_data(cps), i32(len(cps)))
				if f.glyphCount > 0 {
					rl.SetTextureFilter(f.texture, .BILINEAR)
					return f
				}
			}
		}
		return rl.GetFontDefault()
	}
	ui_regular := []cstring{"C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/arial.ttf"}
	ui_semibold := []cstring{"C:/Windows/Fonts/seguisb.ttf", "C:/Windows/Fonts/segoeuib.ttf", "C:/Windows/Fonts/arialbd.ttf"}
	mono := []cstring{"C:/Windows/Fonts/CascadiaMono.ttf", "C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/cour.ttf"}

	fonts[.Small] = load(ui_regular, font_size[.Small], cps[:])
	fonts[.Body] = load(ui_regular, font_size[.Body], cps[:])
	fonts[.Bold] = load(ui_semibold, font_size[.Bold], cps[:])
	fonts[.Heading] = load(ui_semibold, font_size[.Heading], cps[:])
	fonts[.Title] = load(ui_semibold, font_size[.Title], cps[:])
	fonts[.Mono] = load(mono, font_size[.Mono], cps[:])
}

// ---------------------------------------------------------------------------
// UI state
// ---------------------------------------------------------------------------

UI :: struct {
	mouse:           Vec2,
	pressed:         bool, // left click this frame (consumed by the first widget that uses it)
	pressed_raw:     bool,
	down:            bool,
	released:        bool,
	wheel:           f32,
	blocked:         bool, // all widgets ignore input (e.g. a modal is open)
	changed:         bool, // some editable value changed this frame (drives autosave)
	clip_stack:      [dynamic]Rect,
	cursor:          rl.MouseCursor,
	time:            f32,

	// text editing
	focus:           rawptr,
	focus_next:      bool,
	focus_drawn:     bool,
	buf:             [dynamic]u8,
	caret:           int,
	anchor:          int,
	edit_scroll:     f32,
	caret_t:         f32,
	drag_select:     bool,

	// scrollbar dragging
	drag_scroll:     ^Scroll,
	drag_scroll_off: f32,
}

ui: UI

ui_begin_frame :: proc() {
	ui.mouse = rl.GetMousePosition()
	ui.pressed = rl.IsMouseButtonPressed(.LEFT)
	ui.pressed_raw = ui.pressed
	ui.down = rl.IsMouseButtonDown(.LEFT)
	ui.released = rl.IsMouseButtonReleased(.LEFT)
	ui.wheel = rl.GetMouseWheelMove()
	ui.cursor = .DEFAULT
	ui.time += rl.GetFrameTime()
	ui.caret_t += rl.GetFrameTime()
	ui.focus_drawn = false
	clear(&ui.clip_stack)
	append(&ui.clip_stack, Rect{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())})
	if !ui.down {
		ui.drag_select = false
		ui.drag_scroll = nil
	}
}

ui_end_frame :: proc() {
	// Focused field was not drawn this frame (tab switch etc.) -> drop focus.
	if ui.focus != nil && !ui.focus_drawn do ui.focus = nil
	ui.focus_next = false
	rl.SetMouseCursor(ui.cursor)
}

ui_text_focused :: proc() -> bool {return ui.focus != nil}

// ---------------------------------------------------------------------------
// Rect helpers (RectCut style layout)
// ---------------------------------------------------------------------------

cut_top :: proc(r: ^Rect, h: f32) -> Rect {
	out := Rect{r.x, r.y, r.width, h}
	r.y += h
	r.height -= h
	return out
}
cut_bottom :: proc(r: ^Rect, h: f32) -> Rect {
	r.height -= h
	return Rect{r.x, r.y + r.height, r.width, h}
}
cut_left :: proc(r: ^Rect, w: f32) -> Rect {
	out := Rect{r.x, r.y, w, r.height}
	r.x += w
	r.width -= w
	return out
}
cut_right :: proc(r: ^Rect, w: f32) -> Rect {
	r.width -= w
	return Rect{r.x + r.width, r.y, w, r.height}
}
inset :: proc(r: Rect, dx: f32, dy: f32 = -1) -> Rect {
	dy := dy if dy >= 0 else dx
	return Rect{r.x + dx, r.y + dy, max(r.width - dx * 2, 0), max(r.height - dy * 2, 0)}
}
rect_intersect :: proc(a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.width, b.x + b.width)
	y1 := min(a.y + a.height, b.y + b.height)
	return Rect{x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
}
point_in :: proc(p: Vec2, r: Rect) -> bool {
	return p.x >= r.x && p.y >= r.y && p.x < r.x + r.width && p.y < r.y + r.height
}

current_clip :: proc() -> Rect {return ui.clip_stack[len(ui.clip_stack) - 1]}

push_clip :: proc(r: Rect) {
	c := rect_intersect(current_clip(), r)
	append(&ui.clip_stack, c)
	rl.EndScissorMode()
	rl.BeginScissorMode(i32(c.x), i32(c.y), i32(math.ceil(c.width)), i32(math.ceil(c.height)))
}

pop_clip :: proc() {
	pop(&ui.clip_stack)
	rl.EndScissorMode()
	if len(ui.clip_stack) > 1 {
		c := current_clip()
		rl.BeginScissorMode(i32(c.x), i32(c.y), i32(math.ceil(c.width)), i32(math.ceil(c.height)))
	}
}

hovered :: proc(r: Rect) -> bool {
	return !ui.blocked && point_in(ui.mouse, r) && point_in(ui.mouse, current_clip())
}

// Returns true if r was clicked this frame and consumes the click.
clicked :: proc(r: Rect) -> bool {
	if ui.pressed && hovered(r) {
		ui.pressed = false
		return true
	}
	return false
}

// ---------------------------------------------------------------------------
// Drawing primitives
// ---------------------------------------------------------------------------

fill :: proc(r: Rect, radius: f32, c: Color) {
	if radius <= 0 {
		rl.DrawRectangleRec(r, c)
		return
	}
	m := min(r.width, r.height)
	if m <= 0 do return
	rl.DrawRectangleRounded(r, min(radius * 2 / m, 1), 8, c)
}

outline :: proc(r: Rect, radius: f32, thick: f32, c: Color) {
	m := min(r.width, r.height)
	if m <= 0 do return
	if radius <= 0 {
		rl.DrawRectangleLinesEx(r, thick, c)
		return
	}
	rl.DrawRectangleRoundedLinesEx(r, min(radius * 2 / m, 1), 8, thick, c)
}

hline :: proc(x0, x1, y: f32, c: Color) {
	rl.DrawRectangleRec(Rect{x0, math.floor(y), x1 - x0, 1}, c)
}

with_alpha :: proc(c: Color, a: f32) -> Color {
	return Color{c.r, c.g, c.b, u8(f32(c.a) * clamp(a, 0, 1))}
}

mix :: proc(a, b: Color, t_in: f32) -> Color {
	t := clamp(t_in, 0, 1)
	return Color {
		u8(f32(a.r) + (f32(b.r) - f32(a.r)) * t),
		u8(f32(a.g) + (f32(b.g) - f32(a.g)) * t),
		u8(f32(a.b) + (f32(b.b) - f32(a.b)) * t),
		u8(f32(a.a) + (f32(b.a) - f32(a.a)) * t),
	}
}

cstr :: proc(s: string) -> cstring {return strings.clone_to_cstring(s, context.temp_allocator)}

measure :: proc(s: string, kind: Font_Kind) -> f32 {
	if len(s) == 0 do return 0
	return rl.MeasureTextEx(fonts[kind], cstr(s), font_size[kind], 0).x
}

draw_text :: proc(s: string, x, y: f32, kind: Font_Kind, c: Color) {
	if len(s) == 0 do return
	rl.DrawTextEx(fonts[kind], cstr(s), {math.round(x), math.round(y)}, font_size[kind], 0, c)
}

Align :: enum {
	Left,
	Center,
	Right,
}

// Truncates with an ellipsis when it doesn't fit.
fit_text :: proc(s: string, kind: Font_Kind, max_w: f32) -> string {
	if measure(s, kind) <= max_w do return s
	ell :: "…"
	ew := measure(ell, kind)
	lo, hi := 0, len(s)
	for lo < hi {
		mid := (lo + hi + 1) / 2
		for mid > 0 && mid < len(s) && !utf8.rune_start(s[mid]) do mid -= 1
		if mid <= lo do break
		if measure(s[:mid], kind) + ew <= max_w do lo = mid
		else do hi = mid - 1
	}
	return strings.concatenate({s[:lo], ell}, context.temp_allocator)
}

label :: proc(r: Rect, s: string, kind := Font_Kind.Body, c := C_TEXT, align := Align.Left) {
	t := fit_text(s, kind, r.width)
	w := measure(t, kind)
	x := r.x
	switch align {
	case .Left:
	case .Center: x = r.x + (r.width - w) / 2
	case .Right: x = r.x + r.width - w
	}
	y := r.y + (r.height - font_size[kind]) / 2 - 1
	draw_text(t, x, y, kind, c)
}

// Wrapped paragraph; returns height used.
paragraph :: proc(x, y, w: f32, s: string, kind := Font_Kind.Body, c := C_TEXT_DIM, draw := true) -> f32 {
	lh := font_size[kind] * 1.35
	line_y := y
	for para in strings.split_lines(s, context.temp_allocator) {
		words := strings.fields(para, context.temp_allocator)
		line := strings.builder_make(context.temp_allocator)
		for word in words {
			candidate := word if strings.builder_len(line) == 0 else strings.concatenate({strings.to_string(line), " ", word}, context.temp_allocator)
			if measure(candidate, kind) > w && strings.builder_len(line) > 0 {
				if draw do draw_text(strings.to_string(line), x, line_y, kind, c)
				line_y += lh
				strings.builder_reset(&line)
				strings.write_string(&line, word)
			} else {
				strings.builder_reset(&line)
				strings.write_string(&line, candidate)
			}
		}
		if draw do draw_text(strings.to_string(line), x, line_y, kind, c)
		line_y += lh
	}
	return line_y - y
}

// ---------------------------------------------------------------------------
// Icons (vector, drawn in a square)
// ---------------------------------------------------------------------------

Icon :: enum {
	None,
	Plus,
	Close,
	Folder,
	Upload,
	External,
	Refresh,
	Trash,
	Gear,
	Grid,
	Terminal,
	Check,
	File,
}

draw_icon :: proc(icon: Icon, center: Vec2, size: f32, c: Color) {
	s := size / 2
	cx, cy := center.x, center.y
	t := max(size / 9, 1.5)
	switch icon {
	case .None:
	case .Plus:
		rl.DrawLineEx({cx - s * 0.8, cy}, {cx + s * 0.8, cy}, t, c)
		rl.DrawLineEx({cx, cy - s * 0.8}, {cx, cy + s * 0.8}, t, c)
	case .Close:
		k := s * 0.6
		rl.DrawLineEx({cx - k, cy - k}, {cx + k, cy + k}, t, c)
		rl.DrawLineEx({cx + k, cy - k}, {cx - k, cy + k}, t, c)
	case .Check:
		rl.DrawLineEx({cx - s * 0.65, cy}, {cx - s * 0.15, cy + s * 0.5}, t, c)
		rl.DrawLineEx({cx - s * 0.18, cy + s * 0.5}, {cx + s * 0.7, cy - s * 0.5}, t, c)
	case .Folder:
		body := Rect{cx - s * 0.85, cy - s * 0.45, s * 1.7, s * 1.2}
		tab := Rect{cx - s * 0.85, cy - s * 0.7, s * 0.7, s * 0.35}
		fill(tab, 1.5, c)
		outline(body, 2, t * 0.8, c)
	case .File:
		outline(Rect{cx - s * 0.6, cy - s * 0.8, s * 1.2, s * 1.6}, 2, t * 0.8, c)
		hline(cx - s * 0.3, cx + s * 0.3, cy - s * 0.2, c)
		hline(cx - s * 0.3, cx + s * 0.3, cy + s * 0.15, c)
	case .Upload:
		rl.DrawLineEx({cx, cy + s * 0.5}, {cx, cy - s * 0.75}, t, c)
		rl.DrawLineEx({cx - s * 0.5, cy - s * 0.25}, {cx + t * 0.3, cy - s * 0.8}, t, c)
		rl.DrawLineEx({cx + s * 0.5, cy - s * 0.25}, {cx - t * 0.3, cy - s * 0.8}, t, c)
		rl.DrawLineEx({cx - s * 0.8, cy + s * 0.85}, {cx + s * 0.8, cy + s * 0.85}, t, c)
	case .External:
		outline(Rect{cx - s * 0.8, cy - s * 0.5, s * 1.3, s * 1.3}, 1.5, t * 0.8, c)
		rl.DrawLineEx({cx - s * 0.05, cy + s * 0.05}, {cx + s * 0.8, cy - s * 0.8}, t, c)
		rl.DrawLineEx({cx + s * 0.25, cy - s * 0.8}, {cx + s * 0.85, cy - s * 0.8}, t, c)
		rl.DrawLineEx({cx + s * 0.8, cy - s * 0.85}, {cx + s * 0.8, cy - s * 0.25}, t, c)
	case .Refresh:
		rl.DrawRing({cx, cy}, s * 0.75 - t / 2, s * 0.75 + t / 2, 40, 330, 24, c)
		tip := Vec2{cx + s * 0.75 * math.cos_f32(math.to_radians_f32(40)), cy + s * 0.75 * math.sin_f32(math.to_radians_f32(40))}
		rl.DrawTriangle(tip + {-s * 0.45, -s * 0.05}, tip + {s * 0.35, s * 0.1}, tip + {s * 0.2, -s * 0.6}, c)
	case .Trash:
		outline(Rect{cx - s * 0.55, cy - s * 0.45, s * 1.1, s * 1.3}, 2, t * 0.8, c)
		hline(cx - s * 0.85, cx + s * 0.85, cy - s * 0.6, c)
		fill(Rect{cx - s * 0.25, cy - s * 0.85, s * 0.5, s * 0.25}, 1, c)
	case .Gear:
		rl.DrawRing({cx, cy}, s * 0.3, s * 0.6, 0, 360, 24, c)
		for i in 0 ..< 8 {
			a := f32(i) * math.PI / 4
			d := Vec2{math.cos(a), math.sin(a)}
			rl.DrawLineEx({cx, cy} + d * s * 0.55, {cx, cy} + d * s * 0.9, t * 1.6, c)
		}
	case .Grid:
		k := s * 0.75
		g := s * 0.15
		fill(Rect{cx - k, cy - k, k - g, k - g}, 1.5, c)
		fill(Rect{cx + g, cy - k, k - g, k - g}, 1.5, c)
		fill(Rect{cx - k, cy + g, k - g, k - g}, 1.5, c)
		fill(Rect{cx + g, cy + g, k - g, k - g}, 1.5, c)
	case .Terminal:
		outline(Rect{cx - s * 0.9, cy - s * 0.7, s * 1.8, s * 1.4}, 2, t * 0.8, c)
		rl.DrawLineEx({cx - s * 0.5, cy - s * 0.25}, {cx - s * 0.15, cy}, t, c)
		rl.DrawLineEx({cx - s * 0.15, cy}, {cx - s * 0.5, cy + s * 0.25}, t, c)
		hline(cx, cx + s * 0.45, cy + s * 0.25, c)
	}
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------

Button_Style :: enum {
	Default,
	Primary,
	Danger,
	Ghost,
	Subtle_Danger,
}

button :: proc(r: Rect, text: string, style := Button_Style.Default, icon := Icon.None, enabled := true) -> bool {
	hot := enabled && hovered(r)
	held := hot && ui.down
	if hot do ui.cursor = .POINTING_HAND

	bg, fg, border: Color
	switch style {
	case .Default:
		bg = C_PANEL_HI if hot else C_PANEL
		border = C_BORDER_HI if hot else C_BORDER
		fg = C_TEXT
	case .Primary:
		bg = C_ACCENT_BG_HI if hot else C_ACCENT_BG
		border = bg
		fg = Color{245, 250, 255, 255}
	case .Danger:
		bg = Color{180, 64, 64, 255} if hot else C_ERROR_BG
		border = bg
		fg = Color{255, 240, 240, 255}
	case .Ghost:
		bg = with_alpha(C_PANEL_HI, 1) if hot else Color{}
		border = Color{}
		fg = C_TEXT if hot else C_TEXT_DIM
	case .Subtle_Danger:
		bg = with_alpha(C_ERROR_BG, 0.35) if hot else Color{}
		border = Color{}
		fg = C_ERROR if hot else C_TEXT_DIM
	}
	if held do bg = mix(bg, Color{0, 0, 0, 255}, 0.15)
	if !enabled {
		bg = with_alpha(bg, 0.45)
		fg = C_TEXT_FAINT
		border = with_alpha(border, 0.5)
	}
	fill(r, 6, bg)
	if border.a > 0 do outline(r, 6, 1, border)

	icon_sz: f32 = 14
	tw := measure(text, .Bold)
	gap: f32 = 7 if (icon != .None && text != "") else 0
	total := tw + gap + (icon_sz if icon != .None else 0)
	x := r.x + (r.width - total) / 2
	if icon != .None {
		draw_icon(icon, {x + icon_sz / 2, r.y + r.height / 2}, icon_sz, fg)
		x += icon_sz + gap
	}
	if text != "" do draw_text(text, x, r.y + (r.height - font_size[.Bold]) / 2 - 1, .Bold, fg)

	return enabled && clicked(r)
}

icon_button :: proc(r: Rect, icon: Icon, style := Button_Style.Ghost, enabled := true) -> bool {
	return button(r, "", style, icon, enabled)
}

checkbox :: proc(r: Rect, value: ^bool, text: string) -> bool {
	hot := hovered(r)
	if hot do ui.cursor = .POINTING_HAND
	box := Rect{r.x, r.y + (r.height - 18) / 2, 18, 18}
	if value^ {
		fill(box, 4, C_ACCENT_BG_HI if hot else C_ACCENT_BG)
		draw_icon(.Check, {box.x + 9, box.y + 9}, 13, Color{245, 250, 255, 255})
	} else {
		fill(box, 4, C_INPUT)
		outline(box, 4, 1, C_ACCENT if hot else C_BORDER_HI)
	}
	if text != "" do label(Rect{r.x + 26, r.y, r.width - 26, r.height}, text, .Body, C_TEXT)
	if clicked(r) {
		value^ = !value^
		ui.changed = true
		return true
	}
	return false
}

tab :: proc(r: Rect, text: string, active: bool, icon := Icon.None) -> bool {
	hot := hovered(r)
	if hot do ui.cursor = .POINTING_HAND
	fg := C_TEXT if active else (C_TEXT if hot else C_TEXT_DIM)
	if hot && !active do fill(inset(r, 2, 8), 6, with_alpha(C_PANEL_HI, 0.7))
	tw := measure(text, .Bold)
	isz: f32 = 15
	total := tw + (isz + 8 if icon != .None else 0)
	x := r.x + (r.width - total) / 2
	if icon != .None {
		draw_icon(icon, {x + isz / 2, r.y + r.height / 2}, isz, C_ACCENT if active else fg)
		x += isz + 8
	}
	draw_text(text, x, r.y + (r.height - font_size[.Bold]) / 2 - 1, .Bold, fg)
	if active do fill(Rect{r.x + 12, r.y + r.height - 3, r.width - 24, 3}, 1.5, C_ACCENT)
	return clicked(r)
}

// Small form label above a field
field_label :: proc(r: Rect, text: string, hint := "") {
	draw_text(text, r.x, r.y, .Bold, C_TEXT_DIM)
	if hint != "" {
		w := measure(text, .Bold)
		draw_text(fit_text(hint, .Small, r.width - w - 10), r.x + w + 10, r.y + 1.5, .Small, C_TEXT_FAINT)
	}
}

// --- text field ----------------------------------------------------------------

@(private = "file")
prev_rune_start :: proc(s: []u8, i: int) -> int {
	if i <= 0 do return 0
	j := i - 1
	for j > 0 && !utf8.rune_start(s[j]) do j -= 1
	return j
}

@(private = "file")
next_rune_end :: proc(s: []u8, i: int) -> int {
	if i >= len(s) do return len(s)
	j := i + 1
	for j < len(s) && !utf8.rune_start(s[j]) do j += 1
	return j
}

@(private = "file")
is_word_byte :: proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_' || b >= 0x80
}

@(private = "file")
word_left :: proc(s: []u8, i: int) -> int {
	j := i
	for j > 0 && !is_word_byte(s[j - 1]) do j -= 1
	for j > 0 && is_word_byte(s[j - 1]) do j -= 1
	return j
}

@(private = "file")
word_right :: proc(s: []u8, i: int) -> int {
	j := i
	for j < len(s) && !is_word_byte(s[j]) do j += 1
	for j < len(s) && is_word_byte(s[j]) do j += 1
	return j
}

@(private = "file")
index_at_x :: proc(s: []u8, x: f32, kind: Font_Kind) -> int {
	if x <= 0 do return 0
	prev_w: f32 = 0
	i := 0
	for i < len(s) {
		n := next_rune_end(s, i)
		w := measure(string(s[:n]), kind)
		if x < (prev_w + w) / 2 do return i
		prev_w = w
		i = n
	}
	return len(s)
}

@(private = "file")
delete_selection :: proc() -> bool {
	if ui.caret == ui.anchor do return false
	a, b := min(ui.caret, ui.anchor), max(ui.caret, ui.anchor)
	remove_range(&ui.buf, a, b)
	ui.caret = a
	ui.anchor = a
	return true
}

@(private = "file")
insert_text :: proc(s: string) {
	delete_selection()
	inject_at(&ui.buf, ui.caret, ..transmute([]u8)s)
	ui.caret += len(s)
	ui.anchor = ui.caret
}

@(private = "file")
focus_field :: proc(id: rawptr, s: ^string, select_all: bool) {
	ui.focus = id
	clear(&ui.buf)
	append(&ui.buf, ..transmute([]u8)s^)
	ui.caret = len(ui.buf)
	ui.anchor = 0 if select_all else ui.caret
	ui.edit_scroll = 0
	ui.caret_t = 0
}

key_hit :: proc(k: rl.KeyboardKey) -> bool {return rl.IsKeyPressed(k) || rl.IsKeyPressedRepeat(k)}

text_field :: proc(r: Rect, s: ^string, placeholder := "", kind := Font_Kind.Body, enabled := true, mask := false) -> (changed: bool) {
	id := rawptr(s)
	hot := enabled && hovered(r)
	if hot do ui.cursor = .IBEAM
	focused := ui.focus == id

	if enabled && ui.focus_next && !focused {
		focus_field(id, s, true)
		focused = true
		ui.focus_next = false
	}

	inner := inset(r, 10, 0)

	if ui.pressed_raw && !ui.blocked {
		if hot {
			if !focused {
				focus_field(id, s, false)
				focused = true
			}
			ui.caret = index_at_x(mask_bytes(ui.buf[:], mask), ui.mouse.x - inner.x + ui.edit_scroll, kind) / (3 if mask else 1)
			if !(rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)) do ui.anchor = ui.caret
			ui.drag_select = true
			ui.caret_t = 0
			ui.pressed = false
		} else if focused {
			ui.focus = nil
			focused = false
		}
	}

	if focused {
		ui.focus_drawn = true
		if ui.drag_select && ui.down {
			ui.caret = index_at_x(mask_bytes(ui.buf[:], mask), ui.mouse.x - inner.x + ui.edit_scroll, kind) / (3 if mask else 1)
		}

		ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
		shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		edited := false
		moved := false

		for ch := rl.GetCharPressed(); ch != 0; ch = rl.GetCharPressed() {
			if ch < 32 || ctrl do continue
			bytes, n := utf8.encode_rune(ch)
			insert_text(string(bytes[:n]))
			edited = true
		}

		move :: proc(to: int, shift: bool) {
			ui.caret = to
			if !shift do ui.anchor = to
		}

		if key_hit(.BACKSPACE) {
			if !delete_selection() && ui.caret > 0 {
				p := word_left(ui.buf[:], ui.caret) if ctrl else prev_rune_start(ui.buf[:], ui.caret)
				remove_range(&ui.buf, p, ui.caret)
				ui.caret = p
				ui.anchor = p
			}
			edited = true
		}
		if key_hit(.DELETE) {
			if !delete_selection() && ui.caret < len(ui.buf) {
				n := word_right(ui.buf[:], ui.caret) if ctrl else next_rune_end(ui.buf[:], ui.caret)
				remove_range(&ui.buf, ui.caret, n)
			}
			edited = true
		}
		if key_hit(.LEFT) {
			if !shift && ui.caret != ui.anchor do move(min(ui.caret, ui.anchor), false)
			else do move(word_left(ui.buf[:], ui.caret) if ctrl else prev_rune_start(ui.buf[:], ui.caret), shift)
			moved = true
		}
		if key_hit(.RIGHT) {
			if !shift && ui.caret != ui.anchor do move(max(ui.caret, ui.anchor), false)
			else do move(word_right(ui.buf[:], ui.caret) if ctrl else next_rune_end(ui.buf[:], ui.caret), shift)
			moved = true
		}
		if key_hit(.HOME) {move(0, shift); moved = true}
		if key_hit(.END) {move(len(ui.buf), shift); moved = true}
		if ctrl && rl.IsKeyPressed(.A) {
			ui.anchor = 0
			ui.caret = len(ui.buf)
		}
		if !mask && ctrl && (rl.IsKeyPressed(.C) || rl.IsKeyPressed(.X)) && ui.caret != ui.anchor {
			a, b := min(ui.caret, ui.anchor), max(ui.caret, ui.anchor)
			rl.SetClipboardText(cstr(string(ui.buf[a:b])))
			if rl.IsKeyPressed(.X) {
				delete_selection()
				edited = true
			}
		}
		if ctrl && key_hit(.V) {
			clip := string(rl.GetClipboardText())
			clean, _ := strings.replace_all(clip, "\r", "", context.temp_allocator)
			clean, _ = strings.replace_all(clean, "\n", " ", context.temp_allocator)
			clean, _ = strings.replace_all(clean, "\t", " ", context.temp_allocator)
			insert_text(clean)
			edited = true
		}
		if rl.IsKeyPressed(.TAB) {
			ui.focus = nil
			ui.focus_next = true
		}
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) || rl.IsKeyPressed(.ESCAPE) {
			ui.focus = nil
		}
		if edited || moved do ui.caret_t = 0
		if edited {
			set_str(s, string(ui.buf[:]))
			changed = true
			ui.changed = true
		}
	}

	// --- draw ---
	bg := C_INPUT
	if !enabled do bg = with_alpha(C_INPUT, 0.5)
	fill(r, 6, bg)
	border := C_ACCENT if focused else (C_BORDER_HI if hot else C_BORDER)
	outline(r, 6, 1, border)

	push_clip(inner)
	ty := r.y + (r.height - font_size[kind]) / 2 - 1
	if focused {
		text := mask_bytes(ui.buf[:], mask)
		caret_x := measure(string(text[:vis(ui.caret, mask)]), kind)
		total_w := measure(string(text), kind)
		if caret_x - ui.edit_scroll > inner.width - 2 do ui.edit_scroll = caret_x - inner.width + 2
		if caret_x - ui.edit_scroll < 0 do ui.edit_scroll = caret_x
		ui.edit_scroll = clamp(ui.edit_scroll, 0, max(total_w - inner.width + 2, 0))
		x0 := inner.x - ui.edit_scroll

		if ui.caret != ui.anchor {
			a, b := vis(min(ui.caret, ui.anchor), mask), vis(max(ui.caret, ui.anchor), mask)
			sx := measure(string(text[:a]), kind)
			ex := measure(string(text[:b]), kind)
			fill(Rect{x0 + sx, r.y + 6, ex - sx, r.height - 12}, 2, with_alpha(C_ACCENT_BG, 0.6))
		}
		draw_text(string(text), x0, ty, kind, C_TEXT)
		if math.mod(ui.caret_t, 1.0) < 0.55 {
			fill(Rect{math.round(x0 + caret_x), r.y + 7, 1.5, r.height - 14}, 0, C_ACCENT)
		}
	} else if len(s^) == 0 {
		draw_text(placeholder, inner.x, ty, kind, C_TEXT_FAINT)
	} else {
		shown := string(mask_bytes(transmute([]u8)s^, mask))
		draw_text(fit_text(shown, kind, inner.width), inner.x, ty, kind, C_TEXT if enabled else C_TEXT_DIM)
	}
	pop_clip()
	return
}

// ---------------------------------------------------------------------------
// Scroll region
// ---------------------------------------------------------------------------

Scroll :: struct {
	offset:    f32,
	target:    f32,
	content_h: f32,
}

// Returns the y where content should start.
scroll_begin :: proc(sc: ^Scroll, r: Rect) -> f32 {
	max_off := max(sc.content_h - r.height, 0)
	if hovered(r) && ui.wheel != 0 {
		sc.target -= ui.wheel * 70
	}
	sc.target = clamp(sc.target, 0, max_off)
	sc.offset += (sc.target - sc.offset) * min(rl.GetFrameTime() * 18, 1)
	if abs(sc.target - sc.offset) < 0.5 do sc.offset = sc.target
	push_clip(r)
	return r.y - math.round(sc.offset)
}

scroll_end :: proc(sc: ^Scroll, r: Rect, content_end_y: f32) {
	pop_clip()
	sc.content_h = content_end_y - (r.y - math.round(sc.offset))
	if sc.content_h <= r.height + 1 do return

	track := Rect{r.x + r.width - 8, r.y + 4, 5, r.height - 8}
	ratio := r.height / sc.content_h
	th := max(track.height * ratio, 28)
	max_off := sc.content_h - r.height
	ty := track.y + (track.height - th) * clamp(sc.offset / max_off, 0, 1)
	thumb := Rect{track.x, ty, track.width, th}
	grab := Rect{track.x - 4, track.y, track.width + 8, track.height}

	hot := hovered(grab)
	if ui.pressed && hot {
		ui.pressed = false
		ui.drag_scroll = sc
		ui.drag_scroll_off = ui.mouse.y - ty if point_in(ui.mouse, Rect{grab.x, ty, grab.width, th}) else th / 2
	}
	if ui.drag_scroll == sc && ui.down {
		t := (ui.mouse.y - ui.drag_scroll_off - track.y) / max(track.height - th, 1)
		sc.target = clamp(t, 0, 1) * max_off
		sc.offset = sc.target
	}
	active := hot || ui.drag_scroll == sc
	fill(thumb, 2.5, C_BORDER_HI if active else with_alpha(C_BORDER_HI, 0.6))
}

// Password-style display: every byte becomes a bullet (secrets here are ASCII).
@(private = "file")
mask_bytes :: proc(b: []u8, mask: bool) -> []u8 {
	if !mask do return b
	return transmute([]u8)strings.repeat("•", len(b), context.temp_allocator)
}

@(private = "file")
vis :: proc(i: int, mask: bool) -> int {return i * 3 if mask else i}
