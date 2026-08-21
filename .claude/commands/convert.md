---
description: Convert EPUB files to reMarkable 2 PDFs with convert.sh, rename the output to the library convention, then report page counts and warnings.
argument-hint: [options] FILE.epub [FILE.epub ...]
allowed-tools: Bash(./convert.sh:*), Bash(ls:*), Bash(pdfinfo:*), Bash(python3 .claude/skills/rename-book-pdfs/scripts/*), Skill, Read, Write, WebSearch, WebFetch
---

Run the project's conversion script on the files the user named: `$ARGUMENTS`

    ./convert.sh $ARGUMENTS

Then rename what it produced (see "Naming the output" below).

Rules:

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
- Point the helpers at the directories this run actually used: `-o` is the
  `-o DIR` passed to `convert.sh` (`output` by default) and `-e` is the
  directory holding the converted EPUBs (`ebooks` by default). If they came
  from several directories, run `epub_meta.py` once per directory.
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
