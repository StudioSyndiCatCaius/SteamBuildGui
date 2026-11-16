#+build windows
package SteamBuildPusher

import "core:encoding/base64"
import win "core:sys/windows"

// ---------------------------------------------------------------------------
// DPAPI: encrypt secrets so only the current Windows user can decrypt them.
// ---------------------------------------------------------------------------

foreign import crypt32 "system:Crypt32.lib"
foreign import kernel32_secure "system:Kernel32.lib"

@(private = "file")
DATA_BLOB :: struct {
	cbData: u32,
	pbData: [^]u8,
}

@(private = "file")
CRYPTPROTECT_UI_FORBIDDEN :: 0x1

@(default_calling_convention = "system")
@(private = "file")
foreign crypt32 {
	CryptProtectData :: proc(pDataIn: ^DATA_BLOB, szDataDescr: win.LPCWSTR, pOptionalEntropy: ^DATA_BLOB, pvReserved: rawptr, pPromptStruct: rawptr, dwFlags: u32, pDataOut: ^DATA_BLOB) -> win.BOOL ---
	CryptUnprotectData :: proc(pDataIn: ^DATA_BLOB, ppszDataDescr: ^win.LPWSTR, pOptionalEntropy: ^DATA_BLOB, pvReserved: rawptr, pPromptStruct: rawptr, dwFlags: u32, pDataOut: ^DATA_BLOB) -> win.BOOL ---
}

@(default_calling_convention = "system")
@(private = "file")
foreign kernel32_secure {
	LocalFree :: proc(mem: rawptr) -> rawptr ---
}

@(private = "file")
ENTROPY := "SteamBuildGui.webapi.v1"

// Returns base64 of the DPAPI-encrypted secret ("" for empty input / failure).
secret_encrypt :: proc(plain: string, allocator := context.allocator) -> string {
	if plain == "" do return ""
	in_blob := DATA_BLOB{u32(len(plain)), raw_data(plain)}
	ent := DATA_BLOB{u32(len(ENTROPY)), raw_data(ENTROPY)}
	out: DATA_BLOB
	if !CryptProtectData(&in_blob, nil, &ent, nil, nil, CRYPTPROTECT_UI_FORBIDDEN, &out) do return ""
	defer LocalFree(out.pbData)
	return base64.encode(out.pbData[:out.cbData], allocator = allocator)
}

secret_decrypt :: proc(enc: string, allocator := context.allocator) -> (plain: string, ok: bool) {
	if enc == "" do return "", false
	raw, err := base64.decode(enc, allocator = context.temp_allocator)
	if err != nil || len(raw) == 0 do return "", false
	in_blob := DATA_BLOB{u32(len(raw)), raw_data(raw)}
	ent := DATA_BLOB{u32(len(ENTROPY)), raw_data(ENTROPY)}
	out: DATA_BLOB
	if !CryptUnprotectData(&in_blob, nil, &ent, nil, nil, CRYPTPROTECT_UI_FORBIDDEN, &out) do return "", false
	defer LocalFree(out.pbData)
	buf := make([]u8, out.cbData, allocator)
	copy(buf, out.pbData[:out.cbData])
	return string(buf), true
}

