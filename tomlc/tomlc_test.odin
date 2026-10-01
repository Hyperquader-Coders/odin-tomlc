#+test
package tomlc

import "core:testing"

// The document from upstream's simple/simple.toml, plus every value type
// the readers cover.
@(private = "file")
DOC :: `title = "TOML Example"
port = 8001
ratio = 0.75
whole = 2
on = true
names = ["a", "b"]
mixed = [1, "b"]
born = 1979-05-27
alarm = 07:32:00.5
stamp = 1979-05-27T07:32:00Z
local = 1979-05-27T07:32:00

[server]
host = "spark.lan"
"odd key" = 1

[[items]]
n = 1
[[items]]
n = 2
`

@(test)
test_parse_and_read_every_type :: proc(t: ^testing.T) {
	r := parse_string(DOC, "doc.toml")
	defer result_free(r)
	testing.expect(t, r.ok)
	top := r.toptab
	testing.expect(t, top.type == .TABLE)

	s, ok := str(get(top, "title"))
	testing.expect(t, ok)
	testing.expect_value(t, s, "TOML Example")
	c, cok := str_clone(get(top, "title"))
	testing.expect(t, cok)
	testing.expect_value(t, c, "TOML Example")
	delete(c)

	n, nok := integer(get(top, "port"))
	testing.expect(t, nok)
	testing.expect_value(t, n, 8001)
	f, fok := float(get(top, "ratio"))
	testing.expect(t, fok)
	testing.expect_value(t, f, 0.75)
	w, wok := float(get(top, "whole")) // an integer read as a float widens
	testing.expect(t, wok)
	testing.expect_value(t, w, 2.0)
	_, iok := integer(get(top, "ratio")) // but a float is not an integer
	testing.expect(t, !iok)
	b, bok := boolean(get(top, "on"))
	testing.expect(t, bok && b)

	names, sok := strings_clone(get(top, "names"))
	testing.expect(t, sok)
	testing.expect_value(t, len(names), 2)
	testing.expect_value(t, names[1], "b")
	for x in names {delete(x)}
	delete(names)
	_, mok := strings_clone(get(top, "mixed"))
	testing.expect(t, !mok)

	d, dok := timestamp(get(top, "born"))
	testing.expect(t, dok && get(top, "born").type == .DATE)
	testing.expect_value(t, d.year, 1979)
	testing.expect_value(t, d.day, 27)
	a, _ := timestamp(get(top, "alarm"))
	testing.expect_value(t, a.hour, 7)
	testing.expect_value(t, a.usec, 500_000)
	z, _ := timestamp(get(top, "stamp"))
	testing.expect(t, get(top, "stamp").type == .DATETIMETZ)
	testing.expect_value(t, z.tz, 0)
	testing.expect(t, get(top, "local").type == .DATETIME)

	host, hok := str(seek_path(top, "server.host"))
	testing.expect(t, hok)
	testing.expect_value(t, host, "spark.lan")
	keys, vals, tok := table(get(top, "server"))
	testing.expect(t, tok)
	testing.expect_value(t, len(keys), 2)
	testing.expect_value(t, key_at(get(top, "server"), 1), "odd key")
	testing.expect_value(t, vals[1].type, Type.INT64)

	items, aok := array(get(top, "items"))
	testing.expect(t, aok)
	testing.expect_value(t, len(items), 2)
	two, _ := integer(get(items[1], "n"))
	testing.expect_value(t, two, 2)

	// Absent is UNKNOWN, and every reader says no.
	testing.expect(t, get(top, "nope").type == .UNKNOWN)
	_, ok = str(get(top, "nope"))
	testing.expect(t, !ok)
	testing.expect_value(t, get(top, "title").lineno, 1)
	testing.expect_value(t, string(get(top, "title").source), "doc.toml")
}

@(test)
test_a_bad_document_says_where :: proc(t: ^testing.T) {
	r := parse_string("a = \nb = 1", "bad.toml")
	defer result_free(r) // freed whether or not it parsed
	testing.expect(t, !r.ok)
	testing.expect(t, len(error(&r)) > 0)
}

@(test)
test_option_round_trip :: proc(t: ^testing.T) {
	o := default_option()
	testing.expect(t, !o.check_utf8)
	testing.expect(t, o.mem_realloc != nil && o.mem_free != nil)
}

// The config readers: owned values, absent for a missing key, a missing
// table and a wrong type alike, and an integer widened to a float.
@(test)
test_config_readers :: proc(t: ^testing.T) {
	r := parse_string(DOC)
	defer result_free(r)
	top := r.toptab

	title, ok := get_string(top, "title")
	testing.expect(t, ok)
	testing.expect_value(t, title, "TOML Example")
	delete(title)
	port, pok := get_int(top, "port")
	testing.expect(t, pok)
	testing.expect_value(t, port, 8001)
	w, wok := get_float(top, "whole")
	testing.expect(t, wok)
	testing.expect_value(t, w, 2.0)
	on, ook := get_bool(top, "on")
	testing.expect(t, ook && on)

	host, hok := get_string(get(top, "server"), "host")
	testing.expect(t, hok)
	testing.expect_value(t, host, "spark.lan")
	delete(host)
	_, mok := get_string(get(top, "missing"), "host") // no such table: absent, no crash
	testing.expect(t, !mok)
	_, tok := get_int(top, "title") // wrong type: absent
	testing.expect(t, !tok)

	names := get_strings(top, "names")
	testing.expect_value(t, len(names), 2)
	for n in names {delete(n)}
	delete(names)
	testing.expect(t, get_strings(top, "mixed") == nil)
	testing.expect(t, get_strings(top, "nope") == nil)
}

// An empty document is the empty table, whatever pointer an empty Odin
// string happens to carry; and the one reader that indexes answers absent
// like the rest rather than reading through the union.
@(test)
test_empty_document_and_absent_key_at :: proc(t: ^testing.T) {
	r := parse_string("")
	defer result_free(r)
	testing.expect(t, r.ok)
	testing.expect(t, r.toptab.type == .TABLE)
	keys, _, ok := table(r.toptab)
	testing.expect(t, ok)
	testing.expect_value(t, len(keys), 0)
	none: []u8
	r2 := parse_string(string(none)) // nil-backed, as read_entire_file gives for an empty file
	defer result_free(r2)
	testing.expect(t, r2.ok)

	testing.expect_value(t, key_at(get(r.toptab, "nope"), 0), "")
	testing.expect_value(t, key_at(r.toptab, 0), "")
	testing.expect_value(t, key_at(r.toptab, -1), "")
}
