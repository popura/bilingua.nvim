local errors = require("bilingua.domain.error")

local Coordinator = {}
Coordinator.__index = Coordinator

local REQUIRED_ENVIRONMENT_METHODS = {
  "current_buffer",
  "current_window",
  "inspect_buffer",
  "emit",
  "close_buffer",
}

local function state_error(message)
  return errors.new(errors.codes.SESSION_STATE, message, false)
end

local function invoke(callback, value, err, config)
  if callback then
    callback(value, err, config)
  end
end

local function copy_value(value, seen)
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
    copy[copy_value(key, visited)] = copy_value(item, visited)
  end
  return copy
end

function Coordinator.new(components)
  if
    type(components) ~= "table"
    or type(components.session_factory) ~= "table"
    or type(components.sessions) ~= "table"
    or type(components.resolve_config) ~= "function"
  then
    error("Coordinator requires a SessionFactory, SessionRegistry, and configuration resolver", 2)
  end
  if type(components.environment) ~= "table" then
    error("Coordinator requires an injected editor environment", 2)
  end
  for _, method in ipairs(REQUIRED_ENVIRONMENT_METHODS) do
    if type(components.environment[method]) ~= "function" then
      error(("Coordinator environment must implement %s()"):format(method), 2)
    end
  end
  return setmetatable({
    session_factory = components.session_factory,
    sessions = components.sessions,
    environment = components.environment,
    resolve_config = components.resolve_config,
    pending_by_source = {},
    failed_starts = {},
    last_runtime_notifications = {},
  }, Coordinator)
end

function Coordinator:validate_source_buffer(buffer)
  local info = self.environment.inspect_buffer(buffer)
  if
    type(info) ~= "table"
    or info.valid ~= true
    or info.loaded ~= true
    or info.buftype ~= ""
    or info.modifiable ~= true
    or info.binary == true
    or type(info.path) ~= "string"
    or info.path == ""
  then
    return nil,
      errors.new(
        errors.codes.INVALID_SOURCE_BUFFER,
        "Bilingua requires a loaded, file-backed, modifiable, non-binary normal buffer",
        false
      )
  end
  return info
end

function Coordinator:emit(event, session, err, details)
  local supplied = type(details) == "table" and details or {}
  self.environment.emit(event, {
    session_id = session and session.id or nil,
    group_id = type(supplied.group_id) == "string" and supplied.group_id or nil,
    task_id = type(supplied.task_id) == "string" and supplied.task_id or nil,
    state = type(supplied.state) == "string" and supplied.state
      or (session and session.state or nil),
    error_code = type(supplied.error_code) == "string" and supplied.error_code
      or (err and err.code or nil),
  })
end

function Coordinator:notify_runtime_error(session, details)
  local ui = session and session.config and session.config.ui
  if not ui or ui.notify_backend ~= true or type(self.environment.notify_error) ~= "function" then
    return false
  end
  local error_code = type(details) == "table" and details.error_code or nil
  if type(error_code) ~= "string" then
    return false
  end

  local now_ms = 0
  if type(self.environment.now_ms) == "function" then
    local measured, value = pcall(self.environment.now_ms)
    if measured and type(value) == "number" then
      now_ms = value
    end
  end
  local by_error_code = self.last_runtime_notifications[session]
  if not by_error_code then
    by_error_code = {}
    self.last_runtime_notifications[session] = by_error_code
  end
  local previous_ms = by_error_code[error_code]
  if type(previous_ms) == "number" and now_ms - previous_ms < 1000 then
    return false
  end
  by_error_code[error_code] = now_ms
  pcall(self.environment.notify_error, error_code)
  return true
end

function Coordinator:release_session(session, err)
  if session._bilingua_released then
    return false
  end
  session._bilingua_released = true
  self.pending_by_source[session.source_buf] = nil
  self.sessions:remove(session)
  self.last_runtime_notifications[session] = nil
  if type(self.environment.session_removed) == "function" then
    pcall(self.environment.session_removed, session.source_buf, session.target_buf)
  end
  if err then
    self:emit("BilinguaError", session, err)
  end
  self:emit("BilinguaSessionStopped", session, err)
  return true
end

function Coordinator:remember_failed_start(source_buf, options)
  self.failed_starts[source_buf] = {
    options = copy_value(options or {}),
  }
end

