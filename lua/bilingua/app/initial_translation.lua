local errors = require("bilingua.domain.error")
local utf8 = require("bilingua.util.utf8")

local Runner = {}
Runner.__index = Runner

local function batch_ids(snapshot, limits)
  local maximum_units = limits.initial_batch_units or 32
  local maximum_characters = limits.initial_batch_chars or 12000
  local batches = {}
  local current = {}
  local current_characters = 0

  local function flush()
    if #current > 0 then
      batches[#batches + 1] = current
      current = {}
      current_characters = 0
    end
  end

  for _, unit_id in ipairs(snapshot.order) do
    local unit = snapshot.units[unit_id]
    if not unit.opaque then
      local characters, length_error = utf8.length(unit.content_text)
      if not characters then
        return nil,
          errors.new(
            errors.codes.VALIDATION,
            "A translation unit contains invalid UTF-8",
            false,
            { unit_id = unit_id, reason = length_error }
          )
      end
      if characters > maximum_characters then
        return nil,
          errors.new(
            errors.codes.DOCUMENT_TOO_LARGE,
            "A translation unit exceeds the initial batch character limit",
            false,
            {
              unit_id = unit_id,
              characters = characters,
              maximum = maximum_characters,
            }
          )
      end
      if
        #current > 0
        and (
          #current >= maximum_units
          or current_characters + characters > maximum_characters
          or unit.kind == "heading"
        )
      then
        flush()
      end
      current[#current + 1] = unit_id
      current_characters = current_characters + characters
    end
  end
  flush()
  return batches
end

local function document_language(snapshot, source_languages)
  local weights = {}
  local distinct = 0
  local total = 0
  for _, unit_id in ipairs(snapshot.order) do
    local unit = snapshot.units[unit_id]
    if not unit.opaque then
      local language = source_languages[unit_id] or "und"
      if language ~= "und" then
        local length = assert(utf8.length(unit.content_text))
        if weights[language] == nil then
          weights[language] = 0
          distinct = distinct + 1
        end
        weights[language] = weights[language] + length
        total = total + length
      end
    end
  end
  if distinct == 0 then
    return "und"
  elseif distinct == 1 then
    return next(weights)
  end
  for language, weight in pairs(weights) do
    if total > 0 and weight / total >= 0.8 then
      return language
    end
  end
  return "mul"
end

function Runner.new(components)
  if
    type(components) ~= "table"
    or type(components.translator) ~= "table"
    or type(components.make_task) ~= "function"
    or type(components.get_source_version) ~= "function"
  then
    error("Initial translation runner dependencies are required", 2)
  end
  return setmetatable({
    translator = components.translator,
    make_task = components.make_task,
    get_source_version = components.get_source_version,
    limits = components.limits,
    max_concurrency = components.max_concurrency or 1,
    external_active_jobs = components.active_jobs,
    active = {},
    cancelled = false,
    settled = false,
  }, Runner)
end

function Runner:cancel()
  if self.cancelled then
    return
  end
  self.cancelled = true
  for task_id, handle in pairs(self.active) do
    if type(handle.cancel) == "function" then
      handle:cancel()
    end
    self.active[task_id] = nil
    if self.external_active_jobs then
      self.external_active_jobs[task_id] = nil
    end
  end
end

local function result_error(message, details)
  return errors.new(errors.codes.INVALID_OUTPUT, message, false, details)
end

function Runner:run(snapshot, source_version, callbacks)
  if
    type(callbacks) ~= "table"
    or type(callbacks.on_complete) ~= "function"
    or type(callbacks.on_error) ~= "function"
    or type(callbacks.on_stale) ~= "function"
    or (callbacks.on_progress ~= nil and type(callbacks.on_progress) ~= "function")
  then
    error("Initial translation callbacks are required", 2)
  end
  local batches, batching_error = batch_ids(snapshot, self.limits)
  if not batches then
    callbacks.on_error(batching_error)
    return
  end
  local function report_progress(completed)
    if callbacks.on_progress then
      callbacks.on_progress({ completed = completed, total = #batches })
    end
  end
  report_progress(0)
  if #batches == 0 then
    self.settled = true
    callbacks.on_complete({
      schema_version = 1,
      task_id = "initial:empty",
      destination_side = "target",
      replacement_units = {},
      warnings = {},
      metadata = {
        source_languages = {},
        document_source_language = "und",
      },
    })
    return
  end

  local next_batch = 1
  local active_count = 0
  local completed_count = 0
  local replacement_by_id = {}
  local warnings = {}
  local source_languages = {}
  local pumping = false
  local pump_requested = false

  local function fail(err)
    if self.settled or self.cancelled then
      return
    end
    self.settled = true
    self:cancel()
    callbacks.on_error(err)
  end

  local function finish_if_ready()
    if self.settled or self.cancelled or completed_count ~= #batches then
      return
    end
    local replacements = {}
    for _, unit_id in ipairs(snapshot.order) do
      if not snapshot.units[unit_id].opaque then
        replacements[#replacements + 1] = replacement_by_id[unit_id]
      end
    end
    self.settled = true
    callbacks.on_complete({
      schema_version = 1,
      task_id = "initial:aggregate",
      destination_side = "target",
      replacement_units = replacements,
      warnings = warnings,
      metadata = {
        source_languages = source_languages,
        document_source_language = document_language(snapshot, source_languages),
      },
    })
  end

  local pump
  local function complete_task(task, result)
    if self.cancelled or self.settled then
      return
    end
    self.active[task.task_id] = nil
    if self.external_active_jobs then
      self.external_active_jobs[task.task_id] = nil
    end
    active_count = active_count - 1
    if self.get_source_version() ~= source_version then
      self:cancel()
      self.settled = true
      callbacks.on_stale()
      return
    end
    if
      type(result) ~= "table"
      or result.schema_version ~= 1
      or result.task_id ~= task.task_id
      or result.destination_side ~= "target"
      or type(result.replacement_units) ~= "table"
    then
      fail(result_error("An initial translation batch returned an invalid envelope"))
      return
    end
    local expected = {}
    for _, unit in ipairs(task.edited_after.units) do
      expected[unit.unit_id] = true
    end
    local seen = {}
    for _, replacement in ipairs(result.replacement_units) do
      local ids = replacement.corresponds_to_edited_unit_ids
      local unit_id = type(ids) == "table" and #ids == 1 and ids[1] or nil
      if not unit_id or not expected[unit_id] or seen[unit_id] or replacement_by_id[unit_id] then
        fail(result_error("Initial translation batch IDs are incomplete, duplicate, or unknown"))
        return
      end
      seen[unit_id] = true
      replacement_by_id[unit_id] = replacement
    end
    for unit_id in pairs(expected) do
      if not seen[unit_id] then
        fail(result_error("Initial translation batch omitted a unit", { unit_id = unit_id }))
        return
      end
    end
    for _, warning in ipairs(result.warnings or {}) do
      warnings[#warnings + 1] = warning
    end
    for unit_id, language in pairs(result.metadata and result.metadata.source_languages or {}) do
      source_languages[unit_id] = language
    end
    completed_count = completed_count + 1
    report_progress(completed_count)
    pump()
  end

  pump = function()
    if pumping then
      pump_requested = true
      return
    end
    pumping = true
    repeat
      pump_requested = false
      while
        not self.cancelled
        and not self.settled
        and active_count < self.max_concurrency
        and next_batch <= #batches
      do
        local ids = batches[next_batch]
        next_batch = next_batch + 1
        local task, task_error = self.make_task(ids)
        if not task then
          fail(task_error)
          break
        end
        active_count = active_count + 1
        local terminal = false
        local handle = self.translator:submit(task, {
          on_complete = function(result)
            if terminal then
              return
            end
            terminal = true
            complete_task(task, result)
          end,
          on_error = function(err)
            if terminal then
              return
            end
            terminal = true
            self.active[task.task_id] = nil
            if self.external_active_jobs then
              self.external_active_jobs[task.task_id] = nil
            end
            active_count = active_count - 1
            fail(err)
          end,
          is_current = function()
            return not self.cancelled
              and not self.settled
              and self.get_source_version() == source_version
          end,
        })
        if not terminal then
          self.active[task.task_id] = handle
          if self.external_active_jobs then
            self.external_active_jobs[task.task_id] = handle
          end
        end
      end
      finish_if_ready()
    until not pump_requested
    pumping = false
  end
  pump()
end

return {
  new = Runner.new,
  batch_ids = batch_ids,
  document_language = document_language,
}
