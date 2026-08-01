local document = require("bilingua.domain.document")
local errors = require("bilingua.domain.error")
local hash = require("bilingua.util.hash")
local ranges = require("bilingua.util.ranges")
local protected_tokens = require("bilingua.adapters.document.protected_tokens")

local Markdown = {}
Markdown.__index = Markdown

local SUPPORTED_KINDS = {
  heading = true,
  paragraph = true,
  list_item = true,
}

local function invalid(code, message, details)
  return nil, errors.new(code, message, false, details)
end

local function line_records(text)
  local records = {}
  if text == "" then
    return records
  end
  local start_index = 1
  local row = 0
  while start_index <= #text do
    local newline_index = text:find("\n", start_index, true)
    local raw_finish = newline_index and (newline_index - 1) or #text
    local content_finish = raw_finish
    if content_finish >= start_index and text:sub(content_finish, content_finish) == "\r" then
      content_finish = content_finish - 1
    end
    records[#records + 1] = {
      row = row,
      start_offset = start_index - 1,
      finish_offset = content_finish,
      text = text:sub(start_index, content_finish),
      newline = newline_index and text:sub(content_finish + 1, newline_index) or "",
    }
    if not newline_index then
      break
    end
    start_index = newline_index + 1
    row = row + 1
  end
  return records
end

local function blank(value)
  return value:match("^[ \t]*$") ~= nil
end

local function trim(value)
  return value:match("^[ \t]*(.-)[ \t]*$")
end

