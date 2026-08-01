local test = require("tests.testlib")
local json = require("bilingua.util.json")

-- Preconditions: A JSON value contains UTF-8 text, control characters, booleans,
-- a numeric array and an explicit null. Prerequisites: Codec and backend layers
-- must not depend on Neovim JSON APIs or repair malformed JSON. Verification
-- items: strict encode/decode round-trips every value including the null sentinel,
-- and trailing non-whitespace input is rejected.
test.it("strictly round-trips JSON without Neovim dependencies", function()
  local encoded = json.encode({
    text = '日本語\n\t"quoted"',
    enabled = true,
    values = { 1, 2.5, json.null },
  })
  local decoded, decode_error = json.decode(encoded)

  test.eq(nil, decode_error)
  test.eq('日本語\n\t"quoted"', decoded.text)
  test.eq(true, decoded.enabled)
  test.eq(2.5, decoded.values[2])
  test.eq(json.null, decoded.values[3])
  local invalid, invalid_error = json.decode('{"ok":true} trailing')
  test.eq(nil, invalid)
  test.eq(true, type(invalid_error) == "string" and invalid_error ~= "")
end)
