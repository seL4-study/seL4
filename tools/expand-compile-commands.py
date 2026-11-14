#!/usr/bin/env python3
"""Expand compile_commands.json's kernel_all.c unity-build entry into per-source-file entries."""
import argparse
import copy
import json
import re
import shlex
import sys
from pathlib import Path

LINE_MARKER_RE = re.compile(r'^#line \d+ "(.*)"')


def find_unity_entry(entries):
    matches = [e for e in entries if Path(e["file"]).name == "kernel_all.c"]
    if not matches:
        sys.exit("no kernel_all.c entry in compile_commands.json - build kernel.elf first")
    if len(matches) > 1:
        sys.exit("multiple kernel_all.c entries found, expected exactly one")
    return matches[0]


def resolve(path, directory):
    p = Path(path)
    return str(p if p.is_absolute() else Path(directory) / p)


def discover_source_files(kernel_all_c):
    seen = []
    with open(kernel_all_c) as f:
        for line in f:
            m = LINE_MARKER_RE.match(line)
            if m and m.group(1) not in seen:
                seen.append(m.group(1))
    return seen


def clone_entry_for_file(unity_entry, kernel_all_c, target_file):
    entry = copy.deepcopy(unity_entry)
    entry["file"] = target_file
    if "command" in entry:
        entry["command"] = entry["command"].replace(kernel_all_c, target_file)
    if "arguments" in entry:
        entry["arguments"] = [target_file if a == kernel_all_c else a for a in entry["arguments"]]
    return entry


def build_libsel4_header_entries(entries):
    """Give every libsel4 header (incl. generated sel4_client.h, shared_types_gen.h)
    its own entry. These headers are not self-contained (they rely on sel4/sel4.h
    having been included first), so force-include it. Without these entries clangd
    borrows flags from an unrelated *_pbf_temp.c entry and cannot resolve symbols."""
    bases = [e for e in entries if Path(e["file"]).name == "sel4_bootinfo.c"]
    if not bases:
        return []
    base = bases[0]
    args = base.get("arguments") or shlex.split(base["command"])
    flags, it = [], iter(args)
    for a in it:
        if a in ("-o", "-c"):
            next(it, None)
            continue
        if a == base["file"]:
            continue
        flags.append(a)

    include_dirs = [a[2:] for a in flags if a.startswith("-I") and "/libsel4/" in a]
    headers = []
    for d in include_dirs:
        for h in sorted(Path(d).rglob("*.h")):
            if str(h) not in headers:
                headers.append(str(h))

    return [{"directory": base["directory"], "file": h,
             "arguments": flags + ["-x", "c-header", "-include", "sel4/sel4.h", "-c", h]}
            for h in headers]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_dir", help="CMake build directory containing compile_commands.json")
    args = parser.parse_args()

    db_path = Path(args.build_dir) / "compile_commands.json"
    if not db_path.exists():
        sys.exit(f"{db_path} not found")

    entries = json.loads(db_path.read_text())
    unity_entry = find_unity_entry(entries)
    kernel_all_c = resolve(unity_entry["file"], unity_entry["directory"])

    source_files = discover_source_files(kernel_all_c)
    if not source_files:
        sys.exit(f"no '#line' markers found in {kernel_all_c}")

    stale = {resolve(f, unity_entry["directory"]) for f in source_files} | {kernel_all_c}
    kept = [e for e in entries if resolve(e["file"], e["directory"]) not in stale]
    expanded = [clone_entry_for_file(unity_entry, kernel_all_c, f) for f in source_files]

    headers = build_libsel4_header_entries(kept)
    header_files = {e["file"] for e in headers}
    kept = [e for e in kept if e["file"] not in header_files]

    db_path.write_text(json.dumps(kept + [unity_entry] + expanded + headers, indent=2))
    print(f"expanded {len(source_files)} files from kernel_all.c into {db_path}")
    print(f"added {len(headers)} libsel4 header entries")


if __name__ == "__main__":
    main()
