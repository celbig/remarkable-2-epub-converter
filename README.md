# EPUB → PDF for the reMarkable 2

Novels bought as EPUBs are laid out for whatever screen happens to open them.
This pipeline pins that down: it takes an EPUB — French by default, English or
another language with `-l` — and typesets a PDF for one specific screen — the
reMarkable 2's 10.3" panel — so the page you read looks like a printed novel
rather than a reflowed web page.

```
epub → pandoc (+ Lua filter) → LaTeX (lualatex) → pdf
```

What comes out: a 157 × 209 mm page with 10 mm margins, set in 16 pt EB
Garamond, with the typography of the book's own language (in French:
guillemets, thin spaces before `; : ! ?`, French hyphenation; in English:
“quotes”, no space before those marks, English hyphenation), drop caps where
the publisher used them, no running heads
or page numbers cluttering a small screen, and a PDF outline so chapter
navigation works on the device. The book opens on its cover and its own title
page rather than on the publisher's ISBN block, and ornaments are drawn at the
size of an ornament instead of a page.

```bash
./convert.sh "ebooks/My Book.epub"
```

That is the whole thing. Everything below is detail.

## Before you start

You need three things installed:

- **pandoc** 3.1 or newer, with Lua scripting — `pandoc --version` should
  mention `+lua`
- **lualatex**, with KOMA-Script, `polyglossia`, `fontspec`, `lettrine` and
  `hyperref` — TeX Live's `scheme-medium` or larger covers all of them.
  `xelatex` and `pdflatex` will *not* work as substitutes; the template relies
  on lualatex's font handling.
- **EB Garamond**, all three faces: the regular family, `EB Garamond SC` for
  small caps, and `EB Garamond Initials` for drop caps. Check with
  `fc-list | grep -i garamond`.

Three optional extras: `pdfinfo` (from poppler) gives you a page count in the
conversion summary, `luacheck` lints the Lua filters, and `python3` 3.8+ runs
the renaming scripts.

## Converting books

Put your EPUBs anywhere — `ebooks/` is the habitual place — and run:

```bash
./convert.sh "ebooks/My Book.epub"          # one book
./convert.sh ebooks/*.epub                  # the whole shelf
./convert.sh -m 8mm -s 18pt ebooks/*.epub   # tighter margins, larger type
./convert.sh -l en "ebooks/A Novel.epub"    # an English book
```

Options:

| Flag | Meaning | Default |
| --- | --- | --- |
| `-o DIR` | where to write the PDFs | `./output` |
| `-m DIM` | page margin | `10mm` |
| `-s SIZE` | base font size | `16pt` |
| `-l LANG` | language of the book | `fr` |
| `-V K=V` | set a template variable, repeatable | |
| `-M K=V` | set a document setting, repeatable | |
| `-k` | keep the build log even when the book converts cleanly | off |
| `-h` | show this help | |

Each book becomes `output/<name of the epub>.pdf`. If a conversion fails, the
build log is kept next to where the PDF would have gone and the last lines are
printed; on success the log is deleted unless you passed `-k`.

`-l` is the one option worth passing for a book that is not French. It picks
four things at once: the hyphenation patterns, whether `; : ! ?` take a space
before them (French) or not (everything else), which quotation marks `\enquote`
produces, and which publisher's front matter the filter recognises — an English
edition's *All rights reserved* and *Also by* pages are dropped exactly as a
French one's *Tous droits réservés* and *Du même auteur* are. It takes
`fr`, `fr-FR`, `fr-CA`, `en`, `en-US`, `en-GB`, and `de`, `es`, `it`, `nl`,
`pt`; only French and English have their punctuation and front-matter rules
tuned, the rest get correct typesetting and the non-French defaults. Any other
polyglossia language still works the long way round:
`-V mainlanguage=<gloss> -V lang=<bcp47> -M lang=<code>`.

The language is never guessed from the EPUB. These files declare it wrongly
often enough — one French novel in the test shelf reports `dc:language en` from
cover to cover — that trusting the metadata would silently ruin the typography
of the books this pipeline exists for.

`-V` reaches the template, `-M` reaches the filter. The ones you are most
likely to want:

| Setting | Meaning | Default |
| --- | --- | --- |
| `-M frontmatter-trim=false` | keep the publisher's copyright, ISBN and catalogue pages | trimmed |
| `-M small-image-max=N` | pixel size at or below which an image is a decoration, drawn at its real size rather than fitted to the page | `200` |
| `-M front-page-max-lines=N` | how tall a front-matter page may be and still be centred | `18` |
| `-V dropcap-lines=N` | how many lines a drop cap spans | `2` |

Trimming the front matter throws content away, so it says what it dropped:
every removed page prints a `[WARNING] cleanup.lua: front matter dropped: …`
line, which is included in the warning count each book reports. Run with `-k`
and read the log if a book comes out missing something you wanted.

Two practical notes. **Quote every path** — real book filenames are full of
spaces, brackets and apostrophes. And a 600-page novel takes a minute or two,
so converting a whole shelf is a coffee-break operation, not an instant one.

