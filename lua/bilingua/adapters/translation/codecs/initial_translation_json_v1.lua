local json = require("bilingua.util.json")
local common = require("bilingua.adapters.translation.codecs.common")

local InitialTranslationJsonV1 = {}
InitialTranslationJsonV1.__index = InitialTranslationJsonV1

local TOP_LEVEL_FIELDS = {
  schema_version = true,
  task_id = true,
  translations = true,
}

local TRANSLATION_FIELDS = {
  source_unit_id = true,
  source_language = true,
  translated_text = true,
  warnings = true,
}

local function schema()
  return {
    type = "object",
    properties = {
      schema_version = { const = 1 },
      task_id = { type = "string" },
      translations = {
        type = "array",
        items = {
          type = "object",
          properties = {
            source_unit_id = { type = "string" },
            source_language = { type = "string" },
            translated_text = { type = "string" },
            warnings = { type = "array", items = { type = "string" } },
          },
          required = { "source_unit_id", "source_language", "translated_text", "warnings" },
          additionalProperties = false,
        },
      },
    },
    required = { "schema_version", "task_id", "translations" },
    additionalProperties = false,
  }
end

local function allowed_languages(values)
  if values == nil then
    return nil
  end
  local indexed = {}
  for _, value in ipairs(values) do
    indexed[value:lower()] = true
  end
  indexed.und = true
  indexed.mul = true
  return indexed
end

function InitialTranslationJsonV1.new(options)
  local resolved = options or {}
  return setmetatable({
    api_version = 1,
    id = "initial_translation_json_v1",
    max_input_chars = resolved.max_input_chars,
    max_output_chars = resolved.max_output_chars or 24000,
    timeout_ms = resolved.timeout_ms,
    allowed_source_languages = allowed_languages(resolved.allowed_source_languages),
  }, InitialTranslationJsonV1)
end

function InitialTranslationJsonV1:response_schema(_)
  return schema()
end

local function validate_task(task)
  if
    type(task) ~= "table"
    or task.schema_version ~= 1
    or type(task.task_id) ~= "string"
    or task.task_id == ""
    or task.kind ~= "initial_translate"
    or task.direction ~= "source_to_target"
    or type(task.source_language) ~= "string"
    or type(task.target_language) ~= "string"
    or type(task.edited_after) ~= "table"
    or not common.task_list(task.edited_after.units)
  then
    return common.invalid_argument("Initial translation task is malformed")
  end
  for _, unit in ipairs(task.edited_after.units) do
    if
      type(unit) ~= "table"
      or type(unit.unit_id) ~= "string"
      or unit.unit_id == ""
      or type(unit.kind) ~= "string"
      or type(unit.content_text) ~= "string"
      or not common.task_string_list(unit.structural_path or {})
      or type(unit.protected_tokens or {}) ~= "table"
    then
      return common.invalid_argument("Initial translation task contains a malformed unit")
    end
  end
  return true
end

function InitialTranslationJsonV1:encode(task, backend_capabilities)
  local valid, task_error = validate_task(task)
  if not valid then
    return nil, task_error
  end
  local units = json.array()
  for _, unit in ipairs(task.edited_after.units) do
    units[#units + 1] = {
      source_unit_id = unit.unit_id,
      kind = unit.kind,
      text = unit.content_text,
      structural_path = json.array(unit.structural_path or {}),
      protected_placeholders = json.array(common.placeholders_from_unit(unit)),
    }
  end
  local document_data = {
    task_id = task.task_id,
    source_language = task.source_language,
    target_language = task.target_language,
    units = units,
    context = {
      document_title = task.metadata and task.metadata.document_title or json.null,
    },
  }
  local instruction = table.concat({
    "Translate every DOCUMENT_DATA unit into the target language.",
    "Do not add, delete, or reorder units. Return each source_unit_id exactly once.",
    "Return content text only, without document-level Markdown wrappers.",
    "Preserve every protected placeholder exactly. If source_language is auto,",
    "return a BCP-47-like source language for each unit.",
  }, "\n")
  return common.normalized_request(
    self,
    task,
    backend_capabilities,
    instruction,
    document_data,
    schema()
  )
end

