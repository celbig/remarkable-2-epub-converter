--[[
filters/cleanup.lua — repair EPUB source artifacts before the LaTeX writer.

Four jobs, all of them repairs of the source rather than layout decisions (the
layout itself lives in template.latex, which this filter only calls into):

  1. Line wraps.  These EPUBs wrap their XHTML mid-sentence and pandoc turns
     every wrap into a SoftBreak that LaTeX renders as a space:
       Span[.lettrine]["W"], SoftBreak, Str "axillium"  ->  "W axillium"
       Emph[..."fois"],      SoftBreak, Str ","         ->  "une seule fois ,"
     The first case also becomes \dropcap{}{}, which pandoc has no concept of.

  2. Page images.  Covers and publisher title-page artwork get a page to
     themselves instead of sharing one with whatever follows.

  3. Front matter.  Everything before the first chapter is grouped by source
     file and laid out a page at a time: spacer paragraphs dropped, publisher
     boilerplate dropped, short units centred, long ones left to flow.

  4. Image size.  Every image is measured and the decorations — table glyphs,
     scanner marks, fleurons — are given a real size, so the template's
     fit-to-the-text-block rule applies only to artwork that wants it.

Scope note for (1): only SoftBreak is touched, never Space. Measured on
test.epub, SoftBreak precedes . 295x  , 172x  ’ 4x  ) 3x  … 2x, whereas a real
Space only ever precedes ':' (2x) — which is correct French and must survive.

Edition-specific: the 2019 "Tome 5" edition has 4 SoftBreaks total and needs
neither fix, while test.epub and the 2017 edition have ~470 each. Validating
against the 2019 file alone proves nothing.

Returned as a list of two filters rather than as top-level globals, because the
settings below come from document metadata and pandoc runs Meta *after* every
block and inline handler. A second pass is the only way for an Image handler to
see a -M flag at all.
]]