Font size is worth experimenting with. 16 pt is the default because it reads
well on a 226 DPI panel at arm's length, but the right answer is personal:
convert one book at `-s 18pt`, put both on the device, and see.

## Renaming the output

PDFs come out named after the EPUB that produced them, which for a downloaded
library means names like `[Le cycle des cendres _3] Auteur, Un - Fievres et
marees (1998, Éditeur) - source.pdf`. Tidying those into `[Series N] Title.pdf` is a
separate step you run when you want it — see the Claude Code section below,
which is where that particular chore lives.

## Claude Code integration

This repository is also a [Claude Code](https://claude.com/claude-code) plugin.
It adds one command and one skill.

### Installing

If you have cloned the repository and you are working *inside* it, there is
nothing to install — Claude Code picks up the `.claude/` directory on its own,
and the command is simply `/convert`.

To use it from anywhere else, install it as a plugin:

```
/plugin marketplace add celbig/remarkable-2-epub-converter
/plugin install remarkable-2-epub-converter@remarkable-2-epub-converter
```

Installed that way, the command and skill are namespaced under the plugin name:
`/remarkable-2-epub-converter:convert`.

### The `/convert` command

Give it the books you want converted:

```
/convert "ebooks/My Book.epub"
/convert -m 8mm -s 18pt ebooks/*.epub
```

It runs `convert.sh` with those arguments and reports, per book, the page count
and how many warnings pandoc raised. When a conversion fails it reads the build
log and tells you what actually broke instead of handing you the whole file.
It takes the same flags as the script, so anything in the table above works.

Once the run finishes it hands the fresh PDFs to the `rename-book-pdfs` skill
below, so they land in `output/` already named `[Series N] Title.pdf` instead of
whatever the source EPUB was called. Only the books from that run are touched,
and the mapping is still shown to you before anything moves. `convert.sh`
itself is unchanged — run the script directly and you get the source filenames,
as always.

### The `rename-book-pdfs` skill

Skills are not commands you memorise — you just say what you want:

> Rename the PDFs in output/

The skill reads each PDF's originating EPUB, pulls the title, series name and
volume number out of its metadata, and proposes `[Series N] Title.pdf` for each
one. Downloaded metadata is unreliable, so it checks its own work: it looks up
anything doubtful on the web, restores accents that were stripped somewhere in
the chain, drops subtitles the volume does not really carry, and folds
`Les Chroniques du Vent` and `Les chroniques du vent` onto one spelling so a
series stays together in a file listing.

Then it stops and shows you the full old → new mapping before touching
anything. Nothing moves until you have seen the list. Where it had to guess, it
asks — once, all questions batched together, never one file at a time — and
writes each answer into its own `corrections.md` so the same question is never
asked twice. That file stays on your machine; it is git-ignored, because it
describes your shelf and nobody else's.

You can also invoke it explicitly as `/rename-book-pdfs`.

## What is in here

```
convert.sh, convert.fish   the entry points — same options, two shells
template.latex             the LaTeX template: page geometry, fonts, French
                           setup, drop caps, no page chrome
filters/cleanup.lua        repairs EPUB quirks before LaTeX sees them
dev/                       debugging aids, not used by a conversion
.claude/                   the command and skill described above
CLAUDE.md                  design notes: why each decision was made
ebooks/, output/           your library and its PDFs — git-ignored
```

`ebooks/` and `output/` are excluded from the repository on purpose: books are
copyrighted, and only the pipeline belongs in version control. Keep it that
way.

If you want to know *why* the page is 157 mm wide or why the class is
`scrbook`, [CLAUDE.md](CLAUDE.md) has the reasoning — device geometry, the
French typographic rules the output has to satisfy, and the EPUB structures the
filters are written against.

## Working on the filters

Publisher EPUBs differ wildly, so the first move on any new bug is to look at
the document as pandoc sees it rather than guess:

```bash
pandoc test.epub --lua-filter=dev/simple.lua -t native -o /dev/null 2>test.log
```

`test.epub` is whatever short novel you drop in at the project root under that
name — it is not in the repository, since every `.epub` is git-ignored. Use a
short one; you will run this a lot.

The resulting log is millions of lines, so search it, never open it whole.
Three smaller views of the same book are often enough:

```bash
pandoc test.epub -t markdown -o test.md    # the AST, readably
pandoc test.epub -t latex    -o test.tex   # what the writer currently emits
unzip -d test test.epub                    # the raw XHTML, CSS and OPF
```

All of these are throwaway artefacts and are git-ignored.

Before calling a filter done, lint it — and if you added a new element handler,
list it in `.luacheckrc` so luacheck knows it is meant to be global:

```bash
luacheck filters/ dev/
```

Then validate against a real book. One fixture proves nothing about another
publisher's class names, which is how most of the bugs in `cleanup.lua` were
found in the first place.

## Licence

MIT. The one exception is `dev/logging.lua`, which is
[pandoc-lua-logging](https://github.com/wlupton/pandoc-lua-logging) by William
Lupton — vendored unmodified, also MIT.
