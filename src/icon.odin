package SteamBuildPusher

import "core:math"
import os "core:os"

// App icon, rendered procedurally (anti-aliased signed distance fields) so the
// .ico, the window icon and the in-app logo all come from the same artwork:
// a rounded Steam-blue tile with an "upload to cloud" arrow.
//
// Regenerate the .ico with:  SteamBuildGui.exe --write-icon SteamBuildGui.ico

@(private = "file")
V2 :: [2]f32

@(private = "file")
sd_round_box :: proc(p: V2, half: V2, r: f32) -> f32 {
	q := V2{abs(p.x), abs(p.y)} - half + r
	outside := V2{max(q.x, 0), max(q.y, 0)}
	return math.sqrt(outside.x * outside.x + outside.y * outside.y) + min(max(q.x, q.y), 0) - r
}

@(private = "file")
sd_segment :: proc(p, a, b: V2) -> f32 {
	pa := p - a
	ba := b - a
	h := clamp((pa.x * ba.x + pa.y * ba.y) / (ba.x * ba.x + ba.y * ba.y), 0, 1)
	d := pa - ba * h
	return math.sqrt(d.x * d.x + d.y * d.y)
}

@(private = "file")
sd_circle :: proc(p, c: V2, r: f32) -> f32 {
	d := p - c
	return math.sqrt(d.x * d.x + d.y * d.y) - r
}

@(private = "file")
lerp3 :: proc(a, b: [3]f32, t: f32) -> [3]f32 {return a + (b - a) * clamp(t, 0, 1)}

// Returns tightly packed RGBA8 pixels (straight alpha).
icon_pixels :: proc(size: int, allocator := context.allocator) -> []u8 {
	pixels := make([]u8, size * size * 4, allocator)
	px := 1.0 / f32(size)
	// Small sizes get slightly bolder strokes so they stay legible.
	stroke: f32 = 0.072 if size > 24 else 0.085

	top := [3]f32{78, 178, 240}
	bottom := [3]f32{24, 92, 168}
	cloud_col := [3]f32{255, 255, 255}
	arrow_col := [3]f32{30, 104, 178}

	SS :: 4 // supersampling per axis for clean edges at tiny sizes
	for y in 0 ..< size {
		for x in 0 ..< size {
			acc: [4]f32
			for sy in 0 ..< SS {
				for sx in 0 ..< SS {
					u := V2{(f32(x) + (f32(sx) + 0.5) / SS) * px, (f32(y) + (f32(sy) + 0.5) / SS) * px}

					// Tile
					d_tile := sd_round_box(u - 0.5, {0.46, 0.46}, 0.2)
					if d_tile > 0 do continue
					col := lerp3(top, bottom, (u.y - 0.04) / 0.92)
					// soft top highlight
					col = lerp3(col, {255, 255, 255}, 0.12 * clamp(1 - u.y * 2.2, 0, 1))

					// Cloud: three circles + flat base
					d_cloud := min(
						sd_circle(u, {0.36, 0.56}, 0.15),
						sd_circle(u, {0.53, 0.47}, 0.19),
						sd_circle(u, {0.69, 0.58}, 0.13),
						sd_round_box(u - {0.52, 0.65}, {0.27, 0.06}, 0.06),
					)
					if d_cloud <= 0 do col = cloud_col

					// Arrow inside the cloud (pointing up)
					d_arrow := min(
						sd_segment(u, {0.52, 0.63}, {0.52, 0.43}),
						sd_segment(u, {0.52, 0.40}, {0.42, 0.50}),
						sd_segment(u, {0.52, 0.40}, {0.62, 0.50}),
					) - stroke * 0.5
					if d_arrow <= 0 do col = arrow_col

					acc += {col.r, col.g, col.b, 1}
				}
			}
			n := f32(SS * SS)
			i := (y * size + x) * 4
			if acc.a > 0 {
				pixels[i + 0] = u8(clamp(acc.r / acc.a, 0, 255))
				pixels[i + 1] = u8(clamp(acc.g / acc.a, 0, 255))
				pixels[i + 2] = u8(clamp(acc.b / acc.a, 0, 255))
				pixels[i + 3] = u8(clamp(acc.a / n * 255, 0, 255))
			}
		}
	}
	return pixels
}

// Writes a multi-resolution .ico (32-bit BMP entries with alpha).
write_ico :: proc(path: string, sizes: []int) -> bool {
	buf := make([dynamic]u8, context.temp_allocator)
	put16 :: proc(b: ^[dynamic]u8, v: u16) {append(b, u8(v), u8(v >> 8))}
	put32 :: proc(b: ^[dynamic]u8, v: u32) {append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}

	images := make([dynamic][]u8, context.temp_allocator)
	for s in sizes {
		img := make([dynamic]u8, context.temp_allocator)
		px := icon_pixels(s, context.temp_allocator)
		mask_row := ((s + 31) / 32) * 4
		// BITMAPINFOHEADER (height is doubled: XOR + AND masks)
		put32(&img, 40)
		put32(&img, u32(s))
		put32(&img, u32(s * 2))
		put16(&img, 1)
		put16(&img, 32)
		put32(&img, 0)
		put32(&img, u32(s * s * 4 + mask_row * s))
		put32(&img, 0); put32(&img, 0); put32(&img, 0); put32(&img, 0)
		// Pixels, bottom-up BGRA
		for y := s - 1; y >= 0; y -= 1 {
			for x in 0 ..< s {
				i := (y * s + x) * 4
				append(&img, px[i + 2], px[i + 1], px[i + 0], px[i + 3])
			}
		}
		// AND mask (all zero: alpha channel is used)
		for _ in 0 ..< mask_row * s do append(&img, 0)
		append(&images, img[:])
	}

	put16(&buf, 0)
	put16(&buf, 1)
	put16(&buf, u16(len(sizes)))
	offset := 6 + 16 * len(sizes)
	for s, i in sizes {
		append(&buf, u8(s) if s < 256 else 0, u8(s) if s < 256 else 0, 0, 0)
		put16(&buf, 1)
		put16(&buf, 32)
		put32(&buf, u32(len(images[i])))
		put32(&buf, u32(offset))
		offset += len(images[i])
	}
	for img in images do append(&buf, ..img)
	return os.write_entire_file(path, buf[:]) == nil
}