--------------------------------------------------------------------------
-- Settings.  Every one is overridable with -M <key>=<value>.
--------------------------------------------------------------------------
local settings = {
  -- Longest side, in pixels, at or below which an image is a decoration
  -- rather than artwork. The corpus splits cleanly: nothing between 189 px
  -- (a publisher's mark) and 300 px (a chapter banner).
  ['small-image-max'] = 200,

  -- The reMarkable 2 panel. Used to turn a decoration's pixel count into a
  -- real size, since the JFIF density in these files cannot be trusted.
  ['device-dpi'] = 226,

  -- A decoration sitting in a line of text is sized against the type, not
  -- against its own pixel count.
  ['inline-image-height'] = '1.1em',

  -- Drop the publisher's legal and commercial pages, and the marks left by
  -- whoever digitised the book. -M frontmatter-trim=false keeps everything.
  ['frontmatter-trim'] = true,

  -- A front-matter unit estimated at more than this many lines is too tall to
  -- centre on one page. ~27 lines fit at the default 16 pt.
  ['front-page-max-lines'] = 18,

  -- Used by that estimate. EB Garamond 16 pt over a 137 mm measure runs to
  -- about 62 characters; 55 errs towards calling a unit too tall, which is
  -- the harmless direction.
  ['chars-per-line'] = 55,
}

local function read_settings(meta)
  for key, default in pairs(settings) do
    local value = meta[key]
    if value ~= nil then
      local text = pandoc.utils.stringify(value)
      if type(default) == 'boolean' then
        settings[key] = text ~= 'false'
      elseif type(default) == 'number' then
        settings[key] = tonumber(text) or default
      else
        settings[key] = text
      end
    end
  end
end

--- Report something the filter threw away.
-- The [WARNING] prefix is the one convert.sh and convert.fish already count,
-- so a lossy step shows up in the conversion summary rather than happening
-- silently.
local function warn(what, sample)
  local text = sample:gsub('%s+', ' '):gsub('^ ', '')
  if pandoc.text.len(text) > 60 then
    text = pandoc.text.sub(text, 1, 60) .. '…'
  end
  io.stderr:write(('[WARNING] cleanup.lua: %s: %s\n'):format(what, text))
end

--------------------------------------------------------------------------
-- Line-wrap repair
--------------------------------------------------------------------------

-- Punctuation that must never carry a space before it in French.
-- ; : ! ? and » are deliberately absent: those *do* take a space in French,
-- and polyglossia normalises whatever precedes them into the correct thin or
-- full space, so leaving their SoftBreaks alone is what keeps them right.
local TIGHT = {
  ['.'] = true,
  [','] = true,
  [')'] = true,
  ['…'] = true,
  ['’'] = true,
}

-- Initials that are themselves complete French words, so the gap after them is
-- a real word break rather than a line wrap.
--
-- The source cannot tell these apart: "À</span>\n l’heure" and "I</span>\n l
-- s’agit" are byte-for-byte the same shape, yet the first must stay "À
-- l’heure" and the second must close up into "Il s’agit". Only the letter
-- distinguishes them.
--
-- 'A' is deliberately absent: as a drop cap it far more often opens "Après",
-- "Alors", "Aucun" than it stands as the bare word "A", so joining is the
-- better bet. Accented 'À' is the opposite — it is nearly always the
-- preposition.
local STANDALONE_WORD = { ['À'] = true, ['Y'] = true, ['Ô'] = true }

local function first_char(s)
  return pandoc.text.sub(s, 1, 1)
end

local function is_lettrine(el)
  return el.t == 'Span' and el.classes:includes('lettrine')
end

local function is_break(el)
  return el.t == 'SoftBreak' or el.t == 'Space' or el.t == 'LineBreak'
end

-- Page-break markers and link anchors stringify to nothing. They sit between
-- the drop cap and its word often enough to matter, so they are stepped over
-- rather than treated as the end of the word.
local function is_invisible(el)
  return pandoc.utils.stringify(el) == ''
end

--- Build the \dropcap{L}{etter} call.
-- The letter and tail go through as real inline elements, not interpolated
-- into the raw string, so the LaTeX writer still escapes them.
local function dropcap(letter, tail)
  if not FORMAT:match('latex') then
    return pandoc.List({ pandoc.Str(letter) }) .. tail
  end
  local out = pandoc.List({
    pandoc.RawInline('latex', '\\dropcap{'),
    pandoc.Str(letter),
    pandoc.RawInline('latex', '}{'),
  })
  out:extend(tail)
  out:insert(pandoc.RawInline('latex', '}'))
  return out
end

--------------------------------------------------------------------------
-- Image measurement
--------------------------------------------------------------------------

-- Marks an image the template's fit-to-the-text-block rule must not touch.
-- Image classes are ignored by the LaTeX writer, so this costs nothing in the
-- output and lets the block handlers below recognise their own work.
local SMALL_CLASS = 'eb-small'

local function is_small(img)
  return img.classes:includes(SMALL_CLASS)
end

local function be16(d, i)
  return d:byte(i) * 256 + d:byte(i + 1)
end

-- pandoc.image, which would do all of this, only arrived in pandoc 3.1.13;
-- this project is pinned to 3.1.3. Parsing the three formats an EPUB can hold
-- is a couple of dozen lines, so read the headers directly.
local function jpeg_size(d)
  local i = 3
  while i + 9 <= #d do
    if d:byte(i) ~= 0xFF then
      return nil
    end
    local marker = d:byte(i + 1)
    if marker == 0x01 or (marker >= 0xD0 and marker <= 0xD9) then
      i = i + 2 -- standalone marker, no length field
    elseif marker >= 0xC0 and marker <= 0xCF
       and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
      -- SOF frame header: height then width, both 16-bit big-endian.
      -- C4/C8/CC fall in the same range but are Huffman/arithmetic tables.
      return be16(d, i + 7), be16(d, i + 5)
    else
      i = i + 2 + be16(d, i + 2)
    end
  end
end

local function png_size(d)
  local function be32(o)
    return ((d:byte(o) * 256 + d:byte(o + 1)) * 256 + d:byte(o + 2)) * 256
      + d:byte(o + 3)
  end
  return be32(17), be32(21) -- IHDR, immediately after the signature
end

local function gif_size(d)
  return d:byte(7) + d:byte(8) * 256, d:byte(9) + d:byte(10) * 256
end

local function pixel_size(data)
  if #data < 24 then
    return nil
  end
  if data:sub(1, 2) == '\255\216' then
    return jpeg_size(data)
  end
  if data:sub(1, 8) == '\137PNG\r\n\26\n' then
    return png_size(data)
  end
  if data:sub(1, 3) == 'GIF' then
    return gif_size(data)
  end
end

-- A single book reaches for the same ornament up to ninety times and
-- mediabag.lookup copies the whole file on every call, so measure once.
local size_cache = {}

local function image_pixels(src)
  local cached = size_cache[src]
  if cached ~= nil then
    if cached == false then
      return nil
    end
    return cached[1], cached[2]
  end
  local _, data = pandoc.mediabag.lookup(src)
  local w, h
  if data then
    w, h = pixel_size(data)
  end
  size_cache[src] = (w and h) and { w, h } or false
  return w, h
end

--------------------------------------------------------------------------
-- Page images
--------------------------------------------------------------------------

-- Image sources that identify a cover or title page. Matched against the
-- lowercased src, plus the EPUB 3 role=doc-cover attribute.
local COVER_HINTS = { 'cover', 'couverture', 'pagetitre', 'titlepage', 'titre' }

local function looks_like_cover(img)
  if img.attributes['role'] == 'doc-cover' then
    return true
  end
  local src = img.src:lower()
  for _, hint in ipairs(COVER_HINTS) do
    if src:find(hint, 1, true) then
      return true
    end
  end
  return false
end

--- Flag books that already carry their own title page as artwork.
--
-- Every one of these EPUBs opens with the publisher's cover and title-page
-- images, which render as real pages. Pandoc's \maketitle then adds a second,
-- plain title page in front of them, so the book opens on a typeset title
-- followed immediately by the same title as art. The template skips \maketitle
-- when this flag is set.
--
-- An explicit -M has-cover-image=... always wins, so the title page can be
-- forced back on for a book whose artwork is missing or broken.
--
-- Recorded as a flag rather than recomputed in Pandoc(): pandoc runs block
-- handlers first, so by the time Pandoc() sees the document every page image
-- has already become a \pageimage raw block, and a walk for Image elements
-- would find nothing at all.
local saw_page_image = false

--- Is this an image that deserves a page to itself?
-- The cover and the publisher's title-page artwork, which EPUBs mark either by
-- filename or with the "page image" classes. Never a decoration: one book
-- names a 66 px table glyph in a way that matches a cover hint.
local function is_page_image(img)
  if is_small(img) then
    return false
  end
  return looks_like_cover(img)
      or img.classes:includes('imgpp')
      or img.classes:includes('imagepp')
end

--- If a block's whole visible content is one page image, return that image.
local function sole_page_image(block)
  local found = {}
  block:walk({
    Image = function(img)
      found[#found + 1] = img
    end,
  })
  if #found ~= 1 or not is_page_image(found[1]) then
    return nil
  end
  return found[1]
end

--- Give a page image the page to itself, centred vertically.
--
-- Without the page break the title-page artwork shares its page with whatever
-- follows — in these books the dedication, which ends up crammed under the
-- picture instead of standing on its own page. Any anchor span wrapped around
-- the image is dropped with the block, as with figures.
--
-- \pageimage lives in template.latex: the page-breaking and centring is a
-- layout decision, and keeping it there means it can be retuned without
-- touching this filter. It is emitted as one raw block rather than as raw
-- blocks around a Plain, because pandoc separates blocks with blank lines,
-- which would end the paragraph inside the macro argument.
-- Page images already placed, keyed by source. The cover is routinely present
-- twice — once as a bare Image and again inside the cover document — and
-- without this the book opens on the same picture two pages running.
local emitted_page_images = {}

local function on_its_own_page(img)
  saw_page_image = true
  if emitted_page_images[img.src] then
    return pandoc.List() -- a repeat of a picture already given its own page
  end
  emitted_page_images[img.src] = true
  return pandoc.List({
    pandoc.RawBlock('latex', '\\pageimage{' .. img.src .. '}'),
  })
end

--------------------------------------------------------------------------
-- Front matter
--------------------------------------------------------------------------

--- Does this block, or anything inside it, open a chapter?
-- Chapters are not top-level Headers in these EPUBs: each one is a Div (.chap,
-- .div_prol, .part …) with the Header nested inside, so the end of the front
-- matter has to be found by looking into the blocks rather than at them.
local function opens_a_chapter(block)
  if block.t == 'Header' then
    return true
  end
  local found = false
  block:walk({
    Header = function()
      found = true
    end,
  })
  return found
end

-- Characters that take up room but show nothing. Lua's %s is ASCII-only, so a
-- paragraph holding just U+00A0 reads as non-empty and would be given a page
-- of its own — one EPUB opens with 28 such spacer paragraphs in a row.
local BLANKS = {
  '\194\160', -- U+00A0 no-break space
  '\226\128\139', -- U+200B zero-width space
  '\226\128\137', -- U+2009 thin space
  '\226\128\175', -- U+202F narrow no-break space
}

local function visible(str)
  local out = (str:gsub('%s+', ''))
  for _, blank in ipairs(BLANKS) do
    out = (out:gsub(blank, ''))
  end
  return out
end

--- Is this block one of pandoc's EPUB spine-item anchors?
-- Pandoc opens each file of the EPUB with an empty Span carrying the source
-- filename as its id. They are invisible in the output, but they are the only
-- record of where one front-matter page ended and the next began.
local function is_file_anchor(block)
  if block.t ~= 'Para' and block.t ~= 'Plain' then
    return false
  end
  if #block.content ~= 1 then
    return false
  end
  local span = block.content[1]
  return span.t == 'Span' and span.identifier ~= '' and #span.content == 0
end

local function has_image(block)
  local found = false
  block:walk({
    Image = function()
      found = true
    end,
  })
  return found
end

--- A block that occupies vertical space and shows nothing.
-- Word-derived EPUBs pad their front matter with rows of <p>&nbsp;</p> — 33 of
-- them around five useful lines on one title page — and Calibre leaves a
-- <br clear="all"> page-break marker at the head of every file. Both arrive as
-- real blocks and both push the page they are on past its own bottom.
local function is_blank_block(block)
  if block.t ~= 'Para' and block.t ~= 'Plain' and block.t ~= 'Div' then
    return false
  end
  if has_image(block) then
    return false
  end
  return visible(pandoc.utils.stringify(block)) == ''
end

--- Strip the marks that are not part of the book.
-- Publisher logos and, in this corpus more often, the stamp of whoever
-- digitised the file: a 164 x 170 px "TEAM AlexandriZ" roundel that the
-- template used to blow up to a page of its own in every Hobb volume.
local function drop_publisher_marks(blocks)
  local out = pandoc.List()
  for _, block in ipairs(blocks) do
    local dropped = pandoc.List()
    local stripped = block:walk({
      Image = function(img)
        if is_small(img) then
          dropped:insert(img.src)
          return {}
        end
      end,
    })
    if #dropped > 0 then
      warn('front matter mark dropped', table.concat(dropped, ' '))
    end
    out:insert(stripped)
  end
  return out
end

--- Remove \begin{center} … \end{center} pairs left empty by the line above.
local function drop_empty_centers(blocks)
  local out = pandoc.List()
  local i = 1
  while i <= #blocks do
    local here, next_one = blocks[i], blocks[i + 1]
    if here.t == 'RawBlock' and here.text == '\\begin{center}'
       and next_one and next_one.t == 'RawBlock'
       and next_one.text == '\\end{center}' then
      i = i + 2
    else
      out:insert(here)
      i = i + 1
    end
  end
  return out
end

local function tidy(blocks)
  return drop_empty_centers(blocks:filter(function(block)
    return not is_blank_block(block)
  end))
end

--- Clear the padding out of a front-matter unit, at every depth.
--
-- Depth is the whole difficulty. One publisher emits a Para per line straight
-- into the document, another wraps the identical page in a single Div — and
-- that Div is where Hobb keeps its thirty spacer paragraphs, so a top-level
-- pass leaves the page exactly as overstuffed as it found it. walk() runs
-- innermost-first, so a Div emptied by the pass is then blank itself and the
-- outer call catches it.
local function tidy_front_blocks(blocks)
  local out = pandoc.List()
  for _, block in ipairs(blocks) do
    out:insert(block:walk({ Blocks = tidy }))
  end
  return tidy(out)
end

-- Front-matter pages that exist for legal and commercial reasons and carry
-- nothing to read. Publishers who mark them up semantically say so in a class;
-- everyone else is recognised by what is written on the page.
local BOILERPLATE_CLASSES = {
  cop = true,
  copyright = true,
  pagecopyright = true,
  titrevo = true,
  ours = true, -- the French printing trade's name for the colophon block
  mentionslegales = true,
}

-- Lua patterns, not plain substrings. The short ones need their word
-- boundaries: a bare "ean" matched "Jean Marchand" and threw away a
-- twelve-page dramatis personae.
local BOILERPLATE_MARKERS = {
  'isbn',
  '%f[%a]ean%f[%A]',
  'copyright',
  '©',
  'dépôt légal',
  'tous droits réservés',
  'titre original',
  'du même auteur',
  "achevé d'imprimer",
  'propriété intellectuelle',
  'loi n° 57%-298',
  'https?://',
  'www%.',
  'e%-mail',
}

local function is_publisher_boilerplate(text, blocks)
  for _, block in ipairs(blocks) do
    local classes = pandoc.List()
    if block.classes then
      classes:extend(block.classes)
    end
    block:walk({
      Div = function(div)
        classes:extend(div.classes)
      end,
    })
    for _, class in ipairs(classes) do
      if BOILERPLATE_CLASSES[pandoc.text.lower(class)] then
        return true
      end
    end
  end

  local lowered = pandoc.text.lower(text)
  for _, marker in ipairs(BOILERPLATE_MARKERS) do
    if lowered:find(marker) then
      return true
    end
  end
  return false
end

--- Roughly how many lines will this front-matter unit take?
--
-- Estimated rather than measured, because measuring means boxing the material
-- in TeX and a \vbox cannot be typeset twice — the choice of layout has to be
-- made before the content is set. The estimate only has to separate a title
-- page from a cast list, and the failure mode of getting it wrong is the
-- behaviour this replaces.
local function estimated_lines(blocks)
  local lines = 0

  local function count(block)
    local text = visible(pandoc.utils.stringify(block))
    local breaks = 0
    block:walk({
      LineBreak = function()
        breaks = breaks + 1
      end,
    })
    lines = lines
      + math.max(1, math.ceil(pandoc.text.len(text) / settings['chars-per-line']))
      + breaks
  end

  for _, block in ipairs(blocks) do
    if block.t ~= 'RawBlock' then
      -- A Div holding twelve paragraphs is twelve lines, not one, so count the
      -- leaves. walk() does not visit the element it is called on, hence the
      -- fallback for a block that is already a leaf.
      local leaves = 0
      local function leaf(inner)
        leaves = leaves + 1
        count(inner)
      end
      block:walk({ Para = leaf, Plain = leaf, Header = leaf, LineBlock = leaf })
      if leaves == 0 then
        count(block)
      end
      -- A picture left in a text page still takes room; enough of an
      -- allowance that one is never centred off the bottom of the page.
      if has_image(block) then
        lines = lines + 10
      end
    end
  end

  return lines
end

--- Lay out one run of pre-chapter blocks as a single page.
--
-- Grouping by source file, not by block, is the whole point. Publishers differ
-- wildly in how finely they slice their front matter: some EPUBs wrap each
-- section in a single Div, while one edition in the corpus emits a Para per
-- *line* — 80 of them before chapter one. Treating each block as a page turned
-- that into 80 pages, most holding a single line or nothing at all.
--
local function lay_out_front_page(group)
  if #group == 0 then
    return pandoc.List()
  end

  local blocks = pandoc.List(group)
  if settings['frontmatter-trim'] then
    blocks = drop_publisher_marks(blocks)
  end
  blocks = tidy_front_blocks(blocks)

  -- \pageimage calls the Para/Plain handlers already made carry their own
  -- page. They must be held apart from the rest: stringify() on a RawBlock
  -- returns its literal LaTeX source, so counting one as prose would wrap a
  -- finished page image in a second page wrapper.
  local placed = pandoc.List()
  local rest = pandoc.List()
  for _, block in ipairs(blocks) do
    if block.t == 'RawBlock' and block.text:match('^\\pageimage') then
      placed:insert(block)
    else
      rest:insert(block)
    end
  end

  local images = {}
  local text = {}
  for _, block in ipairs(rest) do
    block:walk({
      Image = function(img)
        images[#images + 1] = img
      end,
    })
    -- Images stripped first, so alt text is not mistaken for prose.
    local stripped = block:walk({
      Image = function()
        return {}
      end,
    })
    text[#text + 1] = pandoc.utils.stringify(stripped)
  end

  local out = placed
  local prose = table.concat(text, ' ')

  if visible(prose) == '' then
    for _, img in ipairs(images) do
      out:extend(on_its_own_page(img))
    end
    return out
  end

  -- A page that also carries prose keeps its images inline; still record them,
  -- so a later bare repeat of the same picture is recognised as a duplicate.
  for _, img in ipairs(images) do
    emitted_page_images[img.src] = true
  end

  if settings['frontmatter-trim'] and is_publisher_boilerplate(prose, rest) then
    warn('front matter dropped', prose)
    return out
  end

  local top, bottom = '\\frontpagetop', '\\frontpagebottom'
  if estimated_lines(rest) > settings['front-page-max-lines'] then
    top, bottom = '\\frontblocktop', '\\frontblockbottom'
  end

  out:insert(pandoc.RawBlock('latex', top))
  out:extend(rest)
  out:insert(pandoc.RawBlock('latex', bottom))
  return out
end

--------------------------------------------------------------------------
-- Handlers
--------------------------------------------------------------------------

local function Pandoc(doc)
  if doc.meta['has-cover-image'] == nil then
    doc.meta['has-cover-image'] = saw_page_image
  end

  local first_chapter = nil
  for i, block in ipairs(doc.blocks) do
    if opens_a_chapter(block) then
      first_chapter = i
      break
    end
  end

  -- No chapter anywhere means no front matter to speak of, not a book that is
  -- front matter from cover to cover. Without this guard a heading-less EPUB
  -- has every one of its blocks centred on a page of its own, which turns a
  -- defective source into an unreadable 1000-page PDF.
  if not first_chapter then
    return doc
  end

  local blocks = pandoc.List()
  local group = pandoc.List()

  for i = 1, first_chapter - 1 do
    local block = doc.blocks[i]
    if is_file_anchor(block) then
      blocks:extend(lay_out_front_page(group))
      group = pandoc.List()
    else
      group:insert(block)
    end
  end
  blocks:extend(lay_out_front_page(group))

  for i = first_chapter, #doc.blocks do
    blocks:insert(doc.blocks[i])
  end
  doc.blocks = blocks

  return doc
end

--- Measure every image and mark the decorations.
--
-- The template fits images to the text block, scaling up as well as down,
-- which is right for a cover or a map and catastrophic for a 66 px table
-- glyph: sixteen of them each took a page to themselves in one book, at 12
-- ppi. Anything at or below the threshold gets a real size instead, computed
-- from its pixel count at the panel's own resolution.
--
-- The size goes on as an *attribute*, never as a RawInline wrapping
-- \includegraphics: this filter runs before pandoc rewrites image paths for
-- --extract-media, so a hand-written path would point at a file inside the
-- zip and the build would fail. An explicit width in the optional argument
-- overrides the template's default; keepaspectratio survives either way.
local function Image(img)
  if img.attributes.width or img.attributes.height then
    return nil -- the publisher gave it a size; respect it
  end
  local w, h = image_pixels(img.src)
  if not w or math.max(w, h) > settings['small-image-max'] then
    return nil
  end
  img.classes:insert(SMALL_CLASS)
  img.attributes.width =
    string.format('%.1fmm', w / settings['device-dpi'] * 25.4)
  return img
end

--- Does this paragraph open with a drop cap?
local function opens_with_dropcap(block)
  local first = block.content[1]
  return first ~= nil
    and first.t == 'RawInline'
    and first.format == 'latex'
    and first.text:match('^\\dropcap')
end

--- Place the decorations a block carries, according to where they sit.
local function lay_out_small_images(block)
  local found = false
  block:walk({
    Image = function(img)
      if is_small(img) then
        found = true
      end
    end,
  })
  if not found then
    return nil
  end

  local stripped = block:walk({
    Image = function()
      return {}
    end,
  })

  if visible(pandoc.utils.stringify(stripped)) == '' then
    -- A fleuron or a scene divider on a line of its own: centre it.
    return pandoc.List({
      pandoc.RawBlock('latex', '\\begin{center}'),
      block,
      pandoc.RawBlock('latex', '\\end{center}'),
    })
  end

  -- Sitting in a line of text — an allomantic symbol beside "Fer" in a table
  -- cell, a glyph mid-sentence. Its pixel count says nothing useful next to
  -- type; what matters is that it matches the line it sits on.
  return block:walk({
    Image = function(img)
      if not is_small(img) then
        return nil
      end
      img.attributes.width = nil
      img.attributes.height = settings['inline-image-height']
      return img
    end,
  })
end

local function text_block(block)
  local changed = false

  if opens_with_dropcap(block) then
    -- \dropcapfix closes the paragraph and makes up the lines a short one
    -- never gave the drop cap to hang in. See template.latex.
    block.content:insert(pandoc.RawInline('latex', '\\dropcapfix'))
    changed = true
  end

  local laid_out = lay_out_small_images(block)
  if laid_out then
    return laid_out
  end
  return changed and block or nil
end

local function Para(block)
  local img = sole_page_image(block)
  if img then
    return on_its_own_page(img)
  end
  return text_block(block)
end

local function Plain(block)
  local img = sole_page_image(block)
  if img then
    return on_its_own_page(img)
  end
  return text_block(block)
end

--- Stop caption-less images from becoming floats.
--
-- Pandoc maps a Figure onto LaTeX's `figure` environment, which floats. In a
-- novel these are illustrations and chapter ornaments that belong exactly
-- where the author put them, and on a 157 mm page a float has little room to
-- settle, so LaTeX pushes it pages away from its text.
--
-- Only caption-less figures are unwrapped: an empty \caption{} means the EPUB
-- never had a figure caption to begin with, just an image pandoc had to put
-- somewhere. A figure that does carry a caption is left alone as a real float.
local function Figure(fig)
  if pandoc.utils.stringify(fig.caption) ~= '' then
    return nil
  end
  local first = fig.content[1]
  if first and first.t == 'RawBlock' and first.text == '\\begin{center}' then
    -- Its content is a lone decoration the Plain handler has already centred;
    -- a second `center` would only add its own vertical space.
    return fig.content
  end
  -- The figure's attr is dropped with it. It only ever held an auto-generated
  -- anchor (fig-003, …) that nothing in a novel links to, and keeping it would
  -- leave a \hypertarget wrapped around every illustration.
  local blocks = pandoc.List({ pandoc.RawBlock('latex', '\\begin{center}') })
  blocks:extend(fig.content)
  blocks:insert(pandoc.RawBlock('latex', '\\end{center}'))
  return blocks
end

--- Give every table column a width.
--
-- Pandoc's LaTeX writer has two modes and both fail on a 137 mm measure. With
-- no width anywhere it emits `l` columns, which do not wrap: the third column
-- of the Ars Arcanum table simply ran off the right edge of the page. With
-- widths on some columns only — which is what an EPUB that styles three of its
-- four <col> elements produces — the unstyled one comes out as
-- `p{… * \real{0.0000}}`, a column of zero width whose contents pile on top of
-- the next one.
--
-- Filling in the missing widths fixes both. Widths the publisher did set are
-- kept and only rescaled, so a deliberately narrow symbol column stays narrow.
local function Table(tbl)
  local count = #tbl.colspecs
  if count == 0 then
    return nil
  end

  local known, missing = 0, pandoc.List()
  for i, spec in ipairs(tbl.colspecs) do
    if type(spec[2]) == 'number' and spec[2] > 0 then
      known = known + spec[2]
    else
      missing:insert(i)
    end
  end
  if #missing == 0 then
    return nil
  end

  -- Never below half an even share: a column holding a glyph and a word still
  -- needs room for the word.
  local share = math.max((1 - known) / #missing, 0.5 / count)

  local widths = {}
  local total = 0
  for i, spec in ipairs(tbl.colspecs) do
    widths[i] = (type(spec[2]) == 'number' and spec[2] > 0) and spec[2] or share
    total = total + widths[i]
  end

  local colspecs = {}
  for i, spec in ipairs(tbl.colspecs) do
    colspecs[i] = { spec[1], widths[i] / total }
  end
  tbl.colspecs = colspecs
  return tbl
end

local function Inlines(inlines)
  local out = pandoc.List()
  local i, n = 1, #inlines
  local changed = false

  while i <= n do
    local el = inlines[i]

    if is_lettrine(el) then
      local letter_text = (pandoc.utils.stringify(el):gsub('%s+', ''))

      if letter_text == '' then
        -- Not actually a drop cap; leave it for the writer to handle.
        out:insert(el)
        i = i + 1
      else
        local letter = pandoc.text.sub(letter_text, 1, 1)
        local tail = pandoc.List()
        local anchors = pandoc.List()

        -- A publisher may put more than the initial inside the span.
        local extra = pandoc.text.sub(letter_text, 2)
        if extra ~= '' then
          tail:insert(pandoc.Str(extra))
        end

        i = i + 1

        -- Take the rest of the word: plain Str only, stopping at any break or
        -- at styled content, so an italic phrase is never pulled into the
        -- drop cap's small-caps argument.
        while i <= n do
          local nx = inlines[i]
          if nx.t == 'SoftBreak' and #tail == 0 and not STANDALONE_WORD[letter] then
            -- Still hunting for the start of the word. There can be several
            -- of these, with invisible page anchors between them; skipping
            -- only the first leaves a stray one that reopens the "W axillium"
            -- gap this filter exists to close.
            i = i + 1
          elseif is_break(nx) then
            -- A real Space means the initial stands as its own word ("À",
            -- "Y"); joining it to the next word would corrupt the text.
            break
          elseif is_invisible(nx) then
            anchors:insert(nx)
            i = i + 1
          elseif nx.t == 'Str' then
            tail:insert(nx)
            i = i + 1
          else
            break
          end
        end

        out:extend(dropcap(letter, tail))
        out:extend(anchors)
        changed = true
      end

    elseif el.t == 'SoftBreak'
       and i < n
       and inlines[i + 1].t == 'Str'
       and TIGHT[first_char(inlines[i + 1].text)] then
      -- Drop the wrap so the punctuation closes up against the word.
      i = i + 1
      changed = true

    else
      out:insert(el)
      i = i + 1
    end
  end

  if not changed then
    return nil
  end
  return out
end

return {
  { Meta = read_settings },
  {
    Inlines = Inlines,
    Image = Image,
    Para = Para,
    Plain = Plain,
    Figure = Figure,
    Table = Table,
    Pandoc = Pandoc,
  },
}
