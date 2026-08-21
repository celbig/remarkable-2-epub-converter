#!/usr/bin/env fish
#
# convert.fish — EPUB -> PDF for the reMarkable 2.
#
#   ./convert.fish book.epub
#   ./convert.fish ebooks/*.epub
#   ./convert.fish -m 8mm -s 18pt ebooks/*.epub
#   ./convert.fish -l en "ebooks/An English Novel.epub"
#
# Every source filename in this project contains spaces, and several contain
# braces and brackets too, so every path here stays quoted.
#
# See convert.sh for the bash version; keep the two in sync.

set -l here (cd (dirname (status --current-filename)); and pwd)

set -l outdir "$here/output"
set -l margin ""
set -l fontsize ""
set -l lang ""
set -l keeplog ""
set -l sources
# -V/-M pairs, passed straight through to pandoc.
set -l passthrough

function __convert_usage
    echo "Usage: convert.fish [options] FILE.epub [FILE.epub ...]"
    echo
    echo "  -o DIR    output directory (default: ./output)"
    echo "  -m DIM    page margin, e.g. 8mm      (default: template's 10mm)"
    echo "  -s SIZE   base font size, e.g. 18pt  (default: template's 16pt)"
    echo "  -l LANG   language of the book       (default: fr)"
    echo "  -V K=V    set a template variable    (repeatable)"
    echo "  -M K=V    set a document setting     (repeatable)"
    echo "  -k        keep the build log even when the conversion succeeds"
    echo "  -h        this help"
    echo
    echo "-l picks the hyphenation, the spacing before ; : ! ?, the quotation"
    echo "marks and the publisher's front matter the filter knows how to drop."
    echo "It is never guessed from the EPUB, whose declared language is"
    echo "routinely wrong. Accepted:"
    echo
    echo "  fr fr-FR fr-CA        en en-US en-GB        de es it nl pt"
    echo
    echo "Only French and English have their punctuation and front-matter rules"
    echo "tuned; the others are typeset in their own language and read with the"
    echo "French-free defaults. Any other polyglossia language works the long"
    echo "way round: -V mainlanguage=<gloss> -V lang=<bcp47> -M lang=<code>."
    echo
    echo "-V reaches template.latex, -M reaches filters/cleanup.lua. Settings"
    echo "worth knowing about:"
    echo
    echo "  -M frontmatter-trim=false   keep the publisher's copyright and"
    echo "                              catalogue pages instead of dropping them"
    echo "  -M small-image-max=N        pixel size below which an image counts"
    echo "                              as a decoration and is drawn at its"
    echo "                              real size (200)"
    echo "  -V dropcap-lines=N          how many lines a drop cap spans (2)"
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
        case -l
            set i (math $i + 1)
            set lang $argv[$i]
        case -V
            set i (math $i + 1)
            set -a passthrough -V $argv[$i]
        case -M
            set i (math $i + 1)
            set -a passthrough -M $argv[$i]
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

# The -l table. Three things come out of it and they have to agree: the
# polyglossia gloss that carries the hyphenation patterns and the spacing rules
# (-V mainlanguage), the BCP-47 tag that goes into the PDF's own metadata
# (-V lang), and the code the Lua filter matches its rule table against
# (-M lang). Nothing here is read from the EPUB — its declared language is
# routinely wrong, see the note in template.latex.
set -l lang_gloss ""
set -l lang_options ""
set -l lang_tag ""
set -l lang_code ""
if test -n "$lang"
    switch (string lower -- $lang)
        case fr fr-fr french
            set lang_gloss french
            set lang_tag fr-FR
            set lang_code fr
        case fr-ca canadian
            set lang_gloss french
            set lang_options variant=canadian
            set lang_tag fr-CA
            set lang_code fr
        case en en-us english
            set lang_gloss english
            set lang_tag en-US
            set lang_code en
        case en-gb en-uk british
            set lang_gloss english
            set lang_options variant=british
            set lang_tag en-GB
            set lang_code en
        case de german
            set lang_gloss german
            set lang_tag de-DE
            set lang_code de
        case es spanish
            set lang_gloss spanish
            set lang_tag es-ES
            set lang_code es
        case it italian
            set lang_gloss italian
            set lang_tag it-IT
            set lang_code it
        case nl dutch
            set lang_gloss dutch
            set lang_tag nl-NL
            set lang_code nl
        case pt portuguese
            set lang_gloss portuguese
            set lang_tag pt-PT
            set lang_code pt
        case '*'
            echo "convert.fish: unknown language '$lang'" >&2
            echo "  known: fr fr-FR fr-CA  en en-US en-GB  de es it nl pt" >&2
            echo "  any other polyglossia language: -V mainlanguage=<gloss> -V lang=<bcp47> -M lang=<code>" >&2
            exit 2
    end
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
# Nothing is passed without -l, so the default run is byte-for-byte the command
# it was before the option existed: the template and the filter default to
# French on their own.
if test -n "$lang_gloss"
    set -a common_args -V "mainlanguage=$lang_gloss" -V "lang=$lang_tag" -M "lang=$lang_code"
    test -n "$lang_options"; and set -a common_args -V "mainlanguage-options=$lang_options"
end
# Last, so an explicit -V/-M overrides what -m/-s just set.
set -a common_args $passthrough

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
