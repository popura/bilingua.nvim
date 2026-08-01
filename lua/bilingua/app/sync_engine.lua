local document = require("bilingua.domain.document")
local errors = require("bilingua.domain.error")
local task_queue_module = require("bilingua.app.task_queue")
local ranges = require("bilingua.util.ranges")
local utf8 = require("bilingua.util.utf8")

local SyncEngine = {}
SyncEngine.__index = SyncEngine

local function fragments_equal(left, right)
  return left and right and left.text_hash == right.text_hash
end

local function tokens_by_unit(fragment)
  local indexed = {}
  for _, unit in ipairs(fragment.units) do
    indexed[unit.unit_id] = unit.protected_tokens
  end
  return indexed
end

local function structure_unsupported_error()
  return errors.new(
    errors.codes.STRUCTURE_UNSUPPORTED,
    "Structural synchronization is disabled by configuration",
    false
  )
end

local function structural_ids(report)
  local previous_ids = {}
  local current_ids = {}
  for _, match in ipairs(report.matches) do
    if match.kind ~= "same" and match.kind ~= "edited" then
      for _, unit_id in ipairs(match.old_ids or {}) do
        previous_ids[unit_id] = true
      end
      for _, unit_id in ipairs(match.new_ids or {}) do
        current_ids[unit_id] = true
      end
    end
  end
  return previous_ids, current_ids
end

local function group_has_structural_ids(group, side, previous_ids, current_ids)
  local current_field = side .. "_unit_ids"
  for _, unit_id in ipairs(group[current_field]) do
    if current_ids[unit_id] then
      return true
    end
  end
  local baseline = group.baseline and group.baseline[side]
  for _, unit in ipairs((baseline and baseline.units) or {}) do
    if previous_ids[unit.unit_id] then
      return true
    end
  end
  return false
end

function SyncEngine.new(components)
  return setmetatable({
    session_id = components.session_id,
    editor = components.editor,
    document_adapter = components.document_adapter,
    unit_tracker = components.unit_tracker,
    aligner = components.aligner,
    translator = components.translator,
    config = components.config,
    get_session_state = components.get_session_state,
    on_update = components.on_update,
    on_event = components.on_event or function() end,
    source_snapshot = components.source_snapshot,
    target_snapshot = components.target_snapshot,
    graph = components.mapping_graph,
    task_queue = task_queue_module.new({
      max_concurrency = components.config.sync and components.config.sync.max_concurrency or 1,
    }),
    sequence = 0,
    active_jobs = {},
    last_error = nil,
    active_conflicts = {},
  }, SyncEngine)
end

function SyncEngine:next_task_id()
  self.sequence = self.sequence + 1
  return ("%s:task:patch:%d"):format(self.session_id, self.sequence)
end

function SyncEngine:notify(event, group, task, err)
  local data = {
    session_id = self.session_id,
    group_id = group and group.id or (task and task.mapping_group_id) or nil,
    task_id = task and task.task_id or nil,
    state = group and group.state or nil,
    error_code = err and err.code or nil,
  }
  pcall(self.on_event, event, data, err)
end

function SyncEngine:notify_error(group, task, err)
  if err and err.code == errors.codes.STALE_RESULT then
    return false
  end
  self:notify("BilinguaError", group, task, err)
  return true
end

function SyncEngine:publish_conflicts()
  local active = {}
  for _, group_id in ipairs(self.graph.order) do
    local group = self.graph.groups[group_id]
    if group.state == "conflict" then
      active[group_id] = true
      if not self.active_conflicts[group_id] then
        self:notify(
          "BilinguaConflict",
          group,
          nil,
          errors.new(errors.codes.CONFLICT, "A mapping group entered conflict", false)
        )
      end
    end
  end
  self.active_conflicts = active
end

function SyncEngine:snapshot(side)
  return side == "source" and self.source_snapshot or self.target_snapshot
end

function SyncEngine:set_snapshot(side, snapshot)
  if side == "source" then
    self.source_snapshot = snapshot
  else
    self.target_snapshot = snapshot
  end
end

function SyncEngine:current_fragment(side, group)
  local ids = side == "source" and group.source_unit_ids or group.target_unit_ids
  return document.fragment(self:snapshot(side), ids)
end

