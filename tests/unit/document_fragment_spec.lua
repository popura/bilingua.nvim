local test = require("tests.testlib")
local document = require("bilingua.domain.document")

local function snapshot(overrides)
  local unit = {
    id = "src:u:000001",
    kind = "heading",
    language = "en",
    raw_text = "# Hello `x`",
    content_text = "Hello ⟦BIL:0001⟧",
    structural_path = { "document", "heading:1" },
    attributes = { marker = "#", level = 1 },
    protected_tokens = {
      {
        id = "tok:0001",
        placeholder = "⟦BIL:0001⟧",
        literal = "`x`",
        kind = "code",
        occurrence = 1,
      },
    },
    opaque = false,
  }
  for key, value in pairs(overrides or {}) do
    unit[key] = value
  end
  return {
    side = "source",
    language = "en",
    units = { [unit.id] = unit },
    order = { unit.id },
  }
end

-- Preconditions: Several snapshots retain the same content_text but change one
-- structural or protected fact at a time. Prerequisites: dirty comparison uses
-- only DocumentFragment.text_hash and therefore its digest must cover the full
-- unit sequence without exposing raw_text in the fragment sent to a provider.
-- Verification items: kind, raw Markdown, structural path, attributes, and token
-- literal changes each produce a distinct hash while raw_text remains absent.
test.it("hashes every fact required for structural dirty detection", function()
  local baseline = assert(document.fragment(snapshot(), { "src:u:000001" }))
  local changed = {
    document.fragment(snapshot({ kind = "paragraph" }), { "src:u:000001" }),
    document.fragment(snapshot({ raw_text = "## Hello `x`" }), { "src:u:000001" }),
    document.fragment(
      snapshot({ structural_path = { "document", "heading:2" } }),
      { "src:u:000001" }
    ),
    document.fragment(snapshot({ attributes = { marker = "##", level = 2 } }), { "src:u:000001" }),
    document.fragment(
      snapshot({
        protected_tokens = {
          {
            id = "tok:0001",
            placeholder = "⟦BIL:0001⟧",
            literal = "`y`",
            kind = "code",
            occurrence = 1,
          },
        },
      }),
      { "src:u:000001" }
    ),
  }

  test.eq(nil, baseline.units[1].raw_text)
  for _, fragment in ipairs(changed) do
    test.eq(false, fragment.text_hash == baseline.text_hash)
  end
end)

-- Preconditions: A fragment captures nested attributes and protected token data.
-- Prerequisites: a baseline pair must remain stable when a current snapshot or a
-- caller mutates its own tables later. Verification items: nested attribute lists
-- and token records are copied rather than aliased to the source DocumentUnit.
test.it("detaches fragment metadata from mutable snapshot tables", function()
  local source = snapshot({ attributes = { marker = "#", flags = { "a", "b" } } })
  local fragment = assert(document.fragment(source, { "src:u:000001" }))

  source.units["src:u:000001"].attributes.flags[1] = "changed"
  source.units["src:u:000001"].protected_tokens[1].literal = "changed"

  test.eq("a", fragment.units[1].attributes.flags[1])
  test.eq("`x`", fragment.units[1].protected_tokens[1].literal)
end)

-- Preconditions: Two separately captured baseline fragments come from adjacent
-- units of the same snapshot. Prerequisites: A structural merge must consolidate
-- groups without retaining raw document text or treating the unchanged opposite
-- side as dirty. Verification items: fragment composition produces the same
-- ordered units and text hash as one direct multi-unit fragment.
test.it("composes adjacent fragments without losing their structural digest", function()
  local source = snapshot()
  source.units["src:u:000002"] = {
    id = "src:u:000002",
    kind = "paragraph",
    language = "en",
    raw_text = "World",
    content_text = "World",
    structural_path = { "document", "paragraph:2" },
    attributes = {},
    protected_tokens = {},
    opaque = false,
  }
  source.order[2] = "src:u:000002"

  local first = assert(document.fragment(source, { source.order[1] }))
  local second = assert(document.fragment(source, { source.order[2] }))
  local combined, combine_error = document.combine({ first, second })
  local direct = assert(document.fragment(source, source.order))

  test.eq(nil, combine_error)
  test.eq(direct.text_hash, combined.text_hash)
  test.eq({ source.order[1], source.order[2] }, {
    combined.units[1].unit_id,
    combined.units[2].unit_id,
  })
  test.eq(nil, combined.units[1].raw_text)
end)
