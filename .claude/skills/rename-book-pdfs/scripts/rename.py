#!/usr/bin/env python3
"""Apply a rename plan to output/, dry-run by default.

    python3 .claude/skills/rename-book-pdfs/scripts/rename.py plan.json
    python3 .claude/skills/rename-book-pdfs/scripts/rename.py plan.json --apply

plan.json is a list of {"pdf": "<current path or basename>", "new": "<new
basename>"} objects. The script never guesses: it refuses the whole plan —
moving nothing — if any source is missing or ambiguous, any target already
exists, or two entries claim the same target. Entries already correctly named
are skipped, so re-running a plan is a no-op.

Only the .pdf is touched; a matching .log beside it is deliberately left alone.
"""

import argparse
import json
import os
import re
import sys
import unicodedata

# Windows-forbidden characters. Square brackets are absent on purpose: they
# are legal on NTFS and load-bearing in this naming convention.
FORBIDDEN = r'<>:"/\\|?*'


def nfc(s):
    return unicodedata.normalize("NFC", s)


def sanitise(name):
    """Make a basename safe for the NTFS mount without losing the brackets."""
    stem, ext = os.path.splitext(name)
    stem = re.sub(f"[{re.escape(FORBIDDEN)}]", "_", stem)
    stem = "".join(c for c in stem if unicodedata.category(c)[0] != "C")
    stem = re.sub(r" {2,}", " ", stem).strip().rstrip(".")
    return stem + ext


def resolve(outdir, wanted):
    """Find the real directory entry for `wanted` despite NFC/NFD drift."""
    target = nfc(os.path.basename(wanted))
    for entry in os.listdir(outdir):
        if nfc(entry) == target:
            return entry
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("plan", help="JSON file: [{pdf, new}, ...]")
    ap.add_argument("-o", "--output", default="output")
    ap.add_argument("--apply", action="store_true",
                    help="actually rename (default: dry run)")
    args = ap.parse_args()

    with open(args.plan, encoding="utf-8") as fh:
        plan = json.load(fh)

    outdir = args.output
    existing = {nfc(e) for e in os.listdir(outdir)}
    moves, skipped, errors = [], [], []
    claimed = {}

    for entry in plan:
        src_name = os.path.basename(entry["pdf"])
        new_name = sanitise(entry["new"])

        actual = resolve(outdir, src_name)
        if actual is None:
            # Source gone and target already sitting there: this plan has been
            # applied before. Re-running it is a no-op, not a failure.
            if resolve(outdir, new_name):
                skipped.append(new_name)
            else:
                errors.append(f"missing source: {src_name}")
            continue
        if not new_name.lower().endswith(".pdf"):
            errors.append(f"target is not a .pdf: {new_name}")
            continue
        if nfc(actual) == nfc(new_name):
            skipped.append(actual)
            continue
        if nfc(new_name) in existing:
            errors.append(f"target exists: {new_name}  (from {actual})")
            continue
        prev = claimed.get(nfc(new_name))
        if prev:
            errors.append(f"two sources claim {new_name}: {prev}, {actual}")
            continue
        claimed[nfc(new_name)] = actual
        moves.append((actual, new_name))

    for old, new in moves:
        print(f"  {old}\n    -> {new}")
    for name in skipped:
        print(f"  = {name}  (already correct)")
    # Flush before touching stderr, so a refusal cannot appear above the plan
    # it refuses and read as though those moves had happened.
    sys.stdout.flush()
    for err in errors:
        print(f"  ! {err}", file=sys.stderr)

    if errors:
        print(f"\nrename.py: {len(errors)} problem(s); nothing moved.",
              file=sys.stderr)
        return 1

    if not args.apply:
        print(f"\nDry run: {len(moves)} to rename, {len(skipped)} already "
              f"correct. Re-run with --apply.")
        return 0

    for old, new in moves:
        os.rename(os.path.join(outdir, old), os.path.join(outdir, new))
    print(f"\nRenamed {len(moves)} file(s); {len(skipped)} already correct.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
