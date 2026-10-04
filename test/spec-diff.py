#!/usr/bin/python3
"""Run upstream's driver and ours over the toml-test corpus and compare.

    spec-diff.py <ref-driver> <our-driver> <toml-test/tests>

Every file the corpus lists for TOML 1.1 (files-toml-1.1.0) is fed to both
twice (as a path argument, and on stdin, which is the parse_string route
every consumer takes), and stdout and the exit code must match byte for byte
each way. The empty document is added to the corpus, since no file there is
empty and an empty Odin string is the one that carries a nil pointer. Both
drivers run the same C, so a difference is the port's: a struct laid out
wrong, a string read short, a number formatted by a different printf.
"""
import subprocess
import sys
from pathlib import Path


def run(driver, path):
    p = subprocess.run([driver, str(path)], capture_output=True)
    return p.returncode, p.stdout


def run_stdin(driver, data):
    p = subprocess.run([driver], input=data, capture_output=True)
    return p.returncode, p.stdout


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    ref, ours, tests = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    listed = (tests / "files-toml-1.1.0").read_text().split()
    files = [tests / f for f in listed if f.endswith(".toml")]
    bad = []
    for f in files:
        a, b = run(ref, f), run(ours, f)
        if a != b:
            bad.append((f"{f.relative_to(tests)} (path)", a, b))
        data = f.read_bytes()
        a, b = run_stdin(ref, data), run_stdin(ours, data)
        if a != b:
            bad.append((f"{f.relative_to(tests)} (stdin)", a, b))
    a, b = run_stdin(ref, b""), run_stdin(ours, b"")
    if a != b:
        bad.append(("<empty document> (stdin)", a, b))
    for name, a, b in bad:
        print(f"MISMATCH {name}: ref exit {a[0]}, ours exit {b[0]}")
        if a[1] != b[1]:
            print("  ref:  " + a[1].decode(errors="replace")[:200].rstrip())
            print("  ours: " + b[1].decode(errors="replace")[:200].rstrip())
    runs = 2 * len(files) + 1
    print(f"spec-diff: {runs - len(bad)} identical, {len(bad)} differ, of {runs} runs over {len(files)} files")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
