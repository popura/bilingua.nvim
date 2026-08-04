local errors = require("bilingua.domain.error")
local curl = require("bilingua.adapters.translation.transports.curl")
local json = require("bilingua.util.json")

local Backend = {}
Backend.__index = Backend

local DEFAULT_ENDPOINT = "http://127.0.0.1:8080"
local DEFAULT_MAX_RESPONSE_BYTES = 16 * 1024 * 1024

local function backend_error(code, message, retryable, details, cause)
  return errors.new(code, message, retryable, details, cause)
end

local function configuration_error(message)
  return backend_error(errors.codes.BACKEND_INIT, message, false)
end

local function configured(options, name, default)
  if options[name] == nil then
    return default
  end
  return options[name]
end

local function positive_integer(value)
  return type(value) == "number" and value >= 1 and value % 1 == 0
end

local function non_negative_integer(value)
  return type(value) == "number" and value >= 0 and value % 1 == 0
end

local function string_list(value)
  if type(value) ~= "table" then
    return false
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
  if count == 0 or maximum ~= count then
    return false
  end
  for index = 1, count do
    if type(value[index]) ~= "string" or value[index] == "" then
      return false
    end
  end
  return true
end

local function copy_list(values)
  local copy = {}
  for index, value in ipairs(values or {}) do
    copy[index] = value
  end
  return copy
end

local function normalized_endpoint(value)
  if type(value) ~= "string" or value == "" then
    return nil, "llama-server endpoint must be a non-empty string"
  end
  local candidate = value
  if candidate:sub(-1) == "/" then
    candidate = candidate:sub(1, -2)
  end
  local scheme, authority = candidate:match("^([%a][%w+.-]*)://(.+)$")
  if not scheme or scheme:lower() ~= "http" then
    return nil, "llama-server endpoint must use http"
  end
  if
    authority:find("/", 1, true)
    or authority:find("?", 1, true)
    or authority:find("#", 1, true)
    or authority:find("@", 1, true)
  then
    return nil, "llama-server endpoint must contain only a loopback authority"
  end

  local host
  local port_text
  local ipv6 = authority:sub(1, 1) == "["
  if ipv6 then
    local address, suffix = authority:match("^%[([^%]]+)%](.*)$")
    if not address or address:lower() ~= "::1" then
      return nil, "llama-server endpoint host must be loopback"
    end
    host = "[::1]"
    if suffix ~= "" then
      port_text = suffix:match("^:(%d+)$")
      if not port_text then
        return nil, "llama-server endpoint port is invalid"
      end
    end
  else
    local first_colon = authority:find(":", 1, true)
    if first_colon then
      host = authority:sub(1, first_colon - 1)
      port_text = authority:sub(first_colon + 1)
      if port_text == "" or not port_text:match("^%d+$") then
        return nil, "llama-server endpoint port is invalid"
      end
    else
      host = authority
    end
    host = host:lower()
    if host ~= "localhost" and host ~= "127.0.0.1" then
      return nil, "llama-server endpoint host must be loopback"
    end
  end

  local port
  if port_text then
    port = tonumber(port_text)
    if not port or port < 1 or port > 65535 then
      return nil, "llama-server endpoint port must be between 1 and 65535"
    end
  end
  local normalized = "http://" .. host
  if port then
    normalized = normalized .. ":" .. tostring(port)
  end
  return normalized
end

