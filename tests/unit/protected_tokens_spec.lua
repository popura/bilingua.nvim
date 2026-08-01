local test = require("tests.testlib")
local protected_tokens = require("bilingua.adapters.document.protected_tokens")

-- Preconditions: The text contains inline code, a URL whose path includes a
-- template variable, and a positional printf conversion. Prerequisites: Longer
-- protected regions take precedence over nested candidates and placeholders use
-- deterministic session-local numbering. Verification items: each literal is
-- replaced exactly once, the URL remains one token, token kinds are recorded, and
-- exact restoration recreates the original text.
test.it("protects overlapping literals and restores them exactly", function()
  local original = "See `open_file()` at https://example.com/{name} and %1$d."
  local content, tokens = protected_tokens.protect(original)

  test.eq("See ⟦BIL:0001⟧ at ⟦BIL:0002⟧ and ⟦BIL:0003⟧.", content)
  test.eq({ "code", "url", "printf" }, { tokens[1].kind, tokens[2].kind, tokens[3].kind })
  test.eq("https://example.com/{name}", tokens[2].literal)
  test.eq(original, protected_tokens.restore(content, tokens))
end)

-- Preconditions: One known placeholder is respectively missing, duplicated, or
-- accompanied by an unknown five-digit placeholder. Prerequisites: Placeholder
-- identity is independent of display width, and restoration is the final Adapter
-- boundary before literal text can be rendered. Verification items: all three
-- malformed outputs return no restored text and a diagnostic reason.
test.it("rejects missing duplicate and unknown protected placeholders", function()
  local content, tokens = protected_tokens.protect("Keep `literal`.")
  local handle =
    assert(io.open("tests/fixtures/regressions/unknown-protected-placeholder.txt", "rb"))
  local unknown_placeholder = assert(handle:read("*a"))
  handle:close()
  local cases = {
    "Keep literal.",
    content .. " " .. content,
    unknown_placeholder,
  }

  for _, candidate in ipairs(cases) do
    local restored, reason = protected_tokens.restore(candidate, tokens)
    test.eq(nil, restored)
    test.eq("string", type(reason))
  end
end)
