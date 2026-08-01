local document = require("bilingua.domain.document")
local errors = require("bilingua.domain.error")
local initial_translation_module = require("bilingua.app.initial_translation")
local sync_engine_module = require("bilingua.app.sync_engine")

local Session = {}
Session.__index = Session

local REQUIRED_DEPENDENCIES = {
  "editor",
  "document_adapter",
  "unit_tracker",
  "aligner",
  "translator",
  "config",
}

local function empty_document_range(text)
  if text == "" then
    return { start = { row = 0, col = 0 }, finish = { row = 0, col = 0 } }
  end

  local row = 0
  local line_start = 1
  while true do
    local newline = text:find("\n", line_start, true)
    if not newline then
      break
    end
    row = row + 1
    line_start = newline + 1
  end
  return {
    start = { row = 0, col = 0 },
    finish = { row = row, col = #text - line_start + 1 },
  }
end

local IMMEDIATE_SCHEDULER = {
  defer = function(_, _, callback)
    callback()
    return {
      cancel = function() end,
    }
  end,
}

local function recovery_error(value, message)
  if
    type(value) == "table"
    and type(value.code) == "string"
    and type(value.message) == "string"
  then
    return value
  end
  return errors.new(errors.codes.BACKEND_INIT, message, false, nil, value)
end

local REQUIRED_TRANSLATION_METHODS = {
  "capabilities",
  "open",
  "submit",
  "close",
}

local AUTO_SYNC_PAUSE_CODES = {
  [errors.codes.BACKEND_NOT_FOUND] = true,
  [errors.codes.BACKEND_INIT] = true,
  [errors.codes.BACKEND_UNAVAILABLE] = true,
  [errors.codes.BACKEND_PROTOCOL] = true,
  [errors.codes.BACKEND_AUTH] = true,
  [errors.codes.BACKEND_TOOL_ATTEMPT] = true,
  [errors.codes.BACKEND_INSTRUCTION_SOURCE] = true,
  [errors.codes.EPHEMERAL_REQUIRED] = true,
  [errors.codes.INVALID_OUTPUT] = true,
}

local function valid_translation_service(service)
  if type(service) ~= "table" then
    return false
  end
  for _, method in ipairs(REQUIRED_TRANSLATION_METHODS) do
    if type(service[method]) ~= "function" then
      return false
    end
  end
  return true
end

function Session.new(components)
  if type(components) ~= "table" then
    error("Session components are required", 2)
  end
  for _, name in ipairs(REQUIRED_DEPENDENCIES) do
    if components[name] == nil then
      error(("Session component '%s' is required"):format(name), 2)
    end
  end

  return setmetatable({
    id = components.id,
    editor = components.editor,
    document_adapter = components.document_adapter,
    unit_tracker = components.unit_tracker,
    aligner = components.aligner,
    translator = components.translator,
    translator_factory = components.translator_factory,
    scheduler = components.scheduler or IMMEDIATE_SCHEDULER,
    config = components.config,
    state = "new",
    health = "starting",
    backend_restarting = false,
    automatic_sync_paused = false,
    source_snapshot = nil,
    target_snapshot = nil,
    mapping_graph = nil,
    subscriptions = {},
    active_jobs = {},
    sync_timers = {},
    pending_changes = { source = {}, target = {} },
    task_sequence = 0,
    disposed = false,
  }, Session)
end

function Session:next_task_id(kind)
  self.task_sequence = self.task_sequence + 1
  return ("%s:task:%s:%d"):format(self.id, kind, self.task_sequence)
end

function Session:handle_sync_event(event, data, err)
  local event_data = type(data) == "table" and data or {}
  if
    event == "BilinguaError"
    and err
    and err.code ~= errors.codes.STALE_RESULT
    and err.code ~= errors.codes.BACKEND_CANCELLED
  then
    self.last_error = err
    self.health = "degraded"
    if AUTO_SYNC_PAUSE_CODES[err.code] then
      self.automatic_sync_paused = true
      self:cancel_sync_timers()
    end
  elseif
    event == "BilinguaSyncCompleted"
    and not self.automatic_sync_paused
    and self.sync_engine
    and self.sync_engine.last_error == nil
  then
    self.last_error = nil
    self.health = "healthy"
  end

  if type(self.on_event) == "function" then
    pcall(self.on_event, event, {
      session_id = self.id,
      group_id = event_data.group_id,
      task_id = event_data.task_id,
      state = event_data.state,
      error_code = event_data.error_code or (err and err.code or nil),
    })
  end
end

function Session:fail_start(err, callback)
  if self.initial_runner then
    self.initial_runner:cancel()
    self.initial_runner = nil
  end
  if self.initial_restart_timer then
    self.initial_restart_timer:cancel()
    self.initial_restart_timer = nil
  end
  self:update_initial_progress(nil)
  self.state = "failed"
  self.health = "degraded"
  local close_called, close_failure = pcall(
    self.translator.close,
    self.translator,
    function(_, close_error)
      if close_error then
        self.close_error = type(close_error) == "table" and close_error
          or errors.new(
            errors.codes.INTERNAL,
            "TranslationService cleanup failed after Session start",
            false,
            nil,
            close_error
          )
      end
    end
  )
  if not close_called then
    self.close_error = errors.new(
      errors.codes.INTERNAL,
      "TranslationService cleanup raised after Session start",
      false,
      nil,
      close_failure
    )
  end

  local dispose_called, _, dispose_failure =
    pcall(self.editor.dispose, self.editor, { force = true })
  if not dispose_called then
    self.dispose_error =
      errors.new(errors.codes.INTERNAL, "Editor cleanup raised after Session start", false, nil, _)
  elseif dispose_failure then
    self.dispose_error = type(dispose_failure) == "table" and dispose_failure
      or errors.new(
        errors.codes.INTERNAL,
        "Editor cleanup failed after Session start",
        false,
        nil,
        dispose_failure
      )
  end
  callback(nil, err)
end

function Session:update_initial_progress(progress)
  local ui = self.config and self.config.ui or nil
  if
    ui
    and ui.show_progress == true
    and type(self.editor.render_initial_progress) == "function"
  then
    pcall(self.editor.render_initial_progress, self.editor, progress)
  end
end

function Session:submit_initial_batches(source_document, callback)
  self.state = "translating_initial"
  self.initial_runner = initial_translation_module.new({
    translator = self.translator,
    limits = self.config.limits,
    max_concurrency = self.config.sync and self.config.sync.max_concurrency or 1,
    active_jobs = self.active_jobs,
    get_source_version = function()
      return self.editor:get_version("source")
    end,
    make_task = function(unit_ids)
      return self:initial_task(self.source_snapshot, unit_ids)
    end,
  })
  self.initial_runner:run(self.source_snapshot, source_document.version, {
    on_progress = function(progress)
      self:update_initial_progress(progress)
    end,
    on_complete = function(result)
      self.initial_runner = nil
      self:complete_initial_start(source_document, result, callback)
    end,
    on_error = function(err)
      self.initial_runner = nil
      self:fail_start(err, callback)
    end,
    on_stale = function()
      self.initial_runner = nil
      self:update_initial_progress(nil)
      self:schedule_initial_restart(callback)
    end,
  })
end

function Session:restart_initial(callback)
  if self.state == "stopping" or self.state == "stopped" then
    return
  end
  self.state = "parsing_source"
  local source_document, source_error = self.editor:get_document("source")
  local valid, validation_error = self:validate_source(source_document)
  if not valid then
    return self:fail_start(validation_error or source_error, callback)
  end
  self.source_snapshot, source_error = self.document_adapter:parse({
    side = "source",
    text = source_document.text,
    filetype = source_document.filetype,
    language = self.config.source_language,
    editor_version = source_document.version,
    metadata = source_document.metadata,
  })
  if not self.source_snapshot then
    return self:fail_start(source_error, callback)
  end
  if #self.source_snapshot.order > self.config.limits.max_units then
    return self:fail_start(
      errors.new(
        errors.codes.DOCUMENT_TOO_LARGE,
        "The source document exceeds the unit limit",
        false
      ),
      callback
    )
  end
  self:submit_initial_batches(source_document, callback)
end

function Session:schedule_initial_restart(callback)
  if self.initial_restart_timer then
    self.initial_restart_timer:cancel()
  end
  self.state = "parsing_source"
  local milliseconds = self.config.sync and self.config.sync.debounce_ms or 700
  local timer
  timer = self.scheduler:defer(milliseconds, function()
    if self.initial_restart_timer == timer then
      self.initial_restart_timer = nil
    end
    self:restart_initial(callback)
  end)
  self.initial_restart_timer = timer
end

function Session:validate_source(source)
  if
    type(source) ~= "table"
    or type(source.text) ~= "string"
    or type(source.version) ~= "number"
  then
    return nil,
      errors.new(errors.codes.INVALID_SOURCE_BUFFER, "The source document is unavailable", false)
  end
  local limits = self.config.limits
  if #source.text > limits.max_document_bytes then
    return nil,
      errors.new(
        errors.codes.DOCUMENT_TOO_LARGE,
        "The source document exceeds the byte limit",
        false
      )
  end
  return true
end

function Session:initial_task(source_snapshot, unit_ids)
  local fragment, fragment_error = document.fragment(source_snapshot, unit_ids)
  if not fragment then
    return nil, fragment_error
  end
  return {
    schema_version = 1,
    task_id = self:next_task_id("initial"),
    session_id = self.id,
    kind = "initial_translate",
    direction = "source_to_target",
    source_language = self.config.source_language,
    target_language = self.config.target_language,
    mapping_group_id = nil,
    baseline = nil,
    edited_side = "source",
    edited_before = nil,
    edited_after = fragment,
    destination_before = nil,
    context_before = {},
    context_after = {},
    constraints = { preserve_placeholders = true },
    revision = source_snapshot.document_version,
    metadata = {},
  }
end

function Session:install_subscriptions()
  for _, side in ipairs({ "source", "target" }) do
    self.subscriptions[#self.subscriptions + 1] = self.editor:subscribe_changes(
      side,
      function(change)
        self:on_editor_change(change)
      end
    )
  end
end

function Session:cancel_sync_timer(side)
  local token = self.sync_timers[side]
  if not token then
    return
  end
  self.sync_timers[side] = nil
  if token.handle and type(token.handle.cancel) == "function" then
    token.handle:cancel()
  end
end

function Session:cancel_sync_timers()
  self:cancel_sync_timer("source")
  self:cancel_sync_timer("target")
end

function Session:run_automatic_sync()
  if self.state ~= "ready" or self.backend_restarting or self.automatic_sync_paused then
    return
  end
  local synced, sync_error = self:sync_all()
  if not synced and self.last_error ~= sync_error then
    self:handle_sync_event("BilinguaError", {
      session_id = self.id,
      state = self.state,
      error_code = sync_error and sync_error.code or nil,
    }, sync_error)
  end
end

function Session:schedule_sync(side, immediate)
  self:cancel_sync_timer(side)
  if self.automatic_sync_paused then
    return
  end
  if immediate then
    self:run_automatic_sync()
    return
  end
  local token = {}
  self.sync_timers[side] = token
  token.handle = self.scheduler:defer(self.config.sync.debounce_ms, function()
    if self.sync_timers[side] ~= token then
      return
    end
    self.sync_timers[side] = nil
    self:run_automatic_sync()
  end)
end

function Session:handle_editor_detach(side)
  if self.auto_dispose_started or self.state == "stopped" then
    return
  end
  self.auto_dispose_started = true

  if self.state == "stopping" and self.stop_operation then
    local previous = self.stop_operation
    previous.settled = true
    self:cancel_stop_timeout(previous)
    self.stop_operation = nil
    self.state = "failed"
    local interrupted = errors.new(
      errors.codes.SESSION_CLOSED,
      "Normal stop was interrupted because an owned buffer detached",
      false
    )
    if previous.callback then
      previous.callback(nil, interrupted)
    end
  end

  local notified = false
  local function notify(stop_error)
    if notified then
      return
    end
    notified = true
    if type(self.on_auto_dispose) == "function" then
      local ok, callback_error = pcall(self.on_auto_dispose, self, side, stop_error)
      if not ok then
        self.lifecycle_error = errors.new(
          errors.codes.INTERNAL,
          "Autonomous Session disposal callback failed",
          false,
          nil,
          callback_error
        )
      end
    end
  end
  local stopped, stop_error = self:stop({ force = true }, function(_, err)
    notify(err)
  end)
  if not stopped then
    notify(stop_error)
  end
end

function Session:on_editor_change(change)
  if type(change) ~= "table" then
    return
  end
  if change.detached then
    self:handle_editor_detach(change.side)
    return
  end
  if self.state ~= "ready" or change.origin == "plugin" then
    return
  end
  if change.side ~= "source" and change.side ~= "target" then
    return
  end
  if change.flush then
    if self.config.sync.automatic and self.config.sync.on_insert_leave ~= false then
      self:schedule_sync(change.side, true)
    end
    return
  end
  local pending = self.pending_changes[change.side]
  pending[#pending + 1] = change
  if self.config.sync.automatic then
    self:schedule_sync(change.side, false)
  end
end

function Session:apply_initial_source_languages(result)
  local metadata = result.metadata or {}
  local source_languages = metadata.source_languages or {}
  local configured = self.config.source_language
  local document_language = configured ~= "auto" and configured
    or metadata.document_source_language
    or "und"
  self.source_snapshot.language = document_language
  for _, unit_id in ipairs(self.source_snapshot.order) do
    local unit = self.source_snapshot.units[unit_id]
    unit.language = configured ~= "auto" and configured
      or source_languages[unit_id]
      or (unit.opaque and document_language or "und")
  end
end

function Session:create_sync_engine(translator)
  return sync_engine_module.new({
    session_id = self.id,
    editor = self.editor,
    document_adapter = self.document_adapter,
    unit_tracker = self.unit_tracker,
    aligner = self.aligner,
    translator = translator,
    config = self.config,
    source_snapshot = self.source_snapshot,
    target_snapshot = self.target_snapshot,
    mapping_graph = self.mapping_graph,
    get_session_state = function()
      return self.state
    end,
    on_update = function(source, target, graph)
      self.source_snapshot, self.target_snapshot, self.mapping_graph = source, target, graph
    end,
    on_event = function(event, data, err)
      self:handle_sync_event(event, data, err)
    end,
  })
end

function Session:complete_initial_start(source_document, result, callback)
  if self.editor:get_version("source") ~= source_document.version then
    return self:schedule_initial_restart(callback)
  end

  self:apply_initial_source_languages(result)
  local built, build_error = self.document_adapter:build_initial_target({
    source_snapshot = self.source_snapshot,
    result = result,
  })
  if not built then
    return self:fail_start(build_error, callback)
  end

  if type(built.text) ~= "string" then
    return self:fail_start(
      errors.new(
        errors.codes.INVALID_OUTPUT,
        "The document adapter returned invalid initial target text",
        false
      ),
      callback
    )
  end
  if #built.text > self.config.limits.max_document_bytes then
    return self:fail_start(
      errors.new(
        errors.codes.DOCUMENT_TOO_LARGE,
        "The initial target exceeds the configured byte limit",
        false,
        { bytes = #built.text, maximum = self.config.limits.max_document_bytes }
      ),
      callback
    )
  end

  local target_document, target_error = self.editor:get_document("target")
  if not target_document then
    return self:fail_start(target_error, callback)
  end
  local applied, apply_error = self.editor:apply_edits("target", {
    {
      range = empty_document_range(target_document.text),
      replacement = built.text,
      expected_text = target_document.text,
      metadata = { initial = true },
    },
  }, target_document.version, "bilingua-initial")
  if not applied then
    return self:fail_start(apply_error, callback)
  end

  target_document, target_error = self.editor:get_document("target")
  if not target_document then
    return self:fail_start(target_error, callback)
  end
  self.target_snapshot, target_error = self.document_adapter:parse({
    side = "target",
    text = target_document.text,
    filetype = target_document.filetype,
    language = self.config.target_language,
    editor_version = target_document.version,
    metadata = target_document.metadata,
  })
  if not self.target_snapshot then
    return self:fail_start(target_error, callback)
  end

  if #self.target_snapshot.order > self.config.limits.max_units then
    return self:fail_start(
      errors.new(
        errors.codes.DOCUMENT_TOO_LARGE,
        "The initial target exceeds the configured unit limit",
        false,
        { units = #self.target_snapshot.order, maximum = self.config.limits.max_units }
      ),
      callback
    )
  end

  self.mapping_graph, target_error = self.aligner:initialize({
    source_snapshot = self.source_snapshot,
    target_snapshot = self.target_snapshot,
    construction_seeds = built.seeds,
    initial_translation_result = result,
  })
  if not self.mapping_graph then
    return self:fail_start(target_error, callback)
  end

  self.sync_engine = self:create_sync_engine(self.translator)
  self.editor:set_unit_anchors("source", self.source_snapshot)
  self.editor:set_unit_anchors("target", self.target_snapshot)
  self:update_initial_progress(nil)
  self.editor:render_group_states(self.mapping_graph)
  self:install_subscriptions()
  self.editor:set_target_modifiable(true)
  self.state = "ready"
  self.health = "healthy"
  self.automatic_sync_paused = false
  callback(true)
end

function Session:start(callback)
  if self.state ~= "new" then
    callback(nil, errors.new(errors.codes.SESSION_STATE, "Session can only be started once", false))
    return
  end
  if type(callback) ~= "function" then
    error("Session start callback is required", 2)
  end

  local source_document, source_error = self.editor:get_document("source")
  local valid, validation_error = self:validate_source(source_document)
  if not valid then
    return self:fail_start(validation_error or source_error, callback)
  end

  self.state = "starting_backend"
  self.editor:create_target_view(
    { target_language = self.config.target_language },
    function(_, view_error)
      if view_error then
        return self:fail_start(view_error, callback)
      end

      self.translator:open(function(opened, open_error)
        if not opened then
          return self:fail_start(open_error, callback)
        end

        self.state = "parsing_source"
        self.source_snapshot, source_error = self.document_adapter:parse({
          side = "source",
          text = source_document.text,
          filetype = source_document.filetype,
          language = self.config.source_language,
          editor_version = source_document.version,
          metadata = source_document.metadata,
        })
        if not self.source_snapshot then
          return self:fail_start(source_error, callback)
        end
        if #self.source_snapshot.order > self.config.limits.max_units then
          return self:fail_start(
            errors.new(
              errors.codes.DOCUMENT_TOO_LARGE,
              "The source document exceeds the unit limit",
              false
            ),
            callback
          )
        end

        self:submit_initial_batches(source_document, callback)
      end)
    end
  )
end

function Session:side_for_buffer(buffer)
  if buffer == self.source_buf then
    return "source"
  elseif buffer == self.target_buf then
    return "target"
  end
  return nil
end

function Session:group_id_for_unit(side, unit_id)
  if not self.mapping_graph or not unit_id then
    return nil
  end
  if type(self.mapping_graph.group_ids_for_unit) == "function" then
    local group_ids = self.mapping_graph:group_ids_for_unit(side, unit_id)
    return group_ids and group_ids[1] or nil
  end
  local index = self.mapping_graph[side .. "_index"]
  if index and index[unit_id] then
    return index[unit_id][1]
  end
  local field = side .. "_unit_ids"
  for _, group_id in ipairs(self.mapping_graph.order or {}) do
    for _, candidate in ipairs(self.mapping_graph.groups[group_id][field] or {}) do
      if candidate == unit_id then
        return group_id
      end
    end
  end
  return nil
end

function Session:current_group_id(buffer)
  if self.state ~= "ready" then
    return nil, errors.new(errors.codes.SESSION_STATE, "The Session is not ready", false)
  end
  local side = self:side_for_buffer(buffer)
  if not side then
    return nil,
      errors.new(
        errors.codes.SESSION_STATE,
        "The current buffer does not belong to this Session",
        false
      )
  end
  local unit_id = self.editor:unit_at_cursor(side)
  local group_id = self:group_id_for_unit(side, unit_id)
  if not group_id then
    return nil,
      errors.new(errors.codes.ALIGNMENT, "No mapping group exists at the cursor", false),
      side
  end
  return group_id, nil, side
end

function Session:toggle(buffer)
  local group_id, group_error, side = self:current_group_id(buffer)
  local destination = side == "source" and "target" or "source"
  if not group_id then
    if side and self.editor:focus_side(destination) then
      return true
    end
    return nil, group_error
  end
  local group = self.mapping_graph.groups[group_id]
  local unit_ids = destination == "source" and group.source_unit_ids or group.target_unit_ids
  if #unit_ids > 0 and self.editor:focus_group(destination, unit_ids) then
    return group_id
  end
  if self.editor:focus_side(destination) then
    return group_id
  end
  return nil,
    errors.new(errors.codes.SESSION_STATE, "The opposite Session buffer is unavailable", false)
end

function Session:navigate_group(buffer, step)
  local group_id, group_error, side = self:current_group_id(buffer)
  if not group_id then
    return nil, group_error
  end
  local ordinal
  for index, candidate in ipairs(self.mapping_graph.order) do
    if candidate == group_id then
      ordinal = index
      break
    end
  end
  if not ordinal then
    return nil,
      errors.new(errors.codes.ALIGNMENT, "The current mapping group is not ordered", false)
  end
  local destination_ordinal = math.max(1, math.min(#self.mapping_graph.order, ordinal + step))
  local destination_id = self.mapping_graph.order[destination_ordinal]
  local destination_group = self.mapping_graph.groups[destination_id]
  local unit_ids = side == "source" and destination_group.source_unit_ids
    or destination_group.target_unit_ids
  if #unit_ids == 0 or not self.editor:focus_group(side, unit_ids) then
    return nil,
      errors.new(errors.codes.ALIGNMENT, "The mapping group has no position on this side", false)
  end
  return destination_id
end

function Session:next_group(buffer)
  return self:navigate_group(buffer, 1)
end

function Session:prev_group(buffer)
  return self:navigate_group(buffer, -1)
end

function Session:sync_current(buffer)
  if not self.sync_engine then
    return nil,
      errors.new(
        errors.codes.SESSION_STATE,
        "Synchronization is unavailable before startup completes",
        false
      )
  end
  for _, side in ipairs({ "source", "target" }) do
    local changes = self.pending_changes[side]
    if #changes > 0 then
      local processed, process_error = self.sync_engine:process_side(side, changes)
      if not processed then
        return nil, process_error
      end
      self.pending_changes[side] = {}
    end
  end
  local group_id, group_error = self:current_group_id(buffer)
  if not group_id then
    return nil, group_error
  end
  return self.sync_engine:retry_group(group_id, 100)
end

function Session:retry_current(buffer)
  return self:sync_current(buffer)
end

local function count_entries(values)
  local count = 0
  for _ in pairs(values or {}) do
    count = count + 1
  end
  return count
end

function Session:status_snapshot()
  local groups = {
    clean = 0,
    dirty_source = 0,
    dirty_target = 0,
    syncing_source_to_target = 0,
    syncing_target_to_source = 0,
    conflict = 0,
    invalid = 0,
  }
  if self.mapping_graph then
    for _, group_id in ipairs(self.mapping_graph.order) do
      local state = self.mapping_graph.groups[group_id].state
      groups[state] = (groups[state] or 0) + 1
    end
  end
  local backend = self.translator and self.translator.backend
  local model
  if backend and type(backend.selected_model) == "function" then
    model = backend:selected_model()
  end
  return {
    session_id = self.id,
    state = self.state,
    health = self.health,
    source_buf = self.source_buf,
    source_path = self.source_path,
    target_buf = self.target_buf,
    source_language = self.source_snapshot and self.source_snapshot.language
      or self.config.source_language,
    target_language = self.target_snapshot and self.target_snapshot.language
      or self.config.target_language,
    document_adapter = self.document_adapter.id,
    tracker = self.unit_tracker.id,
    aligner = self.aligner.id,
    backend = backend and backend.id
      or (self.config.translation and self.config.translation.backend),
    model = model,
    groups = groups,
    active_tasks = count_entries(self.active_jobs)
      + count_entries(self.sync_engine and self.sync_engine.active_jobs),
    automatic_sync = self.config.sync
      and self.config.sync.automatic == true
      and not self.automatic_sync_paused,
    automatic_sync_configured = self.config.sync and self.config.sync.automatic == true,
    automatic_sync_paused = self.automatic_sync_paused == true,
  }
end

function Session:sync_all()
  if not self.sync_engine then
    return nil,
      errors.new(
        errors.codes.SESSION_STATE,
        "Synchronization is unavailable before startup completes",
        false
      )
  end
  self:cancel_sync_timers()
  return self.sync_engine:sync_all(self.pending_changes)
end

function Session:restart_backend(callback)
  callback = callback or function() end
  if type(callback) ~= "function" then
    error("Backend restart callback must be a function", 2)
  end
  if self.backend_restarting then
    return nil,
      errors.new(errors.codes.SESSION_STATE, "Backend restart is already in progress", false)
  end
  if
    self.state ~= "ready"
    or not self.source_snapshot
    or not self.target_snapshot
    or not self.mapping_graph
  then
    return nil,
      errors.new(
        errors.codes.SESSION_STATE,
        "Backend restart requires an initialized Session",
        false
      )
  end
  if type(self.translator_factory) ~= "function" then
    return nil,
      errors.new(errors.codes.BACKEND_INIT, "No TranslationService factory is available", false)
  end

  local operation = { callback = callback, settled = false, synchronous = true }
  self.backend_restart_operation = operation

  local function settle_failure(value, message)
    if self.backend_restart_operation ~= operation or operation.settled then
      return
    end
    local err = recovery_error(value, message)
    operation.settled = true
    self.backend_restart_operation = nil
    self.backend_restarting = false
    self.health = "degraded"
    self.automatic_sync_paused = true
    self.last_error = err
    if operation.synchronous then
      operation.immediate_error = err
    end
    operation.callback(nil, err)
  end

  local function settle_success(service)
    if self.backend_restart_operation ~= operation or operation.settled then
      return
    end
    local created, engine = pcall(self.create_sync_engine, self, service)
    if not created then
      pcall(service.close, service, function() end)
      settle_failure(engine, "Failed to rebuild synchronization after backend restart")
      return
    end
    self.sync_engine = engine
    operation.settled = true
    self.backend_restart_operation = nil
    self.backend_restarting = false
    self.state = "ready"
    self.health = "healthy"
    self.automatic_sync_paused = false
    self.last_error = nil
    if self.config.sync and self.config.sync.automatic then
      self:run_automatic_sync()
    end
    operation.callback(true)
  end

  local function create_and_open_service()
    if self.backend_restart_operation ~= operation or operation.settled then
      return
    end
    local created, service, factory_error = pcall(self.translator_factory)
    if not created then
      settle_failure(service, "TranslationService factory raised an error")
      return
    end
    if not valid_translation_service(service) then
      settle_failure(factory_error, "TranslationService factory returned an invalid service")
      return
    end

    self.translator = service
    local invoked, open_failure = pcall(service.open, service, function(opened, open_error)
      if self.backend_restart_operation ~= operation or operation.settled then
        return
      end
      if not opened then
        settle_failure(open_error, "TranslationService failed to open after restart")
        return
      end
      settle_success(service)
    end)
    if not invoked then
      settle_failure(open_failure, "TranslationService open raised an error")
    end
  end

  self:cancel_sync_timers()
  self.backend_restarting = true
  self.health = "starting"
  self.automatic_sync_paused = true
  if self.sync_engine then
    self.sync_engine:dispose()
  end
  self.sync_engine = nil

  local previous_service = self.translator
  local invoked, close_failure = pcall(
    previous_service.close,
    previous_service,
    function(closed, close_error)
      if self.backend_restart_operation ~= operation or operation.settled then
        return
      end
      if not closed then
        settle_failure(close_error, "TranslationService failed to close for restart")
        return
      end
      create_and_open_service()
    end
  )
  if not invoked then
    settle_failure(close_failure, "TranslationService close raised an error")
  end

  operation.synchronous = false
  if operation.immediate_error then
    return nil, operation.immediate_error
  end
  return true
end

function Session:cancel_backend_restart(reason)
  local operation = self.backend_restart_operation
  if not operation or operation.settled then
    return false
  end
  operation.settled = true
  self.backend_restart_operation = nil
  self.backend_restarting = false
  local err = reason
    or errors.new(
      errors.codes.SESSION_CLOSED,
      "Backend restart was cancelled because the Session is stopping",
      false
    )
  local delivered, callback_error = pcall(operation.callback, nil, err)
  if not delivered then
    self.lifecycle_error = errors.new(
      errors.codes.INTERNAL,
      "Backend restart cancellation callback failed",
      false,
      nil,
      callback_error
    )
  end
  return true
end

function Session:use_source(group_id)
  if not self.sync_engine then
    return nil, errors.new(errors.codes.SESSION_STATE, "Conflict resolution is unavailable", false)
  end
  return self.sync_engine:resolve_conflict(group_id, "source")
end

function Session:use_japanese(group_id)
  if not self.sync_engine then
    return nil, errors.new(errors.codes.SESSION_STATE, "Conflict resolution is unavailable", false)
  end
  return self.sync_engine:resolve_conflict(group_id, "target")
end

function Session:cancel_stop_timeout(operation)
  if not operation or not operation.timeout_handle then
    return
  end
  local handle = operation.timeout_handle
  operation.timeout_handle = nil
  if type(handle.cancel) == "function" then
    handle:cancel()
  end
end

function Session:cancel_start_work()
  if self.initial_runner then
    self.initial_runner:cancel()
    self.initial_runner = nil
  end
  if self.initial_restart_timer then
    self.initial_restart_timer:cancel()
    self.initial_restart_timer = nil
  end
  self:update_initial_progress(nil)
  for _, handle in pairs(self.active_jobs) do
    if type(handle.cancel) == "function" then
      handle:cancel()
    end
  end
  self.active_jobs = {}
end

function Session:finalize_stop(callback)
  if self.sync_engine then
    self.sync_engine:dispose()
  end
  for _, subscription in ipairs(self.subscriptions) do
    subscription:dispose()
  end
  self.subscriptions = {}
  self.editor:dispose({ force = true })
  self.mapping_graph = nil
  self.source_snapshot = nil
  self.target_snapshot = nil
  self.sync_engine = nil
  self.translator = nil
  self.pending_changes = { source = {}, target = {} }
  self.backend_restart_operation = nil
  self.backend_restarting = false
  self.active_jobs = {}
  self.state = "stopped"
  self.health = "disposed"
  self.disposed = true
  if callback then
    callback(true)
  end
end

function Session:settle_stop_failure(operation, err, recovery_state)
  if self.stop_operation ~= operation or operation.settled then
    return
  end
  operation.settled = true
  self:cancel_stop_timeout(operation)
  self.stop_operation = nil
  self.state = recovery_state
  self.health = "degraded"
  self.last_error = err
  self.editor:set_target_modifiable(recovery_state == "ready")
  if operation.synchronous then
    operation.immediate_error = err
  end
  if operation.callback then
    operation.callback(nil, err)
  end
end

function Session:settle_stop_success(operation)
  if self.stop_operation ~= operation or operation.settled then
    return
  end
  operation.settled = true
  self:cancel_stop_timeout(operation)
  self.stop_operation = nil
  self:finalize_stop(operation.callback)
end

function Session:close_for_stop(operation)
  if self.stop_operation ~= operation or operation.settled then
    return
  end
  local service = self.translator
  if not service then
    self:settle_stop_success(operation)
    return
  end
  local invoked, invocation_error = pcall(service.close, service, function(closed, close_error)
    if self.stop_operation ~= operation or operation.settled then
      return
    end
    if not closed then
      local normalized = close_error
        or errors.new(errors.codes.SESSION_CLOSED, "Translation service did not close", false)
      if not operation.force then
        self:settle_stop_failure(operation, normalized, "failed")
        return
      end
      self.close_error = normalized
    end
    self:settle_stop_success(operation)
  end)
  if not invoked and self.stop_operation == operation and not operation.settled then
    local normalized = errors.new(
      errors.codes.INTERNAL,
      "Translation service close raised an internal error",
      false,
      nil,
      invocation_error
    )
    if operation.force then
      self.close_error = normalized
    else
      self:settle_stop_failure(operation, normalized, "failed")
      return
    end
  end
  if operation.force and self.stop_operation == operation and not operation.settled then
    self:settle_stop_success(operation)
  end
end

function Session:start_stop_timeout(operation)
  local stop_config = self.config.stop or {}
  local timeout_ms = stop_config.timeout_ms or 120000
  if type(timeout_ms) ~= "number" or timeout_ms <= 0 then
    return
  end
  local handle = self.scheduler:defer(timeout_ms, function()
    if self.stop_operation ~= operation or operation.settled then
      return
    end
    self:settle_stop_failure(
      operation,
      errors.new(errors.codes.BACKEND_TIMEOUT, "Session stop timed out", true),
      "failed"
    )
  end)
  if self.stop_operation == operation and not operation.settled then
    operation.timeout_handle = handle
  elseif handle and type(handle.cancel) == "function" then
    handle:cancel()
  end
end

function Session:stop(options, callback)
  local force = options and options.force == true
  if self.state == "stopped" then
    if callback then
      callback(true)
    end
    return true
  end
  if self.state == "stopping" then
    return nil, errors.new(errors.codes.SESSION_STATE, "Session stop is already in progress", false)
  end
  if not force and self.state ~= "ready" and self.state ~= "failed" then
    return nil,
      errors.new(
        errors.codes.SESSION_STATE,
        "Normal stop requires a ready or failed session",
        false
      )
  end

  self:cancel_backend_restart(
    errors.new(
      errors.codes.SESSION_CLOSED,
      "Backend restart was cancelled because the Session is stopping",
      false
    )
  )

  local previous_state = self.state
  local operation = {
    callback = callback,
    force = force,
    settled = false,
    synchronous = true,
  }
  self.stop_operation = operation
  self.state = "stopping"
  self.health = "stopping"
  self:cancel_sync_timers()
  self:cancel_start_work()
  self.editor:set_target_modifiable(false)

  if force then
    if self.sync_engine then
      self.sync_engine:dispose()
    end
    self:close_for_stop(operation)
  elseif previous_state == "failed" or not self.sync_engine then
    self:close_for_stop(operation)
  else
    local stop_config = self.config.stop or {}
    local accepted, sync_error = self.sync_engine:sync_for_stop(
      self.pending_changes,
      stop_config.sync_pending ~= false,
      function(synced, err)
        if self.stop_operation ~= operation or operation.settled then
          return
        end
        if not synced then
          self:settle_stop_failure(operation, err, "ready")
          return
        end
        self:close_for_stop(operation)
      end
    )
    if not accepted then
      self:settle_stop_failure(operation, sync_error, "ready")
    end
  end

  if self.stop_operation == operation and not operation.settled then
    self:start_stop_timeout(operation)
  end
  operation.synchronous = false
  if operation.immediate_error then
    return nil, operation.immediate_error
  end
  return true
end

return {
  new = Session.new,
}