local function validate_user_options(options)
  local endpoint, endpoint_error =
    normalized_endpoint(configured(options, "endpoint", DEFAULT_ENDPOINT))
  if not endpoint then
    return nil, configuration_error(endpoint_error)
  end

  local model = configured(options, "model", "auto")
  if type(model) ~= "string" or model == "" then
    return nil, configuration_error("llama-server model must be a non-empty string")
  end
  local curl_command = configured(options, "curl_command", { "curl" })
  if not string_list(curl_command) then
    return nil, configuration_error("llama-server curl_command must be a string list")
  end
  local open_timeout_ms = configured(options, "open_timeout_ms", 30000)
  if not positive_integer(open_timeout_ms) then
    return nil, configuration_error("llama-server open_timeout_ms must be a positive integer")
  end
  local health_poll_interval_ms = configured(options, "health_poll_interval_ms", 250)
  if not positive_integer(health_poll_interval_ms) then
    return nil,
      configuration_error("llama-server health_poll_interval_ms must be a positive integer")
  end
  if health_poll_interval_ms > open_timeout_ms then
    return nil,
      configuration_error("llama-server health_poll_interval_ms cannot exceed open_timeout_ms")
  end
  local configured_request_timeout = configured(options, "request_timeout_ms", 0)
  if not non_negative_integer(configured_request_timeout) then
    return nil,
      configuration_error("llama-server request_timeout_ms must be a non-negative integer")
  end
  local global_timeout = configured(options, "timeout_ms", 120000)
  if configured_request_timeout == 0 and not positive_integer(global_timeout) then
    return nil,
      configuration_error(
        "llama-server timeout_ms must be a positive integer when request_timeout_ms is zero"
      )
  end
  local request_timeout_ms = configured_request_timeout == 0 and global_timeout
    or configured_request_timeout
  local structured_output = configured(options, "structured_output", "json_schema")
  if structured_output ~= "json_schema" and structured_output ~= "prompt_only" then
    return nil,
      configuration_error("llama-server structured_output must be json_schema or prompt_only")
  end
  local disable_thinking = configured(options, "disable_thinking", true)
  if type(disable_thinking) ~= "boolean" then
    return nil, configuration_error("llama-server disable_thinking must be boolean")
  end
  local max_response_bytes = configured(options, "max_response_bytes", DEFAULT_MAX_RESPONSE_BYTES)
  if not positive_integer(max_response_bytes) then
    return nil, configuration_error("llama-server max_response_bytes must be a positive integer")
  end

  return {
    endpoint = endpoint,
    model = model,
    curl_command = copy_list(curl_command),
    open_timeout_ms = open_timeout_ms,
    health_poll_interval_ms = health_poll_interval_ms,
    request_timeout_ms = request_timeout_ms,
    structured_output = structured_output,
    disable_thinking = disable_thinking,
    max_response_bytes = max_response_bytes,
  }
end

function Backend.new(options)
  local resolved = type(options) == "table" and options or {}
  local user_options, user_error = validate_user_options(resolved)
  if type(resolved.schedule) ~= "function" then
    error("llama-server backend requires an injected schedule function", 2)
  end
  if type(resolved.timer_factory) ~= "function" then
    error("llama-server backend requires an injected timer_factory function", 2)
  end

  local transport = resolved.transport
  if transport ~= nil then
    if type(transport) ~= "table" or type(transport.request) ~= "function" then
      error("llama-server backend injected transport must expose request()", 2)
    end
  else
    if type(resolved.process_factory) ~= "function" then
      error("llama-server backend requires an injected process_factory function", 2)
    end
    local safe_options = user_options
      or {
        curl_command = { "curl" },
        max_response_bytes = DEFAULT_MAX_RESPONSE_BYTES,
      }
    transport = curl.new({
      command = safe_options.curl_command,
      process_factory = resolved.process_factory,
      schedule = resolved.schedule,
      max_response_bytes = safe_options.max_response_bytes,
    })
  end

  local effective = user_options
    or {
      endpoint = DEFAULT_ENDPOINT,
      model = "auto",
      curl_command = { "curl" },
      open_timeout_ms = 30000,
      health_poll_interval_ms = 250,
      request_timeout_ms = 120000,
      structured_output = "json_schema",
      disable_thinking = true,
      max_response_bytes = DEFAULT_MAX_RESPONSE_BYTES,
    }
  return setmetatable({
    api_version = 1,
    id = "llama_server",
    state = "new",
    endpoint = effective.endpoint,
    configured_model = effective.model,
    selected_model_name = nil,
    structured_output_mode = effective.structured_output,
    disable_thinking = effective.disable_thinking,
    open_timeout_ms = effective.open_timeout_ms,
    health_poll_interval_ms = effective.health_poll_interval_ms,
    request_timeout_ms = effective.request_timeout_ms,
    max_response_bytes = effective.max_response_bytes,
    transport = transport,
    schedule = resolved.schedule,
    timer_factory = resolved.timer_factory,
    configuration_error = user_error,
    pending = {},
    open_request = nil,
    open_timeout_timer = nil,
    health_poll_timer = nil,
    open_callback = nil,
    open_settled = false,
    close_callbacks = {},
    close_scheduled = false,
    close_settled = false,
  }, Backend)
