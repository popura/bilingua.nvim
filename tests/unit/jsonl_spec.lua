local test = require("tests.testlib")
local jsonl = require("bilingua.util.jsonl")

-- Preconditions: Two JSON-RPC messages arrive across arbitrary stdout chunks,
-- including an empty line and CRLF. Prerequisites: Chunk boundaries have no
-- relationship to protocol line boundaries. Verification items: feed emits only
-- complete decoded messages in order, strips CR, and finish reports no remainder.
test.it("frames split JSONL chunks without assuming line callbacks", function()
  local parser = jsonl.new({ max_line_bytes = 1024 })
  local first = assert(parser:feed('{"id":1,"result":{"ok":'))
  local second = assert(parser:feed('true}}\r\n\n{"method":"turn/'))
  local third = assert(parser:feed('completed","params":{}}\n'))
  local final = assert(parser:finish())

  test.eq(0, #first)
  test.eq(1, #second)
  test.eq(true, second[1].result.ok)
  test.eq("turn/completed", third[1].method)
  test.eq(0, #final)
end)

-- Preconditions: One line is malformed JSON and another unterminated buffer is
-- larger than the configured byte ceiling. Prerequisites: The parser must not
-- repair JSON or retain an unbounded stdout buffer. Verification items: both
-- defects fail deterministically, and a failed parser rejects later chunks.
test.it("rejects malformed and oversized JSONL records", function()
  local malformed = jsonl.new({ max_line_bytes = 32 })
  local messages, malformed_error = malformed:feed('{"id":}\n')
  test.eq(nil, messages)
  test.eq("E_BACKEND_PROTOCOL", malformed_error.code)
  local later, later_error = malformed:feed('{"id":1}\n')
  test.eq(nil, later)
  test.eq("E_BACKEND_PROTOCOL", later_error.code)

  local oversized = jsonl.new({ max_line_bytes = 4 })
  local oversized_messages, oversized_error = oversized:feed("12345")
  test.eq(nil, oversized_messages)
  test.eq("E_BACKEND_PROTOCOL", oversized_error.code)
end)
