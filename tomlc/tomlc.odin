// Odin bindings for tomlc17 (https://github.com/cktan/tomlc17), a TOML v1.1
// parser in C. Mirrors vendor/tomlc17/tomlc17.h: a document parses into a
// tree of Datum values owned by the Result, read through `get`/`seek` and
// the typed readers below, and freed once with result_free.
package tomlc

import "core:c"
import "core:strings"

// Built by `make lib` from vendor/tomlc17/tomlc17.c. A consumer with a
// system libtomlc17 can point this at "system:tomlc17" instead.
foreign import lib "../vendor/tomlc17/libtomlc17.a"

// toml_type_t.
Type :: enum c.int {
	UNKNOWN = 0, // absent, or not a TOML value
	STRING,
	INT64,
	FP64,
	BOOLEAN,
	DATE,       // local date
	TIME,       // local time
	DATETIME,   // local date-time
	DATETIMETZ, // offset date-time; `tz` holds the offset
	ARRAY,
	TABLE,
}

// The date-and-time half of a Datum, for the four DATE..DATETIMETZ types.
// Fields a type has no use for are zero: a DATE has no hour, a DATETIME no
// tz. `usec` is microseconds; upstream truncates finer fractions.
Timestamp :: struct {
	year, month, day:     i16,
	hour, minute, second: i16,
	usec:                 i32,
	tz:                   i16, // minutes east of UTC; DATETIMETZ only
}

// toml_datum_t. A node of the parsed tree. Everything it points at (the
// string bytes, an array's elements, a table's keys and values) is owned
// by the Result it came from and lives until result_free: a Datum is a
// value to copy around freely, and never something to free.
Datum :: struct {
	type:   Type,
	flag:   u32, // FLAG_* bits: how the value appeared in the source
	lineno: c.int, // 1-based; 0 when synthesized
	colno:  c.int,
	source: cstring, // the name given to parse_named, or nil
	u:      struct #raw_union {
		s:       cstring, // shorthand for str.ptr
		str:     struct {
			ptr: cstring, // NUL-terminated
			len: c.int, // bytes before the NUL
		},
		int64:   i64,
		fp64:    f64,
		boolean: bool,
		ts:      Timestamp,
		arr:     struct {
			size: i32,
			elem: [^]Datum,
		},
		tab:     struct {
			size:  i32,
			key:   [^]cstring,
			len:   [^]c.int,
			value: [^]Datum,
		},
	},
}
#assert(size_of(Datum) == 56)
#assert(offset_of(Datum, source) == 16)
#assert(offset_of(Datum, u) == 24)

FLAG_INLINED :: 1 // appeared inline: {x = 1} or [1, 2]
FLAG_STDEXPR :: 2 // a table made by a [table] header
FLAG_EXPLICIT :: 4 // a table defined explicitly, not implied by a dotted key

// toml_result_t. What a parse returns, ok or not, and what must be handed
// to result_free either way.
Result :: struct {
	ok:        bool,
	toptab:    Datum, // the document's top-level table, when ok
	errmsg:    [200]u8, // NUL-terminated, when not
	_internal: rawptr,
}
#assert(size_of(Result) == 272)
#assert(offset_of(Result, toptab) == 8)
#assert(offset_of(Result, errmsg) == 64)
#assert(offset_of(Result, _internal) == 264)

// toml_option_t: global to the library, set once before parsing.
Option :: struct {
	check_utf8:  bool, // reject invalid UTF-8; upstream's default is false
	mem_realloc: proc "c" (ptr: rawptr, size: c.size_t) -> rawptr,
	mem_free:    proc "c" (ptr: rawptr),
}
#assert(size_of(Option) == 24)
#assert(offset_of(Option, mem_realloc) == 8)

// The header, one to one. Every Result these return must reach result_free,
// ok or not; every Datum they return is a view into its Result.
//
// `toml_free` is bound as result_free rather than as `free`: a foreign
// `free` at package scope would shadow Odin's builtin for every file in the
// package, and a `free(p)` meant for an Odin allocation would then go to
// libc.
@(default_calling_convention = "c", link_prefix = "toml_")
foreign lib {
	parse            :: proc(src: [^]u8, len: c.int) -> Result ---
	parse_named      :: proc(src: [^]u8, len: c.int, name: cstring) -> Result ---
	parse_file_ex    :: proc(fname: cstring) -> Result ---
	@(link_name = "toml_free")
	result_free      :: proc(result: Result) ---
	get              :: proc(table: Datum, key: cstring) -> Datum ---
	seek             :: proc(table: Datum, multipart_key: cstring) -> Datum ---
	merge            :: proc(r1, r2: ^Result) -> Result ---
	equiv            :: proc(r1, r2: ^Result) -> bool ---
	default_option   :: proc() -> Option ---
	set_option       :: proc(opt: Option) ---
}

// --- the Odin side ---------------------------------------------------------
//
// Thin, and only what the header leaves awkward from Odin: a string in, a
// string out, a typed read that says whether the value was there and of that
// type. Nothing here allocates unless its name says clone.

// Parses `src`; `name` tags every datum's `source` and is copied by the
// library. The Result owns everything it holds until result_free, even
// when `ok` is false.
//
// An empty document is a valid one, the empty table. An empty Odin string
// may carry a nil pointer, and the library refuses NULL before it reads the
// length, so the pointer handed over is never nil.
parse_string :: proc(src: string, name := "") -> Result {
	@(static) empty: [1]u8
	p := raw_data(src)
	if p == nil {
		p = &empty[0]
	}
	if name == "" {
		return parse(p, c.int(len(src)))
	}
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	return parse_named(p, c.int(len(src)), cname)
}