end

function Backend:capabilities()
  return {
    structured_output = self.structured_output_mode == "json_schema",
    schema_in_prompt = true,
    streaming = false,
    cancellation = true,
    system_instructions = true,
    parallel_requests = true,
    ephemeral_sessions = false,
    max_input_chars = nil,
  }
end

function Backend:selected_model()
  return self.selected_model_name
end

function Backend:defer(callback)
  self.schedule(callback)
end

local function cancel_timer(timer)
  if timer and type(timer.cancel) == "function" then
    pcall(timer.cancel, timer)
  end
end

function Backend:start_timer(milliseconds, callback)
  local created, timer = pcall(self.timer_factory, milliseconds, function()
    self:defer(callback)
  end)
  if not created or type(timer) ~= "table" or type(timer.cancel) ~= "function" then
    return nil,
      backend_error(errors.codes.INTERNAL, "Could not create a llama-server backend timer", false)
  end
  return timer
end

local function transport_failure(transport_error)
  local kind = type(transport_error) == "table" and transport_error.kind or nil
  if kind == "spawn" then
    return backend_error(
      errors.codes.BACKEND_NOT_FOUND,
      "Could not start the curl HTTP client",
      false
    )
  elseif kind == "timeout" then
    return backend_error(errors.codes.BACKEND_TIMEOUT, "llama-server request timed out", true)
  elseif kind == "network" then
    return backend_error(errors.codes.BACKEND_UNAVAILABLE, "llama-server is unavailable", true)
  elseif kind == "protocol" then
    return backend_error(
      errors.codes.BACKEND_PROTOCOL,
      "The llama-server HTTP response was malformed",
      false
    )
  elseif kind == "cancelled" then
    return backend_error(
      errors.codes.BACKEND_CANCELLED,
      "llama-server request was cancelled",
      false
    )
  end
  return backend_error(
    errors.codes.BACKEND_UNAVAILABLE,
    "The llama-server HTTP request failed",
    true
  )
end

local function decode_object(body)
  local decoded = json.decode(body)
  if type(decoded) ~= "table" or json.is_array(decoded) or decoded == json.null then
    return nil
  end
  return decoded
end

local MAX_SERVER_MESSAGE_BYTES = 512

local function http_error_details(response)
  local details = {
    http_status = type(response) == "table" and response.status or nil,
  }
  local decoded = type(response) == "table" and decode_object(response.body) or nil
  local server_error = decoded and decoded.error or nil
  if type(server_error) ~= "table" or json.is_array(server_error) then
    return details
  end
  if type(server_error.code) == "string" or type(server_error.code) == "number" then
    details.server_code = server_error.code
  end
  if type(server_error.type) == "string" then
    details.server_type = server_error.type
  end
  if type(server_error.message) == "string" then
    details.server_message = server_error.message:sub(1, MAX_SERVER_MESSAGE_BYTES)
  end
  return details
end

local function http_failure(response)
  local status = type(response) == "table" and response.status or nil
  local code = errors.codes.BACKEND_PROTOCOL
  local retryable = false
  if status == 401 or status == 403 then
    code = errors.codes.BACKEND_AUTH
  elseif status == 408 or status == 504 then
    code = errors.codes.BACKEND_TIMEOUT
    retryable = true
  elseif status == 429 then
    code = errors.codes.BACKEND_RATE_LIMITED
    retryable = true
  elseif
    status == 502
    or status == 503
    or (type(status) == "number" and status >= 500 and status <= 599)
  then
    code = errors.codes.BACKEND_UNAVAILABLE
    retryable = true
  end
  return backend_error(
    code,
    "llama-server returned an HTTP error",
    retryable,
    http_error_details(response)
  )
end

function Backend:cancel_open_request()
  local operation = self.open_request
  self.open_request = nil
  if not operation then
    return
  end
  operation.active = false
  if operation.handle and type(operation.handle.cancel) == "function" then
    pcall(operation.handle.cancel, operation.handle)
  end
end

