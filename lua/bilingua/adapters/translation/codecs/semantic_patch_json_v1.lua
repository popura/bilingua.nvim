local json = require("bilingua.util.json")
local common = require("bilingua.adapters.translation.codecs.common")

local SemanticPatchJsonV1 = {}
SemanticPatchJsonV1.__index = SemanticPatchJsonV1

local TOP_LEVEL_FIELDS = {
  schema_version = true,
  task_id = true,
  destination_side = true,
  replacement_units = true,
  warnings = true,
}

local REPLACEMENT_FIELDS = {
  local_id = true,
  corresponds_to_edited_unit_ids = true,
  kind = true,
  content_text = true,
  language = true,
}

local function schema()
  return {
    type = "object",
    properties = {
      schema_version = { type = "integer", const = 1 },
      task_id = { type = "string" },
      destination_side = { type = "string", enum = { "source", "target" } },
      replacement_units = {
        type = "array",
        items = {
          type = "object",
          properties = {
            local_id = { type = "string" },
            corresponds_to_edited_unit_ids = { type = "array", items = { type = "string" } },
            kind = { type = "string" },
            content_text = { type = "string" },
            language = { type = { "string", "null" } },
          },
          required = {
            "local_id",
            "corresponds_to_edited_unit_ids",
            "kind",
            "content_text",
            "language",
          },
          additionalProperties = false,
        },
      },
      warnings = { type = "array", items = { type = "string" } },
    },
    required = { "schema_version", "task_id", "destination_side", "replacement_units", "warnings" },
    additionalProperties = false,
  }
end

function SemanticPatchJsonV1.new(options)
  local resolved = options or {}
  return setmetatable({
    api_version = 1,
    id = "semantic_patch_json_v1",
    max_input_chars = resolved.max_input_chars,
    max_output_chars = resolved.max_output_chars or 24000,
    timeout_ms = resolved.timeout_ms,
    supported_kinds = resolved.supported_kinds,
  }, SemanticPatchJsonV1)
end

function SemanticPatchJsonV1:response_schema(_)
  return schema()
end

local function valid_fragment(fragment)
  if type(fragment) ~= "table" or not common.task_list(fragment.units) then
    return false
  end
  for _, unit in ipairs(fragment.units) do
    if
      type(unit) ~= "table"
      or type(unit.unit_id) ~= "string"
      or type(unit.kind) ~= "string"
      or type(unit.content_text) ~= "string"
      or type(unit.language) ~= "string"
    then
      return false
    end
  end
  return true
end

local function validate_task(task)
  local direction_ok = task
    and (
      (task.direction == "source_to_target" and task.edited_side == "source")
      or (task.direction == "target_to_source" and task.edited_side == "target")
    )
  if
    type(task) ~= "table"
    or task.schema_version ~= 1
    or type(task.task_id) ~= "string"
    or task.task_id == ""
    or (task.kind ~= "propagate_edit" and task.kind ~= "propagate_structure" and task.kind ~= "resolve_conflict")
    or not direction_ok
    or type(task.source_language) ~= "string"
    or type(task.target_language) ~= "string"
    or type(task.mapping_group_id) ~= "string"
    or not valid_fragment(task.edited_before)
    or not valid_fragment(task.edited_after)
    or not valid_fragment(task.destination_before)
    or not common.task_list(task.context_before or {})
    or not common.task_list(task.context_after or {})
    or type(task.constraints) ~= "table"
  then
    return common.invalid_argument("Semantic patch task is malformed")
  end
  for _, fragment in ipairs(task.context_before or {}) do
    if not valid_fragment(fragment) then
      return common.invalid_argument("Semantic patch context contains a malformed fragment")
    end
  end
  for _, fragment in ipairs(task.context_after or {}) do
    if not valid_fragment(fragment) then
      return common.invalid_argument("Semantic patch context contains a malformed fragment")
    end
  end
  return true
end

function SemanticPatchJsonV1:encode(task, backend_capabilities)
  local valid, task_error = validate_task(task)
  if not valid then
    return nil, task_error
  end
  local data = {
    task_id = task.task_id,
    direction = task.direction,
    source_language = task.source_language,
    target_language = task.target_language,
    mapping_group_id = task.mapping_group_id,
    context_before = common.context_fragments(task.context_before),
    context_after = common.context_fragments(task.context_after),
    constraints = task.constraints,
  }
  if task.direction == "source_to_target" then
    data.source_before = common.fragment_units(task.edited_before)
    data.source_after = common.fragment_units(task.edited_after)
    data.target_before = common.fragment_units(task.destination_before)
  else
    data.source_before = common.fragment_units(task.destination_before)
    data.target_before = common.fragment_units(task.edited_before)
    data.target_after = common.fragment_units(task.edited_after)
  end
  local instruction = table.concat({
    "Revise the destination-language baseline minimally so that it reflects only",
    "semantic and structural changes between the edited-side BEFORE and AFTER data.",
    "Preserve destination wording, tone, terminology, and unaffected content.",
    "Return replacement units for the whole mapping group, not a diff and not markup.",
  }, "\n")
  return common.normalized_request(self, task, backend_capabilities, instruction, data, schema())
