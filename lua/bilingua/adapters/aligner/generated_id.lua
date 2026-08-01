local document = require("bilingua.domain.document")
local errors = require("bilingua.domain.error")
local mapping_graph = require("bilingua.domain.mapping_graph")

local GeneratedId = {}
GeneratedId.__index = GeneratedId

local function copy_list(values)
  local copy = {}
  for index, value in ipairs(values or {}) do
    copy[index] = value
  end
  return copy
end

local function copy_table(value, seen)
  if type(value) ~= "table" then
    return value
  end
  local visited = seen or {}
  if visited[value] then
    return visited[value]
  end
  local copy = {}
  visited[value] = copy
  for key, item in pairs(value) do
    copy[copy_table(key, visited)] = copy_table(item, visited)
  end
  return copy
end

local function maximum_group_id(graph)
  local maximum = 0
  for _, group_id in ipairs(graph.order) do
    local suffix = tonumber(group_id:match("(%d+)$"))
    if suffix then
      maximum = math.max(maximum, suffix)
    end
  end
  return maximum
end

local function empty_fragment(side, language)
  return assert(document.fragment({
    side = side,
    language = language or "und",
    units = {},
  }, {}))
end

local function validate_initial_ids(source, seeds, result)
  if type(result) ~= "table" or type(result.replacement_units) ~= "table" then
    return nil,
      errors.new(
        errors.codes.ALIGNMENT,
        "Initial alignment requires translation replacement units",
        false
      )
  end
  local expected = {}
  for _, seed in ipairs(seeds) do
    if seed.mode ~= "mirror" then
      for _, source_id in ipairs(seed.source_unit_ids or {}) do
        expected[source_id] = true
      end
    end
  end
  local seen = {}
  for _, replacement in ipairs(result.replacement_units) do
    local ids = replacement.corresponds_to_edited_unit_ids
    if type(ids) ~= "table" or #ids ~= 1 or not expected[ids[1]] or seen[ids[1]] then
      return nil,
        errors.new(
          errors.codes.ALIGNMENT,
          "Initial translation IDs must match every translatable source unit exactly once",
          false
        )
    end
    seen[ids[1]] = true
  end
  for source_id in pairs(expected) do
    if not seen[source_id] or not source.units[source_id] then
      return nil,
        errors.new(
          errors.codes.ALIGNMENT,
          "Initial translation omitted a required source unit",
          false,
          { unit_id = source_id }
        )
    end
  end
  return true
end

function GeneratedId.new()
  return setmetatable({ api_version = 1, id = "generated_id" }, GeneratedId)
end

function GeneratedId:capabilities()
  return {
    overlapping_groups = false,
    structural_edits = true,
    asynchronous = false,
  }
end