function SyncEngine:check_document_limits(text, snapshot)
  local limits = self.config.limits or {}
  if type(limits.max_document_bytes) == "number" and #text > limits.max_document_bytes then
    return nil,
      errors.new(
        errors.codes.DOCUMENT_TOO_LARGE,
        "The document exceeds the configured byte limit",
        false,
        { bytes = #text, maximum = limits.max_document_bytes }
      )
  end
  if snapshot and type(limits.max_units) == "number" and #snapshot.order > limits.max_units then
    return nil,
      errors.new(
        errors.codes.DOCUMENT_TOO_LARGE,
        "The document exceeds the configured unit limit",
        false,
        { units = #snapshot.order, maximum = limits.max_units }
      )
  end
  return true
end

function SyncEngine:validate_virtual_edits(side, snapshot, edits)
  local text = snapshot.adapter_state and snapshot.adapter_state.text
  if type(text) ~= "string" then
    local text_error
    text, text_error = self.editor:get_text(side)
    if not text then
      return nil, text_error
    end
  end

  local ordered = {}
  for _, edit in ipairs(edits) do
    local converted, first, finish = pcall(function()
      return ranges.position_to_offset(text, edit.range.start),
        ranges.position_to_offset(text, edit.range.finish)
    end)
    if not converted or first > finish or text:sub(first + 1, finish) ~= edit.expected_text then
      return nil,
        errors.new(
          errors.codes.APPLY,
          "A virtual TextEdit no longer matches the destination",
          false
        )
    end
    ordered[#ordered + 1] = { edit = edit, first = first, finish = finish }
  end
  table.sort(ordered, function(left, right)
    return left.first > right.first
  end)
  for _, checked in ipairs(ordered) do
    text = text:sub(1, checked.first) .. checked.edit.replacement .. text:sub(checked.finish + 1)
  end

  local limited, limit_error = self:check_document_limits(text)
  if not limited then
    return nil, limit_error
  end
  local parsed_ok, parsed, parse_error = pcall(self.document_adapter.parse, self.document_adapter, {
    side = side,
    text = text,
    filetype = snapshot.filetype,
    language = snapshot.language,
    editor_version = self.editor:get_version(side),
    previous = snapshot,
    changed_ranges = edits,
    anchor_hints = self.editor:get_anchor_hints(side),
  })
  if not parsed_ok then
    return nil,
      errors.new(
        errors.codes.PARSE,
        "Virtual destination parsing raised an error",
        false,
        nil,
        parsed
      )
  elseif not parsed then
    return nil, parse_error
  end
  return self:check_document_limits(text, parsed)
end

function SyncEngine:publish()
  for _, side in ipairs({ "source", "target" }) do
    local snapshot = self:snapshot(side)
    if snapshot and self.editor:get_version(side) == snapshot.editor_version then
      self.editor:set_unit_anchors(side, snapshot)
    end
  end
  self.editor:render_group_states(self.graph)
  self.on_update(self.source_snapshot, self.target_snapshot, self.graph)
  self:publish_conflicts()
end

function SyncEngine:refresh_group_states(changed_side)
  for _, group_id in ipairs(self.graph.order) do
    local group = self.graph.groups[group_id]
    local source, source_error = self:current_fragment("source", group)
    if not source then
      return nil, source_error
    end
    local target, target_error = self:current_fragment("target", group)
    if not target then
      return nil, target_error
    end

    local source_dirty = not fragments_equal(source, group.baseline.source)
    local target_dirty = not fragments_equal(target, group.baseline.target)
    if group.metadata and group.metadata.structure_blocked_by_policy then
      if source_dirty or target_dirty then
        group.state = "invalid"
      else
        group.metadata.structure_blocked_by_policy = nil
        group.state = "clean"
      end
    elseif group.state ~= "conflict" then
      if source_dirty and target_dirty then
        group.state = "conflict"
      elseif source_dirty then
        group.state = "dirty_source"
      elseif target_dirty then
        group.state = "dirty_target"
      else
        group.state = "clean"
      end
    end

    if changed_side == "source" and source_dirty then
      group.source_revision = group.source_revision + 1
    elseif changed_side == "target" and target_dirty then
      group.target_revision = group.target_revision + 1
    end
  end
  return true
end

function SyncEngine:process_side(side, changes)
  local previous = self:snapshot(side)
  local current_document, document_error = self.editor:get_document(side)
  if not current_document then
    return nil, document_error
  end
  local within_limits, limit_error = self:check_document_limits(current_document.text)
  if not within_limits then
    return nil, limit_error
  end

  local changed_ranges = {}
  for _, change in ipairs(changes) do
    for _, range in ipairs(change.ranges or {}) do
      changed_ranges[#changed_ranges + 1] = range
    end
  end
  local parsed, parse_error = self.document_adapter:parse({
    side = side,
    text = current_document.text,
    filetype = current_document.filetype,
    language = previous.language,
    editor_version = current_document.version,
    metadata = current_document.metadata,
    previous = previous,
    changed_ranges = changed_ranges,
    anchor_hints = self.editor:get_anchor_hints(side),
  })
  if not parsed then
    return nil, parse_error
  end
  within_limits, limit_error = self:check_document_limits(current_document.text, parsed)
  if not within_limits then
    return nil, limit_error
  end

  local report, tracking_error = self.unit_tracker:reconcile({
    side = side,
    previous = previous,
    current = parsed,
    changed_ranges = changed_ranges,
    anchor_hints = self.editor:get_anchor_hints(side),
  })
  if not report then
    return nil, tracking_error
  end

  local structural = false
  for _, match in ipairs(report.matches) do
    if match.kind ~= "same" and match.kind ~= "edited" then
      structural = true
      break
    end
  end
  self:set_snapshot(side, report.snapshot)
  if structural then
    local graph, alignment_error = self.aligner:reconcile({
      graph = self.graph,
      changed_side = side,
      previous_snapshot = previous,
      current_snapshot = report.snapshot,
      tracking_report = report,
    })
    if not graph then
      return nil, alignment_error
    end
    self.graph = graph
  end
  local refreshed, refresh_error = self:refresh_group_states(side)
  if not refreshed then
    return nil, refresh_error
  end
  if structural and self.config.sync.structural_changes == "manual" then
    local previous_ids, current_ids = structural_ids(report)
    for _, group_id in ipairs(self.graph.order) do
      local group = self.graph.groups[group_id]
      if
        (group.state == "dirty_source" or group.state == "dirty_target")
        and group_has_structural_ids(group, side, previous_ids, current_ids)
      then
        group.state = "conflict"
      end
    end
  elseif structural and self.config.sync.structural_changes == "disabled" then
    local previous_ids, current_ids = structural_ids(report)
    local blocked = false
    for _, group_id in ipairs(self.graph.order) do
      local group = self.graph.groups[group_id]
      if
        group.state ~= "clean"
        and group_has_structural_ids(group, side, previous_ids, current_ids)
      then
        group.metadata.structure_blocked_by_policy = true
        group.state = "invalid"
        blocked = true
      end
    end
    if blocked then
      self:publish()
      return nil, structure_unsupported_error()
    end
  end
  self:publish()
  return true
end

function SyncEngine:context_for_group(group_id)
  local maximum = self.config.sync.context_groups or 1
  local ordinal
  for index, candidate in ipairs(self.graph.order) do
    if candidate == group_id then
      ordinal = index
      break
    end
  end
  if not ordinal then
    return nil, nil, errors.new(errors.codes.ALIGNMENT, "The mapping group is not ordered", false)
  end
  local before = {}
  local after = {}
  local function append(destination, neighbor_id)
    local neighbor = self.graph.groups[neighbor_id]
    if
      not neighbor
      or type(neighbor.baseline) ~= "table"
      or type(neighbor.baseline.source) ~= "table"
      or type(neighbor.baseline.target) ~= "table"
    then
      return nil, errors.new(errors.codes.ALIGNMENT, "A context group has no baseline pair", false)
    end
    destination[#destination + 1] = neighbor.baseline.source
    destination[#destination + 1] = neighbor.baseline.target
    return true
  end
  for index = math.max(1, ordinal - maximum), ordinal - 1 do
    local ok, context_error = append(before, self.graph.order[index])
    if not ok then
      return nil, nil, context_error
    end
  end
  for index = ordinal + 1, math.min(#self.graph.order, ordinal + maximum) do
    local ok, context_error = append(after, self.graph.order[index])
    if not ok then
      return nil, nil, context_error
    end
  end
  return before, after
end

function SyncEngine:create_task(group, authoritative_side)
  local edited_side = authoritative_side
  if not edited_side then
    edited_side = group.state == "dirty_source" and "source" or "target"
  end
  if edited_side ~= "source" and edited_side ~= "target" then
    return nil,
      errors.new(
        errors.codes.INVALID_ARGUMENT,
        "An authoritative side must be source or target",
        false
      )
  end
  local destination_side = edited_side == "source" and "target" or "source"
  local edited_after, edited_error = self:current_fragment(edited_side, group)
  if not edited_after then
    return nil, edited_error
  end
  local destination_before, destination_error = self:current_fragment(destination_side, group)
  if not destination_before then
    return nil, destination_error
  end
  local edited_before = edited_side == "source" and group.baseline.source or group.baseline.target
  local context_before, context_after, context_error = self:context_for_group(group.id)
  if not context_before then
    return nil, context_error
  end

  local destination_baseline = edited_side == "source" and group.baseline.target
    or group.baseline.source
  local structural = group.metadata.provisional == true
    or group.metadata.structural_change == true
    or #edited_before.units ~= #edited_after.units
    or #destination_before.units ~= #destination_baseline.units
  local task = {
    schema_version = 1,
    task_id = self:next_task_id(),
    session_id = self.session_id,
    kind = authoritative_side and "resolve_conflict"
      or (structural and "propagate_structure" or "propagate_edit"),
    direction = edited_side == "source" and "source_to_target" or "target_to_source",
    source_language = self.source_snapshot.language,
    target_language = self.target_snapshot.language,
    mapping_group_id = group.id,
    baseline = group.baseline,
    edited_side = edited_side,
    edited_before = edited_before,
    edited_after = edited_after,
    destination_before = destination_before,
    context_before = context_before,
    context_after = context_after,
    constraints = {
      preserve_unedited_meaning = true,
      preserve_style = true,
      preserve_placeholders = true,
    },
    revision = edited_side == "source" and group.source_revision or group.target_revision,
    metadata = {
      expected_versions = {
        source = self.editor:get_version("source"),
        target = self.editor:get_version("target"),
      },
      edited_hash = edited_after.text_hash,
      destination_hash = destination_before.text_hash,
    },
  }
  return task
end

function SyncEngine:result_is_current(group, task)
  local state = self.get_session_state()
  if (state ~= "ready" and state ~= "stopping") or group.inflight_task_id ~= task.task_id then
    return false
  end
  if group.inflight_revision ~= task.revision then
    return false
  end
  if
    self.editor:get_version("source") ~= task.metadata.expected_versions.source
    or self.editor:get_version("target") ~= task.metadata.expected_versions.target
  then
    return false
  end
  local edited, edited_error = self:current_fragment(task.edited_side, group)
  if not edited or edited_error or edited.text_hash ~= task.metadata.edited_hash then
    return false
  end
  local destination_side = task.edited_side == "source" and "target" or "source"
  local destination, destination_error = self:current_fragment(destination_side, group)
  return destination
    and not destination_error
    and destination.text_hash == task.metadata.destination_hash
end

function SyncEngine:insertion_hints(group, destination_side)
  local field = destination_side .. "_unit_ids"
  local group_ordinal
  for ordinal, group_id in ipairs(self.graph.order) do
    if group_id == group.id then
      group_ordinal = ordinal
      break
    end
  end
  local previous_unit_id
  for ordinal = (group_ordinal or 1) - 1, 1, -1 do
    local ids = self.graph.groups[self.graph.order[ordinal]][field]
    if #ids > 0 then
      previous_unit_id = ids[#ids]
      break
    end
  end
  local next_unit_id
  for ordinal = (group_ordinal or #self.graph.order) + 1, #self.graph.order do
    local ids = self.graph.groups[self.graph.order[ordinal]][field]
    if #ids > 0 then
      next_unit_id = ids[1]
      break
    end
  end
  return { previous_unit_id = previous_unit_id, next_unit_id = next_unit_id }
end

function SyncEngine:refresh_after_apply(side, changed_ranges, preferred_group_id)
  local previous = self:snapshot(side)
  local current_document, document_error = self.editor:get_document(side)
  if not current_document then
    return nil, document_error
  end
  local parsed, parse_error = self.document_adapter:parse({
    side = side,
    text = current_document.text,
    filetype = current_document.filetype,
    language = previous.language,
    editor_version = current_document.version,
    metadata = current_document.metadata,
    previous = previous,
    changed_ranges = changed_ranges,
    anchor_hints = self.editor:get_anchor_hints(side),
  })
  if not parsed then
    return nil, parse_error
  end
  local report, tracking_error = self.unit_tracker:reconcile({
    side = side,
    previous = previous,
    current = parsed,
    changed_ranges = changed_ranges,
    anchor_hints = self.editor:get_anchor_hints(side),
  })
  if not report then
    return nil, tracking_error
  end
  self:set_snapshot(side, report.snapshot)
  local structural = false
  for _, match in ipairs(report.matches) do
    if match.kind ~= "same" and match.kind ~= "edited" then
      structural = true
      break
    end
  end
  if structural then
    local graph, alignment_error = self.aligner:reconcile({
      graph = self.graph,
      changed_side = side,
      previous_snapshot = previous,
      current_snapshot = report.snapshot,
      tracking_report = report,
      preferred_group_id = preferred_group_id,
    })
    if not graph then
      return nil, alignment_error
    end
    self.graph = graph
  end
  return true
end

function SyncEngine:apply_result(group, task, result)
  if result.task_id ~= task.task_id then
    return nil,
      errors.new(errors.codes.INVALID_OUTPUT, "Translation result task ID does not match", false)
  end
  local destination_side = task.edited_side == "source" and "target" or "source"
  if result.destination_side ~= destination_side then
    return nil,
      errors.new(
        errors.codes.INVALID_OUTPUT,
        "Translation result destination does not match",
        false
      )
  end
  if not self:result_is_current(group, task) then
    return nil, errors.new(errors.codes.STALE_RESULT, "Translation result is stale", true)
  end

  local output_size = 0
  for _, replacement in ipairs(result.replacement_units or {}) do
    local length, length_error = utf8.length(replacement.content_text or "")
    if not length then
      return nil,
        errors.new(
          errors.codes.INVALID_OUTPUT,
          "Translation result contains invalid UTF-8",
          false,
          nil,
          length_error
        )
    end
    output_size = output_size + length
  end
  if output_size > self.config.limits.max_task_output_chars then
    return nil,
      errors.new(errors.codes.INVALID_OUTPUT, "Translation result exceeds the output limit", false)
  end

  local destination_snapshot = self:snapshot(destination_side)
  local destination_ids = destination_side == "source" and group.source_unit_ids
    or group.target_unit_ids
  local edits, plan_error = self.document_adapter:plan_replace({
    snapshot = destination_snapshot,
    destination_unit_ids = destination_ids,
    replacement_units = result.replacement_units,
    insertion = self:insertion_hints(group, destination_side),
    protected_tokens_by_edited_unit_id = tokens_by_unit(task.edited_after),
    edited_units_by_id = self:snapshot(task.edited_side).units,
  })
  if not edits then
    return nil, plan_error
  end
  local validation, validation_error = self.document_adapter:validate_edits({
    snapshot = destination_snapshot,
    edits = edits,
    result = result,
  })
  if not validation then
    return nil, validation_error
  end
  local safe, preflight_error =
    self:validate_virtual_edits(destination_side, destination_snapshot, edits)
  if not safe then
    return nil, preflight_error
  end

  local applied, apply_error = self.editor:apply_edits(
    destination_side,
    edits,
    task.metadata.expected_versions[destination_side],
    "bilingua-sync"
  )
  if not applied then
    return nil, apply_error
  end
  local refreshed, refresh_error = self:refresh_after_apply(destination_side, edits, group.id)
  if not refreshed then
    return nil, refresh_error
  end

  group = self.graph.groups[task.mapping_group_id]
  if not group then
    if #task.edited_after.units == 0 and #(result.replacement_units or {}) == 0 then
      if destination_side == "target" then
        self.editor:set_target_modified(false)
      end
      self:publish()
      return true
    end
    return nil, errors.new(errors.codes.ALIGNMENT, "Synchronized mapping group disappeared", false)
  end
  local source, source_error = self:current_fragment("source", group)
  if not source then
    return nil, source_error
  end
  local target, target_error = self:current_fragment("target", group)
  if not target then
    return nil, target_error
  end
  group.baseline_revision = group.baseline_revision + 1
  group.baseline = { source = source, target = target, revision = group.baseline_revision }
  if destination_side == "source" then
    group.source_revision = group.source_revision + 1
  else
    group.target_revision = group.target_revision + 1
  end
  group.state = "clean"
  group.inflight_revision = nil
  group.inflight_task_id = nil
  group.metadata.provisional = nil
  group.metadata.structural_change = nil
  if destination_side == "target" then
    self.editor:set_target_modified(false)
  end
  self:publish()
  return true
end

function SyncEngine:sync_mirror_group(group, authoritative_side)
  if type(self.document_adapter.plan_mirror) ~= "function" then
    return nil,
      errors.new(
        errors.codes.STRUCTURE_UNSUPPORTED,
        "The document adapter does not support opaque mirroring",
        false
      )
  end

  local edited_side = authoritative_side
  if not edited_side then
    edited_side = group.state == "dirty_source" and "source" or "target"
  end
  if edited_side ~= "source" and edited_side ~= "target" then
    return nil,
      errors.new(
        errors.codes.INVALID_ARGUMENT,
        "An authoritative side must be source or target",
        false
      )
  end
  local destination_side = edited_side == "source" and "target" or "source"
  local edited_ids = edited_side == "source" and group.source_unit_ids or group.target_unit_ids
  local destination_ids = destination_side == "source" and group.source_unit_ids
    or group.target_unit_ids
  local destination_snapshot = self:snapshot(destination_side)
  local edits, plan_error = self.document_adapter:plan_mirror({
    edited_snapshot = self:snapshot(edited_side),
    destination_snapshot = destination_snapshot,
    edited_unit_ids = edited_ids,
    destination_unit_ids = destination_ids,
    insertion = self:insertion_hints(group, destination_side),
  })
  if not edits then
    return nil, plan_error
  end

  local validation, validation_error = self.document_adapter:validate_edits({
    snapshot = destination_snapshot,
    edits = edits,
    mirror = true,
  })
  if not validation then
    return nil, validation_error
  end
  local safe, preflight_error =
    self:validate_virtual_edits(destination_side, destination_snapshot, edits)
  if not safe then
    return nil, preflight_error
  end

  if #edits > 0 then
    local applied, apply_error = self.editor:apply_edits(
      destination_side,
      edits,
      self.editor:get_version(destination_side),
      "bilingua-mirror"
    )
    if not applied then
      return nil, apply_error
    end
    local refreshed, refresh_error = self:refresh_after_apply(destination_side, edits, group.id)
    if not refreshed then
      return nil, refresh_error
    end
  end

  group = self.graph.groups[group.id]
  if not group then
    if #edited_ids == 0 then
      if destination_side == "target" then
        self.editor:set_target_modified(false)
      end
      self:publish()
      return true
    end
    return nil, errors.new(errors.codes.ALIGNMENT, "Mirrored mapping group disappeared", false)
  end
  local source, source_error = self:current_fragment("source", group)
  if not source then
    return nil, source_error
  end
  local target, target_error = self:current_fragment("target", group)
  if not target then
    return nil, target_error
  end

  group.baseline_revision = group.baseline_revision + 1
  group.baseline = { source = source, target = target, revision = group.baseline_revision }
  if #edits > 0 then
    if destination_side == "source" then
      group.source_revision = group.source_revision + 1
    else
      group.target_revision = group.target_revision + 1
    end
  end
  group.state = "clean"
  group.inflight_revision = nil
  group.inflight_task_id = nil
  group.metadata.mode = "mirror"
  group.metadata.provisional = nil
  group.metadata.structural_change = nil
  if destination_side == "target" then
    self.editor:set_target_modified(false)
  end
  self:publish()
  return true
end

function SyncEngine:sync_group(group, authoritative_side, priority)
  local resolvable_conflict = group.state == "conflict" and authoritative_side ~= nil
  if
    group.state ~= "dirty_source"
    and group.state ~= "dirty_target"
    and not resolvable_conflict
  then
    return true
  end
  if group.metadata and group.metadata.mode == "mirror" then
    local task = { task_id = self:next_task_id() }
    self:notify("BilinguaSyncStarted", group, task)
    local mirrored, mirror_error = self:sync_mirror_group(group, authoritative_side)
    local latest_group = self.graph.groups[group.id] or group
    if mirrored then
      self:notify("BilinguaSyncCompleted", latest_group, task)
    else
      self:notify_error(latest_group, task, mirror_error)
    end
    return mirrored, mirror_error
  end
  local group_id = group.id
  local immediate_error
  local completion_error
  local item = { key = group_id, priority = priority or 0 }
  item.run = function(done)
    local current_group = self.graph.groups[group_id]
    if not current_group then
      immediate_error =
        errors.new(errors.codes.ALIGNMENT, "The queued mapping group no longer exists", false)
      done()
      return
    end
    local current_resolvable = current_group.state == "conflict" and authoritative_side ~= nil
    if
      current_group.state ~= "dirty_source"
      and current_group.state ~= "dirty_target"
      and not current_resolvable
    then
      done()
      return
    end
    local task, task_error = self:create_task(current_group, authoritative_side)
    if not task then
      immediate_error = task_error
      done()
      return
    end
    item.task = task
    current_group.state = task.edited_side == "source" and "syncing_source_to_target"
      or "syncing_target_to_source"
    current_group.inflight_revision = task.revision
    current_group.inflight_task_id = task.task_id
    self:publish()
    self:notify("BilinguaSyncStarted", current_group, task)

    local terminal = false
    local callbacks = {
      on_complete = function(result)
        if terminal then
          return
        end
        terminal = true
        self.active_jobs[task.task_id] = nil
        local latest_group = self.graph.groups[group_id]
        local ok, err
        if latest_group then
          ok, err = self:apply_result(latest_group, task, result)
        else
          err = errors.new(errors.codes.STALE_RESULT, "The mapping group no longer exists", true)
        end
        if not ok then
          completion_error = err
          latest_group = self.graph.groups[group_id]
          if latest_group and latest_group.inflight_task_id == task.task_id then
            latest_group.inflight_revision = nil
            latest_group.inflight_task_id = nil
            if err and err.code == errors.codes.STALE_RESULT then
              latest_group.state = task.edited_side == "source" and "dirty_source" or "dirty_target"
            else
              latest_group.state = "invalid"
              self.last_error = err
            end
            self:publish()
          end
          self:notify_error(latest_group, task, err)
        else
          self:notify("BilinguaSyncCompleted", self.graph.groups[group_id], task)
        end
        done()
      end,
      on_error = function(err)
        if terminal then
          return
        end
        terminal = true
        self.active_jobs[task.task_id] = nil
        completion_error = err
        local latest_group = self.graph.groups[group_id]
        if latest_group and latest_group.inflight_task_id == task.task_id then
          latest_group.inflight_revision = nil
          latest_group.inflight_task_id = nil
          latest_group.state = task.edited_side == "source" and "dirty_source" or "dirty_target"
          if not err or err.code ~= errors.codes.STALE_RESULT then
            self.last_error = err
          end
          self:publish()
        end
        self:notify_error(latest_group, task, err)
        done()
      end,
      is_current = function()
        local latest_group = self.graph.groups[group_id]
        return latest_group and self:result_is_current(latest_group, task) or false
      end,
    }
    local submitted, handle, submit_error =
      pcall(self.translator.submit, self.translator, task, callbacks)
    if not submitted and not terminal then
      local raised = handle
      handle = nil
      callbacks.on_error(
        errors.new(
          errors.codes.INTERNAL,
          "TranslationService submit raised an internal error",
          false,
          nil,
          raised
        )
      )
    elseif
      submitted
      and not terminal
      and (type(handle) ~= "table" or type(handle.cancel) ~= "function")
    then
      local invalid_handle = type(submit_error) == "table" and submit_error
        or errors.new(
          errors.codes.INTERNAL,
          "TranslationService submit returned no cancellable handle",
          false
        )
      handle = nil
      callbacks.on_error(invalid_handle)
    end
    if not terminal then
      self.active_jobs[task.task_id] = handle
    end
    return handle
  end
  item.on_cancel = function()
    local task = item.task
    if not task then
      return
    end
    self.active_jobs[task.task_id] = nil
    local current_group = self.graph.groups[group_id]
    if current_group and current_group.inflight_task_id == task.task_id then
      current_group.inflight_revision = nil
      current_group.inflight_task_id = nil
      current_group.state = task.edited_side == "source" and "dirty_source" or "dirty_target"
      self:publish()
    end
  end

  local queued, queue_error = self.task_queue:enqueue(item)
  if not queued then
    return nil, queue_error
  end
  if immediate_error then
    return nil, immediate_error
  end
  if completion_error then
    return nil, completion_error
  end
  return true
end

function SyncEngine:sync_all(pending_changes)
  if self.get_session_state() ~= "ready" then
    return nil,
      errors.new(errors.codes.SESSION_STATE, "Synchronization requires a ready session", false)
  end

  for _, side in ipairs({ "source", "target" }) do
    local changes = pending_changes[side]
    if #changes > 0 then
      local processed, process_error = self:process_side(side, changes)
      if not processed then
        return nil, process_error
      end
      pending_changes[side] = {}
    end
  end

  self.last_error = nil
  self.task_queue.last_error = nil
  for _, group_id in ipairs(self.graph.order) do
    local group = self.graph.groups[group_id]
    if
      group.state == "invalid"
      and group.metadata
      and group.metadata.structure_blocked_by_policy
    then
      return nil, structure_unsupported_error()
    end
  end
  local refreshed_invalid = false
  for _, group_id in ipairs(self.graph.order) do
    local group = self.graph.groups[group_id]
    if group.state == "invalid" then
      local source, source_error = self:current_fragment("source", group)
      if not source then
        return nil, source_error
      end
      local target, target_error = self:current_fragment("target", group)
      if not target then
        return nil, target_error
      end
      local source_dirty = not fragments_equal(source, group.baseline.source)
      local target_dirty = not fragments_equal(target, group.baseline.target)
      if source_dirty and target_dirty then
        group.state = "conflict"
      elseif source_dirty then
        group.state = "dirty_source"
      elseif target_dirty then
        group.state = "dirty_target"
      else
        group.state = "clean"
      end
      refreshed_invalid = true
    end
  end
  if refreshed_invalid then
    self:publish()
  end

  for _, group_id in ipairs(self.graph.order) do
    local synced, sync_error = self:sync_group(self.graph.groups[group_id], nil, 0)
    if not synced then
      return nil, sync_error
    end
  end
  return true
end

function SyncEngine:retry_group(group_id, priority)
  if self.get_session_state() ~= "ready" then
    return nil, errors.new(errors.codes.SESSION_STATE, "Retry requires a ready Session", false)
  end
  if not self.graph.groups[group_id] then
    return nil, errors.new(errors.codes.INVALID_ARGUMENT, "The mapping group does not exist", false)
  end

  local refreshed, refresh_error = self:refresh_group_states(nil)
  if not refreshed then
    return nil, refresh_error
  end
  local group = self.graph.groups[group_id]
  self:publish()

  if group.state == "invalid" and group.metadata and group.metadata.structure_blocked_by_policy then
    return nil, structure_unsupported_error()
  elseif group.state == "clean" then
    self.last_error = nil
    self.task_queue.last_error = nil
    return true
  elseif group.state == "conflict" then
    return nil,
      errors.new(
        errors.codes.CONFLICT,
        "A conflicted mapping group requires an authoritative side",
        false
      )
  elseif group.state ~= "dirty_source" and group.state ~= "dirty_target" then
    return nil, errors.new(errors.codes.VALIDATION, "The mapping group cannot be retried", false)
  end

  self.last_error = nil
  self.task_queue.last_error = nil
  return self:sync_group(group, nil, priority or 100)
end

function SyncEngine:stop_group_error()
  for _, group_id in ipairs(self.graph.order) do
    local state = self.graph.groups[group_id].state
    if state == "conflict" then
      return errors.new(errors.codes.CONFLICT, "Session has an unresolved mapping conflict", false)
    elseif state == "invalid" then
      return errors.new(errors.codes.VALIDATION, "Session has an invalid mapping group", false)
    elseif state ~= "clean" and state ~= "dirty_source" then
      return errors.new(
        errors.codes.TRANSLATION,
        "Japanese-side synchronization did not finish before Session stop",
        true
      )
    end
  end
  return nil
end

function SyncEngine:sync_for_stop(pending_changes, sync_pending, callback)
  if self.get_session_state() ~= "stopping" then
    return nil,
      errors.new(
        errors.codes.SESSION_STATE,
        "Stop synchronization requires a stopping Session",
        false
      )
  end
  if type(pending_changes) ~= "table" or type(callback) ~= "function" then
    return nil,
      errors.new(
        errors.codes.INVALID_ARGUMENT,
        "Stop synchronization requires changes and a callback",
        false
      )
  end

  self.last_error = nil
  self.task_queue.last_error = nil
  for _, side in ipairs({ "source", "target" }) do
    local changes = pending_changes[side] or {}
    if #changes > 0 then
      local processed, process_error = self:process_side(side, changes)
      if not processed then
        return nil, process_error
      end
      pending_changes[side] = {}
    end
  end

  for _, group_id in ipairs(self.graph.order) do
    local state = self.graph.groups[group_id].state
    if state == "conflict" then
      return nil,
        errors.new(errors.codes.CONFLICT, "Session has an unresolved mapping conflict", false)
    elseif state == "invalid" then
      return nil, errors.new(errors.codes.VALIDATION, "Session has an invalid mapping group", false)
    elseif state == "dirty_target" and not sync_pending then
      return nil,
        errors.new(
          errors.codes.CONFLICT,
          "Session has unsynchronized Japanese changes and stop.sync_pending is disabled",
          false
        )
    end
  end

  if sync_pending then
    for _, group_id in ipairs(self.graph.order) do
      local group = self.graph.groups[group_id]
      if group.state == "dirty_target" then
        local synced, sync_error = self:sync_group(group, nil, 100)
        if not synced then
          return nil, sync_error
        end
      end
    end
  end

  self.task_queue:when_idle(function()
    local stop_error = self.last_error or self.task_queue.last_error or self:stop_group_error()
    if stop_error then
      callback(nil, stop_error)
    else
      callback(true)
    end
  end)
  return true
end

function SyncEngine:resolve_conflict(group_id, authoritative_side)
  if self.get_session_state() ~= "ready" then
    return nil,
      errors.new(errors.codes.SESSION_STATE, "Conflict resolution requires a ready session", false)
  end
  local group = self.graph.groups[group_id]
  if not group then
    return nil, errors.new(errors.codes.INVALID_ARGUMENT, "The mapping group does not exist", false)
  end
  if group.state ~= "conflict" then
    return nil, errors.new(errors.codes.CONFLICT, "The mapping group is not in conflict", false)
  end
  if authoritative_side ~= "source" and authoritative_side ~= "target" then
    return nil,
      errors.new(
        errors.codes.INVALID_ARGUMENT,
        "An authoritative side must be source or target",
        false
      )
  end
  return self:sync_group(group, authoritative_side, 100)
end

function SyncEngine:dispose()
  self.task_queue:close()
  self.active_jobs = {}
end

return {
  new = SyncEngine.new,
}
