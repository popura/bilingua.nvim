local test = require("tests.testlib")
local hash = require("bilingua.util.hash")
local markdown = require("bilingua.adapters.document.markdown")
local hybrid = require("bilingua.adapters.tracker.hybrid")

local function fixture()
  local handle = assert(io.open("tests/fixtures/markdown/all.md", "rb"))
  local text = assert(handle:read("*a"))
  handle:close()
  return text
end

local function find_unit(snapshot, predicate)
  for _, unit_id in ipairs(snapshot.order) do
    local unit = snapshot.units[unit_id]
    if predicate(unit) then
      return unit
    end
  end
end

-- Preconditions: The complete Markdown fixture contains every required MVP block
-- family and inline protection family. Prerequisites: The explicit parser owns
-- Markdown syntax and emits non-overlapping byte spans in source order.
-- Verification items: ATX/Setext/list/nested-list/quote attributes are extracted,
-- opaque blocks remain exact, and code/link/image/reference/URL/math/template
-- literals are represented only by reversible protected placeholders.
test.it("parses Markdown structure and protects inline literals", function()
  local adapter = markdown.new()
  local source_text = fixture()
  local snapshot, parse_error = adapter:parse({
    side = "source",
    text = source_text,
    filetype = "markdown",
    language = "en",
    editor_version = 1,
  })

  test.eq(nil, parse_error)
  test.eq(hash.sha256(source_text), snapshot.text_hash)
  local atx = assert(find_unit(snapshot, function(unit)
    return unit.kind == "heading" and unit.attributes.style == "atx"
  end))
  test.eq(1, atx.attributes.heading_level)
  test.eq("ATX heading", atx.content_text)
  local setext = assert(find_unit(snapshot, function(unit)
    return unit.kind == "heading" and unit.attributes.style == "setext"
  end))
  test.eq(1, setext.attributes.heading_level)
  local nested = assert(find_unit(snapshot, function(unit)
    return unit.kind == "list_item" and unit.attributes.list_depth == 2
  end))
  test.eq(false, nested.attributes.list_ordered)
  local ordered = assert(find_unit(snapshot, function(unit)
    return unit.kind == "list_item" and unit.attributes.list_ordered == true
  end))
  test.eq("1.", ordered.attributes.list_marker)
  local quote = assert(find_unit(snapshot, function(unit)
    return unit.attributes.blockquote_depth == 1 and not unit.opaque
  end))
  test.eq("paragraph", quote.kind)

  local paragraph = assert(find_unit(snapshot, function(unit)
    return not unit.opaque and unit.raw_text:find("Paragraph with", 1, true) ~= nil
  end))
  local literals = {}
  for _, token in ipairs(paragraph.protected_tokens) do
    literals[token.literal] = true
  end
  for _, literal in ipairs({
    "`code`",
    "guide.md",
    "image.png",
    "[ref]",
    "<https://example.com>",
    "https://openai.com",
    "$x + y$",
    "{{name}}",
  }) do
    test.eq(true, literals[literal])
  end

  for _, raw in ipairs({
    "---\ntitle: Fixture\n---",
    '```lua\nprint("do not translate")\n```',
    "    indented_code()",
    "| Column A | Column B |\n| -------- | -------- |\n| value    | value    |",
    "---",
    "[ref]: https://example.com/reference",
    "[^note]: Footnote definition.",
    "![diagram](diagram.png)",
    "<div>\nHTML block\n</div>",
    "$$\nx = y + 1\n$$",
  }) do
    test.eq(true, find_unit(snapshot, function(unit)
      return unit.opaque and unit.raw_text == raw
    end) ~= nil)
  end
end)

