#!/usr/bin/env python3
"""Rename and move converted source EPUBs into the library, dry-run by default.

    python3 .claude/skills/rename-book-pdfs/scripts/file_epub.py plan.json
    python3 .claude/skills/rename-book-pdfs/scripts/file_epub.py plan.json --apply

plan.json is a list of {"epub": "<current path>", "dest": "<new path>"}
objects, both relative to the current directory (the library root). `dest`
carries the folders as well as the new basename; missing folders are created.

Same guarantees as rename.py: it refuses the whole plan — moving nothing — if
any source is missing, any target already exists, or two entries claim the
same target. Entries already filed are skipped, so re-running is a no-op.
"""

import argparse
import json
import os
import sys

from rename import nfc, sanitise


def resolve(path):
    """Real path of `path` despite NFC/NFD drift in any of its components."""
    real = "."
    for part in os.path.normpath(path).split(os.sep):
        if part in ("", "."):
            continue
        if part == "..":
            real = os.path.join(real, part)
            continue
        if not os.path.isdir(real):
            return None
        match = next((e for e in os.listdir(real) if nfc(e) == nfc(part)), None)
        if match is None:
            return None
        real = os.path.join(real, match)
    return real


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("plan", help="JSON file: [{epub, dest}, ...]")
    ap.add_argument("--apply", action="store_true",
                    help="actually move (default: dry run)")
    args = ap.parse_args()

    with open(args.plan, encoding="utf-8") as fh:
        plan = json.load(fh)

    moves, skipped, errors = [], [], []
    claimed = {}

    for entry in plan:
        folder, base = os.path.split(entry["dest"])
        dest = os.path.join(folder, sanitise(base))
        src = resolve(entry["epub"])
        if src is None:
            if resolve(dest):
                skipped.append(dest)
            else:
                errors.append(f"missing source: {entry['epub']}")
            continue
        if not dest.lower().endswith(".epub"):
            errors.append(f"target is not an .epub: {dest}")
            continue
        if resolve(dest):
            errors.append(f"target exists: {dest}  (from {src})")
            continue
        key = nfc(os.path.normpath(dest))
        if key in claimed:
            errors.append(f"two sources claim {dest}: {claimed[key]}, {src}")
            continue
        claimed[key] = src
        moves.append((src, dest))

    for old, new in moves:
        print(f"  {old}\n    -> {new}")
    for name in skipped:
        print(f"  = {name}  (already filed)")
    sys.stdout.flush()
    for err in errors:
        print(f"  ! {err}", file=sys.stderr)

    if errors:
        print(f"\nfile_epub.py: {len(errors)} problem(s); nothing moved.",
              file=sys.stderr)
        return 1

    if not args.apply:
        print(f"\nDry run: {len(moves)} to file, {len(skipped)} already "
              f"filed. Re-run with --apply.")
        return 0

    for old, new in moves:
        if os.path.dirname(new):
            os.makedirs(os.path.dirname(new), exist_ok=True)
        os.rename(old, new)
    print(f"\nFiled {len(moves)} EPUB(s); {len(skipped)} already filed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
