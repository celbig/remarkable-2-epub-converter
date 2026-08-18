# ebook — EPUB → PDF pipeline for the reMarkable 2

## Goal

Build a LaTeX template + Pandoc Lua filters that convert French-language EPUB
novels into PDFs laid out for the reMarkable 2's screen (not a generic
A4/Letter page). The pipeline is: `epub → pandoc (+ lua filters) → LaTeX
(lualatex) → pdf`.

## Confirmed toolchain (this machine)

- `pandoc 3.1.3` — Lua scripting engine: **Lua 5.4** (`+lua` feature)
- PDF engines available: `xelatex`, `lualatex`, `pdflatex` — **use
  `lualatex`** (`--pdf-engine=lualatex`), not `xelatex` or `pdflatex`. The
  source text is French with accented characters and needs proper
  font/Unicode handling (`fontspec`) plus **polyglossia** for correct
  French typographic rules (see below) — both work under lualatex the same
  as under xelatex. `pdflatex` + babel can work but polyglossia requires
  lualatex/xelatex.

## Directory layout

```
.
├── convert.sh          Entry point: epub(s) -> output/*.pdf. Options -o/-m/-s/-k.
├── convert.fish         Same tool for fish; keep the two in sync.
├── template.latex       Forked from `pandoc -D latex`: page geometry, EB Garamond,
│                        polyglossia French, \dropcap, no headers/footers/folios.
├── filters/
│   └── cleanup.lua      Repairs EPUB source artifacts (SoftBreak before
│                        punctuation, .lettrine spans -> \dropcap).
├── dev/                 Debugging aids, never part of a conversion:
│   ├── simple.lua       Dumps the whole Pandoc AST to stderr via logging.temp().
│   └── logging.lua      pandoc-lua-logging (github.com/wlupton/pandoc-lua-logging),
│                        vendored; simple.lua finds it via PANDOC_SCRIPT_FILE.
├── .luacheckrc          Declares pandoc globals (Pandoc, Meta, Header, Blocks,
│                        FORMAT, PANDOC_VERSION, …) — keep any new global filter
│                        function added across .lua files listed here.
├── .claude/             settings.json, commands/convert.md, skills/rename-book-pdfs/
├── .claude-plugin/      plugin.json + marketplace.json — this repo is also an
│                        installable Claude Code plugin; both point back at
│                        .claude/, so there is one copy of each command and skill.
├── test.epub            Small fixture to iterate on filters/template. Git-ignored.
├── ebooks/              The real library. Git-ignored (copyrighted).
└── output/              Converted PDFs and failed-build logs. Git-ignored.
```

Everything derived from `test.epub` is a regenerable artifact, git-ignored,
and absent from a fresh clone — recreate what you need:

```
pandoc test.epub --lua-filter=dev/simple.lua -t native -o /dev/null 2>test.log
pandoc test.epub -t markdown -o test.md      # readable AST
pandoc test.epub -t latex    -o test.tex     # current writer output
unzip -d test test.epub                      # raw XHTML/CSS/OPF
```

`test.log` is ~9 MB — grep it, never cat it whole.

There is no build system, package manager or test harness here: the project
is a handful of scripts driving pandoc and lualatex directly, and the commands
above are the whole workflow.

## Target device / page geometry

```
Largeur (width)  = 10,3 × 4/5 = 8,24 po ≈ 20,9 cm = 209 mm
Hauteur (height) = 10,3 × 3/5 = 6,18 po ≈ 15,7 cm = 157 mm
Surface          ≈ 50,9 po² ≈ 328 cm²
Résolution       = 1872 × 1404 px, 226 DPI
```

This is the reMarkable 2: a 10.3", 4:3 monochrome e-ink panel. Its published
specification — 10.3", 1872 × 1404 px, 226 DPI — is exactly the figures above,
so treat them as the device's own, not as a target someone picked.

`157 mm × 209 mm` is the **portrait** reading orientation (width × height);
the numbers above are given
width-first, and so is the resolution (1872×1404 landscape-style, i.e.
1404×1872 px in portrait — confirmed by `1404 / 226 dpi ≈ 157 mm` and
`1872 / 226 dpi ≈ 209 mm`). When setting LaTeX geometry, be explicit about
which is which rather than trusting variable name order:

```yaml
geometry: "paperwidth=157mm,paperheight=209mm"
fontsize: 14pt
```