local function document_language(source_languages, source_units)
  local weights = {}
  local distinct = 0
  for _, unit in ipairs(source_units) do
    local language = source_languages[unit.unit_id]
    local length = common.utf8_length(unit.content_text) or 0
    if language ~= "und" then
      if weights[language] == nil then
        weights[language] = 0
        distinct = distinct + 1
      end
      weights[language] = weights[language] + length
    end
  end
  if distinct == 0 then
    return "und"
  elseif distinct == 1 then
    return next(weights)
  end
  local total = 0
  for _, weight in pairs(weights) do
    total = total + weight
  end
  for language, weight in pairs(weights) do
    if total > 0 and weight / total >= 0.8 then
      return language
    end
  end
  return "mul"
end

function InitialTranslationJsonV1:decode(raw_response, task, backend_capabilities)
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
    { "schema_version", "task_id", "translations" },
    TOP_LEVEL_FIELDS,
    "Initial translation response"
  )
  if not fields_ok then
    return common.invalid(fields_error)
  end
  if
    value.schema_version ~= 1
    or value.task_id ~= task.task_id
    or not common.is_list(value.translations)
  then
    return common.invalid(
      "Initial translation response has an invalid schema version, task ID, or translations array"
    )
  end
  if #value.translations ~= #task.edited_after.units then
    return common.invalid("Initial translation count does not match the input unit count")
  end

  local source_units = {}
  for _, unit in ipairs(task.edited_after.units) do
    if source_units[unit.unit_id] then
      return common.invalid_argument("Initial translation task contains duplicate unit IDs")
    end
    source_units[unit.unit_id] = unit
  end

  local seen = {}
  local source_languages = {}
  local replacements = json.array()
  local aggregate_warnings = json.array()
  local output_length = 0
  for ordinal, translation in ipairs(value.translations) do
    local translation_ok, translation_error = common.object_fields(
      translation,
      { "source_unit_id", "source_language", "translated_text", "warnings" },
      TRANSLATION_FIELDS,
      ("Initial translation %d"):format(ordinal)
    )
    if not translation_ok then
      return common.invalid(translation_error)
    end
    if
      type(translation.source_unit_id) ~= "string"
      or type(translation.source_language) ~= "string"
      or translation.source_language == ""
      or type(translation.translated_text) ~= "string"
      or not common.string_list(translation.warnings, true)
    then
      return common.invalid(("Initial translation %d has invalid field types"):format(ordinal))
    end
    local source_unit = source_units[translation.source_unit_id]
    if not source_unit or seen[translation.source_unit_id] then
      return common.invalid("Initial translation IDs must match input IDs exactly once")
    end
    seen[translation.source_unit_id] = true

    local language = task.source_language
    if language == "auto" then
      language = translation.source_language
      local language_allowed = not self.allowed_source_languages
        or self.allowed_source_languages[language:lower()]
      if not common.valid_language(language) or not language_allowed then
        language = "und"
        aggregate_warnings[#aggregate_warnings + 1] = ("Invalid source language for %s normalized to und"):format(
          translation.source_unit_id
        )
      end
    end
    source_languages[translation.source_unit_id] = language

    local expected = common.expected_placeholder_counts({ source_unit })
    local actual = common.actual_placeholder_counts({ translation.translated_text })
    if not common.same_counts(expected, actual) then
      return common.invalid("Initial translation did not preserve protected placeholders")
    end
    local length, length_error = common.utf8_length(translation.translated_text)
    if not length then
      return common.invalid("Initial translation contains invalid UTF-8", { reason = length_error })
    end
    output_length = output_length + length
    if output_length > self.max_output_chars then
      return common.invalid("Initial translation exceeds the output character limit")
    end

    for _, warning in ipairs(translation.warnings) do
      aggregate_warnings[#aggregate_warnings + 1] = warning
    end
    replacements[#replacements + 1] = {
      local_id = ("translation:%d"):format(ordinal),
      corresponds_to_edited_unit_ids = { translation.source_unit_id },
      kind = source_unit.kind,
      content_text = translation.translated_text,
      language = task.target_language,
    }
  end

  return {
    schema_version = 1,
    task_id = task.task_id,
    destination_side = "target",
    replacement_units = replacements,
    warnings = aggregate_warnings,
    metadata = {
      source_languages = source_languages,
      document_source_language = document_language(source_languages, task.edited_after.units),
    },
  }
end

return {
  new = InitialTranslationJsonV1.new,
}
