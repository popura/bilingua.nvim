local Transport = {}
Transport.__index = Transport

local M = {}

local STATUS_WRITE_OUT = "\n__BILINGUA_HTTP_STATUS__:%{http_code}"

local function copy_list(values)
  local copy = {}
  for index, value in ipairs(values or {}) do
    copy[index] = value
  end
  return copy
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

local function positive_integer(value)
  return type(value) == "number" and value >= 1 and value % 1 == 0
end

local function non_negative_integer(value)
  return type(value) == "number" and value >= 0 and value % 1 == 0
end

local function failure(kind, message, exit_code)
  local result = {
    kind = kind,
    message = message,
  }
  if exit_code ~= nil then
    result.exit_code = exit_code
  end
  return result
end

local NETWORK_EXIT_CODES = {
  [6] = true,
  [7] = true,
  [52] = true,
  [55] = true,
  [56] = true,
}

local function exit_failure(exit_code)
  if exit_code == 28 then
    return failure("timeout", "curl request timed out", exit_code)
  elseif NETWORK_EXIT_CODES[exit_code] then
    return failure("network", "curl could not reach the HTTP server", exit_code)
  end
  return failure("io", "curl request failed", exit_code)
end

local function timeout_seconds(milliseconds)
  if milliseconds % 1000 == 0 then
    return tostring(milliseconds / 1000)
  end
  return ("%.3f"):format(milliseconds / 1000):gsub("0+$", ""):gsub("%.$", "")
end

local function parse_response(stdout, stderr)
  local body, status = stdout:match("^(.*)\n__BILINGUA_HTTP_STATUS__:(%d%d%d)$")
  if not body then
    return nil, failure("protocol", "curl returned an invalid HTTP status marker", 0)
  end
  if body:sub(-1) == "\r" then
    body = body:sub(1, -2)
  end
  return {
    status = tonumber(status),
    body = body,
    stderr = stderr,
  }
end

local function sorted_header_names(headers)
  local names = {}
  for name in pairs(headers or {}) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

local function valid_headers(headers)
  if headers == nil then
    return true
  end
  if type(headers) ~= "table" then
    return false
  end
  for name, value in pairs(headers) do
    if
      type(name) ~= "string"
      or name == ""
      or type(value) ~= "string"
      or name:find("[\r\n]")
      or value:find("[\r\n]")
    then
      return false
    end
  end
  return true
end