function GeneratedId:initialize(request)
  if
    type(request) ~= "table"
    or type(request.source_snapshot) ~= "table"
    or type(request.target_snapshot) ~= "table"
    or type(request.construction_seeds) ~= "table"
  then
    return nil,
      errors.new(
        errors.codes.INVALID_ARGUMENT,
        "Aligner initialization requires snapshots and seeds",
        false
      )
  end
  local source = request.source_snapshot
  local target = request.target_snapshot
  local ids_valid, id_error =
    validate_initial_ids(source, request.construction_seeds, request.initial_translation_result)
  if not ids_valid then
    return nil, id_error
  end

  local seen_source = {}
  local seen_target = {}
  local groups = {}
  for ordinal, seed in ipairs(request.construction_seeds) do
    if
      type(seed.source_unit_ids) ~= "table"
      or #seed.source_unit_ids == 0
      or type(seed.target_ordinal) ~= "number"
      or seed.target_ordinal % 1 ~= 0
    then
      return nil, errors.new(errors.codes.ALIGNMENT, "A construction seed is malformed", false)
    end
    local target_id = target.order[seed.target_ordinal]
    if not target_id or seen_target[target_id] then
      return nil,
        errors.new(
          errors.codes.ALIGNMENT,
          "Target construction ordinals must be unique and valid",
          false
        )
    end
    for _, source_id in ipairs(seed.source_unit_ids) do
      if not source.units[source_id] or seen_source[source_id] then
        return nil,
          errors.new(
            errors.codes.ALIGNMENT,
            "Source construction IDs must be unique and valid",
            false
          )
      end
      seen_source[source_id] = true
    end
    seen_target[target_id] = true
    local source_fragment, source_error = document.fragment(source, seed.source_unit_ids)
    if not source_fragment then
      return nil, source_error
    end
    local target_fragment, target_error = document.fragment(target, { target_id })
    if not target_fragment then
      return nil, target_error
    end
    groups[#groups + 1] = {
      id = ("group:%06d"):format(ordinal),
      source_unit_ids = copy_list(seed.source_unit_ids),
      target_unit_ids = { target_id },
      baseline = { source = source_fragment, target = target_fragment, revision = 0 },
      state = "clean",
      source_revision = 0,
      target_revision = 0,
      baseline_revision = 0,
      warnings = {},
      metadata = {
        construction_kind = seed.kind,
        mode = seed.mode or "translate",
      },
    }
  end
  if #groups ~= #target.order then
    return nil,
      errors.new(
        errors.codes.ALIGNMENT,
        "Construction seeds must cover the target snapshot exactly",
        false
      )
  end
  for _, source_id in ipairs(source.order) do
    if not seen_source[source_id] then
      return nil,
        errors.new(
          errors.codes.ALIGNMENT,
          "Construction seeds must cover the source snapshot exactly",
          false
        )
    end
  end
  for _, target_id in ipairs(target.order) do
    if not seen_target[target_id] then
      return nil,
        errors.new(
          errors.codes.ALIGNMENT,
          "Construction seeds must cover the target snapshot exactly",
          false
        )
    end
  end
  return mapping_graph.new(groups)
end

local function conflicted_units(report)
  local old_ids = {}
  local new_ids = {}
  for _, match in ipairs(report.matches) do
    if match.kind == "move" or match.kind == "ambiguous" then
      for _, id in ipairs(match.old_ids) do
        old_ids[id] = true
      end
      for _, id in ipairs(match.new_ids) do
        new_ids[id] = true
      end
    end
  end
  return old_ids, new_ids
end

local function existing_group_copy(group)
  return {
    id = group.id,
    source_unit_ids = copy_list(group.source_unit_ids),
    target_unit_ids = copy_list(group.target_unit_ids),
    baseline = copy_table(group.baseline),
    state = group.state,
    source_revision = group.source_revision,
    target_revision = group.target_revision,
    baseline_revision = group.baseline_revision,
    inflight_revision = group.inflight_revision,
    inflight_task_id = group.inflight_task_id,
    warnings = copy_list(group.warnings),
    metadata = copy_table(group.metadata),
  }
end

