local test = require("tests.testlib")
local hash = require("bilingua.util.hash")

-- Preconditions: The input strings are the empty message and the ASCII text
-- "abc". Prerequisites: SHA-256 output is lowercase hexadecimal and must not
-- depend on Neovim, LuaJIT-only APIs, or external commands. Verification items:
-- both published SHA-256 test vectors are reproduced exactly.
test.it("computes standard SHA-256 vectors", function()
  test.eq("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", hash.sha256(""))
  test.eq("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hash.sha256("abc"))
end)

-- Preconditions: A published SHA-256 input spans many compression blocks.
-- Prerequisites: The implementation may reuse its internal message schedule but
-- cannot retain words from a prior block. Verification items: one million ASCII
-- "a" bytes reproduce the published long-message digest exactly.
test.it("computes a multi-block SHA-256 vector", function()
  test.eq(
    "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
    hash.sha256(string.rep("a", 1000000))
  )
end)