local function build_argv(transport, request)
  local argv = copy_list(transport.command)
  local function append(...)
    for index = 1, select("#", ...) do
      argv[#argv + 1] = select(index, ...)
    end
  end

  append("--silent", "--show-error", "--noproxy", "*")
  append("--request", request.method)
  for _, name in ipairs(sorted_header_names(request.headers)) do
    append("--header", name .. ": " .. request.headers[name])
  end
  local seconds = timeout_seconds(request.timeout_ms)
  append("--connect-timeout", seconds, "--max-time", seconds)
  append("--write-out", STATUS_WRITE_OUT)
  if request.method == "POST" then
    append("--data-binary", "@-")
  end
  append(request.url)
  return argv
end

local DEFAULT_MAX_STDERR_BYTES = 64 * 1024

function M.new(options)
  if type(options) ~= "table" then
    error("curl transport options are required", 2)
  end
  if not string_list(options.command) then
    error("curl transport command must be a non-empty string list", 2)
  end
  if type(options.process_factory) ~= "function" then
    error("curl transport requires an injected process_factory function", 2)
  end
  if type(options.schedule) ~= "function" then
    error("curl transport requires an injected schedule function", 2)
  end
  if not positive_integer(options.max_response_bytes) then
    error("curl transport max_response_bytes must be a positive integer", 2)
  end
  local max_stderr_bytes = options.max_stderr_bytes or DEFAULT_MAX_STDERR_BYTES
  if not non_negative_integer(max_stderr_bytes) then
    error("curl transport max_stderr_bytes must be a non-negative integer", 2)
  end
  return setmetatable({
    command = copy_list(options.command),
    process_factory = options.process_factory,
    schedule = options.schedule,
    max_response_bytes = options.max_response_bytes,
    max_stderr_bytes = max_stderr_bytes,
  }, Transport)
end

function Transport:request(request, callback)
  if type(callback) ~= "function" then
    error("curl transport request callback is required", 2)
  end
  local state = {
    callback = callback,
    cancelled = false,
    settling = false,
    delivered = false,
    exited = false,
    stdout = {},
    stdout_bytes = 0,
    stderr = {},
    stderr_bytes = 0,
    process = nil,
    pending_error = nil,
    killed = false,
  }

  local function kill_process()
    if
      state.killed
      or state.exited
      or not state.process
      or type(state.process.kill) ~= "function"
    then
      return
    end
    state.killed = true
    pcall(state.process.kill, state.process, 15)
  end

  local handle = {}
  function handle:cancel()
    if state.cancelled or state.delivered then
      return
    end
    state.cancelled = true
    kill_process()
  end

  local function schedule_delivery(resolve)
    if state.settling or state.delivered or state.cancelled then
      return
    end
    state.settling = true
    self.schedule(function()
      if state.cancelled or state.delivered then
        return
      end
      state.delivered = true
      local response, transport_error = resolve()
      state.callback(response, transport_error)
    end)
  end

  local function schedule_result(response, transport_error)
    schedule_delivery(function()
      return response, transport_error
    end)
  end

  if type(request) ~= "table" or (request.method ~= "GET" and request.method ~= "POST") then
    schedule_result(nil, failure("protocol", "curl transport accepts only GET and POST"))
    return handle
  end
  if type(request.url) ~= "string" or request.url == "" then
    schedule_result(nil, failure("protocol", "curl transport requires a non-empty URL"))
    return handle
  end
  if not valid_headers(request.headers) then
    schedule_result(nil, failure("protocol", "curl transport headers are invalid"))
    return handle
  end
  if not non_negative_integer(request.timeout_ms) then
    schedule_result(nil, failure("protocol", "curl transport timeout must be milliseconds"))
    return handle
  end

  if request.method == "POST" and type(request.body) ~= "string" then
    schedule_result(nil, failure("protocol", "curl POST body must be a string"))
    return handle
  end

  local function stop_with_error(transport_error)
    if not state.pending_error then
      state.pending_error = transport_error
    end
    kill_process()
  end

  local process_options = {
    text = true,
    stdout = function(error_message, chunk)
      if state.cancelled or state.pending_error then
        return
      end
      if error_message then
        stop_with_error(failure("io", "curl stdout could not be read"))
      elseif chunk and chunk ~= "" then
        local new_size = state.stdout_bytes + #chunk
        if new_size > self.max_response_bytes then
          stop_with_error(failure("protocol", "curl response exceeded its size limit"))
        else
          state.stdout_bytes = new_size
          state.stdout[#state.stdout + 1] = chunk
        end
      end
    end,
    stderr = function(error_message, chunk)
      if state.cancelled or state.pending_error then
        return
      end
      if error_message then
        stop_with_error(failure("io", "curl stderr could not be read"))
      elseif chunk and chunk ~= "" then
        local remaining = self.max_stderr_bytes - state.stderr_bytes
        if remaining > 0 then
          local retained = chunk:sub(1, remaining)
          if retained ~= "" then
            state.stderr[#state.stderr + 1] = retained
            state.stderr_bytes = state.stderr_bytes + #retained
          end
        end
      end
    end,
  }
  if request.method == "POST" then
    process_options.stdin = true
  end
  local spawned, process = pcall(
    self.process_factory,
    build_argv(self, request),
    process_options,
    function(result)
      if state.cancelled or state.settling or state.delivered then
        return
      end
      state.exited = true
      schedule_delivery(function()
        local code = type(result) == "table" and result.code or nil
        if state.pending_error then
          if state.pending_error.exit_code == nil then
            state.pending_error.exit_code = code
          end
          return nil, state.pending_error
        end
        if code ~= 0 then
          return nil, exit_failure(code)
        end
        return parse_response(table.concat(state.stdout), table.concat(state.stderr))
      end)
    end
  )
  if not spawned or type(process) ~= "table" then
    schedule_result(nil, failure("spawn", "curl process could not be started"))
    return handle
  end
  state.process = process
  if state.pending_error then
    stop_with_error(state.pending_error)
  end
  if request.method == "POST" then
    if type(process.write) ~= "function" then
      kill_process()
      schedule_result(nil, failure("io", "curl request body could not be written"))
      return handle
    end
    local wrote_body, write_result = pcall(process.write, process, request.body)
    local closed_stdin, close_result = pcall(process.write, process, nil)
    if not wrote_body or write_result == false or not closed_stdin or close_result == false then
      kill_process()
      schedule_result(nil, failure("io", "curl request body could not be written"))
    end
  end
  return handle
end

return M