function Backend:cancel_open_resources()
  self:cancel_open_request()
  cancel_timer(self.open_timeout_timer)
  cancel_timer(self.health_poll_timer)
  self.open_timeout_timer = nil
  self.health_poll_timer = nil
end

function Backend:complete_open(opened, open_error)
  if self.open_settled then
    return
  end
  self.open_settled = true
  self:cancel_open_resources()
  self.state = opened and "ready" or "failed"
  local callback = self.open_callback
  self.open_callback = nil
  if callback then
    self:defer(function()
      if opened then
        callback(true)
      else
        callback(nil, open_error)
      end
    end)
  end
end

function Backend:start_open_request(request, handler)
  local operation = { active = true, handle = nil }
  self.open_request = operation
  local requested, handle = pcall(
    self.transport.request,
    self.transport,
    request,
    function(response, request_error)
      self:defer(function()
        if self.state ~= "opening" or self.open_request ~= operation or not operation.active then
          return
        end
        operation.active = false
        self.open_request = nil
        handler(response, request_error)
      end)
    end
  )
  if not requested or type(handle) ~= "table" or type(handle.cancel) ~= "function" then
    if self.open_request == operation then
      self.open_request = nil
    end
    operation.active = false
    self:complete_open(
      nil,
      backend_error(errors.codes.BACKEND_INIT, "Could not start a llama-server HTTP request", false)
    )
    return
  end
  operation.handle = handle
end