-- Preconditions: A parsed Markdown source has translated replacements for every
-- non-opaque unit and no replacements for opaque units. Prerequisites: Initial
-- assembly owns syntax templates, token restoration, separators, and exact opaque
-- copying. Verification items: one heading body changes without losing '# ', all
-- opaque raw blocks are byte-identical, and parsing the rendered document yields
-- the same unit kinds, opacity flags, order length, and final-newline state.
test.it("builds a structurally stable initial Markdown target", function()
  local adapter = markdown.new()
  local source = assert(adapter:parse({
    side = "source",
    text = fixture(),
    filetype = "markdown",
    language = "en",
    editor_version = 1,
  }))
  local replacements = {}
  for _, unit_id in ipairs(source.order) do
    local unit = source.units[unit_id]
    if not unit.opaque then
      replacements[#replacements + 1] = {
        local_id = "result:" .. unit_id,
        corresponds_to_edited_unit_ids = { unit_id },
        kind = unit.kind,
        content_text = unit.content_text == "ATX heading" and "ATX 見出し" or unit.content_text,
        language = "ja",
      }
    end
  end
  local built, build_error = adapter:build_initial_target({
    source_snapshot = source,
    result = { replacement_units = replacements },
  })

  test.eq(nil, build_error)
  test.eq(true, built.text:find("# ATX 見出し", 1, true) ~= nil)
  test.eq(true, built.text:find('```lua\nprint("do not translate")\n```', 1, true) ~= nil)
  test.eq("\n", built.text:sub(-1))
  local target = assert(adapter:parse({
    side = "target",
    text = built.text,
    filetype = "markdown",
    language = "ja",
    editor_version = 1,
  }))
  test.eq(#source.order, #target.order)
  for ordinal, source_id in ipairs(source.order) do
    local target_unit = target.units[target.order[ordinal]]
    test.eq(source.units[source_id].kind, target_unit.kind)
    test.eq(source.units[source_id].opaque, target_unit.opaque)
  end
end)

-- Preconditions: A target ATX heading receives a one-to-one body replacement,
-- while a second proposed edit overlaps an opaque fenced code block.
-- Prerequisites: Text changes preserve the destination Markdown frame and every
-- edit is validated against a fully reparsed virtual document. Verification
-- items: the safe edit range covers only heading content, validates successfully,
-- and the opaque-overlap edit is rejected as E_VALIDATION before application.
test.it("plans body-only Markdown edits and protects opaque blocks", function()
  local adapter = markdown.new()
  local snapshot = assert(adapter:parse({
    side = "target",
    text = fixture(),
    filetype = "markdown",
    language = "ja",
    editor_version = 7,
  }))
  local heading = assert(find_unit(snapshot, function(unit)
    return unit.kind == "heading" and unit.attributes.style == "atx"
  end))
  local edits, plan_error = adapter:plan_replace({
    snapshot = snapshot,
    destination_unit_ids = { heading.id },
    replacement_units = {
      {
        local_id = "replacement:1",
        corresponds_to_edited_unit_ids = { "src:u:1" },
        kind = "heading",
        content_text = "新しい見出し",
        language = "ja",
      },
    },
    protected_tokens_by_edited_unit_id = { ["src:u:1"] = {} },
  })

  test.eq(nil, plan_error)
  test.eq("ATX heading", edits[1].expected_text)
  test.eq("新しい見出し", edits[1].replacement)
  test.eq(true, assert(adapter:validate_edits({ snapshot = snapshot, edits = edits })).ok)

  local fence = assert(find_unit(snapshot, function(unit)
    return unit.opaque and unit.raw_text:sub(1, 3) == "```"
  end))
  local invalid, validation_error = adapter:validate_edits({
    snapshot = snapshot,
    edits = {
      {
        range = fence.span,
        expected_text = fence.raw_text,
        expected_hash = hash.sha256(fence.raw_text),
        replacement = "```lua\nbroken",
        metadata = {},
      },
    },
  })
  test.eq(nil, invalid)
  test.eq("E_VALIDATION", validation_error.code)
end)

-- Preconditions: A CRLF Markdown document has no final newline and contains one
-- heading plus one paragraph. Prerequisites: Parsing and identity initial assembly
-- preserve byte-oriented editor coordinates and original separators.
-- Verification items: the rendered bytes remain exactly CRLF and no final newline
-- is invented or removed.
test.it("preserves CRLF separators and final-newline absence", function()
  local adapter = markdown.new()
  local text = "## Heading\r\n\r\nParagraph"
  local source = assert(adapter:parse({
    side = "source",
    text = text,
    filetype = "markdown",
    language = "en",
    editor_version = 1,
  }))
  local replacements = {}
  for _, unit_id in ipairs(source.order) do
    local unit = source.units[unit_id]
    replacements[#replacements + 1] = {
      local_id = unit_id,
      corresponds_to_edited_unit_ids = { unit_id },
      kind = unit.kind,
      content_text = unit.content_text,
      language = "ja",
    }
  end
  local built = assert(adapter:build_initial_target({
    source_snapshot = source,
    result = { replacement_units = replacements },
  }))
  test.eq(text, built.text)
end)

-- Preconditions: Two ordered Markdown list items keep their bodies while their
-- visible markers change from 1/2 to 7/8. Prerequisites: List markers are mutable
-- structure attributes, whereas tracker identity is based on content, kind, and
-- structural evidence. Verification items: both stable IDs survive, the new
-- markers are retained, and no insert, delete, or ambiguity is reported.
test.it("retains list item identity across ordered-list renumbering", function()
  local adapter = markdown.new()
  local previous = assert(adapter:parse({
    side = "source",
    text = "1. First\n2. Second\n",
    filetype = "markdown",
    language = "en",
    editor_version = 1,
  }))
  local current = assert(adapter:parse({
    side = "source",
    text = "7. First\n8. Second\n",
    filetype = "markdown",
    language = "en",
    editor_version = 2,
    previous = previous,
  }))
  local report = assert(hybrid.new():reconcile({
    side = "source",
    previous = previous,
    current = current,
    changed_ranges = {},
    anchor_hints = {},
  }))

  test.eq(previous.order, report.snapshot.order)
  test.eq("7.", report.snapshot.units[previous.order[1]].attributes.list_marker)
  test.eq("8.", report.snapshot.units[previous.order[2]].attributes.list_marker)
  test.eq(false, report.ambiguous)
  for _, relation in ipairs(report.matches) do
    test.eq("same", relation.kind)
  end
end)
