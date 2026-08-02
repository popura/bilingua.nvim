local test = require("tests.testlib")
local json = require("bilingua.util.json")
local initial_codec = require("bilingua.adapters.translation.codecs.initial_translation_json_v1")

local function task()
  return {
    schema_version = 1,
    task_id = "task:initial:1",
    session_id = "session:1",
    kind = "initial_translate",
    direction = "source_to_target",
    source_language = "auto",
    target_language = "ja",
    edited_after = {
      side = "source",
      language = "auto",
      units = {
        {
          unit_id = "src:u:000001",
          kind = "paragraph",
          language = "auto",
          content_text = "Run ⟦BIL:0001⟧.",
          structural_path = { "document", "paragraph:1" },
          protected_tokens = {
            { placeholder = "⟦BIL:0001⟧", literal = "`run`", kind = "inline_code" },
          },
        },
      },
    },
    context_before = {},
    context_after = {},
    constraints = { preserve_placeholders = true },
    revision = 1,
    metadata = {},
  }
end

-- Preconditions: An initial-translation task contains one protected source unit.
-- Prerequisites: The backend supports both system instructions and structured
-- output, while document strings remain untrusted data. Verification items: the
-- normalized request separates instructions from DOCUMENT_DATA, includes the v1
-- response schema, and serializes the exact unit ID, path, and placeholder.
test.it("encodes an initial translation as isolated document data", function()
  local codec = initial_codec.new({ max_output_chars = 100 })
  local request, encode_error = codec:encode(task(), {
    system_instructions = true,
    structured_output = true,
  })

  test.eq(nil, encode_error)
  test.eq("task:initial:1", request.request_id)
  test.eq(true, request.system_instructions:find("untrusted document data", 1, true) ~= nil)
  test.eq("integer", request.response_schema.properties.schema_version.type)
  test.eq(1, request.response_schema.properties.schema_version.const)
  local document_json = request.user_content:match("DOCUMENT_DATA\n(.*)$")
  local payload = assert(json.decode(document_json))
  test.eq("src:u:000001", payload.units[1].source_unit_id)
  test.eq("paragraph:1", payload.units[1].structural_path[2])
  test.eq("⟦BIL:0001⟧", payload.units[1].protected_placeholders[1])
end)

-- Preconditions: A valid model response returns every input ID once and keeps
-- its protected placeholder. Prerequisites: The codec owns JSON decoding and
-- normalizes an initial result to the shared TranslationResult shape.
-- Verification items: translation content, destination, correspondence, detected
-- source language, and warnings survive decoding without provider-specific IDs.
test.it("decodes a complete initial result into replacement units", function()
  local codec = initial_codec.new({ max_output_chars = 100 })
  local result, decode_error = codec:decode(
    json.encode({
      schema_version = 1,
      task_id = "task:initial:1",
      translations = {
        {
          source_unit_id = "src:u:000001",
          source_language = "en",
          translated_text = "実行 ⟦BIL:0001⟧。",
          warnings = { "terminology" },
        },
      },
    }),
    task(),
    { structured_output = true }
  )

  test.eq(nil, decode_error)
  test.eq("target", result.destination_side)
  test.eq("src:u:000001", result.replacement_units[1].corresponds_to_edited_unit_ids[1])
  test.eq("実行 ⟦BIL:0001⟧。", result.replacement_units[1].content_text)
  test.eq("ja", result.replacement_units[1].language)
  test.eq("en", result.metadata.source_languages["src:u:000001"])
  test.eq("en", result.metadata.document_source_language)
  test.eq("terminology", result.warnings[1])
  test.eq(nil, result.metadata.provider_id)
end)

-- Preconditions: Three malformed initial responses respectively duplicate an ID,
-- lose a protected placeholder, and exceed a four-character output limit.
-- Prerequisites: The decoder must not repair or complete model output.
-- Verification items: every response is rejected as E_INVALID_OUTPUT, including
-- the Japanese length check which counts characters rather than UTF-8 bytes.
test.it("rejects invalid initial IDs placeholders and output limits", function()
  local codec = initial_codec.new({ max_output_chars = 4 })
  local responses = {
    {
      schema_version = 1,
      task_id = "task:initial:1",
      translations = {
        {
          source_unit_id = "src:u:000001",
          source_language = "en",
          translated_text = "⟦BIL:0001⟧",
          warnings = json.array(),
        },
        {
          source_unit_id = "src:u:000001",
          source_language = "en",
          translated_text = "⟦BIL:0001⟧",
          warnings = json.array(),
        },
      },
    },
    {
      schema_version = 1,
      task_id = "task:initial:1",
      translations = {
        {
          source_unit_id = "src:u:000001",
          source_language = "en",
          translated_text = "実行",
          warnings = json.array(),
        },
      },
    },
    {
      schema_version = 1,
      task_id = "task:initial:1",
      translations = {
        {
          source_unit_id = "src:u:000001",
          source_language = "en",
          translated_text = "あいうえお⟦BIL:0001⟧",
          warnings = json.array(),
        },
      },
    },
  }

  for _, response in ipairs(responses) do
    local result, decode_error =
      codec:decode(json.encode(response), task(), { structured_output = true })
    test.eq(nil, result)
    test.eq("E_INVALID_OUTPUT", decode_error.code)
  end
end)
