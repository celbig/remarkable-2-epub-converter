#!/usr/bin/env python3
"""Match each PDF in output/ to the EPUB that produced it and dump its metadata.

    python3 .claude/skills/rename-book-pdfs/scripts/epub_meta.py [-e ebooks] [-o output]

Prints JSON to stdout:

    {"matched": [{"pdf": ..., "epub": ..., "title": ..., "series": ...,
                  "index": ..., "proposed": ...}],
     "unmatched": [...], "ambiguous": [{"pdf": ..., "epubs": [...]}]}

`proposed` is the raw-metadata name only. It is a starting point, not an
answer: the caller still has to apply corrections.md, fix accents/case, drop
subtitles and check the series against the web.
"""

import argparse
import glob
import html
import json
import os
import re
import sys
import unicodedata
import zipfile


def ascii_key(s):
    """Accent-, case- and punctuation-insensitive key.

    The library lives on an NTFS mount where the same name can arrive as NFC
    or NFD, so every comparison in this skill goes through here rather than
    comparing filenames directly.
    """
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r"[^0-9a-zA-Z]+", " ", s.lower())
    return s.strip()


def read_opf(path):
    """Return the flattened .opf text of an EPUB, or None."""
    try:
        with zipfile.ZipFile(path) as z:
            names = [n for n in z.namelist() if n.lower().endswith(".opf")]
            if not names:
                return None
            raw = z.read(names[0]).decode("utf-8", "replace")
    except (zipfile.BadZipFile, OSError) as exc:
        print(f"warning: cannot read {path}: {exc}", file=sys.stderr)
        return None
    # Tags in these files are routinely split across newlines, so flatten
    # first and let the patterns below stay single-line.
    return re.sub(r"\s+", " ", raw)


def unent(s):
    """Decode XML entities, including the numeric ones html.unescape misses."""
    if s is None:
        return None
    s = re.sub(r"&#x([0-9a-fA-F]+);", lambda m: chr(int(m.group(1), 16)), s)
    s = re.sub(r"&#(\d+);", lambda m: chr(int(m.group(1))), s)
    return html.unescape(s).strip()


def metadata(path):
    flat = read_opf(path)
    if flat is None:
        return None

    def find(*patterns):
        for pat in patterns:
            m = re.search(pat, flat)
            if m and m.group(1).strip():
                return unent(m.group(1))
        return None

    title = find(r"<dc:title[^>]*>(.*?)</dc:title>")
    series = find(
        r'<meta[^>]*name="calibre:series"[^>]*content="([^"]*)"',
        r'<meta[^>]*content="([^"]*)"[^>]*name="calibre:series"[^>]*>',
        r'<meta[^>]*property="belongs-to-collection"[^>]*>(.*?)</meta>',
    )
    index = find(
        r'<meta[^>]*name="calibre:series_index"[^>]*content="([^"]*)"',
        r'<meta[^>]*content="([^"]*)"[^>]*name="calibre:series_index"[^>]*>',
        r'<meta[^>]*property="group-position"[^>]*>(.*?)</meta>',
    )
    return {"title": title, "series": series, "index": tidy_index(index)}


def tidy_index(index):
    """calibre stores the series index as a float: 5.0 -> 5."""
    if not index:
        return None
    try:
        f = float(index)
    except ValueError:
        return index.strip()
    return str(int(f)) if f == int(f) else str(f)


def proposed_name(meta):
    title = meta.get("title") or ""
    series, index = meta.get("series"), meta.get("index")
    if series and index:
        return f"[{series} {index}] {title}.pdf"
    return f"{title}.pdf"


def match(pdf_stem, epubs):
    """EPUBs that could have produced this PDF, best evidence first.

    Substring matching in both directions, never whole-filename equality: the
    PDF may already carry its final `[Series N] Title` name while the EPUB
    still carries the one it was downloaded under.
    """
    key = ascii_key(pdf_stem)
    hits = []
    for epub, meta in epubs:
        stem = ascii_key(os.path.splitext(os.path.basename(epub))[0])
        if stem and (stem in key or key in stem):
            hits.append((0, epub, meta))
            continue
        title = meta.get("title") if meta else None
        if not title:
            continue
        # Subtitles are dropped from the final name, so match on the part
        # before the colon too ("<Title> : une histoire de …").
        for cand in {ascii_key(title), ascii_key(re.split(r"[:–—]", title)[0])}:
            if cand and cand in key:
                hits.append((1, epub, meta))
                break
    hits.sort(key=lambda h: h[0])
    return hits


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-e", "--ebooks", default="ebooks")
    ap.add_argument("-o", "--output", default="output")
    args = ap.parse_args()

    epubs = []
    for path in sorted(glob.glob(os.path.join(args.ebooks, "*.epub"))):
        epubs.append((path, metadata(path) or {}))

    matched, unmatched, ambiguous = [], [], []
    for pdf in sorted(glob.glob(os.path.join(args.output, "*.pdf"))):
        stem = os.path.splitext(os.path.basename(pdf))[0]
        hits = match(stem, epubs)
        best = [h for h in hits if h[0] == hits[0][0]] if hits else []
        if not best:
            unmatched.append(pdf)
        elif len(best) > 1:
            ambiguous.append({"pdf": pdf, "epubs": [h[1] for h in best]})
        else:
            _, epub, meta = best[0]
            matched.append({
                "pdf": pdf,
                "epub": epub,
                "title": meta.get("title"),
                "series": meta.get("series"),
                "index": meta.get("index"),
                "proposed": proposed_name(meta),
            })

    json.dump(
        {"matched": matched, "unmatched": unmatched, "ambiguous": ambiguous},
        sys.stdout,
        ensure_ascii=False,
        indent=2,
    )
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
