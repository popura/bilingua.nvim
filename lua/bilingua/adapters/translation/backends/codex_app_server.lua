local errors = require("bilingua.domain.error")
local json = require("bilingua.util.json")
local jsonl = require("bilingua.util.jsonl")

local Backend = {}
Backend.__index = Backend

local PROHIBITED_ITEM_TYPES = {
  commandExecution = true,
  fileChange = true,
  mcpToolCall = true,
  dynamicToolCall = true,
  collabAgentToolCall = true,
  subAgentActivity = true,
  webSearch = true,
  imageView = true,
}

local APPROVAL_METHODS = {
  ["item/commandExecution/requestApproval"] = "approval",
  ["item/fileChange/requestApproval"] = "approval",
  ["item/permissions/requestApproval"] = "permission",
  ["mcpServer/elicitation/request"] = "elicitation",
  ["item/tool/requestUserInput"] = "user_input",
}

local function copy_list(values)
  local copy = {}
  for index, value in ipairs(values or {}) do
    copy[index] = value
  end
  return copy
end

local function is_list(value)
  if type(value) ~= "table" then
    return false
  end
  if next(value) == nil then
    return json.is_array(value)
  end
  local count = 0
  local maximum = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  return count == maximum
end

local function backend_error(code, message, retryable, details, cause)
  return errors.new(code, message, retryable, details, cause)
end

local function safe_error(value, fallback_code, fallback_message)
  if
    type(value) == "table"
    and type(value.code) == "string"
    and type(value.message) == "string"
    and type(value.retryable) == "boolean"
  then
    return value
  end
  return backend_error(fallback_code, fallback_message, false)
end

function Backend.new(options)
  local resolved = options or {}
  local strict_isolation = resolved.strict_isolation ~= false
  local include_platform_defaults = resolved.include_platform_default_reads == true
  local configuration_error
  if strict_isolation and include_platform_defaults then
    configuration_error = backend_error(
      errors.codes.BACKEND_INIT,
      "Strict isolation cannot include platform default readable roots",
      false
    )
  end
  for _, dependency in ipairs({
    "schedule",
    "timer_factory",
    "tempdir_factory",
    "remove_tree",
    "realpath",
    "process_factory",
  }) do
    if type(resolved[dependency]) ~= "function" then
      error(("Codex backend requires an injected %s function"):format(dependency), 2)
    end
  end
  return setmetatable({
    api_version = 1,
    id = "codex_app_server",
    command = copy_list(resolved.command or { "codex", "app-server" }),
    configured_model = resolved.model,
    reasoning_effort = resolved.reasoning_effort,
    require_ephemeral = resolved.require_ephemeral ~= false,
    strict_isolation = strict_isolation,
    reject_external_instruction_sources = resolved.reject_external_instruction_sources ~= false,
    include_platform_default_reads = include_platform_defaults,
    experimental_api = resolved.experimental_api == true,
    request_timeout_ms = resolved.request_timeout_ms or 10000,
    turn_timeout_ms = resolved.turn_timeout_ms or resolved.timeout_ms or 120000,
    shutdown_timeout_ms = resolved.shutdown_timeout_ms or 500,
    schedule = resolved.schedule,
    timer_factory = resolved.timer_factory,
    tempdir_factory = resolved.tempdir_factory,
    remove_tree = resolved.remove_tree,
    realpath = resolved.realpath,
    process_factory = resolved.process_factory,
    logger = resolved.logger,
    ring_size = resolved.ring_size or 200,
    max_line_bytes = resolved.max_line_bytes or (16 * 1024 * 1024),
    configuration_error = configuration_error,
    state = "new",
    process = nil,
    parser = nil,
    isolated_temp_dir = nil,
    next_request_id = 0,
    pending = {},
    jobs = {},
    jobs_by_thread = {},
    jobs_by_turn = {},
    stderr_ring = {},
    models = {},
    selected_model_name = nil,
    selected_model_record = nil,
    warnings = {},
    open_callback = nil,
    open_settled = false,
    close_callbacks = {},
    close_settled = false,
    shutdown_timer = nil,
  }, Backend)
end

