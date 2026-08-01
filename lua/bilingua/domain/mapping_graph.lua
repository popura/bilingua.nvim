local errors = require("bilingua.domain.error")

local Graph = {}
Graph.__index = Graph

local function copy_list(values)
  local copy = {}
  for index, value in ipairs(values) do
    copy[index] = value
  end
  return copy
end

local function index_units(groups, order, side)
  local index = {}
  local field = side .. "_unit_ids"

  for _, group_id in ipairs(order) do
    for _, unit_id in ipairs(groups[group_id][field]) do
      if index[unit_id] then
        return nil,
          errors.new(
            errors.codes.ALIGNMENT,
            ("%s unit belongs to more than one mapping group"):format(side),
            false,
            { unit_id = unit_id }
          )
      end
      index[unit_id] = { group_id }
    end
  end

  return index
end

function Graph.new(group_list, revision)
  if type(group_list) ~= "table" then
    return nil, errors.new(errors.codes.INVALID_ARGUMENT, "Mapping groups must be a table", false)
  end

  local groups = {}
  local order = {}
  for _, candidate in ipairs(group_list) do
    if type(candidate) ~= "table" or type(candidate.id) ~= "string" or candidate.id == "" then
      return nil,
        errors.new(errors.codes.INVALID_ARGUMENT, "Every mapping group requires an ID", false)
    end
    if groups[candidate.id] then
      return nil, errors.new(errors.codes.ALIGNMENT, "Mapping group IDs must be unique", false)
    end
    if type(candidate.source_unit_ids) ~= "table" or type(candidate.target_unit_ids) ~= "table" then
      return nil,
        errors.new(errors.codes.INVALID_ARGUMENT, "Mapping group memberships must be lists", false)
    end
    if #candidate.source_unit_ids == 0 and #candidate.target_unit_ids == 0 then
      return nil,
        errors.new(errors.codes.ALIGNMENT, "A mapping group cannot be empty on both sides", false)
    end

    groups[candidate.id] = {
      id = candidate.id,
      source_unit_ids = copy_list(candidate.source_unit_ids),
      target_unit_ids = copy_list(candidate.target_unit_ids),
      baseline = candidate.baseline,
      state = candidate.state,
      source_revision = candidate.source_revision or 0,
      target_revision = candidate.target_revision or 0,
      baseline_revision = candidate.baseline_revision or 0,
      inflight_revision = candidate.inflight_revision,
      inflight_task_id = candidate.inflight_task_id,
      warnings = copy_list(candidate.warnings or {}),
      metadata = candidate.metadata or {},
    }
    order[#order + 1] = candidate.id
  end

  local source_index, source_error = index_units(groups, order, "source")
  if not source_index then
    return nil, source_error
  end
  local target_index, target_error = index_units(groups, order, "target")
  if not target_index then
    return nil, target_error
  end

  return setmetatable({
    groups = groups,
    source_index = source_index,
    target_index = target_index,
    order = order,
    revision = revision or 1,
  }, Graph)
end

function Graph:get(group_id)
  return self.groups[group_id]
end

function Graph:group_ids_for_unit(side, unit_id)
  local index = side == "source" and self.source_index or self.target_index
  return index[unit_id]
end

return {
  new = Graph.new,
}
