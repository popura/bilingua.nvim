local errors = require("bilingua.domain.error")

local Service = {}
Service.__index = Service

local function normalized_error(value, fallback_code, fallback_message)
  if
    type(value) == "table"
    and type(value.code) == "string"
    and type(value.message) == "string"
    and type(value.retryable) == "boolean"
  then
    return value
  end
  return errors.new(fallback_code, fallback_message, false)
end

local function deep_copy(value, seen)
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
    copy[deep_copy(key, visited)] = deep_copy(item, visited)
  end
  return copy
end

local function require_component(components, name)
  local component = components[name]
  if type(component) ~= "table" then
    error(("TranslationService component '%s' is required"):format(name), 3)
  end
  return component
end

function Service.new(components)
  if type(components) ~= "table" then
    error("TranslationService components are required", 2)
  end
  local backend = require_component(components, "backend")
  local initial_codec = require_component(components, "initial_codec")
  local patch_codec = require_component(components, "patch_codec")
  if
    backend.api_version ~= 1
    or type(backend.id) ~= "string"
    or backend.id == ""
    or type(backend.open) ~= "function"
    or type(backend.request) ~= "function"
    or type(backend.close) ~= "function"
    or type(backend.capabilities) ~= "function"
  then
    error("TranslationService backend does not satisfy the inference backend contract", 2)
  end
  for name, codec in pairs({ initial_codec = initial_codec, patch_codec = patch_codec }) do
    if
      codec.api_version ~= 1
      or type(codec.id) ~= "string"
      or codec.id == ""
      or type(codec.encode) ~= "function"
      or type(codec.decode) ~= "function"
      or type(codec.response_schema) ~= "function"
    then
      error(("TranslationService %s does not satisfy the task codec contract"):format(name), 2)
    end
  end
  local retry = components.retry or {}
  local max_attempts = retry.max_attempts or 1
  local initial_delay_ms = retry.initial_delay_ms or 500
  local max_delay_ms = retry.max_delay_ms or 3000
  if
    type(max_attempts) ~= "number"
    or max_attempts < 1
    or max_attempts % 1 ~= 0
    or type(initial_delay_ms) ~= "number"
    or initial_delay_ms < 0
    or type(max_delay_ms) ~= "number"
    or max_delay_ms < initial_delay_ms
  then
    error("TranslationService retry options are invalid", 2)
  end
  if type(components.schedule) ~= "function" then
    error("TranslationService requires an injected scheduler", 2)
  end
  if max_attempts > 1 and type(components.defer) ~= "function" then
    error("TranslationService retries require an injected delay scheduler", 2)
  end

  return setmetatable({
    api_version = 1,
    backend = backend,
    initial_codec = initial_codec,
    patch_codec = patch_codec,
    schedule = components.schedule,
    defer = components.defer,
    retry = {
      max_attempts = max_attempts,
      initial_delay_ms = initial_delay_ms,
      max_delay_ms = max_delay_ms,
    },
    logger = components.logger,
    runtime_metrics = {
      retry_count = 0,
      last_first_agent_message_delta_ms = nil,
      last_turn_completed_ms = nil,
    },
    state = "new",
    jobs = {},
    close_callbacks = {},
  }, Service)
end

function Service:record(event, task, metadata)
  if not self.logger then
    return
  end
  local entry = {
    level = metadata and metadata.level or "debug",
    event = event,
    task_id = task and task.task_id or nil,
    metadata = {
      codec_id = metadata and metadata.codec_id or nil,
      error_code = metadata and metadata.error_code or nil,
    },
  }
  local ok, logger_error
  if type(self.logger) == "function" then
    ok, logger_error = pcall(self.logger, entry)
  elseif type(self.logger) == "table" and type(self.logger.record) == "function" then
    ok, logger_error = pcall(self.logger.record, self.logger, entry)
  else
    ok, logger_error = false, "logger must be a function or expose record()"
  end
  if not ok then
    self.logger_error = logger_error
  end
end

function Service:capabilities()
  local ok, capabilities = pcall(self.backend.capabilities, self.backend)
  if not ok or type(capabilities) ~= "table" then
    return {}
  end
  local copy = {}
  for key, value in pairs(capabilities) do
    copy[key] = value
  end
  return copy
end

function Service:runtime_status()
  return {
    retry_count = self.runtime_metrics.retry_count,
    last_first_agent_message_delta_ms = self.runtime_metrics.last_first_agent_message_delta_ms,
    last_turn_completed_ms = self.runtime_metrics.last_turn_completed_ms,
  }
end

