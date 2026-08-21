#!/usr/bin/env bash
#
# convert.sh — EPUB -> PDF for the reMarkable 2.
#
#   ./convert.sh book.epub
#   ./convert.sh ebooks/*.epub
#   ./convert.sh -m 8mm -s 18pt ebooks/*.epub
#   ./convert.sh -l en "ebooks/An English Novel.epub"
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
lang=""
keeplog=""
# -V/-M pairs, passed straight through to pandoc.
passthrough=()

usage() {
    cat <<'EOF'
Usage: convert.sh [options] FILE.epub [FILE.epub ...]

  -o DIR    output directory (default: ./output)
  -m DIM    page margin, e.g. 8mm      (default: template's 10mm)
  -s SIZE   base font size, e.g. 18pt  (default: template's 16pt)
  -l LANG   language of the book       (default: fr)
  -V K=V    set a template variable    (repeatable)
  -M K=V    set a document setting     (repeatable)
  -k        keep the build log even when the conversion succeeds
  -h        this help

-l picks the hyphenation, the spacing before ; : ! ?, the quotation marks and
the publisher's front matter the filter knows how to drop. It is never guessed
from the EPUB, whose declared language is routinely wrong. Accepted:

  fr fr-FR fr-CA        en en-US en-GB        de es it nl pt

Only French and English have their punctuation and front-matter rules tuned;
the others are typeset in their own language and read with the French-free
defaults. Any other polyglossia language works the long way round:
-V mainlanguage=<gloss> -V lang=<bcp47> -M lang=<code>.

-V reaches template.latex, -M reaches filters/cleanup.lua. Settings worth
knowing about:

  -M frontmatter-trim=false   keep the publisher's copyright and catalogue
                              pages instead of dropping them
  -M small-image-max=N        pixel size below which an image counts as a
                              decoration and is drawn at its real size (200)
  -V dropcap-lines=N          how many lines a drop cap spans (2)

Writes DIR/<name>.pdf. The build log is a conversion artefact and is deleted
once a book converts cleanly; it is always kept when one fails.
EOF
}

while getopts ':o:m:s:l:V:M:kh' opt; do
    case "$opt" in
        o) outdir="$OPTARG" ;;
        m) margin="$OPTARG" ;;
        s) fontsize="$OPTARG" ;;
        l) lang="$OPTARG" ;;
        V) passthrough+=(-V "$OPTARG") ;;
        M) passthrough+=(-M "$OPTARG") ;;
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

# The -l table. Three things come out of it and they have to agree: the
# polyglossia gloss that carries the hyphenation patterns and the spacing rules
# (-V mainlanguage), the BCP-47 tag that goes into the PDF's own metadata
# (-V lang), and the code the Lua filter matches its rule table against
# (-M lang). Nothing here is read from the EPUB — its declared language is
# routinely wrong, see the note in template.latex.
lang_gloss=""
lang_options=""
lang_tag=""
lang_code=""
if [ -n "$lang" ]; then
    case "$(printf '%s' "$lang" | tr '[:upper:]' '[:lower:]')" in
        fr|fr-fr|french)     lang_gloss=french;     lang_tag=fr-FR; lang_code=fr ;;
        fr-ca|canadian)      lang_gloss=french;     lang_tag=fr-CA; lang_code=fr
                             lang_options=variant=canadian ;;
        en|en-us|english)    lang_gloss=english;    lang_tag=en-US; lang_code=en ;;
        en-gb|en-uk|british) lang_gloss=english;    lang_tag=en-GB; lang_code=en
                             lang_options=variant=british ;;
        de|german)           lang_gloss=german;     lang_tag=de-DE; lang_code=de ;;
        es|spanish)          lang_gloss=spanish;    lang_tag=es-ES; lang_code=es ;;
        it|italian)          lang_gloss=italian;    lang_tag=it-IT; lang_code=it ;;
        nl|dutch)            lang_gloss=dutch;      lang_tag=nl-NL; lang_code=nl ;;
        pt|portuguese)       lang_gloss=portuguese; lang_tag=pt-PT; lang_code=pt ;;
        *)
            echo "convert.sh: unknown language '$lang'" >&2
            echo "  known: fr fr-FR fr-CA  en en-US en-GB  de es it nl pt" >&2
            echo "  any other polyglossia language: -V mainlanguage=<gloss> -V lang=<bcp47> -M lang=<code>" >&2
            exit 2
            ;;
    esac
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
# Nothing is passed without -l, so the default run is byte-for-byte the command
# it was before the option existed: the template and the filter default to
# French on their own.
if [ -n "$lang_gloss" ]; then
    common_args+=(-V "mainlanguage=$lang_gloss" -V "lang=$lang_tag" -M "lang=$lang_code")
    [ -n "$lang_options" ] && common_args+=(-V "mainlanguage-options=$lang_options")
fi
# Last, so an explicit -V/-M overrides what -m/-s just set.
# ${a[@]+…} because expanding an empty array trips `set -u` on older bash.
common_args+=(${passthrough[@]+"${passthrough[@]}"})

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