function Backend:request_models()
  self:start_open_request({
    method = "GET",
    url = self.endpoint .. "/v1/models",
    headers = {},
    timeout_ms = self.open_timeout_ms,
  }, function(response, request_error)
    if request_error then
      self:complete_open(nil, transport_failure(request_error))
      return
    end
    if type(response) ~= "table" or response.status ~= 200 then
      self:complete_open(nil, http_failure(response))
      return
    end
    local decoded = decode_object(response.body)
    if not decoded or not json.is_array(decoded.data) then
      self:complete_open(
        nil,
        backend_error(
          errors.codes.BACKEND_PROTOCOL,
          "llama-server returned an invalid model list",
          false
        )
      )
      return
    end

    local candidates = {}
    for _, candidate in ipairs(decoded.data) do
      if type(candidate) == "table" and type(candidate.id) == "string" and candidate.id ~= "" then
        candidates[#candidates + 1] = candidate.id
      end
    end
    if self.configured_model == "auto" then
      if #candidates ~= 1 then
        self:complete_open(
          nil,
          backend_error(
            errors.codes.BACKEND_INIT,
            "Configure a model explicitly when llama-server does not expose exactly one model",
            false
          )
        )
        return
      end
      self.selected_model_name = candidates[1]
    else
      self.selected_model_name = self.configured_model
    end
    self:complete_open(true)
  end)
end

function Backend:schedule_health_poll()
  local timer, timer_error = self:start_timer(self.health_poll_interval_ms, function()
    if self.state ~= "opening" or self.open_settled then
      return
    end
    self.health_poll_timer = nil
    self:request_health()
  end)
  if not timer then
    self:complete_open(nil, timer_error)
    return
  end
  self.health_poll_timer = timer
end

function Backend:request_health()
  self:start_open_request({
    method = "GET",
    url = self.endpoint .. "/health",
    headers = {},
    timeout_ms = self.open_timeout_ms,
  }, function(response, request_error)
    if request_error then
      self:complete_open(nil, transport_failure(request_error))
      return
    end
    if type(response) == "table" and response.status == 503 then
      self:schedule_health_poll()
      return
    end
    if type(response) ~= "table" or response.status ~= 200 then
      self:complete_open(nil, http_failure(response))
      return
    end
    local decoded = decode_object(response.body)
    if not decoded or decoded.status ~= "ok" then
      self:complete_open(
        nil,
        backend_error(
          errors.codes.BACKEND_PROTOCOL,
          "llama-server returned an invalid health response",
          false
        )
      )
      return
    end
    self:request_models()
  end)
end

function Backend:open(callback)
  if type(callback) ~= "function" then
    error("llama-server backend open callback is required", 2)
  end
  if self.state == "ready" then
    self:defer(function()
      callback(true)
    end)
    return
  elseif self.state ~= "new" then
    self:defer(function()
      callback(
        nil,
        backend_error(
          errors.codes.BACKEND_INIT,
          "llama-server backend cannot be opened from its current state",
          false
        )
      )
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
  self.open_settled = false
  local timeout_timer, timer_error = self:start_timer(self.open_timeout_ms, function()
    if self.state ~= "opening" or self.open_settled then
      return
    end
    self:complete_open(
      nil,
      backend_error(
        errors.codes.BACKEND_TIMEOUT,
        "llama-server did not become ready before the open timeout",
        true
      )
    )
  end)
  if not timeout_timer then
    self:complete_open(nil, timer_error)
    return
  end
  self.open_timeout_timer = timeout_timer
  self:request_health()
end

function Backend:finish_job(job, kind, value)
  if job.settled or job.cancelled then
    return
  end
  job.settled = true
  self.pending[job] = nil
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

local function protocol_failure(message)
  return backend_error(errors.codes.BACKEND_PROTOCOL, message, false)
end

function Backend:handle_chat_response(job, response, request_error)
  if job.cancelled or job.settled then
    return
  end
  if request_error then
    self:finish_job(job, "error", transport_failure(request_error))
    return
  end
  if type(response) ~= "table" or response.status ~= 200 then
    self:finish_job(job, "error", http_failure(response))
    return
  end
  local decoded = decode_object(response.body)
  if not decoded or not json.is_array(decoded.choices) or #decoded.choices == 0 then
    self:finish_job(
      job,
      "error",
      protocol_failure("llama-server returned an invalid chat completion envelope")
    )
    return
  end
  local choice = decoded.choices[1]
  if
    type(choice) ~= "table"
    or json.is_array(choice)
    or type(choice.message) ~= "table"
    or json.is_array(choice.message)
  then
    self:finish_job(
      job,
      "error",
      protocol_failure("llama-server returned an invalid chat completion choice")
    )
    return
  end
  local tool_calls = choice.message.tool_calls
  if tool_calls ~= nil and tool_calls ~= json.null then
    if not json.is_array(tool_calls) then
      self:finish_job(
        job,
        "error",
        protocol_failure("llama-server returned malformed tool call data")
      )
      return
    elseif #tool_calls > 0 then
      self:finish_job(
        job,
        "error",
        backend_error(
          errors.codes.BACKEND_TOOL_ATTEMPT,
          "llama-server attempted to return a tool call",
          false
        )
      )
      return
    end
  end
  if choice.finish_reason == "length" then
    self:finish_job(job, "error", protocol_failure("llama-server truncated the chat completion"))
    return
  end
  if type(choice.message.content) ~= "string" then
    self:finish_job(
      job,
      "error",
      protocol_failure("llama-server returned chat content with an invalid type")
    )
    return
  end
  self:finish_job(job, "complete", {
    text = choice.message.content,
    model = decoded.model,
    finish_reason = choice.finish_reason,
  })
end

local function request_payload(backend, request)
  local messages = json.array()
  if type(request.system_instructions) == "string" and request.system_instructions ~= "" then
    messages[#messages + 1] = {
      role = "system",
      content = request.system_instructions,
    }
  end
  messages[#messages + 1] = {
    role = "user",
    content = request.user_content,
  }
  local payload = {
    model = backend.selected_model_name,
    messages = messages,
    stream = false,
  }
  if backend.structured_output_mode == "json_schema" then
    payload.response_format = {
      type = "json_schema",
      json_schema = {
        name = "bilingua_response",
        strict = true,
        schema = request.response_schema,
      },
    }
  end
  if backend.disable_thinking then
    payload.reasoning_effort = "none"
    payload.chat_template_kwargs = {
      enable_thinking = false,
    }
  end
  return payload
end

function Backend:request(request, callbacks)
  if
    type(request) ~= "table"
    or type(request.request_id) ~= "string"
    or request.request_id == ""
    or type(request.user_content) ~= "string"
    or (request.system_instructions ~= nil and type(request.system_instructions) ~= "string")
    or (request.timeout_ms ~= nil and not non_negative_integer(request.timeout_ms))
    or type(callbacks) ~= "table"
    or type(callbacks.on_complete) ~= "function"
    or type(callbacks.on_error) ~= "function"
  then
    error("llama-server backend request requires normalized input and terminal callbacks", 2)
  end

  local job = {
    request_id = request.request_id,
    callbacks = callbacks,
    transport_handle = nil,
    cancelled = false,
    settled = false,
    delivered = false,
  }
  local owner = self
  local handle = {}
  function handle:cancel()
    if job.cancelled or job.delivered then
      return
    end
    job.cancelled = true
    owner.pending[job] = nil
    if job.transport_handle and type(job.transport_handle.cancel) == "function" then
      pcall(job.transport_handle.cancel, job.transport_handle)
    end
  end
  function handle:is_cancelled()
    return job.cancelled
  end

  if self.state ~= "ready" then
    self:finish_job(
      job,
      "error",
      backend_error(errors.codes.BACKEND_UNAVAILABLE, "llama-server backend is not ready", false)
    )
    return handle
  end
  if
    self.structured_output_mode == "json_schema"
    and (type(request.response_schema) ~= "table" or request.response_schema == json.null)
  then
    self:finish_job(
      job,
      "error",
      backend_error(
        errors.codes.BACKEND_PROTOCOL,
        "llama-server JSON Schema mode requires a response schema",
        false
      )
    )
    return handle
  end

  local encoded, body = pcall(json.encode, request_payload(self, request))
  if not encoded then
    self:finish_job(
      job,
      "error",
      backend_error(
        errors.codes.BACKEND_PROTOCOL,
        "Could not encode the llama-server chat request",
        false
      )
    )
    return handle
  end

  self.pending[job] = true
  local submitted, transport_handle = pcall(self.transport.request, self.transport, {
    method = "POST",
    url = self.endpoint .. "/v1/chat/completions",
    headers = { ["Content-Type"] = "application/json" },
    body = body,
    timeout_ms = request.timeout_ms ~= nil and request.timeout_ms or self.request_timeout_ms,
  }, function(response, request_error)
    self:defer(function()
      self:handle_chat_response(job, response, request_error)
    end)
  end)
  if
    not submitted
    or type(transport_handle) ~= "table"
    or type(transport_handle.cancel) ~= "function"
  then
    self:finish_job(
      job,
      "error",
      backend_error(
        errors.codes.BACKEND_UNAVAILABLE,
        "Could not start the llama-server chat request",
        true
      )
    )
    return handle
  end
  job.transport_handle = transport_handle
  if job.cancelled then
    pcall(transport_handle.cancel, transport_handle)
  end
  return handle
end

function Backend:abort_open_for_close(closed_error)
  if self.open_settled then
    return
  end
  self.open_settled = true
  self:cancel_open_resources()
  local callback = self.open_callback
  self.open_callback = nil
  if callback then
    self:defer(function()
      callback(nil, closed_error)
    end)
  end
end

function Backend:finalize_close()
  if self.close_settled then
    return
  end
  self.close_settled = true
  self.close_scheduled = false
  self:cancel_open_resources()
  self.pending = {}
  self.state = "closed"
  local callbacks = self.close_callbacks
  self.close_callbacks = {}
  for _, callback in ipairs(callbacks) do
    callback(true)
  end
end

function Backend:schedule_close_finalization()
  if self.close_scheduled or self.close_settled then
    return
  end
  self.close_scheduled = true
  self:defer(function()
    self:finalize_close()
  end)
end

function Backend:close(callback)
  if callback ~= nil and type(callback) ~= "function" then
    error("llama-server backend close callback must be a function", 2)
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
  end

  local previous_state = self.state
  if callback then
    self.close_callbacks[#self.close_callbacks + 1] = callback
  end
  self.state = "closing"
  local closed_error =
    backend_error(errors.codes.SESSION_CLOSED, "llama-server backend is closing", false)
  if previous_state == "opening" then
    self:abort_open_for_close(closed_error)
  else
    self:cancel_open_resources()
  end

  local active = {}
  for job in pairs(self.pending) do
    active[#active + 1] = job
  end
  for _, job in ipairs(active) do
    if job.transport_handle and type(job.transport_handle.cancel) == "function" then
      pcall(job.transport_handle.cancel, job.transport_handle)
    end
    job.transport_handle = nil
    self:finish_job(job, "error", closed_error)
  end
  self:schedule_close_finalization()
end

return {
  new = Backend.new,
}