local function append_all(destination, values)
  for _, value in ipairs(values or {}) do
    destination[#destination + 1] = value
  end
end

local function merge_components(graph, report, changed_side)
  local parent = {}
  local ordinals = {}
  for ordinal, group_id in ipairs(graph.order) do
    parent[group_id] = group_id
    ordinals[group_id] = ordinal
  end

  local function root(group_id)
    local current = group_id
    while parent[current] ~= current do
      current = parent[current]
    end
    while parent[group_id] ~= group_id do
      local next_id = parent[group_id]
      parent[group_id] = current
      group_id = next_id
    end
    return current
  end

  local function unite(left, right)
    left, right = root(left), root(right)
    if left == right then
      return
    end
    if ordinals[left] < ordinals[right] then
      parent[right] = left
    else
      parent[left] = right
    end
  end

  local index = changed_side == "source" and graph.source_index or graph.target_index
  for _, match in ipairs(report.matches or {}) do
    if match.kind == "merge" then
      local first_group
      for _, old_id in ipairs(match.old_ids or {}) do
        local owner = index[old_id] and index[old_id][1]
        if owner then
          if first_group then
            unite(first_group, owner)
          else
            first_group = owner
          end
        end
      end
    end
  end

  local by_root = {}
  local components = {}
  for ordinal, group_id in ipairs(graph.order) do
    local root_id = root(group_id)
    local component = by_root[root_id]
    if not component then
      component = { groups = {}, ordinal = ordinal }
      by_root[root_id] = component
      components[#components + 1] = component
    end
    component.groups[#component.groups + 1] = graph.groups[group_id]
  end
  return components
end

local function consolidate_component(component)
  if #component.groups == 1 then
    return existing_group_copy(component.groups[1])
  end

  local combined = existing_group_copy(component.groups[1])
  combined.source_unit_ids = {}
  combined.target_unit_ids = {}
  combined.warnings = {}
  combined.inflight_revision = nil
  combined.inflight_task_id = nil
  combined.metadata.structural_change = true
  local source_fragments = {}
  local target_fragments = {}
  local baseline_revision = 0
  local has_conflict = false
  for _, group in ipairs(component.groups) do
    append_all(combined.source_unit_ids, group.source_unit_ids)
    append_all(combined.target_unit_ids, group.target_unit_ids)
    append_all(combined.warnings, group.warnings)
    source_fragments[#source_fragments + 1] = group.baseline.source
    target_fragments[#target_fragments + 1] = group.baseline.target
    baseline_revision = math.max(baseline_revision, group.baseline.revision or 0)
    combined.source_revision = math.max(combined.source_revision, group.source_revision or 0)
    combined.target_revision = math.max(combined.target_revision, group.target_revision or 0)
    combined.baseline_revision = math.max(combined.baseline_revision, group.baseline_revision or 0)
    has_conflict = has_conflict or group.state == "conflict"
    for key, value in pairs(group.metadata or {}) do
      if combined.metadata[key] == nil then
        combined.metadata[key] = copy_table(value)
      end
    end
  end

  local source, source_error = document.combine(source_fragments)
  if not source then
    return nil, source_error
  end
  local target, target_error = document.combine(target_fragments)
  if not target then
    return nil, target_error
  end
  combined.baseline = {
    source = source,
    target = target,
    revision = baseline_revision,
  }
  if has_conflict then
    combined.state = "conflict"
  end
  return combined
end

local function minimum_position(ids, positions)
  local result = math.huge
  for _, id in ipairs(ids) do
    if positions[id] then
      result = math.min(result, positions[id])
    end
  end
  return result
end

function GeneratedId:reconcile(request)
  if
    type(request) ~= "table"
    or type(request.graph) ~= "table"
    or (request.changed_side ~= "source" and request.changed_side ~= "target")
    or type(request.previous_snapshot) ~= "table"
    or type(request.current_snapshot) ~= "table"
    or type(request.tracking_report) ~= "table"
  then
    return nil,
      errors.new(
        errors.codes.INVALID_ARGUMENT,
        "Aligner reconciliation request is malformed",
        false
      )
  end
  local graph = request.graph
  local report = request.tracking_report
  local changed_field = request.changed_side .. "_unit_ids"
  local conflicted_old, conflicted_new = conflicted_units(report)
  local structural_old = {}
  for _, match in ipairs(report.matches or {}) do
    if match.kind ~= "same" and match.kind ~= "edited" then
      for _, old_id in ipairs(match.old_ids or {}) do
        structural_old[old_id] = true
      end
    end
  end
  local current_positions = {}
  for ordinal, id in ipairs(request.current_snapshot.order) do
    current_positions[id] = ordinal
  end
  local previous_positions = {}
  for ordinal, id in ipairs(request.previous_snapshot.order) do
    previous_positions[id] = ordinal
  end

  local entries = {}
  local assigned_new = {}
  local components = merge_components(graph, report, request.changed_side)
  for _, component in ipairs(components) do
    local original, component_error = consolidate_component(component)
    if not original then
      return nil, component_error
    end
    local copied = existing_group_copy(original)
    copied[changed_field] = {}
    local group_conflict = false
    local group_structural = #component.groups > 1
    local old_position = math.huge
    for _, old_id in ipairs(original[changed_field]) do
      old_position = math.min(old_position, previous_positions[old_id] or math.huge)
      group_structural = group_structural or structural_old[old_id] == true
      for _, new_id in ipairs(report.old_to_new[old_id] or {}) do
        if not assigned_new[new_id] then
          copied[changed_field][#copied[changed_field] + 1] = new_id
          assigned_new[new_id] = true
        end
      end
      if conflicted_old[old_id] then
        group_conflict = true
      end
    end
    if group_conflict then
      copied.state = "conflict"
      copied.warnings[#copied.warnings + 1] =
        "Structural tracking requires manual conflict resolution"
    end
    local opposite_field = request.changed_side == "source" and "target_unit_ids"
      or "source_unit_ids"
    if group_structural then
      copied.metadata.structural_change = true
      if #copied[changed_field] == 0 and #copied[opposite_field] > 0 then
        copied.metadata.provisional = true
      end
    end
    if #copied[changed_field] > 0 or #copied[opposite_field] > 0 then
      local position = minimum_position(copied[changed_field], current_positions)
      if position == math.huge then
        position = #request.current_snapshot.order + old_position
      end
      entries[#entries + 1] = {
        group = copied,
        position = position,
        stable_order = component.ordinal,
      }
    end
  end

  if type(request.preferred_group_id) == "string" then
    local preferred
    for _, entry in ipairs(entries) do
      if entry.group.id == request.preferred_group_id then
        preferred = entry
        break
      end
    end
    if preferred then
      for _, new_id in ipairs(request.current_snapshot.order) do
        if not assigned_new[new_id] and #(report.new_to_old[new_id] or {}) == 0 then
          preferred.group[changed_field][#preferred.group[changed_field] + 1] = new_id
          assigned_new[new_id] = true
          preferred.position = math.min(preferred.position, current_positions[new_id])
          preferred.group.metadata.structural_change = true
        end
      end
    end
  end

  local next_group_number = maximum_group_id(graph) + 1
  local source_language = request.changed_side == "source" and request.current_snapshot.language
    or "und"
  local target_language = request.changed_side == "target" and request.current_snapshot.language
    or "ja"
  for _, new_id in ipairs(request.current_snapshot.order) do
    if not assigned_new[new_id] then
      local source_ids = request.changed_side == "source" and { new_id } or {}
      local target_ids = request.changed_side == "target" and { new_id } or {}
      local ambiguous = conflicted_new[new_id] == true
      local current_unit = request.current_snapshot.units[new_id]
      local group = {
        id = ("group:%06d"):format(next_group_number),
        source_unit_ids = source_ids,
        target_unit_ids = target_ids,
        baseline = {
          source = empty_fragment("source", source_language),
          target = empty_fragment("target", target_language),
          revision = 0,
        },
        state = ambiguous and "conflict"
          or (request.changed_side == "source" and "dirty_source" or "dirty_target"),
        source_revision = 0,
        target_revision = 0,
        baseline_revision = 0,
        warnings = ambiguous and { "Structural tracking is ambiguous" } or {},
        metadata = {
          provisional = true,
          mode = current_unit and current_unit.opaque and "mirror" or "translate",
        },
      }
      entries[#entries + 1] = {
        group = group,
        position = current_positions[new_id],
        stable_order = #graph.order + next_group_number,
      }
      assigned_new[new_id] = true
      next_group_number = next_group_number + 1
    end
  end

  table.sort(entries, function(left, right)
    if left.position ~= right.position then
      return left.position < right.position
    end
    return left.stable_order < right.stable_order
  end)
  local groups = {}
  for _, entry in ipairs(entries) do
    groups[#groups + 1] = entry.group
  end
  return mapping_graph.new(groups, graph.revision + 1)
end

return { new = GeneratedId.new }
