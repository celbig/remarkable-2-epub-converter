#!/usr/bin/env bash
#
# convert.sh — EPUB -> PDF for the reMarkable 2.
#
#   ./convert.sh book.epub
#   ./convert.sh ebooks/*.epub
#   ./convert.sh -m 8mm -s 18pt ebooks/*.epub
#
# Every source filename in this project contains spaces, and several contain
# braces and brackets too, so every path here stays quoted.
#
# See convert.fish for the fish version; keep the two in sync.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

outdir="$here/output"
margin=""
fontsize=""
keeplog=""

usage() {
    cat <<'EOF'
Usage: convert.sh [options] FILE.epub [FILE.epub ...]

  -o DIR    output directory (default: ./output)
  -m DIM    page margin, e.g. 8mm      (default: template's 10mm)
  -s SIZE   base font size, e.g. 18pt  (default: template's 16pt)
  -k        keep the build log even when the conversion succeeds
  -h        this help

Writes DIR/<name>.pdf. The build log is a conversion artefact and is deleted
once a book converts cleanly; it is always kept when one fails.
EOF
}

while getopts ':o:m:s:kh' opt; do
    case "$opt" in
        o) outdir="$OPTARG" ;;
        m) margin="$OPTARG" ;;
        s) fontsize="$OPTARG" ;;
        k) keeplog=1 ;;
        h) usage; exit 0 ;;
        :) echo "convert.sh: -$OPTARG needs an argument" >&2; exit 2 ;;
        \?) echo "convert.sh: unknown option -$OPTARG" >&2; usage >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

if [ "$#" -eq 0 ]; then
    usage >&2
    exit 2
fi

for tool in pandoc lualatex; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "convert.sh: $tool not found in PATH" >&2
        exit 1
    }
done

mkdir -p "$outdir"

# documentclass is not redundant with the template's hardcoded \documentclass:
# the LaTeX *writer* reads it before the template is applied, to decide whether
# a level-1 heading becomes \chapter or \section. Drop it and the chapters
# collapse into sections and the PDF outline goes with them.
common_args=(
    --template="$here/template.latex"
    --lua-filter="$here/filters/cleanup.lua"
    --pdf-engine=lualatex
    -V documentclass=scrbook
)
[ -n "$margin" ] && common_args+=(-V "margin=$margin")
[ -n "$fontsize" ] && common_args+=(-V "fontsize=$fontsize")

failed=0

for src in "$@"; do
    if [ ! -f "$src" ]; then
        echo "  ! not found: $src" >&2
        failed=$((failed + 1))
        continue
    fi

    base="$(basename "$src")"
    base="${base%.epub}"
    pdf="$outdir/$base.pdf"
    log="$outdir/$base.log"

    # Images live inside the zip, so they have to be unpacked somewhere real
    # before lualatex can \includegraphics them. Per-book, so that two books
    # using the same image names cannot overwrite each other.
    media="$(mktemp -d)"
    trap 'rm -rf "$media"' EXIT

    printf '  … %s\n' "$base"

    if pandoc "$src" "${common_args[@]}" \
        --extract-media="$media" \
        -o "$pdf" >"$log" 2>&1
    then
        pages="?"
        command -v pdfinfo >/dev/null 2>&1 &&
            pages="$(pdfinfo "$pdf" 2>/dev/null | awk '/^Pages/{print $2}')"
        # Counted before the log goes away.
        warnings="$(grep -c '^\[WARNING\]' "$log" || true)"
        if [ -n "$keeplog" ]; then
            printf '  ✓ %s — %s pages, %s warnings (log kept)\n' "$base" "$pages" "$warnings"
        else
            rm -f "$log"
            printf '  ✓ %s — %s pages, %s warnings\n' "$base" "$pages" "$warnings"
        fi
    else
        printf '  ✗ %s — failed, see %s\n' "$base" "$log" >&2
        tail -n 15 "$log" >&2
        failed=$((failed + 1))
    fi

    rm -rf "$media"
    trap - EXIT
done

if [ "$failed" -gt 0 ]; then
    echo "convert.sh: $failed file(s) failed" >&2
    exit 1
fi