end

function SemanticPatchJsonV1:decode(raw_response, task, backend_capabilities)
  local valid, task_error = validate_task(task)
  if not valid then
    return nil, task_error
  end
  local value, decode_error = common.decode_json_object(raw_response, backend_capabilities)
  if not value then
    return nil, decode_error
  end
  local fields_ok, fields_error = common.object_fields(
    value,
    { "schema_version", "task_id", "destination_side", "replacement_units", "warnings" },
    TOP_LEVEL_FIELDS,
    "Semantic patch response"
  )
  if not fields_ok then
    return common.invalid(fields_error)
  end
  local expected_side = task.edited_side == "source" and "target" or "source"
  if
    value.schema_version ~= 1
    or value.task_id ~= task.task_id
    or value.destination_side ~= expected_side
    or not common.is_list(value.replacement_units)
    or not common.string_list(value.warnings, true)
  then
    return common.invalid(
      "Semantic patch response has an invalid schema, task ID, destination, or array"
    )
  end

  local edited_ids = {}
  for _, unit in ipairs(task.edited_after.units) do
    edited_ids[unit.unit_id] = true
  end
  local seen_local_ids = {}
  local replacement_texts = {}
  local output_length = 0
  local replacements = json.array()
  for ordinal, replacement in ipairs(value.replacement_units) do
    local replacement_ok, replacement_error = common.object_fields(
      replacement,
      { "local_id", "corresponds_to_edited_unit_ids", "kind", "content_text", "language" },
      REPLACEMENT_FIELDS,
      ("Semantic replacement %d"):format(ordinal)
    )
    if not replacement_ok then
      return common.invalid(replacement_error)
    end
    if
      type(replacement.local_id) ~= "string"
      or replacement.local_id == ""
      or seen_local_ids[replacement.local_id]
      or not common.string_list(replacement.corresponds_to_edited_unit_ids, false)
      or type(replacement.kind) ~= "string"
      or replacement.kind == ""
      or type(replacement.content_text) ~= "string"
      or (replacement.language ~= json.null and type(replacement.language) ~= "string")
    then
      return common.invalid(("Semantic replacement %d has invalid fields"):format(ordinal))
    end
    seen_local_ids[replacement.local_id] = true
    if self.supported_kinds and not self.supported_kinds[replacement.kind] then
      return common.invalid("Semantic replacement kind is not supported by the document adapter")
    end
    local seen_correspondence = {}
    for _, unit_id in ipairs(replacement.corresponds_to_edited_unit_ids) do
      if not edited_ids[unit_id] or seen_correspondence[unit_id] then
        return common.invalid(
          "Semantic replacement references an unknown or duplicate edited unit ID"
        )
      end
      seen_correspondence[unit_id] = true
    end
    local length, length_error = common.utf8_length(replacement.content_text)
    if not length then
      return common.invalid(
        "Semantic replacement contains invalid UTF-8",
        { reason = length_error }
      )
    end
    output_length = output_length + length
    if output_length > self.max_output_chars then
      return common.invalid("Semantic patch exceeds the output character limit")
    end
    replacement_texts[#replacement_texts + 1] = replacement.content_text
    replacements[#replacements + 1] = {
      local_id = replacement.local_id,
      corresponds_to_edited_unit_ids = replacement.corresponds_to_edited_unit_ids,
      kind = replacement.kind,
      content_text = replacement.content_text,
      language = replacement.language == json.null and nil or replacement.language,
    }
  end

  if task.constraints.preserve_placeholders then
    local expected = common.expected_placeholder_counts(task.edited_after.units)
    local actual = common.actual_placeholder_counts(replacement_texts)
    if not common.same_counts(expected, actual) then
      return common.invalid("Semantic patch did not preserve protected placeholders")
    end
  end

  local warnings = json.array()
  for _, warning in ipairs(value.warnings) do
    warnings[#warnings + 1] = warning
  end
  return {
    schema_version = 1,
    task_id = task.task_id,
    destination_side = expected_side,
    replacement_units = replacements,
    warnings = warnings,
    metadata = {},
  }
end

return {
  new = SemanticPatchJsonV1.new,
}