local function cancel_open(service)
  local operation = service.open_operation
  if not operation or operation.delivered then
    return
  end
  operation.settled = true
  operation.delivered = true
  service.open_operation = nil
  local close_error =
    errors.new(errors.codes.SESSION_CLOSED, "Translation service closed while opening", false)
  service.schedule(function()
    operation.callback(nil, close_error)
  end)
end

function Service:open(callback)
  if type(callback) ~= "function" then
    error("TranslationService open callback is required", 2)
  end
  if self.state == "open" then
    self.schedule(function()
      callback(true)
    end)
    return
  elseif self.state == "closed" or self.state == "closing" then
    local state_error =
      errors.new(errors.codes.SESSION_CLOSED, "Translation service is closed", false)
    self.schedule(function()
      callback(nil, state_error)
    end)
    return
  elseif self.state == "opening" then
    local state_error =
      errors.new(errors.codes.SESSION_STATE, "Translation service is already opening", false)
    self.schedule(function()
      callback(nil, state_error)
    end)
    return
  end

  self.state = "opening"
  local operation = { callback = callback, settled = false, delivered = false }
  self.open_operation = operation
  local function finish(opened, open_error)
    if operation.settled then
      return
    end
    operation.settled = true
    local normalized
    if opened then
      self.state = "open"
      self:record("translation_service_opened", nil, {})
    else
      self.state = "failed"
      normalized = normalized_error(
        open_error,
        errors.codes.BACKEND_INIT,
        "Translation backend failed to open"
      )
      self:record(
        "translation_service_open_failed",
        nil,
        { level = "error", error_code = normalized.code }
      )
    end
    self.schedule(function()
      if operation.delivered then
        return
      end
      operation.delivered = true
      if self.open_operation == operation then
        self.open_operation = nil
      end
      if self.state == "closing" or self.state == "closed" then
        callback(
          nil,
          errors.new(errors.codes.SESSION_CLOSED, "Translation service closed while opening", false)
        )
      elseif opened then
        callback(true)
      else
        callback(nil, normalized)
      end
    end)
  end
  local called, call_error = pcall(self.backend.open, self.backend, finish)
  if not called then
    finish(
      nil,
      errors.new(
        errors.codes.BACKEND_INIT,
        "Translation backend failed to open",
        false,
        nil,
        call_error
      )
    )
  end
end

local function select_codec(service, task)
  if task.kind == "initial_translate" then
    return service.initial_codec
  elseif
    task.kind == "propagate_edit"
    or task.kind == "propagate_structure"
    or task.kind == "resolve_conflict"
  then
    return service.patch_codec
  end
  return nil
end

local function cancel_job(service, job, record_event)
  if job.cancelled or job.delivered then
    return
  end
  job.cancelled = true
  service.jobs[job] = nil
  if job.backend_handle and type(job.backend_handle.cancel) == "function" then
    pcall(job.backend_handle.cancel, job.backend_handle)
  end
  if job.retry_handle and type(job.retry_handle.cancel) == "function" then
    pcall(job.retry_handle.cancel, job.retry_handle)
  end
  if record_event then
    service:record("translation_cancelled", job.task, {})
  end
end

