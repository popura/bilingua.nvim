local hash = require("bilingua.util.hash")
local document = require("bilingua.domain.document")
local protected_tokens = require("bilingua.adapters.document.protected_tokens")
local ranges = require("bilingua.util.ranges")

local Plaintext = {}
Plaintext.__index = Plaintext

local function line_records(text)
  local records = {}
  local row = 0
  local start_offset = 0

  while true do
    local newline = text:find("\n", start_offset + 1, true)
    local finish_offset = newline and (newline - 1) or #text
    records[#records + 1] = {
      row = row,
      start_offset = start_offset,
      finish_offset = finish_offset,
      text = text:sub(start_offset + 1, finish_offset),
    }

    if not newline then
      break
    end
    start_offset = newline
    row = row + 1
  end

  return records
end

local function is_blank(line, whitespace_is_blank)
  if whitespace_is_blank then
    return line:match("^%s*$") ~= nil
  end
  return line == ""
end

local function normalized_fingerprint(text, sha256)
  local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  normalized = normalized:gsub("[ \t]+\n", "\n"):gsub("[ \t]+$", "")
  normalized = normalized:gsub("[ \t\v\f]+", " ")
  return sha256(normalized)
end

local function unit_id(side, ordinal)
  local prefix = side == "source" and "src" or "tgt"
  return ("%s:u:%06d"):format(prefix, ordinal)
end

local function requested_endofline(request)
  if type(request.metadata) == "table" and type(request.metadata.endofline) == "boolean" then
    return request.metadata.endofline
  end
  return request.text:sub(-1) == "\n"
end

function Plaintext.new(options)
  local resolved = options or {}
  return setmetatable({
    api_version = 1,
    id = "plaintext",
    whitespace_is_blank = resolved.whitespace_is_blank ~= false,
    custom_protected_patterns = resolved.protected_patterns or {},
    sha256 = type(resolved.sha256) == "function" and resolved.sha256 or hash.sha256,
  }, Plaintext)
end

function Plaintext:capabilities()
  return {
    incremental_parse = false,
    structural_edits = true,
    protected_tokens = true,
    build_target = true,
    supported_kinds = { paragraph = true },
  }
end

