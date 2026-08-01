local test = require("tests.testlib")
local plaintext = require("bilingua.adapters.document.plaintext")

-- Preconditions: A parsed two-paragraph snapshot receives one TextEdit whose
-- range and expected_text exactly match the first paragraph. Prerequisites:
-- validation is performed against a virtual full document before EditorPort is
-- called. Verification items: validation succeeds, returns the complete virtual
-- document, and preserves all text outside the edit.
test.it("validates a plaintext edit against the complete virtual document", function()
  local adapter = plaintext.new()
  local snapshot = assert(adapter:parse({
    side = "target",
    text = "old\n\nuntouched",
    filetype = "text",
    language = "ja",
    editor_version = 3,
  }))
  local first = snapshot.units[snapshot.order[1]]
  local validation, err = adapter:validate_edits({
    snapshot = snapshot,
    edits = {
      {
        range = first.span,
        expected_text = "old",
        replacement = "new",
      },
    },
  })

  test.eq(nil, err)
  test.eq(true, validation.ok)
  test.eq("new\n\nuntouched", validation.text)
end)