function Backend:record(event, metadata)
  if not self.logger then
    return
  end
  local safe_metadata = {
    method = metadata and metadata.method or nil,
    error_code = metadata and metadata.error_code or nil,
    task_id = metadata and metadata.task_id or nil,
    item_type = metadata and metadata.item_type or nil,
  }
  local entry =
    { level = metadata and metadata.level or "debug", event = event, metadata = safe_metadata }
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

function Backend:capabilities()
  return {
    structured_output = true,
    streaming = false,
    cancellation = true,
    system_instructions = true,
    parallel_requests = true,
    ephemeral_sessions = true,
    max_input_chars = nil,
  }
end

function Backend:selected_model()
  return self.selected_model_name
end

function Backend:defer(callback)
  self.schedule(callback)
end

function Backend:start_timer(milliseconds, callback)
  local timer_callback = function()
    self:defer(callback)
  end
  local ok, timer = pcall(self.timer_factory, milliseconds, timer_callback)
  if not ok or type(timer) ~= "table" or type(timer.cancel) ~= "function" then
    return nil, backend_error(errors.codes.INTERNAL, "Could not create a backend timer", false)
  end
  return timer
end

local function cancel_timer(timer)
  if timer and type(timer.cancel) == "function" then
    pcall(timer.cancel, timer)
  end
end

function Backend:next_id()
  self.next_request_id = self.next_request_id + 1
  return self.next_request_id
end

function Backend:write_message(message)
  if not self.process then
    return nil,
      backend_error(
        errors.codes.BACKEND_UNAVAILABLE,
        "Codex app-server process is unavailable",
        true
      )
  end
  local encoded_ok, encoded = pcall(json.encode, message)
  if not encoded_ok then
    return nil,
      backend_error(errors.codes.BACKEND_PROTOCOL, "Could not encode an app-server message", false)
  end
  local written, write_error = pcall(self.process.write, self.process, encoded .. "\n")
  if not written then
    return nil,
      backend_error(
        errors.codes.BACKEND_UNAVAILABLE,
        "Could not write to Codex app-server",
        true,
        nil,
        write_error
      )
  end
  return true
end

function Backend:send_request(method, params, callback, timeout_ms, error_code)
  local id = self:next_id()
  local pending = {
    id = id,
    method = method,
    callback = callback,
    timer = nil,
    error_code = error_code or errors.codes.BACKEND_PROTOCOL,
  }
  self.pending[id] = pending
  local written, write_error =
    self:write_message({ id = id, method = method, params = params or {} })
  if not written then
    self.pending[id] = nil
    callback(nil, write_error)
    return nil, write_error
  end
  local timer, timer_error = self:start_timer(timeout_ms or self.request_timeout_ms, function()
    if self.pending[id] ~= pending then
      return
    end
    self.pending[id] = nil
    callback(
      nil,
      backend_error(
        errors.codes.BACKEND_TIMEOUT,
        ("Codex app-server request '%s' timed out"):format(method),
        true,
        { method = method }
      )
    )
  end)
  if not timer then
    self.pending[id] = nil
    callback(nil, timer_error)
    return nil, timer_error
  end
  pending.timer = timer
  return id
end

function Backend:send_notification(method, params)
  return self:write_message({ method = method, params = params or {} })
end

function Backend:send_fire_and_forget(method, params)
  local id = self:next_id()
  local written, write_error =
    self:write_message({ id = id, method = method, params = params or {} })
  if not written then
    self:record(
      "app_server_write_failed",
      { method = method, error_code = write_error.code, level = "error" }
    )
  end
  return written
end

function Backend:complete_open(opened, open_error)
  if self.open_settled then
    return
  end
  self.open_settled = true
  if opened then
    self.state = "ready"
  else
    self.state = "failed"
    local process = self.process
    self.process = nil
    if process and type(process.kill) == "function" then
      pcall(process.kill, process, 9)
    end
    self:cleanup_tempdir()
  end
  local callback = self.open_callback
  self.open_callback = nil
  if callback then
    self:defer(function()
      if opened then
        callback(true)
      else
        callback(
          nil,
          safe_error(open_error, errors.codes.BACKEND_INIT, "Codex app-server failed to open")
        )
      end
    end)
  end
end

