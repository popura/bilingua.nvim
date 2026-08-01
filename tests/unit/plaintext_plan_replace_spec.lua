local test = require("tests.testlib")
local plaintext = require("bilingua.adapters.document.plaintext")

-- Preconditions: A target snapshot has two paragraphs and the first contains a
-- protected literal. A validated semantic result replaces only that first unit.
-- Prerequisites: The adapter, not the translation backend, renders raw document
-- text and every TextEdit carries exact expected_text. Verification items: one
-- edit targets the paragraph's exclusive byte range, restores the protected
-- literal, and leaves the second paragraph outside the edit.
test.it("plans a guarded replacement for one plaintext unit", function()
  local adapter = plaintext.new()
  local target = assert(adapter:parse({
    side = "target",
    text = "こんにちは `x`。\n\n世界",
    filetype = "text",
    language = "ja",
    editor_version = 9,
  }))
  local first = target.units[target.order[1]]
  local edits, err = adapter:plan_replace({
    snapshot = target,
    destination_unit_ids = { first.id },
    replacement_units = {
      {
        local_id = "replacement:1",
        corresponds_to_edited_unit_ids = { "src:u:000001" },
        kind = "paragraph",
        content_text = "やあ ⟦BIL:0001⟧。",
      },
    },
    protected_tokens_by_edited_unit_id = {
      ["src:u:000001"] = first.protected_tokens,
    },
  })

  test.eq(nil, err)
  test.eq(1, #edits)
  test.eq(first.span, edits[1].range)
  test.eq("こんにちは `x`。", edits[1].expected_text)
  test.eq("やあ `x`。", edits[1].replacement)
end)