function Plaintext:parse(request)
  if type(request) ~= "table" or (request.side ~= "source" and request.side ~= "target") then
    error("parse request must contain a valid side", 2)
  end
  if type(request.text) ~= "string" then
    error("parse request text must be a string", 2)
  end

  local records = line_records(request.text)
  local units = {}
  local order = {}
  local unit_ranges = {}
  local index = 1

  while index <= #records do
    while index <= #records and is_blank(records[index].text, self.whitespace_is_blank) do
      index = index + 1
    end
    if index > #records then
      break
    end

    local first = records[index]
    local last = first
    while index <= #records and not is_blank(records[index].text, self.whitespace_is_blank) do
      last = records[index]
      index = index + 1
    end

    unit_ranges[#unit_ranges + 1] = {
      start_offset = first.start_offset,
      finish_offset = last.finish_offset,
      start_row = first.row,
      finish_row = last.row,
      finish_col = #last.text,
    }
  end

  local separators = {}
  for ordinal, range in ipairs(unit_ranges) do
    local id = unit_id(request.side, ordinal)
    local raw_text = request.text:sub(range.start_offset + 1, range.finish_offset)
    local content_text, tokens = protected_tokens.protect(raw_text, self.custom_protected_patterns)
    units[id] = {
      id = id,
      kind = "paragraph",
      language = request.language or "und",
      span = {
        start = { row = range.start_row, col = 0 },
        finish = { row = range.finish_row, col = range.finish_col },
      },
      raw_text = raw_text,
      content_text = content_text,
      structural_path = { "document", "paragraph" },
      fingerprint = normalized_fingerprint(content_text, self.sha256),
      protected_tokens = tokens,
      opaque = false,
      attributes = {},
      adapter_data = {},
    }
    order[#order + 1] = id

    local next_range = unit_ranges[ordinal + 1]
    if next_range then
      separators[#separators + 1] =
        request.text:sub(range.finish_offset + 1, next_range.start_offset)
    end
  end

  local prefix = unit_ranges[1] and request.text:sub(1, unit_ranges[1].start_offset) or request.text
  local suffix = ""
  if unit_ranges[#unit_ranges] then
    suffix = request.text:sub(unit_ranges[#unit_ranges].finish_offset + 1)
  end

  return {
    schema_version = 1,
    side = request.side,
    language = request.language or "und",
    filetype = request.filetype or "text",
    document_version = request.previous and (request.previous.document_version + 1) or 1,
    editor_version = request.editor_version,
    text_hash = self.sha256(request.text),
    units = units,
    order = order,
    metadata = { endofline = requested_endofline(request) },
    adapter_state = {
      text = request.text,
      prefix = prefix,
      separators = separators,
      suffix = suffix,
    },
  }
end

function Plaintext:extract_fragment(snapshot, unit_ids)
  return document.fragment(snapshot, unit_ids)
end

function Plaintext:build_initial_target(request)
  local source = request and request.source_snapshot
  local result = request and request.result
  if
    type(source) ~= "table"
    or type(result) ~= "table"
    or type(result.replacement_units) ~= "table"
  then
    return nil,
      {
        code = "E_INVALID_ARGUMENT",
        message = "Initial target construction requires a source snapshot and replacement units",
        retryable = false,
      }
  end

  local replacements = {}
  for _, replacement in ipairs(result.replacement_units) do
    local source_ids = replacement.corresponds_to_edited_unit_ids
    if type(source_ids) ~= "table" or #source_ids ~= 1 or replacements[source_ids[1]] then
      return nil,
        {
          code = "E_INVALID_OUTPUT",
          message = "Initial translation unit IDs must match source units exactly once",
          retryable = false,
        }
    end
    replacements[source_ids[1]] = replacement
  end

  local rendered = { source.adapter_state.prefix }
  local seeds = {}
  for ordinal, source_id in ipairs(source.order) do
    local source_unit = source.units[source_id]
    local raw_text
    if source_unit.opaque then
      raw_text = source_unit.raw_text
    else
      local replacement = replacements[source_id]
      if not replacement then
        return nil,
          {
            code = "E_INVALID_OUTPUT",
            message = "Initial translation omitted a source unit",
            retryable = false,
          }
      end
      local restore_error
      raw_text, restore_error =
        protected_tokens.restore(replacement.content_text, source_unit.protected_tokens)
      if not raw_text then
        return nil,
          {
            code = "E_INVALID_OUTPUT",
            message = restore_error,
            retryable = false,
          }
      end
    end

    rendered[#rendered + 1] = raw_text
    seeds[#seeds + 1] = {
      source_unit_ids = { source_id },
      target_ordinal = ordinal,
      kind = source_unit.kind,
    }
    if source.adapter_state.separators[ordinal] then
      rendered[#rendered + 1] = source.adapter_state.separators[ordinal]
    end
  end
  rendered[#rendered + 1] = source.adapter_state.suffix

  return {
    text = table.concat(rendered),
    seeds = seeds,
    metadata = {},
  }
end

local function render_replacement(request, replacement)
  if
    type(replacement) ~= "table"
    or replacement.kind ~= "paragraph"
    or type(replacement.content_text) ~= "string"
  then
    return nil, "Plaintext replacements must be paragraphs"
  end
  local tokens = {}
  for _, edited_id in ipairs(replacement.corresponds_to_edited_unit_ids or {}) do
    local unit_tokens = request.protected_tokens_by_edited_unit_id
      and request.protected_tokens_by_edited_unit_id[edited_id]
    for _, token in ipairs(unit_tokens or {}) do
      tokens[#tokens + 1] = token
    end
  end
  return protected_tokens.restore(replacement.content_text, tokens)
end

local function insertion_separator(snapshot, previous_id)
  local previous_ordinal
  for ordinal, id in ipairs(snapshot.order) do
    if id == previous_id then
      previous_ordinal = ordinal
      break
    end
  end
  return previous_ordinal and snapshot.adapter_state.separators[previous_ordinal] or "\n\n"
end

function Plaintext:plan_replace(request)
  if
    type(request) ~= "table"
    or type(request.snapshot) ~= "table"
    or type(request.destination_unit_ids) ~= "table"
    or type(request.replacement_units) ~= "table"
  then
    return nil,
      {
        code = "E_INVALID_ARGUMENT",
        message = "Replacement planning requires a snapshot, destination IDs, and replacement units",
        retryable = false,
      }
  end

  local rendered = {}
  for index, replacement in ipairs(request.replacement_units) do
    local text, render_error = render_replacement(request, replacement)
    if not text then
      return nil,
        {
          code = replacement.kind == "paragraph" and "E_INVALID_OUTPUT" or "E_VALIDATION",
          message = render_error,
          retryable = false,
        }
    end
    rendered[index] = text
  end

  if #request.destination_unit_ids == 0 then
    local insertion = request.insertion or {}
    local previous = insertion.previous_unit_id
        and request.snapshot.units[insertion.previous_unit_id]
      or nil
    local following = insertion.next_unit_id and request.snapshot.units[insertion.next_unit_id]
      or nil
    if not previous and not following and #request.snapshot.order > 0 then
      return nil,
        {
          code = "E_STRUCTURE_UNSUPPORTED",
          message = "Plaintext insertion requires a neighboring destination unit",
          retryable = false,
        }
    end
    local separator = insertion_separator(request.snapshot, insertion.previous_unit_id)
    local position = following and following.span.start
      or (previous and previous.span.finish or { row = 0, col = 0 })
    local replacement_text = table.concat(rendered, "\n\n")
    if following then
      replacement_text = replacement_text .. separator
    elseif previous then
      replacement_text = separator .. replacement_text
    end
    return {
      {
        range = { start = position, finish = position },
        replacement = replacement_text,
        expected_text = "",
        expected_hash = self.sha256(""),
        metadata = { structural = true, insertion = true },
      },
    }
  end

  local destination = request.snapshot.units[request.destination_unit_ids[1]]
  if not destination then
    return nil,
      {
        code = "E_ALIGNMENT",
        message = "The destination unit no longer exists",
        retryable = false,
      }
  end

  local ordinals = {}
  for ordinal, id in ipairs(request.snapshot.order) do
    ordinals[id] = ordinal
  end
  local last
  for index, id in ipairs(request.destination_unit_ids) do
    local unit = request.snapshot.units[id]
    if not unit then
      return nil,
        {
          code = "E_ALIGNMENT",
          message = "A plaintext destination unit no longer exists",
          retryable = false,
        }
    elseif index > 1 and ordinals[id] ~= ordinals[request.destination_unit_ids[index - 1]] + 1 then
      return nil,
        {
          code = "E_VALIDATION",
          message = "Plaintext destination units must be contiguous",
          retryable = false,
        }
    end
    last = unit
  end

  if #request.replacement_units == 0 then
    local first_ordinal = ordinals[destination.id]
    local last_ordinal = ordinals[last.id]
    local range = {
      start = destination.span.start,
      finish = last.span.finish,
    }
    local following_id = request.snapshot.order[last_ordinal + 1]
    local previous_id = request.snapshot.order[first_ordinal - 1]
    if following_id then
      range.finish = request.snapshot.units[following_id].span.start
    elseif previous_id then
      range.start = request.snapshot.units[previous_id].span.finish
    end
    local first_offset = ranges.position_to_offset(request.snapshot.adapter_state.text, range.start)
    local finish_offset =
      ranges.position_to_offset(request.snapshot.adapter_state.text, range.finish)
    local expected = request.snapshot.adapter_state.text:sub(first_offset + 1, finish_offset)
    return {
      {
        range = range,
        replacement = "",
        expected_text = expected,
        expected_hash = self.sha256(expected),
        metadata = {
          destination_unit_ids = request.destination_unit_ids,
          structural = true,
          deletion = true,
        },
      },
    }
  end

  if #request.destination_unit_ids == 1 and #request.replacement_units == 1 then
    return {
      {
        range = destination.span,
        replacement = rendered[1],
        expected_text = destination.raw_text,
        expected_hash = self.sha256(destination.raw_text),
        metadata = { destination_unit_ids = { destination.id } },
      },
    }
  end

  local first_offset =
    ranges.position_to_offset(request.snapshot.adapter_state.text, destination.span.start)
  local finish_offset =
    ranges.position_to_offset(request.snapshot.adapter_state.text, last.span.finish)
  local expected = request.snapshot.adapter_state.text:sub(first_offset + 1, finish_offset)
  local separator = request.snapshot.adapter_state.separators[ordinals[destination.id]] or "\n\n"
  if #request.destination_unit_ids == 1 then
    separator = "\n\n"
  end
  return {
    {
      range = { start = destination.span.start, finish = last.span.finish },
      replacement = table.concat(rendered, separator),
      expected_text = expected,
      expected_hash = self.sha256(expected),
      metadata = { destination_unit_ids = request.destination_unit_ids, structural = true },
    },
  }
end

function Plaintext:validate_edits(request)
  if
    type(request) ~= "table"
    or type(request.snapshot) ~= "table"
    or type(request.edits) ~= "table"
  then
    return nil,
      {
        code = "E_INVALID_ARGUMENT",
        message = "Edit validation requires a snapshot and edits",
        retryable = false,
      }
  end

  local text = request.snapshot.adapter_state.text
  local checked = {}
  for index, edit in ipairs(request.edits) do
    local ok, first, finish = pcall(function()
      return ranges.position_to_offset(text, edit.range.start),
        ranges.position_to_offset(text, edit.range.finish)
    end)
    if not ok or first > finish then
      return nil,
        {
          code = "E_VALIDATION",
          message = "A replacement range is invalid",
          retryable = false,
        }
    end
    if text:sub(first + 1, finish) ~= edit.expected_text then
      return nil,
        {
          code = "E_VALIDATION",
          message = "Expected replacement text no longer matches the document",
          retryable = false,
        }
    end
    if edit.replacement:find("⟦BIL:", 1, true) then
      return nil,
        {
          code = "E_VALIDATION",
          message = "A protected placeholder was not restored",
          retryable = false,
        }
    end
    checked[index] = {
      first = first,
      finish = finish,
      replacement = edit.replacement,
    }
  end

  table.sort(checked, function(left, right)
    return left.first < right.first
  end)
  for index = 2, #checked do
    if checked[index].first < checked[index - 1].finish then
      return nil,
        {
          code = "E_VALIDATION",
          message = "Replacement ranges overlap",
          retryable = false,
        }
    end
  end

  for index = #checked, 1, -1 do
    local edit = checked[index]
    text = text:sub(1, edit.first) .. edit.replacement .. text:sub(edit.finish + 1)
  end

  local parsed, parse_error = self:parse({
    side = request.snapshot.side,
    text = text,
    filetype = request.snapshot.filetype,
    language = request.snapshot.language,
    editor_version = request.snapshot.editor_version,
    previous = request.snapshot,
    metadata = request.snapshot.metadata,
  })
  if not parsed then
    return nil, parse_error
  end

  return {
    ok = true,
    text = text,
    snapshot = parsed,
  }
end

return {
  new = Plaintext.new,
}