// Parses the file at `path` through the library's own reader.
parse_file :: proc(path: string) -> Result {
	return parse_file_ex(strings.clone_to_cstring(path, context.temp_allocator))
}

// The message of a failed parse, as a view into the Result: "(line 3)
// missing value": the line and the reason, no file name and no column,
// so a caller that wants the file named prefixes it.
error :: proc(r: ^Result) -> string {
	return string(cstring(&r.errmsg[0]))
}

// `seek` on a dotted key from Odin: "server.port". No escapes, at most 255
// bytes, as the header says.
seek_path :: proc(table: Datum, path: string) -> Datum {
	return seek(table, strings.clone_to_cstring(path, context.temp_allocator))
}

// The typed readers: the value and whether the datum was of that type. A
// missing key is a Datum of type UNKNOWN, so `ok` is false for absent and
// for mismatched alike: a key with the wrong type is not a usable value.

// A view of the string bytes, valid until result_free.
str :: proc(d: Datum) -> (s: string, ok: bool) {
	if d.type != .STRING {
		return "", false
	}
	return strings.string_from_ptr(cast(^u8)d.u.str.ptr, int(d.u.str.len)), true
}

// The string copied out, for a value that has to outlive the Result.
str_clone :: proc(d: Datum, allocator := context.allocator) -> (s: string, ok: bool) {
	v := str(d) or_return
	return strings.clone(v, allocator), true
}

integer :: proc(d: Datum) -> (v: i64, ok: bool) {
	if d.type != .INT64 {
		return 0, false
	}
	return d.u.int64, true
}

// A float, or an integer widened: `x = 1` and `x = 1.0` both read as 1.0.
// The widening is exact up to 2^53 and rounds to the nearest float beyond.
float :: proc(d: Datum) -> (v: f64, ok: bool) {
	#partial switch d.type {
	case .FP64:
		return d.u.fp64, true
	case .INT64:
		return f64(d.u.int64), true
	}
	return 0, false
}

boolean :: proc(d: Datum) -> (v: bool, ok: bool) {
	if d.type != .BOOLEAN {
		return false, false
	}
	return d.u.boolean, true
}

// Any of the four date-time types; `d.type` says which fields are set.
timestamp :: proc(d: Datum) -> (v: Timestamp, ok: bool) {
	#partial switch d.type {
	case .DATE, .TIME, .DATETIME, .DATETIMETZ:
		return d.u.ts, true
	}
	return {}, false
}

// An array's elements, as a slice over the library's own storage.
array :: proc(d: Datum) -> (elems: []Datum, ok: bool) {
	if d.type != .ARRAY {
		return nil, false
	}
	return d.u.arr.elem[:d.u.arr.size], true
}

// A table's entries, in document order: keys and values as two slices over
// the library's storage, index for index. The keys are NUL-terminated; a
// key with a NUL inside it (TOML allows one, quoted) reads short through
// `cstring`, and `key_at` gives the exact bytes.
table :: proc(d: Datum) -> (keys: []cstring, values: []Datum, ok: bool) {
	if d.type != .TABLE {
		return nil, nil, false
	}
	return d.u.tab.key[:d.u.tab.size], d.u.tab.value[:d.u.tab.size], true
}

// The i-th key of a table as an exact-length string view; "" for a datum
// that is not a table or an index it has no key at, like every reader
// answering absent rather than reading through the union.
key_at :: proc(d: Datum, i: int) -> string {
	if d.type != .TABLE || i < 0 || i >= int(d.u.tab.size) {
		return ""
	}
	return strings.string_from_ptr(cast(^u8)d.u.tab.key[i], int(d.u.tab.len[i]))
}

// Every string in an array of strings, copied out; a mixed or non-array
// datum is (nil, false). For `names = ["a", "b"]`.
strings_clone :: proc(d: Datum, allocator := context.allocator) -> (out: []string, ok: bool) {
	elems := array(d) or_return
	out = make([]string, len(elems), allocator)
	for e, i in elems {
		s, sok := str(e)
		if !sok {
			for j in 0 ..< i {
				delete(out[j], allocator)
			}
			delete(out, allocator)
			return nil, false
		}
		out[i] = strings.clone(s, allocator)
	}
	return out, true
}

// --- reading a config ------------------------------------------------------
//
// The one layer past the header this package carries, because every program
// reading its own config wants exactly it: a key looked up on a table and
// answered as an owned Odin value plus whether it was there. `tab` may be
// any Datum: an absent sub-table is UNKNOWN, and every reader answers
// absent for it, so `get_int(get(root, "server"), "port")` needs no check
// in between.

// The string under `key`, copied into `allocator`.
get_string :: proc(tab: Datum, key: cstring, allocator := context.allocator) -> (string, bool) {
	return str_clone(get(tab, key), allocator)
}

get_bool :: proc(tab: Datum, key: cstring) -> (bool, bool) {
	return boolean(get(tab, key))
}

get_int :: proc(tab: Datum, key: cstring) -> (i64, bool) {
	return integer(get(tab, key))
}

// A float however it was written: `x = 1` reads as 1.0, like `x = 1.0`.
get_float :: proc(tab: Datum, key: cstring) -> (f64, bool) {
	return float(get(tab, key))
}

// The strings of an array under `key`, copied out, for `names = ["a", "b"]`.
// nil when the key is absent, the array is empty, or an element is not a
// string, which a caller treats alike as "none configured".
get_strings :: proc(tab: Datum, key: cstring, allocator := context.allocator) -> []string {
	out, ok := strings_clone(get(tab, key), allocator)
	if !ok || len(out) == 0 {
		delete(out, allocator)
		return nil
	}
	return out
}