function Coordinator:begin_start(source_buf, options, callback)
  local requested = copy_value(options or {})
  self.failed_starts[source_buf] = nil
  local info, source_error = self:validate_source_buffer(source_buf)
  if not info then
    self:remember_failed_start(source_buf, requested)
    invoke(callback, nil, source_error)
    return nil, source_error
  end
  local config, config_error = self.resolve_config(requested)
  if not config then
    self:remember_failed_start(source_buf, requested)
    invoke(callback, nil, config_error)
    return nil, config_error
  end
  local created, session, create_error = pcall(self.session_factory.create, self.session_factory, {
    source_buf = source_buf,
    source_window = self.environment.current_window(),
    filetype = info.filetype,
    source_path = info.path,
  }, config)
  if not created then
    create_error =
      errors.new(errors.codes.INTERNAL, "Session construction failed", false, nil, session)
    session = nil
  end
  if not session then
    self:remember_failed_start(source_buf, requested)
    invoke(callback, nil, create_error)
    return nil, create_error
  end
  session.on_auto_dispose = function(disposed_session, _, dispose_error)
    self:release_session(disposed_session, dispose_error)
  end
  session.on_event = function(event, data)
    if event == "BilinguaError" then
      self:notify_runtime_error(session, data)
    end
    self:emit(event, session, nil, data)
  end

  self.pending_by_source[source_buf] = session
  local completed = false
  local completion_error
  local start_called, start_exception = pcall(session.start, session, function(started, start_error)
    if completed then
      return
    end
    completed = true
    self.pending_by_source[source_buf] = nil
    if not started then
      completion_error = start_error
        or errors.new(errors.codes.INTERNAL, "Session start failed", false)
      self:remember_failed_start(source_buf, requested)
      self:emit("BilinguaError", session, completion_error)
      invoke(callback, nil, completion_error)
      return
    end
    session.target_buf = session.target_buf or (session.editor and session.editor.target_buf)
    local registered, registration_error = self.sessions:add(session)
    if not registered then
      completion_error = registration_error
      self:remember_failed_start(source_buf, requested)
      pcall(session.stop, session, { force = true })
      self:emit("BilinguaError", session, completion_error)
      invoke(callback, nil, completion_error)
      return
    end
    self.failed_starts[source_buf] = nil
    self:emit("BilinguaSessionStarted", session)
    invoke(callback, session:status_snapshot(), nil, config)
  end)
  if not start_called and not completed then
    completed = true
    self.pending_by_source[source_buf] = nil
    completion_error = errors.new(
      errors.codes.INTERNAL,
      "Session start raised an internal error",
      false,
      nil,
      start_exception
    )
    self:remember_failed_start(source_buf, requested)
    pcall(session.stop, session, { force = true })
    self:emit("BilinguaError", session, completion_error)
    invoke(callback, nil, completion_error)
  end
  if completion_error then
    return nil, completion_error
  end
  return true
end

function Coordinator:stop_session(session, options, callback)
  local completed = false
  local completion_error
  local stopped, stop_error = session:stop(options, function(ok, err)
    if completed then
      return
    end
    completed = true
    if not ok then
      completion_error = err or errors.new(errors.codes.SESSION_STATE, "Session stop failed", false)
      self:emit("BilinguaError", session, completion_error)
      invoke(callback, nil, completion_error)
      return
    end
    self:release_session(session)
    invoke(callback, true)
  end)
  if not stopped then
    completion_error = stop_error
    if not completed then
      completed = true
      self:emit("BilinguaError", session, completion_error)
      invoke(callback, nil, completion_error)
    end
  end
  if completion_error then
    return nil, completion_error
  end
  return true
end

function Coordinator:start(options, callback)
  local resolved = options or {}
  if type(resolved) ~= "table" then
    local argument_error =
      errors.new(errors.codes.INVALID_ARGUMENT, "start options must be a table", false)
    invoke(callback, nil, argument_error)
    return nil, argument_error
  end
  local source_buf = resolved.source_buf or self.environment.current_buffer()
  local existing = self.sessions:for_buffer(source_buf) or self.pending_by_source[source_buf]
  if not existing then
    return self:begin_start(source_buf, resolved, callback)
  end
  if resolved.force ~= true then
    local duplicate_error = state_error("A Bilingua Session already owns this source buffer")
    invoke(callback, nil, duplicate_error)
    return nil, duplicate_error
  end

  local replacement_error
  local stopped, stop_error = self:stop_session(existing, { force = true }, function(ok, err)
    if not ok then
      replacement_error = err
      invoke(callback, nil, err)
      return
    end
    local started, start_error = self:begin_start(source_buf, resolved, callback)
    if not started then
      replacement_error = start_error
    end
  end)
  if not stopped then
    return nil, stop_error
  elseif replacement_error then
    return nil, replacement_error
  end
  return true
end

function Coordinator:current_session()
  local buffer = self.environment.current_buffer()
  return self.sessions:for_buffer(buffer), buffer
end

function Coordinator:require_current_session()
  local session, buffer = self:current_session()
  if not session then
    return nil, state_error("The current buffer does not belong to a Bilingua Session")
  end
  return session, nil, buffer
