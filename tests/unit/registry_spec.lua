local test = require("tests.testlib")
local registry_module = require("bilingua.registry")

-- Preconditions: A fresh registry receives two factories with the same public
-- name in different extension categories. Prerequisites: Categories are
-- independent, but duplicate registration inside one category is rejected unless
-- replace=true is explicit. Verification items: both categories resolve their own
-- factory, an accidental duplicate returns E_INVALID_ARGUMENT, and explicit
-- replacement changes only the selected category.
test.it("isolates extension categories and requires explicit replacement", function()
  local registry = registry_module.new()
  local first = function()
    return { api_version = 1, id = "first" }
  end
  local second = function()
    return { api_version = 1, id = "second" }
  end

  test.eq(true, registry:register_document_adapter("shared", first))
  test.eq(true, registry:register_unit_tracker("shared", second))
  local ok, err = registry:register_document_adapter("shared", second)
  test.eq(nil, ok)
  test.eq("E_INVALID_ARGUMENT", err.code)
  test.eq(true, registry:register_document_adapter("shared", second, { replace = true }))
  test.eq(second, registry:get_document_adapter("shared"))
  test.eq(second, registry:get_unit_tracker("shared"))
end)
