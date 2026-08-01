local test = require("tests.testlib")
local protected_tokens = require("bilingua.adapters.document.protected_tokens")

-- Preconditions: Markdown inline text contains relative link/image destinations,
-- an explicit reference label, escaped punctuation, and visible labels that must
-- remain translatable. Prerequisites: Only destinations/references/escapes are
-- protected, not the human-readable link or image labels. Verification items:
-- each syntax literal is tokenized once and exact restoration is reversible.
test.it("protects Markdown destinations reference labels and escapes", function()
  local original = "Read [the guide](guide.md), ![diagram](img/a.png), [topic][ref], and \\*."
  local protected, tokens = protected_tokens.protect(original)
  local literals = {}
  for _, token in ipairs(tokens) do
    literals[token.literal] = true
  end

  test.eq(true, literals["guide.md"])
  test.eq(true, literals["img/a.png"])
  test.eq(true, literals["[ref]"])
  test.eq(true, literals["\\*"])
  test.eq(true, protected:find("the guide", 1, true) ~= nil)
  test.eq(true, protected:find("diagram", 1, true) ~= nil)
  test.eq(original, assert(protected_tokens.restore(protected, tokens)))
end)