local function quote_parts(value)
  local prefix = ""
  local remaining = value
  local depth = 0
  while true do
    local marker = remaining:match("^([ \t]*>[ \t]?)")
    if not marker then
      break
    end
    prefix = prefix .. marker
    remaining = remaining:sub(#marker + 1)
    depth = depth + 1
  end
  return prefix, remaining, depth
end

local function atx_info(value)
  local quote_prefix, remaining, blockquote_depth = quote_parts(value)
  local indentation, hashes, spacing, tail = remaining:match("^([ ]*)(#+)([ \t]+)(.*)$")
  if not hashes or #indentation > 3 or #hashes > 6 then
    return nil
  end
  local body, closing = tail:match("^(.-)([ \t]+#+[ \t]*)$")
  if not body then
    body, closing = tail, ""
  end
  return {
    kind = "heading",
    body = body,
    prefix = quote_prefix .. indentation .. hashes .. spacing,
    suffix = closing,
    attributes = {
      heading_level = #hashes,
      style = "atx",
      blockquote_depth = blockquote_depth,
      indentation = indentation,
    },
  }
end

local function list_info(value)
  local quote_prefix, remaining, blockquote_depth = quote_parts(value)
  local indentation, marker, spacing, body = remaining:match("^([ \t]*)([-+*])([ \t]+)(.*)$")
  local ordered = false
  if not marker then
    indentation, marker, spacing, body = remaining:match("^([ \t]*)(%d+[%.%)])([ \t]+)(.*)$")
    ordered = marker ~= nil
  end
  if not marker then
    return nil
  end
  local indentation_width = #indentation:gsub("\t", "  ")
  return {
    kind = "list_item",
    body = body,
    prefix = quote_prefix .. indentation .. marker .. spacing,
    suffix = "",
    attributes = {
      list_depth = math.floor(indentation_width / 2) + 1,
      list_ordered = ordered,
      list_marker = marker,
      blockquote_depth = blockquote_depth,
      indentation = indentation,
    },
  }
end

local function setext_level(value)
  local compact = value:gsub("[ \t]", "")
  if #compact == 0 then
    return nil
  elseif compact:match("^=+$") then
    return 1
  elseif compact:match("^-+$") and #compact >= 2 then
    return 2
  end
  return nil
end

local function fence_info(value)
  local indentation, fence = value:match("^([ ]*)(`+)")
  local character = "`"
  if not fence then
    indentation, fence = value:match("^([ ]*)(~+)")
    character = "~"
  end
  if not fence or #indentation > 3 or #fence < 3 then
    return nil
  end
  return { character = character, length = #fence }
end

local function closes_fence(value, opening)
  local indentation, fence = value:match("^([ ]*)(" .. opening.character .. "+)[ \t]*$")
  return fence ~= nil and #indentation <= 3 and #fence >= opening.length
end

local function thematic_break(value)
  local compact = value:gsub("[ \t]", "")
  return #compact >= 3
    and (
      compact:match("^%*+$") ~= nil
      or compact:match("^-+$") ~= nil
      or compact:match("^_+$") ~= nil
    )
end

local function table_delimiter(value)
  if not value:find("|", 1, true) then
    return false
  end
  local body = value:gsub("^[ \t]*|", ""):gsub("|[ \t]*$", "")
  local cells = 0
  for cell in (body .. "|"):gmatch("(.-)|") do
    local normalized = trim(cell)
    if not normalized:match("^:?-+:?$") then
      return false
    end
    cells = cells + 1
  end
  return cells > 0
end

local function image_only(value)
  return value:match("^[ \t]*!%b[]%b()[ \t]*$") ~= nil
end

local function reference_definition(value)
  return value:match("^[ \t]*%[[^%]]+%]:[ \t]*") ~= nil
end

local function html_start(value)
  return value:match("^[ \t]*<!%-%-") ~= nil
    or value:match("^[ \t]*</?[%a][^>]*>") ~= nil
    or value:match("^[ \t]*<![%u]") ~= nil
end

local function indented_code(value)
  return value:match("^    ") ~= nil or value:match("^\t") ~= nil
end

local function opaque_block(lines, index)
  local value = lines[index].text
  if index == 1 and (trim(value) == "---" or trim(value) == "+++") then
    local delimiter = trim(value)
    for finish = index + 1, #lines do
      if trim(lines[finish].text) == delimiter then
        return finish, "front_matter", true
      end
    end
    return #lines, "front_matter", false
  end

  local opening = fence_info(value)
  if opening then
    for finish = index + 1, #lines do
      if closes_fence(lines[finish].text, opening) then
        return finish, "fenced_code", true
      end
    end
    return #lines, "fenced_code", false
  end

  if trim(value) == "$$" then
    for finish = index + 1, #lines do
      if trim(lines[finish].text) == "$$" then
        return finish, "math_block", true
      end
    end
    return #lines, "math_block", false
  end

  if indented_code(value) then
    local finish = index
    while
      finish + 1 <= #lines
      and (indented_code(lines[finish + 1].text) or blank(lines[finish + 1].text))
    do
      if
        blank(lines[finish + 1].text)
        and (finish + 2 > #lines or not indented_code(lines[finish + 2].text))
      then
        break
      end
      finish = finish + 1
    end
    return finish, "indented_code", true
  end

  if
    index + 1 <= #lines
    and value:find("|", 1, true)
    and table_delimiter(lines[index + 1].text)
  then
    local finish = index + 1
    while
      finish + 1 <= #lines
      and not blank(lines[finish + 1].text)
      and lines[finish + 1].text:find("|", 1, true)
    do
      finish = finish + 1
    end
    return finish, "table", true
  end

  if html_start(value) then
    local finish = index
    if value:match("<!%-%-") and not value:match("%-%->") then
      while finish + 1 <= #lines do
        finish = finish + 1
        if lines[finish].text:match("%-%->") then
          break
        end
      end
    else
      while finish + 1 <= #lines and not blank(lines[finish + 1].text) do
        finish = finish + 1
      end
    end
    return finish, "html_block", true
  end

  if thematic_break(value) then
    return index, "thematic_break", true
  elseif reference_definition(value) then
    return index, "reference_definition", true
  elseif image_only(value) then
    return index, "image_only", true
  end
  return nil
end

local function starts_new_block(lines, index)
  if index > #lines or blank(lines[index].text) then
    return true
  end
  if opaque_block(lines, index) or atx_info(lines[index].text) or list_info(lines[index].text) then
    return true
  end
  local _, _, quote_depth = quote_parts(lines[index].text)
  if quote_depth > 0 then
    return true
  end
  return index + 1 <= #lines and setext_level(lines[index + 1].text) ~= nil
end

local function normalized_fingerprint(kind, content, sha256)
  local normalized = content:gsub("\r\n", "\n"):gsub("\r", "\n")
  normalized = normalized:gsub("[ \t]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return sha256(kind .. ":" .. normalized)
end

local function unit_id(side, ordinal)
  return ((side == "source" and "src" or "tgt") .. ":u:%06d"):format(ordinal)
end

local function content_lines(value)
  local lines = {}
  local cursor = 1
  while true do
    local first, last = value:find("\r?\n", cursor)
    if not first then
      lines[#lines + 1] = value:sub(cursor)
      break
    end
    lines[#lines + 1] = value:sub(cursor, first - 1)
    cursor = last + 1
  end
  return lines
end

local function render_unit(unit, content)
  local data = unit.adapter_data
  if data.line_prefixes then
    local translated_lines = content_lines(content)
    local rendered = {}
    for index, line in ipairs(translated_lines) do
      rendered[#rendered + 1] = data.line_prefixes[index]
        or data.line_prefixes[#data.line_prefixes]
        or ""
      rendered[#rendered + 1] = line
      if index < #translated_lines then
        rendered[#rendered + 1] = data.line_endings[index] or data.preferred_newline or "\n"
      end
    end
    return table.concat(rendered)
  end
  return (data.prefix or "") .. content .. (data.suffix or "")
end

local function opaque_units(snapshot)
  local result = {}
  for _, id in ipairs(snapshot.order) do
    local unit = snapshot.units[id]
    if unit.opaque then
      result[#result + 1] = unit.raw_text
    end
  end
  return result
end

function Markdown.new(options)
  local resolved = options or {}
  return setmetatable({
    api_version = 1,
    id = "markdown",
    custom_protected_patterns = resolved.protected_patterns or {},
    tree_sitter_analyzer = resolved.tree_sitter_analyzer,
    tree_sitter_required = resolved.tree_sitter_required == true,
    sha256 = type(resolved.sha256) == "function" and resolved.sha256 or hash.sha256,
  }, Markdown)
end

function Markdown:capabilities()
  return {
    incremental_parse = false,
    structural_edits = true,
    protected_tokens = true,
    opaque_mirroring = true,
    build_target = true,
    parser = self.tree_sitter_analyzer and "tree_sitter" or "explicit",
    supported_kinds = SUPPORTED_KINDS,
  }
end

local function requested_endofline(request)
  if type(request.metadata) == "table" and type(request.metadata.endofline) == "boolean" then
    return request.metadata.endofline
  end
  return request.text:sub(-1) == "\n"
end

function Markdown:parse(request)
  if type(request) ~= "table" or (request.side ~= "source" and request.side ~= "target") then
    return invalid(errors.codes.INVALID_ARGUMENT, "Markdown parse requires a valid document side")
  elseif type(request.text) ~= "string" then
    return invalid(errors.codes.INVALID_ARGUMENT, "Markdown parse text must be a string")
  end
  local text = request.text
  local tree_sitter_analysis
  if type(self.tree_sitter_analyzer) == "function" then
    local analyzed, analysis, analysis_error = pcall(self.tree_sitter_analyzer, text)
    if not analyzed or type(analysis) ~= "table" then
      return invalid(errors.codes.PARSE, "Tree-sitter Markdown analysis failed", {
        reason = analyzed and tostring(analysis_error or "analysis unavailable")
          or "analyzer raised an error",
      })
    end
    tree_sitter_analysis = analysis
  elseif self.tree_sitter_required then
    return invalid(errors.codes.PARSE, "Tree-sitter Markdown parser or query is unavailable")
  end
  local lines = line_records(text)
  local blocks = {}
  local index = 1
  while index <= #lines do
    if blank(lines[index].text) then
      index = index + 1
    else
      local first = index
      local finish, opaque_kind, closed = opaque_block(lines, index)
      local descriptor
      if finish then
        descriptor = {
          first = first,
          finish = finish,
          kind = "opaque",
          opaque = true,
          attributes = { opaque_kind = opaque_kind },
          data = { opaque_kind = opaque_kind, closed = closed },
        }
      else
        local info = atx_info(lines[index].text) or list_info(lines[index].text)
        if info then
          finish = index
          descriptor = {
            first = first,
            finish = finish,
            kind = info.kind,
            opaque = false,
            body = info.body,
            attributes = info.attributes,
            data = {
              prefix = info.prefix,
              suffix = info.suffix,
              content_raw = info.body,
              content_relative_start = #info.prefix,
              content_relative_finish = #info.prefix + #info.body,
              body_contiguous = true,
            },
          }
        elseif index + 1 <= #lines and setext_level(lines[index + 1].text) then
          finish = index + 1
          local suffix = lines[index].newline .. lines[index + 1].text
          descriptor = {
            first = first,
            finish = finish,
            kind = "heading",
            opaque = false,
            body = lines[index].text,
            attributes = {
              heading_level = setext_level(lines[index + 1].text),
              style = "setext",
              blockquote_depth = 0,
              indentation = lines[index].text:match("^([ \t]*)") or "",
            },
            data = {
              prefix = "",
              suffix = suffix,
              content_raw = lines[index].text,
              content_relative_start = 0,
              content_relative_finish = #lines[index].text,
              body_contiguous = true,
            },
          }
        else
          local quote_prefix, quote_body, quote_depth = quote_parts(lines[index].text)
          if quote_depth > 0 then
            finish = index
            local bodies = { quote_body }
            local prefixes = { quote_prefix }
            local endings = {}
            while finish + 1 <= #lines and not blank(lines[finish + 1].text) do
              local next_prefix, next_body, next_depth = quote_parts(lines[finish + 1].text)
              if
                next_depth == 0
                or atx_info(lines[finish + 1].text)
                or list_info(lines[finish + 1].text)
              then
                break
              end
              endings[#endings + 1] = lines[finish].newline
              finish = finish + 1
              bodies[#bodies + 1] = next_body
              prefixes[#prefixes + 1] = next_prefix
            end
            local body_parts = {}
            for body_index, body in ipairs(bodies) do
              body_parts[#body_parts + 1] = body
              if endings[body_index] then
                body_parts[#body_parts + 1] = endings[body_index]
              end
            end
            local body = table.concat(body_parts)
            descriptor = {
              first = first,
              finish = finish,
              kind = "paragraph",
              opaque = false,
              body = body,
              attributes = { blockquote_depth = quote_depth, indentation = "" },
              data = {
                line_prefixes = prefixes,
                line_endings = endings,
                preferred_newline = endings[1] or lines[index].newline or "\n",
                content_raw = body,
                body_contiguous = false,
              },
            }
          else
            finish = index
            while
              finish + 1 <= #lines
              and not blank(lines[finish + 1].text)
              and not starts_new_block(lines, finish + 1)
            do
              finish = finish + 1
            end
            local raw_body = text:sub(lines[first].start_offset + 1, lines[finish].finish_offset)
            descriptor = {
              first = first,
              finish = finish,
              kind = "paragraph",
              opaque = false,
              body = raw_body,
              attributes = { blockquote_depth = 0, indentation = "" },
              data = {
                prefix = "",
                suffix = "",
                content_raw = raw_body,
                content_relative_start = 0,
                content_relative_finish = #raw_body,
                body_contiguous = true,
              },
            }
          end
        end
      end
      descriptor.start_offset = lines[first].start_offset
      descriptor.finish_offset = lines[finish].finish_offset
      blocks[#blocks + 1] = descriptor
      index = finish + 1
    end
  end

  local units = {}
  local order = {}
  for ordinal, block in ipairs(blocks) do
    local id = unit_id(request.side, ordinal)
    local raw_text = text:sub(block.start_offset + 1, block.finish_offset)
    local content_text = ""
    local tokens = {}
    if not block.opaque then
      content_text, tokens = protected_tokens.protect(block.body, self.custom_protected_patterns)
    end
    units[id] = {
      id = id,
      kind = block.kind,
      language = request.language or "und",
      span = {
        start = ranges.offset_to_position(text, block.start_offset),
        finish = ranges.offset_to_position(text, block.finish_offset),
      },
      raw_text = raw_text,
      content_text = content_text,
      structural_path = { "document", block.kind },
      fingerprint = block.opaque and self.sha256("opaque:" .. raw_text)
        or normalized_fingerprint(block.kind, content_text, self.sha256),
      protected_tokens = tokens,
      opaque = block.opaque,
      attributes = block.attributes,
      adapter_data = block.data,
    }
    order[#order + 1] = id
  end

  local separators = {}
  for ordinal = 1, #blocks - 1 do
    separators[ordinal] =
      text:sub(blocks[ordinal].finish_offset + 1, blocks[ordinal + 1].start_offset)
  end
  local prefix = blocks[1] and text:sub(1, blocks[1].start_offset) or text
  local suffix = blocks[#blocks] and text:sub(blocks[#blocks].finish_offset + 1) or ""
  return {
    schema_version = 1,
    side = request.side,
    language = request.language or "und",
    filetype = request.filetype or "markdown",
    document_version = request.previous and (request.previous.document_version + 1) or 1,
    editor_version = request.editor_version,
    text_hash = self.sha256(text),
    units = units,
    order = order,
    metadata = {
      endofline = requested_endofline(request),
      parser = tree_sitter_analysis and "tree_sitter" or "explicit",
      tree_sitter_capture_count = tree_sitter_analysis and tree_sitter_analysis.capture_count
        or nil,
    },
    adapter_state = {
      text = text,
      prefix = prefix,
      separators = separators,
      suffix = suffix,
    },
  }
end

function Markdown:extract_fragment(snapshot, unit_ids)
  return document.fragment(snapshot, unit_ids)
end

local function replacement_index(source, result)
  local indexed = {}
  for _, replacement in ipairs(result.replacement_units or {}) do
    local ids = replacement.corresponds_to_edited_unit_ids
    if type(ids) ~= "table" or #ids ~= 1 or indexed[ids[1]] then
      return invalid(
        errors.codes.INVALID_OUTPUT,
        "Initial Markdown translation IDs must occur exactly once"
      )
    end
    local unit = source.units[ids[1]]
    if not unit or unit.opaque then
      return invalid(
        errors.codes.INVALID_OUTPUT,
        "Initial Markdown translation references an unknown or opaque unit"
      )
    end
    indexed[ids[1]] = replacement
  end
  return indexed
end

function Markdown:build_initial_target(request)
  if
    type(request) ~= "table"
    or type(request.source_snapshot) ~= "table"
    or type(request.result) ~= "table"
    or type(request.result.replacement_units) ~= "table"
  then
    return invalid(
      errors.codes.INVALID_ARGUMENT,
      "Initial Markdown target construction requires a snapshot and result"
    )
  end
  local source = request.source_snapshot
  local replacements, index_error = replacement_index(source, request.result)
  if not replacements then
    return nil, index_error
  end
  local rendered = { source.adapter_state.prefix }
  local seeds = {}
  for ordinal, source_id in ipairs(source.order) do
    local unit = source.units[source_id]
    local raw_text
    if unit.opaque then
      raw_text = unit.raw_text
    else
      local replacement = replacements[source_id]
      if not replacement or replacement.kind ~= unit.kind then
        return invalid(
          errors.codes.INVALID_OUTPUT,
          "Initial Markdown translation omitted or changed a unit kind"
        )
      end
      local restored, restore_error =
        protected_tokens.restore(replacement.content_text, unit.protected_tokens)
      if not restored then
        return invalid(errors.codes.INVALID_OUTPUT, restore_error)
      end
      raw_text = render_unit(unit, restored)
    end
    rendered[#rendered + 1] = raw_text
    seeds[#seeds + 1] = {
      source_unit_ids = { source_id },
      target_ordinal = ordinal,
      kind = unit.kind,
      mode = unit.opaque and "mirror" or "translate",
    }
    if source.adapter_state.separators[ordinal] then
      rendered[#rendered + 1] = source.adapter_state.separators[ordinal]
    end
  end
  rendered[#rendered + 1] = source.adapter_state.suffix
  local target_text = table.concat(rendered)
  local target, parse_error = self:parse({
    side = "target",
    text = target_text,
    filetype = source.filetype,
    language = "ja",
    editor_version = 0,
    metadata = source.metadata,
  })
  if not target then
    return nil, parse_error
  end
  if #target.order ~= #source.order then
    return invalid(errors.codes.VALIDATION, "Rendered Markdown changed the document unit count")
  end
  for ordinal, source_id in ipairs(source.order) do
    local source_unit = source.units[source_id]
    local target_unit = target.units[target.order[ordinal]]
    if source_unit.kind ~= target_unit.kind or source_unit.opaque ~= target_unit.opaque then
      return invalid(errors.codes.VALIDATION, "Rendered Markdown changed document structure")
    end
    if source_unit.opaque and source_unit.raw_text ~= target_unit.raw_text then
      return invalid(errors.codes.VALIDATION, "Rendered Markdown changed an opaque block")
    end
  end
  return { text = target_text, seeds = seeds, metadata = { parser = "explicit" } }
end

local function collect_tokens(request, replacement)
  local tokens = {}
  for _, edited_id in ipairs(replacement.corresponds_to_edited_unit_ids or {}) do
    for _, token in
      ipairs(
        request.protected_tokens_by_edited_unit_id
            and request.protected_tokens_by_edited_unit_id[edited_id]
          or {}
      )
    do
      tokens[#tokens + 1] = token
    end
  end
  return tokens
end

local function default_render(kind, content)
  if kind == "heading" then
    return "# " .. content
  elseif kind == "list_item" then
    return "- " .. content
  end
  return content
end

local function deletion_edit(snapshot, units, metadata, sha256)
  local ordinals = {}
  for ordinal, ordered_id in ipairs(snapshot.order) do
    ordinals[ordered_id] = ordinal
  end
  local first_ordinal = ordinals[units[1].id]
  local last_ordinal = ordinals[units[#units].id]
  local range = {
    start = units[1].span.start,
    finish = units[#units].span.finish,
  }
  local following_id = snapshot.order[last_ordinal + 1]
  local previous_id = snapshot.order[first_ordinal - 1]
  if following_id then
    range.finish = snapshot.units[following_id].span.start
  elseif previous_id then
    range.start = snapshot.units[previous_id].span.finish
  end
  local first_offset = ranges.position_to_offset(snapshot.adapter_state.text, range.start)
  local finish_offset = ranges.position_to_offset(snapshot.adapter_state.text, range.finish)
  local expected = snapshot.adapter_state.text:sub(first_offset + 1, finish_offset)
  return {
    {
      range = range,
      replacement = "",
      expected_text = expected,
      expected_hash = sha256(expected),
      metadata = metadata,
    },
  }
end

function Markdown:plan_replace(request)
  if
    type(request) ~= "table"
    or type(request.snapshot) ~= "table"
    or type(request.destination_unit_ids) ~= "table"
    or type(request.replacement_units) ~= "table"
  then
    return invalid(
      errors.codes.INVALID_ARGUMENT,
      "Markdown replacement planning requires a snapshot, IDs, and replacements"
    )
  end
  local snapshot = request.snapshot
  local destinations = {}
  local ordinals = {}
  for ordinal, id in ipairs(snapshot.order) do
    ordinals[id] = ordinal
  end
  for _, id in ipairs(request.destination_unit_ids) do
    local unit = snapshot.units[id]
    if not unit then
      return invalid(errors.codes.ALIGNMENT, "A Markdown destination unit no longer exists")
    elseif unit.opaque then
      return invalid(
        errors.codes.VALIDATION,
        "Opaque Markdown blocks cannot be translation destinations"
      )
    end
    destinations[#destinations + 1] = unit
  end

  if #destinations == 0 then
    local insertion = request.insertion or {}
    local previous = insertion.previous_unit_id and snapshot.units[insertion.previous_unit_id]
      or nil
    local following = insertion.next_unit_id and snapshot.units[insertion.next_unit_id] or nil
    if not previous and not following and #snapshot.order > 0 then
      return invalid(
        errors.codes.STRUCTURE_UNSUPPORTED,
        "Markdown insertion requires a neighboring destination unit"
      )
    end
    local inserted = {}
    for index, replacement in ipairs(request.replacement_units) do
      if not SUPPORTED_KINDS[replacement.kind] or type(replacement.content_text) ~= "string" then
        return invalid(errors.codes.VALIDATION, "Markdown replacement kind is unsupported")
      end
      local restored, restore_error =
        protected_tokens.restore(replacement.content_text, collect_tokens(request, replacement))
      if not restored then
        return invalid(errors.codes.INVALID_OUTPUT, restore_error)
      end
      local edited_id = replacement.corresponds_to_edited_unit_ids
        and replacement.corresponds_to_edited_unit_ids[1]
      local template = request.edited_units_by_id and request.edited_units_by_id[edited_id] or nil
      inserted[index] = template
          and template.kind == replacement.kind
          and render_unit(template, restored)
        or default_render(replacement.kind, restored)
    end
    local separator = "\n\n"
    if insertion.previous_unit_id then
      for ordinal, id in ipairs(snapshot.order) do
        if id == insertion.previous_unit_id then
          separator = snapshot.adapter_state.separators[ordinal] or separator
          break
        end
      end
    end
    local position = following and following.span.start
      or (previous and previous.span.finish or { row = 0, col = 0 })
    local replacement_text = table.concat(inserted, "\n\n")
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
  for index = 2, #destinations do
    if ordinals[destinations[index].id] ~= ordinals[destinations[index - 1].id] + 1 then
      return invalid(errors.codes.VALIDATION, "Markdown destination units must be contiguous")
    end
  end

  if #request.replacement_units == 0 then
    return deletion_edit(snapshot, destinations, {
      destination_unit_ids = request.destination_unit_ids,
      structural = true,
      deletion = true,
    }, self.sha256)
  end

  if #destinations == 1 and #request.replacement_units == 1 then
    local destination = destinations[1]
    local replacement = request.replacement_units[1]
    if replacement.kind == destination.kind and destination.adapter_data.body_contiguous then
      local restored, restore_error =
        protected_tokens.restore(replacement.content_text, collect_tokens(request, replacement))
      if not restored then
        return invalid(errors.codes.INVALID_OUTPUT, restore_error)
      end
      local block_start =
        ranges.position_to_offset(snapshot.adapter_state.text, destination.span.start)
      local first = block_start + destination.adapter_data.content_relative_start
      local finish = block_start + destination.adapter_data.content_relative_finish
      return {
        {
          range = {
            start = ranges.offset_to_position(snapshot.adapter_state.text, first),
            finish = ranges.offset_to_position(snapshot.adapter_state.text, finish),
          },
          replacement = restored,
          expected_text = destination.adapter_data.content_raw,
          expected_hash = self.sha256(destination.adapter_data.content_raw),
          metadata = { destination_unit_ids = { destination.id }, body_only = true },
        },
      }
    end
  end

  local rendered = {}
  for index, replacement in ipairs(request.replacement_units) do
    if not SUPPORTED_KINDS[replacement.kind] or type(replacement.content_text) ~= "string" then
      return invalid(errors.codes.VALIDATION, "Markdown replacement kind is unsupported")
    end
    local restored, restore_error =
      protected_tokens.restore(replacement.content_text, collect_tokens(request, replacement))
    if not restored then
      return invalid(errors.codes.INVALID_OUTPUT, restore_error)
    end
    local template = destinations[index]
    if not template or template.kind ~= replacement.kind then
      local edited_id = replacement.corresponds_to_edited_unit_ids
        and replacement.corresponds_to_edited_unit_ids[1]
      template = request.edited_units_by_id and request.edited_units_by_id[edited_id] or nil
    end
    rendered[#rendered + 1] = template
        and template.kind == replacement.kind
        and render_unit(template, restored)
      or default_render(replacement.kind, restored)
  end
  local separator = "\n\n"
  local first_ordinal = ordinals[destinations[1].id]
  if #destinations > 1 and snapshot.adapter_state.separators[first_ordinal] then
    separator = snapshot.adapter_state.separators[first_ordinal]
  end
  local first_offset =
    ranges.position_to_offset(snapshot.adapter_state.text, destinations[1].span.start)
  local finish_offset =
    ranges.position_to_offset(snapshot.adapter_state.text, destinations[#destinations].span.finish)
  local expected = snapshot.adapter_state.text:sub(first_offset + 1, finish_offset)
  return {
    {
      range = {
        start = destinations[1].span.start,
        finish = destinations[#destinations].span.finish,
      },
      replacement = table.concat(rendered, separator),
      expected_text = expected,
      expected_hash = self.sha256(expected),
      metadata = { destination_unit_ids = request.destination_unit_ids, structural = true },
    },
  }
end

local function ordered_units(snapshot, unit_ids)
  local ordinals = {}
  for ordinal, current_unit_id in ipairs(snapshot.order) do
    ordinals[current_unit_id] = ordinal
  end
  local units = {}
  for _, current_unit_id in ipairs(unit_ids) do
    local unit = snapshot.units[current_unit_id]
    if not unit or not unit.opaque then
      return nil,
        errors.new(
          errors.codes.VALIDATION,
          "Mirror synchronization requires opaque Markdown units",
          false
        )
    end
    units[#units + 1] = unit
  end
  for index = 2, #units do
    if ordinals[units[index].id] ~= ordinals[units[index - 1].id] + 1 then
      return nil,
        errors.new(errors.codes.VALIDATION, "Mirrored Markdown units must be contiguous", false)
    end
  end
  return units
end

local function exact_unit_range(snapshot, units)
  if #units == 0 then
    return ""
  end
  local first = ranges.position_to_offset(snapshot.adapter_state.text, units[1].span.start)
  local finish = ranges.position_to_offset(snapshot.adapter_state.text, units[#units].span.finish)
  return snapshot.adapter_state.text:sub(first + 1, finish)
end

function Markdown:plan_mirror(request)
  if
    type(request) ~= "table"
    or type(request.edited_snapshot) ~= "table"
    or type(request.destination_snapshot) ~= "table"
    or type(request.edited_unit_ids) ~= "table"
    or type(request.destination_unit_ids) ~= "table"
  then
    return invalid(
      errors.codes.INVALID_ARGUMENT,
      "Markdown mirror planning requires two snapshots and unit IDs"
    )
  end
  local edited_units, edited_error = ordered_units(request.edited_snapshot, request.edited_unit_ids)
  if not edited_units then
    return nil, edited_error
  end
  local destinations, destination_error =
    ordered_units(request.destination_snapshot, request.destination_unit_ids)
  if not destinations then
    return nil, destination_error
  end
  local replacement = exact_unit_range(request.edited_snapshot, edited_units)

  if #destinations == 0 then
    if replacement == "" then
      return {}
    end
    local insertion = request.insertion or {}
    local previous = insertion.previous_unit_id
        and request.destination_snapshot.units[insertion.previous_unit_id]
      or nil
    local following = insertion.next_unit_id
        and request.destination_snapshot.units[insertion.next_unit_id]
      or nil
    if not previous and not following and #request.destination_snapshot.order > 0 then
      return invalid(
        errors.codes.STRUCTURE_UNSUPPORTED,
        "Opaque Markdown insertion requires a neighbor"
      )
    end
    local separator = "\n\n"
    if following then
      replacement = replacement .. separator
    elseif previous then
      replacement = separator .. replacement
    end
    local position = following and following.span.start
      or (previous and previous.span.finish or { row = 0, col = 0 })
    return {
      {
        range = { start = position, finish = position },
        replacement = replacement,
        expected_text = "",
        expected_hash = self.sha256(""),
        metadata = { mirror = true, structural = true },
      },
    }
  end

  if replacement == "" then
    return deletion_edit(request.destination_snapshot, destinations, {
      mirror = true,
      structural = true,
      deletion = true,
    }, self.sha256)
  end

  local expected = exact_unit_range(request.destination_snapshot, destinations)
  return {
    {
      range = {
        start = destinations[1].span.start,
        finish = destinations[#destinations].span.finish,
      },
      replacement = replacement,
      expected_text = expected,
      expected_hash = self.sha256(expected),
      metadata = { mirror = true, structural = #edited_units ~= #destinations },
    },
  }
end

function Markdown:validate_edits(request)
  if
    type(request) ~= "table"
    or type(request.snapshot) ~= "table"
    or type(request.edits) ~= "table"
  then
    return invalid(
      errors.codes.INVALID_ARGUMENT,
      "Markdown edit validation requires a snapshot and edits"
    )
  end
  local snapshot = request.snapshot
  local text = snapshot.adapter_state.text
  local checked = {}
  for index, edit in ipairs(request.edits) do
    local offsets_ok, first, finish = pcall(function()
      return ranges.position_to_offset(text, edit.range.start),
        ranges.position_to_offset(text, edit.range.finish)
    end)
    if not offsets_ok or first > finish or text:sub(first + 1, finish) ~= edit.expected_text then
      return invalid(errors.codes.VALIDATION, "Markdown edit range no longer matches expected text")
    elseif type(edit.replacement) ~= "string" or edit.replacement:find("⟦BIL:", 1, true) then
      return invalid(
        errors.codes.VALIDATION,
        "Markdown edit contains an unrestored protected placeholder"
      )
    end
    for _, snapshot_unit_id in ipairs(snapshot.order) do
      local unit = snapshot.units[snapshot_unit_id]
      if unit.opaque then
        local opaque_first = ranges.position_to_offset(text, unit.span.start)
        local opaque_finish = ranges.position_to_offset(text, unit.span.finish)
        if not request.mirror and first < opaque_finish and finish > opaque_first then
          return invalid(errors.codes.VALIDATION, "Markdown edit overlaps an opaque block")
        end
      end
    end
    checked[index] = { first = first, finish = finish, replacement = edit.replacement }
  end
  table.sort(checked, function(left, right)
    return left.first < right.first
  end)
  for index = 2, #checked do
    if checked[index].first < checked[index - 1].finish then
      return invalid(errors.codes.VALIDATION, "Markdown edit ranges overlap")
    end
  end
  for index = #checked, 1, -1 do
    local edit = checked[index]
    text = text:sub(1, edit.first) .. edit.replacement .. text:sub(edit.finish + 1)
  end
  local parsed, parse_error = self:parse({
    side = snapshot.side,
    text = text,
    filetype = snapshot.filetype,
    language = snapshot.language,
    editor_version = snapshot.editor_version,
    previous = snapshot,
    metadata = snapshot.metadata,
  })
  if not parsed then
    return nil, parse_error
  end
  if not request.mirror then
    local before_opaque = opaque_units(snapshot)
    local after_opaque = opaque_units(parsed)
    if #before_opaque ~= #after_opaque then
      return invalid(errors.codes.VALIDATION, "Markdown edit changed opaque block structure")
    end
    for index, raw_text in ipairs(before_opaque) do
      if after_opaque[index] ~= raw_text then
        return invalid(errors.codes.VALIDATION, "Markdown edit changed an opaque block")
      end
    end
  end
  for _, parsed_unit_id in ipairs(parsed.order) do
    local unit = parsed.units[parsed_unit_id]
    if not unit.opaque and not SUPPORTED_KINDS[unit.kind] then
      return invalid(errors.codes.VALIDATION, "Markdown edit produced an unsupported unit kind")
    elseif unit.opaque and unit.adapter_data.closed == false then
      return invalid(errors.codes.VALIDATION, "Markdown edit produced an unterminated opaque block")
    end
  end
  return { ok = true, text = text, snapshot = parsed }
end

return {
  new = Markdown.new,
}