function Service:submit(task, callbacks)
  if
    type(task) ~= "table"
    or type(callbacks) ~= "table"
    or type(callbacks.on_complete) ~= "function"
    or type(callbacks.on_error) ~= "function"
  then
    error("TranslationService submit requires a task and terminal callbacks", 2)
  end

  local job = {
    task = task,
    callbacks = callbacks,
    cancelled = false,
    settled = false,
    delivered = false,
    backend_handle = nil,
    retry_handle = nil,
    attempts = 0,
    format_retries = 0,
  }
  self.jobs[job] = true

  local handle = {}
  function handle:cancel()
    cancel_job(self.service, job, true)
  end
  function handle:is_cancelled()
    return job.cancelled
  end
  handle.service = self

  local function settle(kind, value)
    if job.cancelled or job.settled then
      return
    end
    job.settled = true
    if job.retry_handle and type(job.retry_handle.cancel) == "function" then
      pcall(job.retry_handle.cancel, job.retry_handle)
    end
    job.retry_handle = nil
    self.schedule(function()
      if job.cancelled or job.delivered then
        return
      end
      job.delivered = true
      self.jobs[job] = nil
      if kind == "complete" then
        self:record("translation_completed", task, {})
        callbacks.on_complete(value)
      else
        self:record("translation_failed", task, { level = "error", error_code = value.code })
        callbacks.on_error(value)
      end
    end)
  end

  if self.state ~= "open" then
    local code = (self.state == "closed" or self.state == "closing") and errors.codes.SESSION_CLOSED
      or errors.codes.SESSION_STATE
    settle("error", errors.new(code, "Translation service is not open", false))
    return handle
  end

  local codec = select_codec(self, task)
  if not codec then
    settle(
      "error",
      errors.new(errors.codes.INVALID_ARGUMENT, "Translation task kind is not supported", false)
    )
    return handle
  end

  local capabilities_ok, capabilities = pcall(self.backend.capabilities, self.backend)
  if not capabilities_ok or type(capabilities) ~= "table" then
    settle(
      "error",
      errors.new(
        errors.codes.BACKEND_PROTOCOL,
        "Translation backend returned invalid capabilities",
        false,
        nil,
        capabilities_ok and nil or capabilities
      )
    )
    return handle
  end

  local encoded_ok, base_request, encode_error = pcall(codec.encode, codec, task, capabilities)
  if not encoded_ok then
    settle(
      "error",
      errors.new(
        errors.codes.INVALID_ARGUMENT,
        "Translation task encoding failed",
        false,
        nil,
        base_request
      )
    )
    return handle
  elseif not base_request then
    settle(
      "error",
      normalized_error(
        encode_error,
        errors.codes.INVALID_ARGUMENT,
        "Translation task encoding failed"
      )
    )
    return handle
  end

  local function is_current()
    if type(callbacks.is_current) ~= "function" then
      return true
    end
    local ok, current = pcall(callbacks.is_current)
    return ok and current == true
  end

  local function request_for_attempt(format_retry)
    local request = deep_copy(base_request)
    if format_retry then
      local correction = table.concat({
        "The previous response failed JSON format validation.",
        "Re-evaluate the original task and return only one object conforming to the response schema.",
        "Include every required field; use an empty array for a required array field when it has no values.",
        "Do not add prose or code fences.",
      }, " ")
      if type(request.system_instructions) == "string" then
        request.system_instructions = request.system_instructions .. "\n" .. correction
      elseif type(request.user_content) == "string" then
        request.user_content = correction .. "\n\n" .. request.user_content
      end
      request.metadata = type(request.metadata) == "table" and request.metadata or {}
      request.metadata.retry_reason = "format"
    end
    return request
  end

  local transient_codes = {
    [errors.codes.BACKEND_UNAVAILABLE] = true,
    [errors.codes.BACKEND_RATE_LIMITED] = true,
    [errors.codes.BACKEND_TIMEOUT] = true,
    [errors.codes.BACKEND_PROTOCOL] = true,
    [errors.codes.TRANSLATION] = true,
  }
  local perform_attempt
  local function retry_or_settle(err, format_retry)
    local format_allowed = format_retry
      and job.format_retries < 1
      and err.details
      and err.details.retryable_format == true
    local backend_allowed = not format_retry
      and err.retryable == true
      and transient_codes[err.code] == true
    if (not format_allowed and not backend_allowed) or job.attempts >= self.retry.max_attempts then
      settle("error", err)
      return
    end
    if not is_current() then
      settle("error", errors.new(errors.codes.STALE_RESULT, "Translation retry became stale", true))
      return
    end
    if format_allowed then
      job.format_retries = job.format_retries + 1
    end
    local exponent = math.max(0, job.attempts - 1)
    local delay = math.min(self.retry.initial_delay_ms * (2 ^ exponent), self.retry.max_delay_ms)
    local scheduled_attempt = job.attempts
    local scheduled, retry_handle = pcall(self.defer, delay, function()
      job.retry_handle = nil
      if job.cancelled or job.settled then
        return
      end
      if not is_current() then
        settle(
          "error",
          errors.new(errors.codes.STALE_RESULT, "Translation retry became stale", true)
        )
        return
      end
      perform_attempt(format_allowed)
    end)
    if not scheduled then
      settle(
        "error",
        errors.new(
          errors.codes.INTERNAL,
          "Translation retry scheduling failed",
          false,
          nil,
          retry_handle
        )
      )
    else
      self.runtime_metrics.retry_count = self.runtime_metrics.retry_count + 1
      self:record("translation_retry_scheduled", task, {
        error_code = err.code,
        codec_id = codec.id,
      })
      if job.attempts == scheduled_attempt and not job.settled and not job.cancelled then
        job.retry_handle = retry_handle
      elseif retry_handle and type(retry_handle.cancel) == "function" then
        retry_handle:cancel()
      end
    end
  end

  perform_attempt = function(format_retry)
    if job.cancelled or job.settled then
      return
    end
    job.attempts = job.attempts + 1
    local attempt = job.attempts
    local attempt_terminal = false
    local request = request_for_attempt(format_retry)
    self:record("translation_started", task, { codec_id = codec.id })

    local backend_callbacks = {
      on_complete = function(raw_response)
        if attempt_terminal or job.cancelled or job.settled or job.attempts ~= attempt then
          return
        end
        attempt_terminal = true
        job.backend_handle = nil
        local metadata = type(raw_response) == "table" and raw_response.metadata or nil
        if type(metadata) == "table" and rawget(metadata, "turn_completed_ms") ~= nil then
          local first_delta = metadata.first_agent_message_delta_ms
          local turn_completed = metadata.turn_completed_ms
          self.runtime_metrics.last_first_agent_message_delta_ms = type(first_delta) == "number"
              and first_delta >= 0
              and first_delta
            or nil
          self.runtime_metrics.last_turn_completed_ms = type(turn_completed) == "number"
              and turn_completed >= 0
              and turn_completed
            or nil
        end
        local decoded_ok, result, result_error =
          pcall(codec.decode, codec, raw_response, task, capabilities)
        if not decoded_ok then
          settle(
            "error",
            errors.new(errors.codes.INVALID_OUTPUT, "Translation response decoding failed", false)
          )
        elseif not result then
          local normalized = normalized_error(
            result_error,
            errors.codes.INVALID_OUTPUT,
            "Translation response is invalid"
          )
          retry_or_settle(normalized, true)
        else
          settle("complete", result)
        end
      end,
      on_error = function(backend_error)
        if attempt_terminal or job.cancelled or job.settled or job.attempts ~= attempt then
          return
        end
        attempt_terminal = true
        job.backend_handle = nil
        retry_or_settle(
          normalized_error(
            backend_error,
            errors.codes.TRANSLATION,
            "Translation backend request failed"
          ),
          false
        )
      end,
      on_progress = function(progress)
        if
          attempt_terminal
          or job.cancelled
          or job.settled
          or job.attempts ~= attempt
          or type(callbacks.on_progress) ~= "function"
        then
          return
        end
        self.schedule(function()
          if
            not attempt_terminal
            and not job.cancelled
            and not job.settled
            and job.attempts == attempt
          then
            callbacks.on_progress(progress)
          end
        end)
      end,
    }

    local requested, backend_handle, request_error =
      pcall(self.backend.request, self.backend, request, backend_callbacks)
    if not requested then
      if not attempt_terminal then
        attempt_terminal = true
        retry_or_settle(
          errors.new(
            errors.codes.TRANSLATION,
            "Translation backend request failed",
            false,
            nil,
            backend_handle
          ),
          false
        )
      end
    elseif backend_handle and not attempt_terminal and not job.settled and not job.cancelled then
      job.backend_handle = backend_handle
    elseif not backend_handle and not attempt_terminal and not job.settled then
      attempt_terminal = true
      retry_or_settle(
        normalized_error(
          request_error,
          errors.codes.BACKEND_PROTOCOL,
          "Translation backend did not return a cancel handle"
        ),
        false
      )
    end
  end

  perform_attempt(false)
  return handle