Requirements for this device, deliberately different from print defaults:
- **Narrow margins** — maximize usable text area on a small screen; there's
  no bleed/trim concern like paper. Set only the physical page size via
  `geometry` and let KOMA's `typearea` compute the text area/margins from
  it (its default `DIV` calculation is margin-narrowing by design, unlike
  `geometry`'s default 1-inch margins) — try that default first rather than
  hardcoding a `margin=` value, and only override with an explicit narrower
  margin if it's still not tight enough once tested on-device.
- **Large base font size, 14pt minimum** — standard LaTeX classes
  (`article`/`report`/`book`) only accept `10pt`/`11pt`/`12pt` as class
  options; this is one more reason to use `scrbook` (see below), since
  KOMA-Script classes accept arbitrary point sizes like `fontsize=14pt`.
  Treat 14pt as a floor, not a target — tune upward against the device's
  actual PPI once tested on-device.
- **226 DPI** is now a known figure, not a guess — use it to reason about
  rasterized output: embedded images extracted from EPUBs are typically
  ~96–150 DPI web-res, so upscaling artifacts won't show at this device's
  resolution, but don't downsample below it either. If image processing is
  ever added to a filter, target 226 DPI (or an integer multiple, for
  headroom) rather than a print convention like 300 DPI.

## Design decisions (settled)

- **Font: EB Garamond.** Confirmed installed (`fc-list | grep -i garamond`)
  with the full family lualatex/fontspec needs: `EB Garamond` (regular/
  italic/bold), plus companion faces `EB Garamond SC` (small caps) and
  `EB Garamond Initials` (decorative drop-cap glyphs). The SC and Initials
  faces exist specifically to serve the "keep original styling" decision
  below — small-caps chapter openers and `.lettrine` drop caps should use
  these rather than faking small-caps/drop-caps with `\textsc`/scaling
  tricks on the regular face.
  ```yaml
  mainfont: "EB Garamond"
  ```
- **PDF bookmarks: yes.** Pandoc's default LaTeX template already loads
  `hyperref` with `bookmarks=true`, generating a PDF outline from `Header`
  levels automatically — no extra template work needed, just make sure a
  custom template doesn't strip the hyperref bookmark setup when forking
  from `-D latex`. This is the primary chapter-navigation mechanism on the
  tablet, so don't let a filter flatten/skip heading levels.
- **Styling fidelity: keep text-level styling, not full layout fidelity.**
  Reproduce `.lettrine` drop caps and inline text styling (italics,
  small caps) — see "What the test fixture's EPUB structure looks like"
  above for the concrete elements (`.lettrine`, `.fmtit`) a filter needs to
  translate to LaTeX (`lettrine` package, `EB Garamond SC`, etc.). Don't
  chase full publisher layout fidelity beyond that: e.g. the raw-HTML
  SVG cover trick doesn't need reproducing — a minimal title page (title/
  author, plain) is fine. Since books vary by publisher, expect filters to
  need per-class-name handling for the styling that *is* kept, rather than
  one universal rule, and validate against more than one real file in
  `ebooks/`.
- **No headers/footers/page numbers.** Disable running heads and folios
  (e.g. `\pagestyle{empty}` — check the KOMA-idiomatic equivalent,
  `\KOMAoptions{headings=...}`/`scrlayer-scrpage`, before defaulting to the
  classic LaTeX command) to keep the narrow-margin page free of chrome; the
  tablet's own PDF viewer supplies page position/progress.

## Pandoc concepts recap (for this project)

### CLI basics
```
pandoc input.epub -f epub -t latex --pdf-engine=lualatex \
  --template=template.latex --lua-filter=filters/foo.lua \
  -o output.pdf
```
- `-f`/`-t` set input/output format; usually inferred from extension.
- `-s`/`--standalone` wraps output in a full document (implied by `--template`).
- `-o` sets output file; format can also be inferred from its extension.
- `--extract-media=DIR` pulls embedded EPUB images out to disk (needed since
  EPUB images are zipped inside the source).
- Multiple `--lua-filter` flags chain in the order given on the command line.

### Template variables relevant to us
Set via YAML metadata block, `-V key=value`, or `-M key=value`:
- `documentclass`, `geometry`, `papersize`, `fontsize`, `mainfont` (lualatex, via `fontspec`)
- `linestretch`, `lang` (drives babel/polyglossia — use `fr` or `fr-FR`)
- `csquotes: true` — makes the LaTeX writer wrap `Quoted` inlines in
  `\enquote{}` instead of raw curly quotes; combined with `lang: fr` and
  polyglossia this produces correct `« … »` guillemets automatically.
- `-D latex` prints pandoc's built-in default LaTeX template — the right
  starting point to fork into our custom template rather than writing one
  from scratch.

### Document class: use KOMA-Script

`documentclass: scrbook` — not `book`/`report`/`article`. This is a
book-length document (novel chapters), and KOMA-Script's typography
(heading style, spacing, `\KOMAoptions`) is a better base than the classic
LaTeX classes for this kind of layout:
- Font size still goes through the `fontsize` template variable / `-V
  fontsize=Xpt`; KOMA also accepts it as a class option, so keep them
  consistent if both appear in the template.
- Prefer KOMA's own `typearea` package for computing the page layout
  (`DIV`, `BCOR`) over hardcoding `geometry` margins by hand — `BCOR`
  (binding correction) can just be `0mm` since this is a PDF for a screen,
  not a printed/bound book. `typearea` and `geometry` can coexist: set the
  physical page size via `geometry` (`paperwidth`/`paperheight`) and let
  `typearea` derive the text-area margins from it.
- `scrbook` gives sensible chapter/section heading commands out of the box
  (`\chapter`, `\section`, …) that map directly onto Pandoc's `Header`
  levels — don't reinvent heading styling in the template when a
  `\KOMAoptions{headings=...}` tweak will do.

