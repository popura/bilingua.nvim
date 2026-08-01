local test = require("tests.testlib")
local plaintext = require("bilingua.adapters.document.plaintext")

-- Preconditions: A parsed source snapshot has two paragraphs separated by one
-- blank line, and the first paragraph contains protected inline code.
-- Prerequisites: Initial results identify every source unit and contain only
-- translated content_text; the adapter owns literal restoration and document
-- separators. Verification items: the exact protected literal and separator are
-- restored, and construction seeds preserve source IDs without embedding them in
-- the target text.
test.it("builds an initial plaintext target from normalized replacement units", function()
  local adapter = plaintext.new()
  local source = assert(adapter:parse({
    side = "source",
    text = "Hello `x`.\n\nWorld",
    filetype = "text",
    language = "en",
    editor_version = 1,
  }))
  local built, err = adapter:build_initial_target({
    source_snapshot = source,
    result = {
      replacement_units = {
        {
          local_id = "result:1",
          corresponds_to_edited_unit_ids = { source.order[1] },
          kind = "paragraph",
          content_text = "こんにちは ⟦BIL:0001⟧。",
          language = "ja",
        },
        {
          local_id = "result:2",
          corresponds_to_edited_unit_ids = { source.order[2] },
          kind = "paragraph",
          content_text = "世界",
          language = "ja",
        },
      },
    },
  })

  test.eq(nil, err)
  test.eq("こんにちは `x`。\n\n世界", built.text)
  test.eq({
    { source_unit_ids = { source.order[1] }, target_ordinal = 1, kind = "paragraph" },
    { source_unit_ids = { source.order[2] }, target_ordinal = 2, kind = "paragraph" },
  }, built.seeds)
end)