function Backend:normalize_rpc_error(rpc_error, pending)
  local message = type(rpc_error) == "table" and tostring(rpc_error.message or "") or ""
  local lowered = message:lower()
  local code = pending.error_code
  local retryable = false
  if lowered:find("auth", 1, true) or lowered:find("unauthorized", 1, true) then
    code = errors.codes.BACKEND_AUTH
  elseif lowered:find("rate", 1, true) then
    code = errors.codes.BACKEND_RATE_LIMITED
    retryable = type(rpc_error.data) == "table" and rpc_error.data.retryable == true
  end
  return backend_error(
    code,
    ("Codex app-server request '%s' failed"):format(pending.method),
    retryable,
    {
      provider_code = type(rpc_error) == "table" and rpc_error.code or nil,
      method = pending.method,
    }
  )
end

function Backend:handle_response(message)
  local pending = self.pending[message.id]
  if not pending then
    self:record("unknown_app_server_response", {})
    return
  end
  self.pending[message.id] = nil
  cancel_timer(pending.timer)
  local has_result = rawget(message, "result") ~= nil
  local has_error = rawget(message, "error") ~= nil
  if has_result == has_error then
    pending.callback(
      nil,
      backend_error(
        errors.codes.BACKEND_PROTOCOL,
        "Codex app-server response must contain exactly one of result or error",
        false,
        { method = pending.method }
      )
    )
  elseif has_error then
    pending.callback(nil, self:normalize_rpc_error(message.error, pending))
  else
    pending.callback(message.result)
  end
end

local function supports_text(model)
  if not is_list(model.inputModalities) then
    return false
  end
  for _, modality in ipairs(model.inputModalities) do
    if modality == "text" then
      return true
    end
  end
  return false
end

