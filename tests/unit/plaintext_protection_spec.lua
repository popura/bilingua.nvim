local test = require("tests.testlib")
local plaintext = require("bilingua.adapters.document.plaintext")

-- Preconditions: A plaintext paragraph contains inline code and a URL.
-- Prerequisites: Standard document adapters send protected placeholders, never
-- the protected literals, in content_text while retaining exact restoration
-- metadata. Verification items: the unit contains deterministic placeholders and
-- records both literals with their expected kinds.
test.it("protects literals while parsing plaintext units", function()
  local snapshot = assert(plaintext.new():parse({
    side = "source",
    text = "Run `build()` at https://example.com/docs.",
    filetype = "text",
    language = "en",
    editor_version = 1,
  }))
  local unit = snapshot.units[snapshot.order[1]]

  test.eq("Run ⟦BIL:0001⟧ at ⟦BIL:0002⟧.", unit.content_text)
  test.eq("`build()`", unit.protected_tokens[1].literal)
  test.eq("code", unit.protected_tokens[1].kind)
  test.eq("https://example.com/docs", unit.protected_tokens[2].literal)
end)

-- Preconditions: Plaintext contains an application-specific token matched only by
-- one configured Lua pattern. Prerequisites: standard and custom protection share
-- the same deterministic placeholder and restoration pipeline. Verification items:
-- the custom literal is removed from content_text, recorded with kind=custom, and
-- restored byte-for-byte before any TextEdit can be planned.
test.it("protects caller-configured Plaintext patterns", function()
  local adapter = plaintext.new({ protected_patterns = { "TOKEN:%d+" } })
  local snapshot = assert(adapter:parse({
    side = "source",
    text = "Keep TOKEN:42 unchanged.",
    filetype = "text",
    language = "en",
    editor_version = 1,
  }))
  local unit = snapshot.units[snapshot.order[1]]

  test.eq(nil, unit.content_text:find("TOKEN:42", 1, true))
  test.eq("TOKEN:42", unit.protected_tokens[1].literal)
  test.eq("custom", unit.protected_tokens[1].kind)
  test.eq(
    "Keep TOKEN:42 unchanged.",
    assert(
      require("bilingua.adapters.document.protected_tokens").restore(
        unit.content_text,
        unit.protected_tokens
      )
    )
  )
end)
