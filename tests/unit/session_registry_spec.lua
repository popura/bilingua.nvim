local test = require("tests.testlib")
local session_registry = require("bilingua.session_registry")

-- Preconditions: A fresh registry receives two sessions with distinct source and
-- target buffers. Prerequisites: Buffer lookup is the only allowed central mutable
-- index; session state itself remains in each Session and removal clears both
-- sides. Verification items: both buffer numbers resolve correctly, duplicate
-- source registration is rejected, and removing one session leaves no stale
-- target lookup while preserving the other session.
test.it("indexes sessions by both buffers and removes them atomically", function()
  local registry = session_registry.new()
  local first = { id = "session:1", source_buf = 3, target_buf = 4 }
  local second = { id = "session:2", source_buf = 5, target_buf = 6 }

  test.eq(true, registry:add(first))
  test.eq(true, registry:add(second))
  test.eq(first, registry:for_buffer(3))
  test.eq(first, registry:for_buffer(4))
  local added, err = registry:add({ id = "session:3", source_buf = 3, target_buf = 7 })
  test.eq(nil, added)
  test.eq("E_INVALID_ARGUMENT", err.code)
  test.eq(true, registry:remove(first))
  test.eq(nil, registry:for_buffer(3))
  test.eq(nil, registry:for_buffer(4))
  test.eq(second, registry:for_buffer(6))
end)
