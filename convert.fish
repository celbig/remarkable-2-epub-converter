#!/usr/bin/env fish
#
# convert.fish — EPUB -> PDF for the reMarkable 2.
#
#   ./convert.fish book.epub
#   ./convert.fish ebooks/*.epub
#   ./convert.fish -m 8mm -s 18pt ebooks/*.epub
#
# Every source filename in this project contains spaces, and several contain
# braces and brackets too, so every path here stays quoted.
#
# See convert.sh for the bash version; keep the two in sync.

set -l here (cd (dirname (status --current-filename)); and pwd)

set -l outdir "$here/output"
set -l margin ""
set -l fontsize ""
set -l keeplog ""
set -l sources

function __convert_usage
    echo "Usage: convert.fish [options] FILE.epub [FILE.epub ...]"
    echo
    echo "  -o DIR    output directory (default: ./output)"
    echo "  -m DIM    page margin, e.g. 8mm      (default: template's 10mm)"
    echo "  -s SIZE   base font size, e.g. 18pt  (default: template's 16pt)"
    echo "  -k        keep the build log even when the conversion succeeds"
    echo "  -h        this help"
    echo
    echo "Writes DIR/<name>.pdf. The build log is a conversion artefact and is"
    echo "deleted once a book converts cleanly; it is always kept when one fails."
end

# Hand-rolled rather than argparse: the option list is tiny, and this keeps the
# script readable next to its bash twin.
set -l i 1
while test $i -le (count $argv)
    set -l arg $argv[$i]
    switch $arg
        case -o
            set i (math $i + 1)
            set outdir $argv[$i]
        case -m
            set i (math $i + 1)
            set margin $argv[$i]
        case -s
            set i (math $i + 1)
            set fontsize $argv[$i]
        case -k
            set keeplog 1
        case -h --help
            __convert_usage
            exit 0
        case '-*'
            echo "convert.fish: unknown option $arg" >&2
            __convert_usage >&2
            exit 2
        case '*'
            set -a sources $arg
    end
    set i (math $i + 1)
end

if test (count $sources) -eq 0
    __convert_usage >&2
    exit 2
end

for tool in pandoc lualatex
    if not command -q $tool
        echo "convert.fish: $tool not found in PATH" >&2
        exit 1
    end
end

mkdir -p "$outdir"

# documentclass is not redundant with the template's hardcoded \documentclass:
# the LaTeX *writer* reads it before the template is applied, to decide whether
# a level-1 heading becomes \chapter or \section. Drop it and the chapters
# collapse into sections and the PDF outline goes with them.
set -l common_args \
    --template="$here/template.latex" \
    --lua-filter="$here/filters/cleanup.lua" \
    --pdf-engine=lualatex \
    -V documentclass=scrbook
test -n "$margin"; and set -a common_args -V "margin=$margin"
test -n "$fontsize"; and set -a common_args -V "fontsize=$fontsize"

set -l failed 0

for src in $sources
    if not test -f "$src"
        echo "  ! not found: $src" >&2
        set failed (math $failed + 1)
        continue
    end

    set -l base (basename "$src" .epub)
    set -l pdf "$outdir/$base.pdf"
    set -l log "$outdir/$base.log"

    # Images live inside the zip, so they have to be unpacked somewhere real
    # before lualatex can \includegraphics them. Per-book, so that two books
    # using the same image names cannot overwrite each other.
    set -l media (mktemp -d)

    printf '  … %s\n' "$base"

    if pandoc "$src" $common_args --extract-media="$media" -o "$pdf" >"$log" 2>&1
        set -l pages "?"
        if command -q pdfinfo
            set pages (pdfinfo "$pdf" 2>/dev/null | awk '/^Pages/{print $2}')
        end
        # Counted before the log goes away.
        set -l warnings (grep -c '^\[WARNING\]' "$log"; or true)
        if test -n "$keeplog"
            printf '  ✓ %s — %s pages, %s warnings (log kept)\n' "$base" "$pages" "$warnings"
        else
            rm -f "$log"
            printf '  ✓ %s — %s pages, %s warnings\n' "$base" "$pages" "$warnings"
        end
    else
        printf '  ✗ %s — failed, see %s\n' "$base" "$log" >&2
        tail -n 15 "$log" >&2
        set failed (math $failed + 1)
    end

    rm -rf "$media"
end

if test $failed -gt 0
    echo "convert.fish: $failed file(s) failed" >&2
    exit 1
end
