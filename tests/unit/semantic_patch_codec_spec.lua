local test = require("tests.testlib")
local json = require("bilingua.util.json")
local patch_codec = require("bilingua.adapters.translation.codecs.semantic_patch_json_v1")

local function fragment(side, id, language, text, placeholder)
  return {
    side = side,
    language = language,
    text_hash = "hash:" .. id .. ":" .. text,
    units = {
      {
        unit_id = id,
        kind = "paragraph",
        language = language,
        content_text = text,
        structural_path = { "document", "paragraph:1" },
        protected_tokens = placeholder and {
          { placeholder = placeholder, literal = "`fast`", kind = "inline_code" },
        } or {},
      },
    },
  }
end

local function task()
  local source =
    fragment("source", "src:u:12", "en", "This is fast ⟦BIL:0001⟧.", "⟦BIL:0001⟧")
  local target_before = fragment(
    "target",
    "tgt:u:15",
    "ja",
    "これは高速です ⟦BIL:0001⟧。",
    "⟦BIL:0001⟧"
  )
  local target_after = fragment(
    "target",
    "tgt:u:15",
    "ja",
    "これは非常に高速です ⟦BIL:0001⟧。",
    "⟦BIL:0001⟧"
  )
  return {
    schema_version = 1,
    task_id = "task:patch:42",
    session_id = "session:1",
    kind = "propagate_edit",
    direction = "target_to_source",
    source_language = "en",
    target_language = "ja",
    mapping_group_id = "group:17",
    baseline = { source = source, target = target_before, revision = 3 },
    edited_side = "target",
    edited_before = target_before,
    edited_after = target_after,
    destination_before = source,
    context_before = {},
    context_after = {},
    constraints = {
      preserve_unedited_meaning = true,
      preserve_style = true,
      preserve_placeholders = true,
    },
    revision = 4,
    metadata = {},
  }
end

-- Preconditions: A target-to-source task contains the baseline triple and a
-- protected token. Prerequisites: The backend lacks structured output and system
-- instruction roles. Verification items: the safe system instruction and schema
-- are embedded in user content, while DOCUMENT_DATA names source_before,
-- target_before, and target_after with languages and placeholders intact.
test.it("encodes a semantic patch for an unstructured backend", function()
  local codec = patch_codec.new({ max_output_chars = 100, supported_kinds = { paragraph = true } })
  local request, encode_error = codec:encode(task(), {
    structured_output = false,
    system_instructions = false,
  })

  test.eq(nil, encode_error)
  test.eq(nil, request.system_instructions)
  test.eq(nil, request.response_schema)
  test.eq(true, request.user_content:find("untrusted document data", 1, true) ~= nil)
  test.eq(true, request.user_content:find("RESPONSE_SCHEMA", 1, true) ~= nil)
  local document_json = request.user_content:match("DOCUMENT_DATA\n([^\n]+)\n\nRESPONSE_SCHEMA")
  local payload = assert(json.decode(document_json))
  test.eq("src:u:12", payload.source_before[1].unit_id)
  test.eq("tgt:u:15", payload.target_after[1].unit_id)
  test.eq("⟦BIL:0001⟧", payload.target_after[1].protected_placeholders[1])
end)

-- Preconditions: An unstructured backend returns exactly one fenced JSON object
-- with a valid whole-group source replacement. Prerequisites: Single-fence input
-- is the only permitted non-raw JSON form. Verification items: the decoder strips
-- the fence, preserves correspondence and warnings, and emits the shared result
-- without retaining backend transport data.
test.it("decodes one fenced semantic patch result", function()
  local codec = patch_codec.new({ max_output_chars = 100, supported_kinds = { paragraph = true } })
  local response = json.encode({
    schema_version = 1,
    task_id = "task:patch:42",
    destination_side = "source",
    replacement_units = {
      {
        local_id = "replacement:1",
        corresponds_to_edited_unit_ids = { "tgt:u:15" },
        kind = "paragraph",
        content_text = "This is extremely fast ⟦BIL:0001⟧.",
        language = "en",
      },
    },
    warnings = { "minimal revision" },
  })
  local result, decode_error = codec:decode("```json\n" .. response .. "\n```", task(), {
    structured_output = false,
  })

  test.eq(nil, decode_error)
  test.eq("source", result.destination_side)
  test.eq("tgt:u:15", result.replacement_units[1].corresponds_to_edited_unit_ids[1])
  test.eq("minimal revision", result.warnings[1])
  test.eq({}, result.metadata)
end)

-- Preconditions: An unstructured backend surrounds an otherwise valid semantic
-- patch JSON object with explanatory prose before or after it. Prerequisites:
-- The compatibility path permits one complete JSON fence but never searches
-- arbitrary text for an embedded object. Verification items: both prose variants
-- return no result and normalize to E_INVALID_OUTPUT.
test.it("rejects explanatory prose around an unstructured JSON response", function()
  local codec = patch_codec.new({ max_output_chars = 100, supported_kinds = { paragraph = true } })
  local response = json.encode({
    schema_version = 1,
    task_id = "task:patch:42",
    destination_side = "source",
    replacement_units = {
      {
        local_id = "replacement:1",
        corresponds_to_edited_unit_ids = { "tgt:u:15" },
        kind = "paragraph",
        content_text = "Changed ⟦BIL:0001⟧",
        language = "en",
      },
    },
    warnings = json.array(),
  })

  for _, candidate in ipairs({
    "Here is the result:\n" .. response,
    response .. "\nThis applies the requested change.",
  }) do
    local result, decode_error = codec:decode(candidate, task(), { structured_output = false })
    test.eq(nil, result)
    test.eq("E_INVALID_OUTPUT", decode_error.code)
  end
end)

-- Preconditions: Semantic responses can be malformed by a wrong destination,
-- unsupported kind, duplicate local ID, unknown edited-unit ID, or missing
-- placeholder. Prerequisites: The codec has the adapter's supported kind set.
-- Verification items: each defect independently produces E_INVALID_OUTPUT and no
-- partial TranslationResult escapes the codec boundary.
test.it("rejects invalid semantic replacement structures", function()
  local codec = patch_codec.new({ max_output_chars = 100, supported_kinds = { paragraph = true } })
  local base = {
    schema_version = 1,
    task_id = "task:patch:42",
    destination_side = "source",
    replacement_units = {
      {
        local_id = "replacement:1",
        corresponds_to_edited_unit_ids = { "tgt:u:15" },
        kind = "paragraph",
        content_text = "Changed ⟦BIL:0001⟧",
        language = "en",
      },
    },
    warnings = json.array(),
  }
  local cases = {
    function(value)
      value.destination_side = "target"
    end,
    function(value)
      value.replacement_units[1].kind = "unknown"
    end,
    function(value)
      value.replacement_units[2] = vim.deepcopy(value.replacement_units[1])
    end,
    function(value)
      value.replacement_units[1].corresponds_to_edited_unit_ids[1] = "tgt:unknown"
    end,
    function(value)
      value.replacement_units[1].content_text = "Changed"
    end,
  }

  for _, mutate in ipairs(cases) do
    local value = vim.deepcopy(base)
    mutate(value)
    local result, decode_error =
      codec:decode(json.encode(value), task(), { structured_output = true })
    test.eq(nil, result)
    test.eq("E_INVALID_OUTPUT", decode_error.code)
  end
end)