function Backend:select_available_model()
  local selected
  if self.configured_model then
    for _, model in ipairs(self.models) do
      if
        (model.model == self.configured_model or model.id == self.configured_model)
        and supports_text(model)
      then
        selected = model
        break
      end
    end
    if not selected then
      return nil,
        backend_error(
          errors.codes.BACKEND_INIT,
          "The configured Codex model is unavailable or lacks text input",
          false
        )
    end
  else
    local defaults = {}
    for _, model in ipairs(self.models) do
      if model.isDefault == true and model.hidden ~= true and supports_text(model) then
        defaults[#defaults + 1] = model
      end
    end
    if #defaults == 1 then
      selected = defaults[1]
    else
      for _, model in ipairs(self.models) do
        if model.hidden ~= true and supports_text(model) then
          selected = model
          break
        end
      end
      self.warnings[#self.warnings + 1] = #defaults == 0
          and "Codex reported no default text model; selected the first visible text model"
        or "Codex reported multiple default text models; selected the first visible text model"
    end
  end
  if not selected or type(selected.model) ~= "string" or selected.model == "" then
    return nil,
      backend_error(errors.codes.BACKEND_INIT, "Codex reported no usable text model", false)
  end
  self.selected_model_record = selected
  self.selected_model_name = selected.model
  if self.reasoning_effort == nil then
    self.resolved_reasoning_effort = selected.defaultReasoningEffort
  else
    self.resolved_reasoning_effort = self.reasoning_effort
  end
  return true
end

function Backend:load_models(cursor)
  local params = {}
  if cursor then
    params.cursor = cursor
  end
  self:send_request("model/list", params, function(result, request_error)
    if not result then
      self:complete_open(nil, request_error)
      return
    end
    if type(result) ~= "table" or not is_list(result.data) then
      self:complete_open(
        nil,
        backend_error(errors.codes.BACKEND_PROTOCOL, "Codex returned an invalid model list", false)
      )
      return
    end
    for _, model in ipairs(result.data) do
      if type(model) ~= "table" or type(model.id) ~= "string" then
        self:complete_open(
          nil,
          backend_error(errors.codes.BACKEND_PROTOCOL, "Codex returned a malformed model", false)
        )
        return
      end
      self.models[#self.models + 1] = model
    end
    if type(result.nextCursor) == "string" and result.nextCursor ~= "" then
      self:load_models(result.nextCursor)
      return
    elseif result.nextCursor ~= json.null then
      self:complete_open(
        nil,
        backend_error(
          errors.codes.BACKEND_PROTOCOL,
          "Codex model pagination cursor is invalid",
          false
        )
      )
      return
    end
    local selected, selection_error = self:select_available_model()
    if not selected then
      self:complete_open(nil, selection_error)
      return
    end
    self:complete_open(true)
  end, self.request_timeout_ms, errors.codes.BACKEND_INIT)
end

function Backend:start_handshake()
  self:send_request("initialize", {
    clientInfo = {
      name = "bilingua_nvim",
      title = "Bilingua.nvim",
      version = "0.1.0",
    },
    capabilities = {
      experimentalApi = self.experimental_api,
      optOutNotificationMethods = { "item/agentMessage/delta" },
    },
  }, function(result, initialize_error)
    if not result then
      self:complete_open(nil, initialize_error)
      return
    end
    local notified, notification_error = self:send_notification("initialized", {})
    if not notified then
      self:complete_open(nil, notification_error)
      return
    end
    self:load_models(nil)
  end, self.request_timeout_ms, errors.codes.BACKEND_INIT)
end

function Backend:append_stderr(chunk)
  if chunk == "" then
    return
  end
  self.stderr_ring[#self.stderr_ring + 1] = chunk
  while #self.stderr_ring > self.ring_size do
    table.remove(self.stderr_ring, 1)
  end
end

function Backend:handle_stdout_error(protocol_error)
  self:fail_connection(
    safe_error(
      protocol_error,
      errors.codes.BACKEND_PROTOCOL,
      "Codex app-server emitted invalid JSONL"
    )
  )
end

function Backend:on_stdout(error_message, chunk)
  if error_message then
    self:fail_connection(
      backend_error(errors.codes.BACKEND_UNAVAILABLE, "Codex stdout failed", true)
    )
    return
  end
  if not chunk or chunk == "" then
    return
  end
  local messages, parse_error = self.parser:feed(chunk)
  if not messages then
    self:handle_stdout_error(parse_error)
    return
  end
  for _, message in ipairs(messages) do
    self:dispatch(message)
  end
end

function Backend:open(callback)
  if type(callback) ~= "function" then
    error("Codex backend open callback is required", 2)
  end
  if self.state == "ready" then
    self:defer(function()
      callback(true)
    end)
    return
  elseif self.state ~= "new" then
    local state_error =
      backend_error(errors.codes.BACKEND_INIT, "Codex backend cannot be reopened", false)
    self:defer(function()
      callback(nil, state_error)
    end)
    return
  end
  if self.configuration_error then
    self.state = "failed"
    self:defer(function()
      callback(nil, self.configuration_error)
    end)
    return
  end
  self.state = "opening"
  self.open_callback = callback
  self.parser = jsonl.new({ max_line_bytes = self.max_line_bytes })

  local temp_ok, temp_path, temp_error = pcall(self.tempdir_factory)
  if not temp_ok or type(temp_path) ~= "string" or temp_path == "" then
    self:complete_open(
      nil,
      backend_error(
        errors.codes.BACKEND_INIT,
        "Could not create the isolated Codex directory",
        false,
        nil,
        temp_ok and temp_error or temp_path
      )
    )
    return
  end
  self.isolated_temp_dir = temp_path
  local real_ok, real_path = pcall(self.realpath, temp_path)
  if not real_ok or type(real_path) ~= "string" or real_path == "" then
    self:complete_open(
      nil,
      backend_error(
        errors.codes.BACKEND_INIT,
        "Could not resolve the isolated Codex directory",
        false
      )
    )
    return
  end
  self.isolated_temp_dir = real_path

  local process_options = {
    stdin = true,
    text = true,
    cwd = self.isolated_temp_dir,
    stdout = function(err, data)
      self:defer(function()
        self:on_stdout(err, data)
      end)
    end,
    stderr = function(err, data)
      self:defer(function()
        if not err and data then
          self:append_stderr(data)
        end
      end)
    end,
  }
  local process_ok, process_or_error = pcall(
    self.process_factory,
    self.command,
    process_options,
    function(result)
      self:defer(function()
        self:on_process_exit(result)
      end)
    end
  )
  if not process_ok or type(process_or_error) ~= "table" then
    self:complete_open(
      nil,
      backend_error(
        errors.codes.BACKEND_NOT_FOUND,
        "Could not start Codex app-server",
        false,
        nil,
        process_ok and nil or process_or_error
      )
    )
    self:cleanup_tempdir()
    return
  end
  self.process = process_or_error
  self:start_handshake()
end

function Backend:canonical_path_is_inside(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  local ok, resolved = pcall(self.realpath, path)
  if not ok or type(resolved) ~= "string" or resolved == "" then
    return false
  end
  local separator = package.config:sub(1, 1)
  local root = self.isolated_temp_dir:gsub("[\\/]+$", "")
  local candidate = resolved:gsub("[\\/]+$", "")
  if separator == "\\" then
    root = root:lower()
    candidate = candidate:lower()
  end
  return candidate == root or candidate:sub(1, #root + 1) == root .. separator
end

function Backend:finish_job(job, kind, value)
  if job.settled or job.cancelled then
    return
  end
  job.settled = true
  cancel_timer(job.turn_timer)
  job.turn_timer = nil
  self.jobs[job] = nil
  if job.thread_id then
    self.jobs_by_thread[job.thread_id] = nil
  end
  if job.turn_id then
    self.jobs_by_turn[job.turn_id] = nil
  end
  if self.state == "ready" and job.thread_id then
    self:send_fire_and_forget("thread/unsubscribe", { threadId = job.thread_id })
  end
  self:defer(function()
    if job.cancelled or job.delivered then
      return
    end
    job.delivered = true
    if kind == "complete" then
      job.callbacks.on_complete(value)
    else
      job.callbacks.on_error(value)
    end
  end)
end

function Backend:interrupt_job(job)
  if job.thread_id and job.turn_id then
    self:send_fire_and_forget("turn/interrupt", {
      threadId = job.thread_id,
      turnId = job.turn_id,
    })
  end
end

function Backend:start_turn(job)
  local request = job.request
  local include_defaults = self.strict_isolation and false or self.include_platform_default_reads
  local params = {
    threadId = job.thread_id,
    input = { { type = "text", text = request.user_content } },
    cwd = self.isolated_temp_dir,
    approvalPolicy = "never",
    sandboxPolicy = {
      type = "readOnly",
      access = {
        type = "restricted",
        includePlatformDefaults = include_defaults,
        readableRoots = { self.isolated_temp_dir },
      },
    },
    model = self.selected_model_name,
  }
  if self.resolved_reasoning_effort then
    params.effort = self.resolved_reasoning_effort
  end
  if request.response_schema then
    params.outputSchema = request.response_schema
  end

  local timeout = type(request.timeout_ms) == "number" and request.timeout_ms
    or self.turn_timeout_ms
  local timer, timer_error = self:start_timer(timeout, function()
    if job.settled or job.cancelled then
      return
    end
    self:interrupt_job(job)
    self:finish_job(
      job,
      "error",
      backend_error(errors.codes.BACKEND_TIMEOUT, "Codex translation turn timed out", true)
    )
  end)
  if not timer then
    self:finish_job(job, "error", timer_error)
    return
  end
  job.turn_timer = timer

  self:send_request("turn/start", params, function(result, turn_error)
    if job.cancelled or job.settled then
      return
    end
    if not result then
      self:finish_job(
        job,
        "error",
        safe_error(turn_error, errors.codes.TRANSLATION, "Codex turn failed to start")
      )
      return
    end
    local turn = type(result) == "table" and result.turn or nil
    if type(turn) ~= "table" or type(turn.id) ~= "string" or turn.id == "" then
      self:finish_job(
        job,
        "error",
        backend_error(errors.codes.BACKEND_PROTOCOL, "Codex returned an invalid turn", false)
      )
      return
    end
    job.turn_id = turn.id
    self.jobs_by_turn[turn.id] = job
  end, self.request_timeout_ms, errors.codes.TRANSLATION)
end

function Backend:start_thread(job)
  local params = {
    ephemeral = true,
    model = self.selected_model_name,
    cwd = self.isolated_temp_dir,
    approvalPolicy = "never",
    sandbox = "readOnly",
    serviceName = "bilingua_nvim",
  }
  if type(job.request.system_instructions) == "string" then
    params.developerInstructions = job.request.system_instructions
  end
  self:send_request("thread/start", params, function(result, thread_error)
    if job.cancelled or job.settled then
      return
    end
    if not result then
      self:finish_job(
        job,
        "error",
        safe_error(thread_error, errors.codes.TRANSLATION, "Codex thread failed to start")
      )
      return
    end
    local thread = type(result) == "table" and result.thread or nil
    if type(thread) ~= "table" or type(thread.id) ~= "string" or thread.id == "" then
      self:finish_job(
        job,
        "error",
        backend_error(errors.codes.BACKEND_PROTOCOL, "Codex returned an invalid thread", false)
      )
      return
    end
    job.thread_id = thread.id
    self.jobs_by_thread[thread.id] = job
    if self.require_ephemeral and thread.ephemeral ~= true then
      self:finish_job(
        job,
        "error",
        backend_error(
          errors.codes.EPHEMERAL_REQUIRED,
          "Codex did not confirm an ephemeral thread",
          false
        )
      )
      return
    end
    if self.reject_external_instruction_sources then
      local sources = result.instructionSources
      if not is_list(sources) then
        self:finish_job(
          job,
          "error",
          backend_error(
            errors.codes.BACKEND_INSTRUCTION_SOURCE,
            "Codex did not provide verifiable instruction sources",
            false
          )
        )
        return
      end
      for _, path in ipairs(sources) do
        if not self:canonical_path_is_inside(path) then
          self:finish_job(
            job,
            "error",
            backend_error(
              errors.codes.BACKEND_INSTRUCTION_SOURCE,
              "Codex loaded instructions outside the isolated directory",
              false
            )
          )
          return
        end
      end
    end
    self:start_turn(job)
  end, self.request_timeout_ms, errors.codes.TRANSLATION)
end

function Backend:request(request, callbacks)
  if
    type(request) ~= "table"
    or type(request.request_id) ~= "string"
    or type(request.user_content) ~= "string"
    or type(callbacks) ~= "table"
    or type(callbacks.on_complete) ~= "function"
    or type(callbacks.on_error) ~= "function"
  then
    error("Codex backend request requires normalized input and terminal callbacks", 2)
  end
  local job = {
    request = request,
    callbacks = callbacks,
    cancelled = false,
    settled = false,
    delivered = false,
    thread_id = nil,
    turn_id = nil,
    turn_timer = nil,
    final_answer = nil,
    last_agent_message = nil,
  }
  local owner = self
  local handle = {}
  function handle:cancel()
    if job.cancelled or job.delivered then
      return
    end
    job.cancelled = true
    cancel_timer(job.turn_timer)
    owner.jobs[job] = nil
    if job.thread_id then
      owner.jobs_by_thread[job.thread_id] = nil
    end
    if job.turn_id then
      owner.jobs_by_turn[job.turn_id] = nil
    end
    owner:interrupt_job(job)
    if owner.state == "ready" and job.thread_id then
      owner:send_fire_and_forget("thread/unsubscribe", { threadId = job.thread_id })
    end
  end
  function handle:is_cancelled()
    return job.cancelled
  end

  if self.state ~= "ready" then
    local code = (self.state == "closed" or self.state == "closing") and errors.codes.SESSION_CLOSED
      or errors.codes.BACKEND_UNAVAILABLE
    self:defer(function()
      if not job.cancelled then
        job.delivered = true
        callbacks.on_error(backend_error(code, "Codex backend is not ready", false))
      end
    end)
    return handle
  end
  self.jobs[job] = true
  self:start_thread(job)
  return handle
end

function Backend:job_for_params(params)
  if type(params) ~= "table" then
    return nil
  end
  local turn_id = params.turnId or (type(params.turn) == "table" and params.turn.id or nil)
  if type(turn_id) == "string" and self.jobs_by_turn[turn_id] then
    return self.jobs_by_turn[turn_id]
  end
  return type(params.threadId) == "string" and self.jobs_by_thread[params.threadId] or nil
end

function Backend:collect_item(job, item)
  if type(item) ~= "table" or type(item.type) ~= "string" then
    return true
  end
  if PROHIBITED_ITEM_TYPES[item.type] then
    self:interrupt_job(job)
    self:finish_job(
      job,
      "error",
      backend_error(
        errors.codes.BACKEND_TOOL_ATTEMPT,
        "Codex attempted a prohibited tool or external action",
        false,
        { item_type = item.type }
      )
    )
    return false
  end
  if item.type == "agentMessage" and type(item.text) == "string" then
    job.last_agent_message = item.text
    if item.phase == "final_answer" then
      job.final_answer = item.text
    end
  end
  return true
end

function Backend:handle_notification(message)
  local method = message.method
  local params = message.params
  local job = self:job_for_params(params)
  if method == "turn/started" then
    if job and type(params.turn) == "table" and type(params.turn.id) == "string" then
      job.turn_id = params.turn.id
      self.jobs_by_turn[job.turn_id] = job
    end
  elseif method == "item/started" or method == "item/completed" then
    if job then
      self:collect_item(job, params.item)
    end
  elseif method == "turn/completed" then
    if not job or job.settled or job.cancelled then
      return
    end
    local turn = type(params) == "table" and params.turn or nil
    if type(turn) ~= "table" or type(turn.id) ~= "string" or type(turn.status) ~= "string" then
      self:finish_job(
        job,
        "error",
        backend_error(
          errors.codes.BACKEND_PROTOCOL,
          "Codex returned an invalid completed turn",
          false
        )
      )
      return
    end
    job.turn_id = turn.id
    self.jobs_by_turn[turn.id] = job
    if is_list(turn.items) then
      for _, item in ipairs(turn.items) do
        if not self:collect_item(job, item) then
          return
        end
      end
    end
    if turn.status ~= "completed" then
      self:finish_job(
        job,
        "error",
        backend_error(
          errors.codes.TRANSLATION,
          "Codex turn did not complete successfully",
          false,
          { status = turn.status }
        )
      )
      return
    end
    local text = job.final_answer or job.last_agent_message
    if not text then
      self:finish_job(
        job,
        "error",
        backend_error(
          errors.codes.BACKEND_PROTOCOL,
          "Codex turn completed without a final agent message",
          false
        )
      )
      return
    end
    self:finish_job(job, "complete", {
      text = text,
      metadata = {
        backend_id = self.id,
        model = self.selected_model_name,
        thread_id = job.thread_id,
        turn_id = job.turn_id,
      },
    })
  elseif method == "error" then
    if job then
      job.last_error = { received = true }
    end
  else
    self:record("unknown_app_server_notification", { method = method })
  end
end

function Backend:reply_to_server_request(message)
  local kind = APPROVAL_METHODS[message.method]
  local result
  if kind == "approval" then
    result = { decision = "decline" }
  elseif kind == "permission" then
    result = { scope = "turn", permissions = {} }
  elseif kind == "elicitation" then
    result = { action = "decline", content = json.null }
  elseif kind == "user_input" then
    local answers = {}
    local questions = type(message.params) == "table" and message.params.questions or nil
    if is_list(questions) then
      for _, question in ipairs(questions) do
        if type(question) == "table" and type(question.id) == "string" then
          answers[question.id] = { answers = json.array() }
        end
      end
    end
    result = { answers = answers }
  else
    self:write_message({
      id = message.id,
      error = { code = -32601, message = "Method not supported" },
    })
    local unknown_job = self:job_for_params(message.params)
    if unknown_job then
      self:interrupt_job(unknown_job)
      self:finish_job(
        unknown_job,
        "error",
        backend_error(
          errors.codes.BACKEND_PROTOCOL,
          "Codex sent an unsupported server request",
          false
        )
      )
    end
    return
  end
  self:write_message({ id = message.id, result = result })
  if kind == "approval" then
    local job = self:job_for_params(message.params)
    if job then
      self:interrupt_job(job)
      self:finish_job(
        job,
        "error",
        backend_error(
          errors.codes.BACKEND_TOOL_ATTEMPT,
          "Codex requested approval for a prohibited action",
          false
        )
      )
    end
  end
end

function Backend:dispatch(message)
  if type(message) ~= "table" or json.is_array(message) then
    self:fail_connection(
      backend_error(
        errors.codes.BACKEND_PROTOCOL,
        "Codex emitted a non-object JSON-RPC message",
        false
      )
    )
    return
  end
  if rawget(message, "id") ~= nil and type(message.method) == "string" then
    self:reply_to_server_request(message)
  elseif rawget(message, "id") ~= nil then
    self:handle_response(message)
  elseif type(message.method) == "string" then
    self:handle_notification(message)
  else
    self:fail_connection(
      backend_error(
        errors.codes.BACKEND_PROTOCOL,
        "Codex emitted an invalid JSON-RPC message",
        false
      )
    )
  end
end

function Backend:fail_pending(connection_error)
  local pending_entries = {}
  for id, pending in pairs(self.pending) do
    pending_entries[#pending_entries + 1] = pending
    self.pending[id] = nil
  end
  for _, pending in ipairs(pending_entries) do
    cancel_timer(pending.timer)
    pending.callback(nil, connection_error)
  end
end

function Backend:fail_jobs(connection_error)
  local active = {}
  for job in pairs(self.jobs) do
    active[#active + 1] = job
  end
  for _, job in ipairs(active) do
    self:finish_job(job, "error", connection_error)
  end
end

function Backend:fail_connection(connection_error)
  if self.state == "closed" or self.state == "closing" or self.state == "failed" then
    return
  end
  self.state = "failed"
  self:fail_pending(connection_error)
  self:fail_jobs(connection_error)
  self:complete_open(nil, connection_error)
  if self.process and type(self.process.kill) == "function" then
    pcall(self.process.kill, self.process, 9)
  end
  self:cleanup_tempdir()
end

function Backend:on_process_exit(result)
  self.process = nil
  if self.state == "closing" then
    self:finalize_close(true)
    return
  elseif self.state == "closed" then
    return
  end
  local code = type(result) == "table" and result.code or nil
  self:fail_connection(
    backend_error(
      errors.codes.BACKEND_UNAVAILABLE,
      "Codex app-server exited unexpectedly",
      true,
      { exit_code = code }
    )
  )
end

function Backend:cleanup_tempdir()
  local path = self.isolated_temp_dir
  if not path then
    return true
  end
  self.isolated_temp_dir = nil
  local ok, removed = pcall(self.remove_tree, path)
  if not ok or removed ~= true then
    self.warnings[#self.warnings + 1] = "Could not remove the isolated Codex directory"
    return false
  end
  return true
end

function Backend:finalize_close(closed)
  if self.close_settled then
    return
  end
  self.close_settled = true
  cancel_timer(self.shutdown_timer)
  self.shutdown_timer = nil
  self.process = nil
  self.pending = {}
  self.jobs = {}
  self.jobs_by_thread = {}
  self.jobs_by_turn = {}
  self.stderr_ring = {}
  self:cleanup_tempdir()
  self.state = "closed"
  local callbacks = self.close_callbacks
  self.close_callbacks = {}
  self:defer(function()
    for _, callback in ipairs(callbacks) do
      callback(closed == true)
    end
  end)
end

function Backend:close(callback)
  if callback ~= nil and type(callback) ~= "function" then
    error("Codex backend close callback must be a function", 2)
  end
  if self.state == "closed" then
    if callback then
      self:defer(function()
        callback(true)
      end)
    end
    return
  elseif self.state == "closing" then
    if callback then
      self.close_callbacks[#self.close_callbacks + 1] = callback
    end
    return
  elseif self.state == "new" then
    if callback then
      self.close_callbacks[#self.close_callbacks + 1] = callback
    end
    self.state = "closing"
    self:finalize_close(true)
    return
  end
  if callback then
    self.close_callbacks[#self.close_callbacks + 1] = callback
  end
  self.state = "closing"
  local closed_error = backend_error(errors.codes.SESSION_CLOSED, "Codex backend is closing", false)
  local active = {}
  for job in pairs(self.jobs) do
    active[#active + 1] = job
  end
  for _, job in ipairs(active) do
    self:interrupt_job(job)
    self:finish_job(job, "error", closed_error)
  end
  self:fail_pending(closed_error)
  if self.process and type(self.process.write) == "function" then
    pcall(self.process.write, self.process, nil)
  end
  if not self.process then
    self:finalize_close(true)
    return
  end
  local timer, timer_error = self:start_timer(self.shutdown_timeout_ms, function()
    if self.close_settled then
      return
    end
    if self.process and type(self.process.kill) == "function" then
      pcall(self.process.kill, self.process, 9)
    end
    self:finalize_close(true)
  end)
  if not timer then
    self.warnings[#self.warnings + 1] = timer_error.message
    if self.process and type(self.process.kill) == "function" then
      pcall(self.process.kill, self.process, 9)
    end
    self:finalize_close(true)
    return
  end
  self.shutdown_timer = timer
end

return {
  new = Backend.new,
}
