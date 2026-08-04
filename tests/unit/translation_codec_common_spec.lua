local test = require("tests.testlib")
local common = require("bilingua.adapters.translation.codecs.common")

local function normalized_request(capabilities, max_input_chars)
  return common.normalized_request(
    {
      id = "test_codec",
      max_input_chars = max_input_chars,
      timeout_ms = 1000,
    },
    { task_id = "task:common:1", kind = "initial_translate" },
    capabilities,
    "Translate the document.",
    { units = {} },
    {
      type = "object",
      properties = { translated_text = { type = "string" } },
      required = { "translated_text" },
      additionalProperties = false,
    }
  )
end

local function occurrence_count(value, literal)
  local count = 0
  local offset = 1
  while true do
    local found = value:find(literal, offset, true)
    if not found then
      return count
    end
    count = count + 1
    offset = found + #literal
  end
end

-- Preconditions: The same Codec request is normalized for structured backends
-- that omit or explicitly set schema_in_prompt and for an unstructured backend.
-- Prerequisites: structured_output controls the provider schema parameter, while
-- schema_in_prompt independently requests a prompt explanation when structured
-- output is available. Verification items: the provider Schema is present only
-- for structured output, omitted capability preserves Codex-compatible behavior,
-- and RESPONSE_SCHEMA appears exactly once whenever the prompt must contain it.
test.it("normalizes the schema capability combinations", function()
  local cases = {
    {
      capabilities = { structured_output = true, schema_in_prompt = false },
      in_api = true,
      in_prompt = false,
    },
    { capabilities = { structured_output = true }, in_api = true, in_prompt = false },
    {
      capabilities = { structured_output = true, schema_in_prompt = true },
      in_api = true,
      in_prompt = true,
    },
    {
      capabilities = { structured_output = false, schema_in_prompt = false },
      in_api = false,
      in_prompt = true,
    },
  }

  for _, case in ipairs(cases) do
    local request, request_error = normalized_request(case.capabilities)

    test.eq(nil, request_error)
    if case.in_api then
      test.eq("object", request.response_schema.type)
    else
      test.eq(nil, request.response_schema)
    end
    test.eq(case.in_prompt, request.user_content:find("RESPONSE_SCHEMA\n", 1, true) ~= nil)
    test.eq(
      case.in_prompt and 1 or 0,
      occurrence_count(request.user_content, '"additionalProperties":false')
    )
  end
end)

-- Preconditions: A structured backend requests the same Schema through both the
-- provider parameter and the prompt, producing a known final user_content length.
-- Prerequisites: max_input_chars applies after every prompt section is assembled.
-- Verification items: reducing the measured final length by one rejects encoding,
-- and the error reports the complete post-Schema length and configured maximum.
test.it("applies the input limit after adding the prompt schema", function()
  local request = assert(normalized_request({
    structured_output = true,
    schema_in_prompt = true,
  }))
  local length = assert(common.utf8_length(request.user_content))

  local limited, limit_error =
    normalized_request({ structured_output = true, schema_in_prompt = true }, length - 1)

  test.eq(nil, limited)
  test.eq("E_INVALID_ARGUMENT", limit_error.code)
  test.eq(length, limit_error.details.actual)
  test.eq(length - 1, limit_error.details.maximum)
end)