end

function Service:close(callback)
  if callback ~= nil and type(callback) ~= "function" then
    error("TranslationService close callback must be a function", 2)
  end
  if self.state == "closed" then
    if callback then
      self.schedule(function()
        callback(true)
      end)
    end
    return
  elseif self.state == "closing" then
    if callback then
      self.close_callbacks[#self.close_callbacks + 1] = callback
    end
    return
  end
  local previous_state = self.state

  self.state = "closing"
  cancel_open(self)
  if callback then
    self.close_callbacks[#self.close_callbacks + 1] = callback
  end
  local active = {}
  for job in pairs(self.jobs) do
    active[#active + 1] = job
  end
  for _, job in ipairs(active) do
    cancel_job(self, job, false)
  end

  local settled = false
  local function finish(closed, close_error)
    if settled then
      return
    end
    settled = true
    self.state = "closed"
    local normalized
    if not closed then
      normalized =
        normalized_error(close_error, errors.codes.INTERNAL, "Translation backend failed to close")
    end
    local pending = self.close_callbacks
    self.close_callbacks = {}
    self:record("translation_service_closed", nil, normalized and {
      level = "error",
      error_code = normalized.code,
    } or {})
    self.schedule(function()
      for _, close_callback in ipairs(pending) do
        if normalized then
          close_callback(nil, normalized)
        else
          close_callback(true)
        end
      end
    end)
  end

  if previous_state == "new" then
    finish(true)
    return
  end
  local called, call_error = pcall(self.backend.close, self.backend, finish)
  if not called then
    finish(
      nil,
      errors.new(
        errors.codes.INTERNAL,
        "Translation backend failed to close",
        false,
        nil,
        call_error
      )
    )
  end
end

return {
  new = Service.new,
}