### Lua filters
- A filter is a Lua table (or top-level functions in a file) mapping element
  type names to handler functions: `Header`, `Para`, `Image`, `Str`, `Div`,
  `Span`, `Meta`, `Pandoc`, etc. Handler receives the element, returns `nil`
  (no change), a replacement element, or a list of elements.
- Default traversal is **typewise**: all `Inline`-level handlers run first
  (leaves before container `Inlines`), then `Block`-level, then `Meta`, then
  a whole-document `Pandoc` function last if present. Set
  `traverse = 'topdown'` in the returned filter table for depth-first order
  with the ability to skip subtrees (`return elem, false`).
- `elem:walk{...}` applies a sub-filter to one node's subtree directly —
  useful for one-off transforms without a second `--lua-filter` pass.
- Useful stdlib: `pandoc.utils.stringify(elem)` (flatten to plain text),
  `pandoc.List` (map/filter/insert on Lua tables), `pandoc.read`/`pandoc.write`
  for round-tripping through another format, `FORMAT` global for
  format-conditional logic.
- Debugging: `dev/simple.lua` + `dev/logging.lua` (`logging.temp(label,
  value)`) is the existing pattern — run it against `test.epub` (see
  "Directory layout" for the command), inspect/grep `test.log` for the AST
  shape before writing a transform.

## What the test fixture's EPUB structure looks like

From `test.md`/`test.log` (Calibre-produced EPUB, typical of the
bulk-converted sources found in `ebooks/`):
- Cover is a raw HTML `<svg>`/`<image>` block (`RawBlock`/`RawInline`,
  `format: "html"`), not a plain Pandoc `Image` — a filter that wants to
  find/replace the cover must handle this raw-HTML case.
- Section/chapter breaks are `Div`s with Calibre-ish classes: `.section`,
  `.sectionpp`, `.dedicaces`, `.div_prol`, `.div_autre`, `.pre`.
- Drop caps use a `.lettrine` class span around the first letter — needs
  explicit LaTeX handling (e.g. the `lettrine` package) since Pandoc has no
  native concept of this.
- Chapter headers mix text and an inline image: `# P[ROLOGUE]{.small}
  ![image](...){.img}  {.fmtit}` — filters/templates touching `Header` must
  not assume header content is plain text.
- Figures appear both as `<figure class="img">` (via `.img`) and bare
  captioned images (`.imgpp`).

Treat these classes as the contract to design filters against; don't assume
a "clean" EPUB — check a *real* file in `ebooks/` occasionally too, since
`test.epub` is one sample and other books may use different
publisher/converter class names.

## French typographic conventions (required for final output)

The source material and target audience are French, so the rendered PDF
must follow standard French typography, not the pandoc/LaTeX English
defaults:

- **Guillemets**, not straight/curly double quotes, for dialogue and
  quotations: `« texte »` (note the non-breaking space *inside* the
  guillemets). Achieve this with `lang: fr-FR` + `csquotes: true` in the
  template/metadata so pandoc emits `\enquote{}`, which polyglossia's French
  module resolves to guillemets with correct spacing automatically — verify
  visually rather than assuming, since template overrides can silently
  disable it.
- **Non-breaking (thin) space before `; : ! ?`** — this is one of the
  defining rules of French typography (`Il fait beau !` not `Il fait
  beau!`). `polyglossia`'s `french` module (loaded automatically for
  `lang: fr`/`fr-FR` under lualatex) handles this natively without needing
  babel shorthands (`<<`/`>>` etc.) — again, confirm in rendered output; if
  it's not applied, a Lua filter walking `Str`/`Inlines` to insert `\,`/`~`
  before those characters is the fallback.
- **Em dash for dialogue**, not a hyphen: French novels use `—` (tiret
  cadratin) to open a line of dialogue, e.g. `— Tiens, commenta le gamin`
  (visible already in `test.md`). Pandoc's `smart` extension converts `--`/
  `---` to en/em dashes on read from Markdown, but EPUB→Pandoc reading of
  existing `—` characters should pass through unchanged — just don't let a
  filter normalize dashes to `-` or `--`.
- **Capitalized letters keep their accents** (`École`, not `Ecole`) — don't
  add any uppercase-normalization filter that strips diacritics.
- Use `polyglossia`'s French hyphenation patterns (implied by `lang: fr` on
  lualatex) rather than leaving hyphenation on the English default —
  critical at this tablet's narrow column width where justified text without
  correct hyphenation will look bad or overflow.

## Workflow notes

- Iterate against `test.epub` first; `ebooks/` files are large real novels —
  use them for final validation passes, not tight edit-render loops.
- `test.log` is a disposable debug artifact regenerated by running the
  `dev/simple.lua` filter against `test.epub` — don't hand-edit it, and avoid
  dumping it into context wholesale (grep for the node type you care about).
- Keep `.luacheckrc`'s `globals` list in sync with any new filter entry
  points (element handlers) added across `.lua` files, and run `luacheck`
  before considering a filter done.
