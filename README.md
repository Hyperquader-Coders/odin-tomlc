# odin-tomlc

**Not maintained.** The Amber projects read TOML with
[amber-toml](https://hyperquader.com/projects/odin/amber-toml/), a TOML 1.1 library
written in Odin. This repository is kept as a worked example of an Odin binding of a C
library, and receives no further changes.

Written with AI assistance.

Odin bindings for [tomlc17](https://github.com/cktan/tomlc17), a TOML 1.1 parser in C
and the successor to tomlc99. The bindings follow `vendor/tomlc17/tomlc17.h` one to one,
and add a few Odin helpers: Odin strings in and out, typed readers that report whether a
value was there, and readers for a key on a table. It does not write TOML; neither does
upstream.

The C is vendored unmodified (the commit is pinned in `vendor/tomlc17/VERSION`) and
built into a static library by `build.ela`'s `lib` step.

## Using it

Clone the repository, build the C once, and point a collection at it:

```sh
git clone https://github.com/Hyperquader-Coders/odin-tomlc
(cd odin-tomlc && ela-run lib)  # builds vendor/tomlc17/libtomlc17.a
odin build . -collection:tomlc=/path/to/odin-tomlc
```

```odin
import "tomlc:tomlc"

r := tomlc.parse_file("config.toml")
defer tomlc.result_free(r)          // free it whether or not the parse succeeded
if !r.ok {
	fmt.eprintln(tomlc.error(&r))   // "(line 3) missing value"; add the file name yourself
	return
}
host, _ := tomlc.str(tomlc.seek_path(r.toptab, "server.host"))   // a view into r
port, has := tomlc.integer(tomlc.get(tomlc.get(r.toptab, "server"), "port"))
```

The `foreign import` path is relative to the package, so the library is found wherever
the repository lives. For the language server, add the collection to `ols.json`:

```json
{ "collections": [{ "name": "tomlc", "path": "../odin-tomlc" }] }
```

## The API

`tomlc/tomlc.odin` mirrors the header. Names drop the `toml_` prefix. The types are
`Type`, `Datum`, `Result`, `Option` and `Timestamp`, and their sizes are checked against
the C at compile time.

| C | Odin |
|---|---|
| `toml_parse`, `toml_parse_named`, `toml_parse_file_ex` | `parse`, `parse_named`, `parse_file_ex`, plus `parse_string(src, name)` and `parse_file(path)` for Odin strings |
| `toml_free` | `result_free` (not `free`, which would shadow Odin's built-in) |
| `toml_get`, `toml_seek` | `get`, `seek`, plus `seek_path(table, "a.b.c")` |
| `toml_merge`, `toml_equiv` | `merge`, `equiv` |
| `toml_default_option`, `toml_set_option` | `default_option`, `set_option` |
| `result.errmsg` | `error(&r)` |

The typed readers take a `Datum` and return `(value, ok)`: `str`, `str_clone`,
`integer`, `float` (an integer widens), `boolean`, `timestamp`, `array`, `table`,
`key_at` and `strings_clone`. A missing key is a `Datum` of type `UNKNOWN`, so `ok` is
false both when the key is absent and when it has the wrong type.

For a key on a table: `get_string(tab, "host")` (cloned), `get_int`, `get_float`,
`get_bool` and `get_strings` (cloned, nil for none). `tab` can be any `Datum`, so
`get_int(get(root, "server"), "port")` returns absent when `[server]` is missing.

Every string, array and table a `Datum` points at belongs to the `Result` and lives
until `result_free`. `str` returns a view; `str_clone` copies. A `Datum` is a plain
value: copy it freely and never free it.

## Tests

`ela-run test` runs two things:

- the package's own tests, every reader over every type.
- `test-spec`: `examples/tomltest` is a port of upstream's toml-test driver. It runs
  beside upstream's own driver, built from the pinned commit, over the 712 files the
  official [toml-test](https://github.com/toml-lang/toml-test) corpus lists for TOML
  1.1, and their output and exit codes must be identical. Both run the same C, so a
  difference points at the bindings.

## Develop

The steps are project-templates' `odin-lib` kind's, with this repository's own in `build.ela`;
`ela-run` runs them.

```
ela-run help    # every step
ela-run setup   # the system packages (sudo apt), ols.json, the toolchain report
ela-run ci      # lint, check, test
```

`ela-run setup` is `init-packages` (the system packages, through sudo apt), `init-modules`
(the language packages: none here) and `init-workstation` (ols.json, the editor's settings,
and the toolchain report). `ela-run ci` runs the lint first, then the checks and the tests, at
the desk; `ela-run farm` runs the same on the farm, and the tests again under
AddressSanitizer. `ela-run lib` builds the C library, `ela-run examples` the `tomltest` driver,
`ela-run clean` removes both with `build/`.

## Licence

MIT, as is tomlc17 (`vendor/tomlc17/LICENSE`).
