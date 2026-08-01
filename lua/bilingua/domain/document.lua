local errors = require("bilingua.domain.error")
local hash = require("bilingua.util.hash")
local json = require("bilingua.util.json")

local M = {}

local function copy_list(values)
  local copy = {}
  for index, value in ipairs(values or {}) do
    copy[index] = value
  end
  return copy
end

local function copy_value(value, seen)
  if type(value) ~= "table" then
    return value
  end
  local visited = seen or {}
  if visited[value] then
    error("Document fragment metadata must not contain cycles", 0)
  end
  visited[value] = true
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = copy_value(item, visited)
  end
  visited[value] = nil
  return copy
end

local function copy_tokens(tokens)
  local copy = {}
  for index, token in ipairs(tokens or {}) do
    copy[index] = {
      id = token.id,
      placeholder = token.placeholder,
      literal = token.literal,
      kind = token.kind,
      occurrence = token.occurrence,
    }
  end
  return copy
end

local function fragment_hash(unit_hashes)
  return hash.sha256(json.encode(json.array(copy_list(unit_hashes))))
end

function M.fragment(snapshot, unit_ids)
  if type(snapshot) ~= "table" or type(unit_ids) ~= "table" then
    return nil,
      errors.new(errors.codes.INVALID_ARGUMENT, "A snapshot and unit ID list are required", false)
  end

  local units = {}
  local unit_hashes = {}
  for ordinal, unit_id in ipairs(unit_ids) do
    local unit = snapshot.units[unit_id]
    if not unit then
      return nil,
        errors.new(
          errors.codes.ALIGNMENT,
          "A mapping group references an unknown document unit",
          false,
          { unit_id = unit_id, side = snapshot.side }
        )
    end
    local attributes = copy_value(unit.attributes or {})
    local tokens = copy_tokens(unit.protected_tokens)
    units[#units + 1] = {
      unit_id = unit.id,
      kind = unit.kind,
      language = unit.language,
      content_text = unit.content_text,
      structural_path = copy_list(unit.structural_path),
      attributes = attributes,
      protected_tokens = tokens,
    }
    local digest = {
      unit_id = unit.id,
      kind = unit.kind,
      language = unit.language,
      raw_text = unit.raw_text or json.null,
      content_text = unit.content_text,
      structural_path = json.array(copy_list(unit.structural_path)),
      attributes = attributes,
      protected_tokens = json.array(tokens),
      opaque = unit.opaque == true,
    }
    unit_hashes[ordinal] = hash.sha256(json.encode(digest))
  end

  return {
    side = snapshot.side,
    language = snapshot.language,
    units = units,
    text_hash = fragment_hash(unit_hashes),
    -- Keep composable digests private so merged baselines never retain raw document text.
    _unit_hashes = unit_hashes,
  }
end

function M.combine(fragments)
  if type(fragments) ~= "table" or #fragments == 0 then
    return nil,
      errors.new(errors.codes.INVALID_ARGUMENT, "At least one fragment is required", false)
  end

  local first = fragments[1]
  if type(first) ~= "table" or type(first.side) ~= "string" then
    return nil, errors.new(errors.codes.INVALID_ARGUMENT, "A fragment is malformed", false)
  end
  local units = {}
  local unit_hashes = {}
  for _, fragment in ipairs(fragments) do
    if
      type(fragment) ~= "table"
      or fragment.side ~= first.side
      or fragment.language ~= first.language
      or type(fragment.units) ~= "table"
      or type(fragment._unit_hashes) ~= "table"
      or #fragment.units ~= #fragment._unit_hashes
    then
      return nil,
        errors.new(
          errors.codes.INVALID_ARGUMENT,
          "Only compatible document fragments can be combined",
          false
        )
    end
    for index, unit in ipairs(fragment.units) do
      units[#units + 1] = copy_value(unit)
      unit_hashes[#unit_hashes + 1] = fragment._unit_hashes[index]
    end
  end

  return {
    side = first.side,
    language = first.language,
    units = units,
    text_hash = fragment_hash(unit_hashes),
    _unit_hashes = unit_hashes,
  }
end

return M
