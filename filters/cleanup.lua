--[[
filters/cleanup.lua — repair EPUB source artifacts before the LaTeX writer.

Two fixes. They look unrelated in the output but share one root cause: these
EPUBs wrap their XHTML source mid-sentence, and pandoc turns every wrap into a
SoftBreak that LaTeX then renders as a space.

  1. Span[.lettrine]["W"], SoftBreak, Str "axillium"  ->  "W axillium"
  2. Emph[..."fois"],      SoftBreak, Str ","         ->  "une seule fois ,"

Fix 1 also converts the drop cap into \dropcap{}{} (defined in template.latex),
which pandoc has no native concept of.

Scope note: only SoftBreak is touched, never Space. Measured on test.epub,
SoftBreak precedes . 295x  , 172x  ’ 4x  ) 3x  … 2x, whereas a real Space only
ever precedes ':' (2x) — which is correct French and must survive.

Edition-specific: the 2019 "Tome 5" edition has 4 SoftBreaks total and needs
neither fix, while test.epub and the 2017 edition have ~470 each. Validating
against the 2019 file alone proves nothing.
]]

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
-- filename or with the "page image" classes.
local function is_page_image(img)
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

  -- RawBlocks here are \pageimage calls the Para/Plain handlers already made,
  -- and they carry their own page. They must be held apart from the rest:
  -- stringify() on a RawBlock returns its literal LaTeX source, so counting it
  -- as prose would wrap a finished page image in a second page wrapper.
  local placed = pandoc.List()
  local rest = pandoc.List()
  for _, block in ipairs(group) do
    if block.t == 'RawBlock' then
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

  if visible(table.concat(text)) == '' then
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

  out:insert(pandoc.RawBlock('latex', '\\frontpagetop'))
  out:extend(rest)
  out:insert(pandoc.RawBlock('latex', '\\frontpagebottom'))
  return out
end

function Pandoc(doc)
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

function Para(block)
  local img = sole_page_image(block)
  return img and on_its_own_page(img) or nil
end

function Plain(block)
  local img = sole_page_image(block)
  return img and on_its_own_page(img) or nil
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
function Figure(fig)
  if pandoc.utils.stringify(fig.caption) ~= '' then
    return nil
  end
  -- The figure's attr is dropped with it. It only ever held an auto-generated
  -- anchor (fig-003, …) that nothing in a novel links to, and keeping it would
  -- leave a \hypertarget wrapped around every illustration.
  local blocks = pandoc.List({ pandoc.RawBlock('latex', '\\begin{center}') })
  blocks:extend(fig.content)
  blocks:insert(pandoc.RawBlock('latex', '\\end{center}'))
  return blocks
end

function Inlines(inlines)
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
