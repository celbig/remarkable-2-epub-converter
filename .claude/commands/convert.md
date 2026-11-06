---
description: Convert EPUB files to reMarkable 2 PDFs with convert.sh, rename the output to the library convention, file the source EPUB when it came from « à convertir », then report page counts and warnings.
argument-hint: [options] FILE.epub [FILE.epub ...]
allowed-tools: Bash, Skill, Read, Write, WebSearch, WebFetch
---

Run the conversion script on the files the user named: `$ARGUMENTS`

Locate the script first. Installed as a plugin it is
`${CLAUDE_PLUGIN_ROOT}/convert.sh`; working inside a clone of the pipeline repo
it is `./convert.sh`. Use whichever exists, by that path, quoted.

    "${CLAUDE_PLUGIN_ROOT}/convert.sh" -o output $ARGUMENTS

Then rename what it produced (see "Naming the output" below), and file every
source EPUB taken from `à convertir/` (see "Filing the source EPUB" below).

Rules:

- **Always pass `-o` explicitly.** The script defaults its output directory to
  `output/` *next to itself*, which as a plugin means inside the plugin cache —
  wiped on the next plugin update. Use the `-o DIR` the user gave, or `output`
  in the current working directory if they gave none.
- Quote every path. Every filename in this library contains spaces, and many
  contain brackets, braces or apostrophes.
- If no argument was given, ask which books to convert rather than converting
  all of `ebooks/` — the real novels take minutes each.
- The script's options are `-o DIR` (output directory), `-m DIM` (page margin),
  `-s SIZE` (base font size), `-l LANG` (language of the book: `fr` by default,
  `en`/`en-GB` for an English one), `-V K=V` and `-M K=V` (repeatable, passed
  straight to pandoc) and `-k` (keep the build log on success). Pass them
  through as given; do not invent defaults.
- The language is not guessed, by the script or by you: convert with whatever
  `-l` the user gave. If they name a book you can see is not French and gave no
  `-l`, say so and ask before converting — a French-typeset English novel comes
  out with spaces before its exclamation marks and the wrong hyphenation.
- On failure the build log is kept next to the PDF. Read its tail, say what
  actually broke, and do not retry the same command unchanged.
- Report per book: page count and warning count, both printed by the script.
  The page count needs `pdfinfo` (poppler); without it the script says so and
  reports the warnings alone.
- The warning count includes the front matter the filter dropped — copyright
  and catalogue pages, digitiser marks. If a book reports warnings and the
  user wonders what went missing, rerun with `-k` and read the
  `[WARNING] cleanup.lua:` lines, or convert that book with
  `-M frontmatter-trim=false` to keep everything.

## Naming the output

`convert.sh` names each PDF after the EPUB that produced it. Once the run
finishes, invoke the `rename-book-pdfs` skill and follow it to rename those
PDFs to `[Series N] Title.pdf`.

- **Only the PDFs this run produced.** `epub_meta.py` reports every PDF in the
  output directory; put just this run's books in the plan and leave the rest
  alone, however they are named. A book that failed to build has no PDF to
  rename — skip it and report the failure instead.
- The skill's two helpers live beside its `SKILL.md`: as a plugin, in
  `${CLAUDE_PLUGIN_ROOT}/.claude/skills/rename-book-pdfs/scripts/`; in a clone
  of the repo, in `.claude/skills/rename-book-pdfs/scripts/`.
- Point the helpers at the directories this run actually used: `-o` is the
  `-o DIR` passed to `convert.sh` and `-e` is the directory holding the
  converted EPUBs. If they came from several directories, run `epub_meta.py`
  once per directory.
- The skill's own rules still apply in full: consult `corrections.md` before
  asking anything, batch every remaining question into one round, show the
  dry-run mapping before applying it, and append each confirmed decision back
  to `corrections.md`.
- Renaming is the last step, never a reason to stop reporting: if it is
  blocked — the EPUB is unmatched or ambiguous, a target name already exists,
  the user does not answer — report the conversion results anyway, say which
  PDFs kept their original names and why.
- Do not modify `convert.sh` or `convert.fish` to do any of this. The renaming
  happens here, in this command, after the script has run.

## Filing the source EPUB

A local rule for this one library, rooted at `~/Documents/books` (the working
directory). New books arrive in `à convertir/`; once one is converted and its
PDF named, its source EPUB is renamed and moved into `Romans/`. An EPUB
converted from anywhere else stays where it is, under its own name.

- **Name: the PDF's final name plus the author.** `[Series N] Title -
  Author.epub`, or `Title - Author.epub` for a book with no series, reusing
  exactly the series, number and title just settled for the PDF. The author
  is written first name first (`Nom, Prénom` → `Prénom Nom`, initials spaced
  as in `J. K. Rowling`); several authors are joined with ` & `, an anthology
  is `Collectif`. A translator listed in `<dc:creator>` is not an author.
- **Destination: `Romans/<genre>/<series>/`**, or `Romans/<genre>/` for a book
  with no series. A series gets its own folder even with a single volume, and
  that folder bears the series name used in the brackets. If the series
  folder already exists somewhere under `Romans/`, file the book there and
  inherit its genre.
- **Genres** are the folders `fantasy`, `science-fiction`, `littérature`,
  `romance` and `erotique`. Romantasy goes in `romance`. A book that is not a
  novel leaves `Romans/`: essays to `Essais/`, technical books to
  `science et technique/`, same naming.
- **Warhammer 40k** goes flat into `Romans/Epub WH40k/`, named in that
  folder's own style — `Faction - Titre.epub`, no author, ` (EN)` before the
  extension for an English book. Never rename or move the files already there.
- **A duplicate** of a book already filed goes to `Romans/_doublons/` under its
  original name. Never delete a book.
- **Ask in the same round.** A genre you are unsure of joins the rename
  skill's single batch of questions; never ask separately. Show the EPUB moves
  in the same dry-run mapping as the PDF renames, before applying anything.
- **Apply with the helper**, from the library root:

      python3 "$SCRIPTS/file_epub.py" epub-plan.json
      python3 "$SCRIPTS/file_epub.py" epub-plan.json --apply

  where `$SCRIPTS` is the rename skill's `scripts/` folder and the plan is
  `[{"epub": "à convertir/<file>.epub", "dest": "Romans/<genre>/<series>/<name>.epub"}, ...]`.
  Like `rename.py`, it refuses the whole plan if a source is missing or a
  target exists, and it matches names under NFC.
- **Only after the PDF is named.** A book that failed to build, or whose PDF
  rename was blocked, keeps its EPUB in `à convertir/` so it can be retried.
  Report where each filed EPUB went.
