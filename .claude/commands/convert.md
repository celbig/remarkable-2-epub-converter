---
description: Convert EPUB files to reMarkable 2 PDFs with convert.sh, then report page counts and warnings.
argument-hint: [options] FILE.epub [FILE.epub ...]
allowed-tools: Bash(./convert.sh:*), Bash(ls:*), Bash(pdfinfo:*)
---

Run the project's conversion script on the files the user named: `$ARGUMENTS`

    ./convert.sh $ARGUMENTS

Rules:

- Quote every path. Every filename in this library contains spaces, and many
  contain brackets, braces or apostrophes.
- If no argument was given, ask which books to convert rather than converting
  all of `ebooks/` — the real novels take minutes each.
- The script's options are `-o DIR` (output directory), `-m DIM` (page margin),
  `-s SIZE` (base font size) and `-k` (keep the build log on success). Pass
  them through as given; do not invent defaults.
- On failure the build log is kept next to the PDF. Read its tail, say what
  actually broke, and do not retry the same command unchanged.
- Report per book: page count and warning count, both printed by the script.
- Do not rename the PDFs here. That is the `rename-book-pdfs` skill, run
  separately when the user asks for it.
