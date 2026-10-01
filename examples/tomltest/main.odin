// A port of upstream's test/stdtest/parser.c: the decoder toml-test drives.
// Reads a document from the file named or from stdin and prints it as the
// tagged JSON the official suite compares. Byte-identical to upstream's own
// driver over the whole corpus, which is what `make test-spec` asserts:
// the same C underneath, so any difference is this binding's.
package tomltest

import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import "tomlc:tomlc"

// C's isprint in the C locale, and the two characters JSON escapes.
@(private = "file")
plain :: proc(ch: u8) -> bool {
	return ch >= 0x20 && ch <= 0x7e && ch != '"' && ch != '\\'
}

@(private = "file")
escaped :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		ch := s[i]
		if plain(ch) {
			strings.write_byte(b, ch)
			continue
		}
		switch ch {
		case '\b': strings.write_string(b, "\\b")
		case '\t': strings.write_string(b, "\\t")
		case '\n': strings.write_string(b, "\\n")
		case '\f': strings.write_string(b, "\\f")
		case '\r': strings.write_string(b, "\\r")
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case:
			if ch < ' ' {
				fmt.sbprintf(b, "\\u%04x", ch)
			} else {
				strings.write_byte(b, ch) // bytes ≥ 0x80 go through as they are
			}
		}
	}
}

// Fractional seconds as upstream prints them: "%.6f" of the fraction, cut
// to millisecond precision, without its leading 0.
@(private = "file")
frac :: proc(usec: i32) -> string {
	if usec == 0 {
		return ""
	}
	buf: [20]u8
	libc.snprintf(&buf[0], len(buf), "%.6f", f64(usec) / 1_000_000.0)
	s := string(cstring(&buf[0]))
	return strings.clone(s[1:5], context.temp_allocator) // ".ddd"
}

@(private = "file")
fmt_double :: proc(f: f64) -> string {
	buf: [50]u8
	libc.snprintf(&buf[0], len(buf), "%.16g", f)
	s := string(cstring(&buf[0]))
	if !strings.contains(s, "e") && !strings.contains(s, ".") && !strings.contains(s, "n") {
		s = fmt.tprintf("%s.0", s)
	}
	if math.is_nan(f) && math.sign_bit(f) {
		s = "-nan"
	}
	return strings.clone(s, context.temp_allocator)
}

@(private = "file")
indent_level := 0

@(private = "file")
indent :: proc(b: ^strings.Builder) {
	for _ in 0 ..< indent_level * 2 {
		strings.write_byte(b, ' ')
	}
}

// One tagged value: {"type": "<typ>", "value": "<value>"}. The braces are
// written, not formatted: Odin's fmt reads `{` as a verb.
@(private = "file")
tagged :: proc(b: ^strings.Builder, typ, value: string) {
	strings.write_string(b, "{\"type\": \"")
	strings.write_string(b, typ)
	strings.write_string(b, "\", \"value\": \"")
	strings.write_string(b, value)
	strings.write_string(b, "\"}")
}

@(private = "file")
print_datum :: proc(b: ^strings.Builder, d: tomlc.Datum) {
	ts := d.u.ts
	switch d.type {
	case .STRING:
		strings.write_string(b, "{\"type\": \"string\", \"value\": \"")
		s, _ := tomlc.str(d)
		escaped(b, s)
		strings.write_string(b, "\"}")
	case .INT64:
		tagged(b, "integer", fmt.tprintf("%d", d.u.int64))
	case .FP64:
		tagged(b, "float", fmt_double(d.u.fp64))
	case .BOOLEAN:
		tagged(b, "bool", d.u.boolean ? "true" : "false")
	case .DATE:
		tagged(b, "date-local", fmt.tprintf("%04d-%02d-%02d", ts.year, ts.month, ts.day))
	case .TIME:
		tagged(b, "time-local", fmt.tprintf("%02d:%02d:%02d%s", ts.hour, ts.minute, ts.second, frac(ts.usec)))
	case .DATETIME:
		tagged(b, "datetime-local", fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d%s",
			ts.year, ts.month, ts.day, ts.hour, ts.minute, ts.second, frac(ts.usec)))
	case .DATETIMETZ:
		tz := int(ts.tz)
		sign := tz < 0 ? '-' : '+'
		if tz < 0 {tz = -tz}
		tagged(b, "datetime", fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d%s%c%02d:%02d",
			ts.year, ts.month, ts.day, ts.hour, ts.minute, ts.second, frac(ts.usec), sign, tz / 60, tz % 60))
	case .ARRAY:
		strings.write_byte(b, '[')
		elems, _ := tomlc.array(d)
		for e, i in elems {
			if i > 0 {strings.write_string(b, ", ")}
			print_datum(b, e)
		}
		strings.write_byte(b, ']')
	case .TABLE:
		strings.write_string(b, "{\n")
		indent_level += 1
		_, vals, _ := tomlc.table(d)
		for v, i in vals {
			if i > 0 {strings.write_string(b, ",\n")}
			indent(b)
			strings.write_byte(b, '"')
			escaped(b, tomlc.key_at(d, i))
			strings.write_string(b, "\": ")
			print_datum(b, v)
		}
		strings.write_byte(b, '\n')
		indent_level -= 1
		indent(b)
		strings.write_byte(b, '}')
	case .UNKNOWN:
		fmt.eprintfln("ERROR: unimplemented datum type %d", int(d.type))
		os.exit(134)
	}
}

main :: proc() {
	if len(os.args) > 2 {
		fmt.eprintfln("Usage: %s [fname]", os.args[0])
		os.exit(1)
	}
	opt := tomlc.default_option()
	opt.check_utf8 = true
	tomlc.set_option(opt)

	r: tomlc.Result
	if len(os.args) == 2 {
		r = tomlc.parse_file(os.args[1])
	} else {
		src, err := os.read_entire_file(os.stdin, context.allocator)
		if err != nil {
			fmt.eprintfln("cannot read stdin: %v", err)
			os.exit(1)
		}
		r = tomlc.parse_string(string(src))
	}
	defer tomlc.result_free(r)
	if !r.ok {
		fmt.printfln("%s", tomlc.error(&r))
		os.exit(1)
	}
	b := strings.builder_make()
	print_datum(&b, r.toptab)
	strings.write_byte(&b, '\n')
	os.write(os.stdout, b.buf[:])
}
