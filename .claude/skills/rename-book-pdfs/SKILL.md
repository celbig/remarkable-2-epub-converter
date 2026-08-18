---
name: rename-book-pdfs
description: Rename converted reMarkable 2 ebook PDFs in output/ to the `[Series N] Title.pdf` convention, taking series and title from EPUB metadata and correcting it against the web when it is wrong or missing. Use after converting EPUBs with convert.sh / convert.fish, or when asked to fix, tidy, or normalise book PDF filenames.
---

# Rename book PDFs

`convert.sh` names each PDF after the EPUB that produced it, so `output/` fills
up with whatever the source files happened to be called — uploader tags,
publisher, year, volume numbers, all of it. This skill renames them to the
library convention.

Every book named below is invented, and so is every series: they illustrate the
shapes this metadata arrives in. The failure modes themselves are real and
recur across editions.

## The convention

`[Series N] Title.pdf`

    [Le Cycle des Cendres 2] La Tour de sel.pdf

- `N` is the volume's position **in the series named in the brackets**, as a
  bare integer — calibre stores it as a float, so `5.0` becomes `5`.
- A book with no series gets a bare `Title.pdf`. Never invent a series or a
  number just to reach the bracket form.
- Leave the matching `.log` file alone unless the user asks otherwise.
- A PDF may carry a trailing variant tag the user added by hand, e.g.
  `[Le Cycle des Cendres 1] Le Serment brisé (18pt sample).pdf`. Keep it.

## Workflow

### 0. Locate the scripts

Both helpers live in `scripts/` next to this SKILL.md. Run them by that
directory, not by a path relative to the project:

- working in a clone of the pipeline repo: `.claude/skills/rename-book-pdfs/scripts/`
- installed as a plugin: `${CLAUDE_PLUGIN_ROOT}/.claude/skills/rename-book-pdfs/scripts/`

Below, `$SCRIPTS` stands for whichever of the two applies. Both scripts take
`-e/--ebooks` and `-o/--output`, defaulting to `ebooks` and `output` relative
to the current directory, so run them from the project root.

### 1. Gather

    python3 "$SCRIPTS/epub_meta.py"

Matches every `output/*.pdf` to the `ebooks/*.epub` that produced it and prints
JSON with `title` / `series` / `index` from the EPUB's `.opf`, plus a
`proposed` name built from the raw metadata. It reports `unmatched` and
`ambiguous` PDFs separately — those are for the user to resolve, not for you to
guess at.

The script flattens the `.opf` to one line (tags are routinely split across
newlines), decodes XML entities, and reads `<dc:title>`,
`<meta name="calibre:series">` / `belongs-to-collection`, and
`<meta name="calibre:series_index">` / `group-position`.

### 2. Correct

`proposed` is a starting point, not an answer. **Read `corrections.md`, next
to this SKILL.md, first** — a book listed there is already settled, so use that
row and do not ask about it again.

That file is git-ignored: it describes one person's library, so it lives on
that machine rather than in the repository, and a fresh clone will not have
one. Treat a missing file as "nothing settled yet", not as an error, and
create it as described in step 3 when you have the first decision to record.

For anything not in that file, this metadata comes from whoever produced the
EPUB and is often wrong. Sanity-check it, and **search the web** whenever
something is unclear, missing, or off. The recurring failure modes, with
invented titles standing in for real ones:

- **Wrong series.** A sub-series filed under its parent with continuous
  numbering — `La Tour de sel` arriving as "Les Chroniques du Vent 6" when it
  is volume 2 of the `Le Cycle des Cendres` sub-series. File it under the
  sub-series the volume actually belongs to, numbered in French publication
  order.
- **Missing series.** `L'Héritier de cendre` carries no series metadata at all,
  even though it closes a quartet.
- **Subtitles.** Its `dc:title` is `L'Héritier de cendre : une histoire des
  Chroniques du Vent`; the volume is just `L'Héritier de cendre`.
- **Inconsistent capitalisation.** The same series arrives as both `Le Cycle
  des Cendres` and `Le cycle des cendres`. Fold case variants onto one
  canonical spelling so the series groups together in a listing.
- **Stripped accents, and a volume number in the title.** `Fièvres et marées`
  arrives as `Fievres et marees 3`. Restore the diacritics and drop the number,
  which the bracket already carries.

### 3. Ask, once

Ask the user to confirm whenever you are unsure — a series number you had to
infer, a title you could not verify, a series name you had to choose between
variants. **Batch every question into one round**; never ask per file. Where
you are confident, just proceed and say what you assumed.

Then append each confirmed decision to `corrections.md` so the same question is
never asked twice. Key rows by the EPUB's `<dc:title>` — source *filenames*
vary far more than the embedded metadata does — and leave series and number
empty for a book deliberately filed as a bare `Title.pdf`. Create the file with
this header if it does not exist yet:

    # Confirmed corrections

    Books whose EPUB metadata is wrong, incomplete, or spelled inconsistently,
    and what the correct filename parts are. **Consult this before asking the
    user anything** — a row here is settled.

    | EPUB `dc:title` | Series | N | Display title |
    | --- | --- | --- | --- |

Add a `## Notes` section below the table for anything a single row cannot
carry — why a sub-series was renumbered, which capitalisation was made
canonical.

### 4. Dry run, then rename

Write the plan as JSON — `[{"pdf": "<current basename>", "new": "<new
basename>"}, ...]` — to the scratchpad, then:

    python3 "$SCRIPTS/rename.py" plan.json
    python3 "$SCRIPTS/rename.py" plan.json --apply

The first call prints the full old → new mapping and moves nothing. **Show that
mapping to the user before applying it.**

`rename.py` handles the constraints so you do not have to re-derive them: it
matches directory entries under NFC normalisation (this is an NTFS mount, and
the names carry accents), replaces `< > : " / \ | ? *` with `_` while keeping
the square brackets, collapses runs of spaces, skips files already correctly
named, and refuses the *whole* plan — moving nothing — if a source is missing,
a target already exists, or two entries claim the same target.

Quote every path you pass around: every filename here contains spaces, and
several contain brackets, braces and apostrophes.

### 5. Report

Say what was renamed, what was skipped as already correct, what you assumed,
and anything you deliberately left alone (unmatched PDFs, stray `.log` files).

## Out of scope

Do not modify `convert.sh` or `convert.fish`. Renaming is a separate step the
user runs when they choose; it must not be wired into conversion.