end

function Coordinator:delegate(method, include_buffer, ...)
  local session, session_error, buffer = self:require_current_session()
  if not session then
    return nil, session_error
  end
  if type(session[method]) ~= "function" then
    return nil, state_error(("Session operation %s is unavailable"):format(method))
  end
  if include_buffer then
    return session[method](session, buffer, ...)
  end
  return session[method](session, ...)
end

function Coordinator:toggle()
  return self:delegate("toggle", true)
end

function Coordinator:sync_current()
  return self:delegate("sync_current", true)
end

function Coordinator:sync_all()
  return self:delegate("sync_all", false)
end

function Coordinator:next_group()
  return self:delegate("next_group", true)
end

function Coordinator:prev_group()
  return self:delegate("prev_group", true)
end

function Coordinator:use_source()
  local session, session_error, buffer = self:require_current_session()
  if not session then
    return nil, session_error
  end
  local group_id, group_error = session:current_group_id(buffer)
  if not group_id then
    return nil, group_error
  end
  return session:use_source(group_id)
end

function Coordinator:use_japanese()
  local session, session_error, buffer = self:require_current_session()
  if not session then
    return nil, session_error
  end
  local group_id, group_error = session:current_group_id(buffer)
  if not group_id then
    return nil, group_error
  end
  return session:use_japanese(group_id)
end

function Coordinator:retry_current(callback)
  local session, buffer = self:current_session()
  if session then
    if type(session.retry_current) ~= "function" then
      local unavailable = state_error("Session operation retry_current is unavailable")
      invoke(callback, nil, unavailable)
      return nil, unavailable
    end
    local retried, retry_error = session:retry_current(buffer)
    invoke(callback, retried, retry_error)
    return retried, retry_error
  end
  if self.pending_by_source[buffer] then
    local pending_error = state_error("A Bilingua Session is still starting for this buffer")
    invoke(callback, nil, pending_error)
    return nil, pending_error
  end
  local failed = self.failed_starts[buffer]
  if not failed then
    local missing_error = state_error("No failed Bilingua start is available for this buffer")
    invoke(callback, nil, missing_error)
    return nil, missing_error
  end
  return self:begin_start(buffer, failed.options, callback)
end

function Coordinator:restart_backend(callback)
  return self:delegate("restart_backend", false, callback)
end

function Coordinator:status()
  local session, session_error = self:require_current_session()
  if not session then
    return nil, session_error
  end
  return session:status_snapshot()
end

function Coordinator:stop(options, callback)
  local session, session_error = self:require_current_session()
  if not session then
    invoke(callback, nil, session_error)
    return nil, session_error
  end
  return self:stop_session(session, options or { force = false }, callback)
end

function Coordinator:quit(options, callback)
  local resolved = options or { force = false }
  local session, session_error = self:require_current_session()
  if not session then
    invoke(callback, nil, session_error)
    return nil, session_error
  end
  local source_buf = session.source_buf
  local quit_error
  local stopped, stop_error = self:stop_session(
    session,
    { force = resolved.force == true },
    function(ok, err)
      if not ok then
        quit_error = err
        invoke(callback, nil, err)
        return
      end
      if not self.environment.close_buffer(source_buf, resolved.force == true) then
        quit_error = errors.new(errors.codes.APPLY, "Neovim did not close the source buffer", false)
        invoke(callback, nil, quit_error)
        return
      end
      invoke(callback, true)
    end
  )
  if not stopped then
    return nil, stop_error
  end
  if quit_error then
    return nil, quit_error
  end
  return true
end

function Coordinator:force_dispose_all()
  self.failed_starts = {}
  local owned = {}
  local seen = {}
  for _, session in ipairs(self.sessions:list()) do
    owned[#owned + 1] = session
    seen[session] = true
  end
  for _, session in pairs(self.pending_by_source) do
    if not seen[session] then
      owned[#owned + 1] = session
      seen[session] = true
    end
  end

  for _, session in ipairs(owned) do
    local owned_session = session
    local delivered = false
    local called, accepted, stop_error = pcall(
      owned_session.stop,
      owned_session,
      { force = true },
      function(ok, err)
        if delivered then
          return
        end
        delivered = true
        if ok then
          self:release_session(owned_session)
        else
          self:emit("BilinguaError", owned_session, err)
        end
      end
    )
    if not called then
      local internal = errors.new(
        errors.codes.INTERNAL,
        "Session force disposal raised an internal error",
        false,
        nil,
        accepted
      )
      self:emit("BilinguaError", owned_session, internal)
    elseif not accepted and not delivered then
      self:emit("BilinguaError", owned_session, stop_error)
    end
  end
  return true
end

return {
  new = Coordinator.new,
}
