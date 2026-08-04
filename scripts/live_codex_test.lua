local backend_module = require("bilingua.adapters.translation.backends.codex_app_server")
local config_module = require("bilingua.config")
local json = require("bilingua.util.json")
local runtime_module = require("bilingua.ui.nvim_runtime")

local uv = vim.uv or vim.loop
local backend
local isolated_temp_dir

local function fail(message)
  error(message, 0)
end

local function elapsed_ms(started_at)
  return math.floor((uv.hrtime() - started_at) / 1000000)
end

local function error_summary(prefix, value)
  local code = type(value) == "table" and value.code or "unknown"
  local message = type(value) == "table" and value.message or "unknown error"
  return ("%s [%s]: %s"):format(prefix, tostring(code), tostring(message))
end

local function await(label, timeout_ms, predicate)
  local completed = vim.wait(timeout_ms, predicate, 20)
  if not completed then
    fail(("%s timed out after %d ms"):format(label, timeout_ms))
  end
end

local function copy_table(values)
  local copy = {}
  for key, value in pairs(values) do
    copy[key] = value
  end
  return copy
end

local function run()
  if type(vim.system) ~= "function" then
    fail("live Codex test requires Neovim with vim.system()")
  end

  local runtime = runtime_module.new()
  local resolved_config, config_error = config_module.resolve({})
  if not resolved_config then
    fail(error_summary("Default configuration failed", config_error))
  end
  local backend_defaults = resolved_config.translation.backends.codex_app_server
  local options = copy_table(runtime.backend_runtime)
  local create_tempdir = options.tempdir_factory
  options.tempdir_factory = function()
    local path, creation_error = create_tempdir()
    isolated_temp_dir = path
    return path, creation_error
  end
  options.request_timeout_ms = 30000
  options.turn_timeout_ms = 240000
  options.shutdown_timeout_ms = 5000
  options.model = backend_defaults.model
  options.reasoning_effort = backend_defaults.reasoning_effort
  backend = backend_module.new(options)

  local open_done = false
  local open_ok
  local open_error
  local open_started_at = uv.hrtime()
  backend:open(function(ok, value)
    open_ok = ok
    open_error = value
    open_done = true
  end)
  await("Codex backend open", 60000, function()
    return open_done
  end)
  if not open_ok then
    fail(error_summary("Codex backend open failed", open_error))
  end
  local selected_model = backend:selected_model()
  if type(selected_model) ~= "string" or selected_model == "" then
    fail("Codex backend did not select a model")
  end
  if selected_model ~= backend_defaults.model then
    fail("Codex backend did not select the pinned live-test model")
  end
  if backend.resolved_reasoning_effort ~= backend_defaults.reasoning_effort then
    fail("Codex backend did not resolve the pinned live-test reasoning effort")
  end
  local open_duration_ms = elapsed_ms(open_started_at)

  local marker = "BILINGUA_LIVE_CODEX_V1"
  local placeholder = "<BILINGUA-LIVE-PROTECTED-001>"
  local request_done = false
  local response
  local request_error
  local request_started_at = uv.hrtime()
  backend:request({
    request_id = "live_codex_transport_v1",
    system_instructions = table.concat({
      "You are running a local transport test.",
      "Do not use tools or take external actions.",
      "Return only one JSON object matching the supplied response schema.",
      "Copy the requested marker and placeholder exactly.",
    }, " "),
    user_content = json.encode({
      task = "Bilingua.nvim live Codex transport test",
      marker = marker,
      placeholder = placeholder,
    }),
    response_schema = {
      type = "object",
      additionalProperties = false,
      required = { "schema_version", "marker", "placeholder" },
      properties = {
        schema_version = { type = "integer", const = 1 },
        marker = { type = "string", const = marker },
        placeholder = { type = "string", const = placeholder },
      },
    },
    timeout_ms = 240000,
    metadata = { codec_id = "live_codex_transport_v1" },
  }, {
    on_complete = function(value)
      response = value
      request_done = true
    end,
    on_error = function(value)
      request_error = value
      request_done = true
    end,
  })
  await("Codex inference", 270000, function()
    return request_done
  end)
  if request_error then
    fail(error_summary("Codex inference failed", request_error))
  end
  if type(response) ~= "table" or type(response.text) ~= "string" then
    fail("Codex inference returned an invalid response envelope")
  end
  local decoded, decode_error = json.decode(response.text)
  if not decoded then
    fail("Codex inference returned invalid JSON: " .. tostring(decode_error))
  end
  if
    type(decoded) ~= "table"
    or decoded.schema_version ~= 1
    or decoded.marker ~= marker
    or decoded.placeholder ~= placeholder
  then
    fail("Codex inference response failed structured-output validation")
  end

  return {
    model = selected_model,
    effort = backend.resolved_reasoning_effort,
    open_duration_ms = open_duration_ms,
    request_duration_ms = elapsed_ms(request_started_at),
  }
end

local function close_backend()
  if not backend then
    return true
  end
  local close_done = false
  local close_ok
  backend:close(function(ok)
    close_ok = ok
    close_done = true
  end)
  if not vim.wait(15000, function()
    return close_done
  end, 20) then
    if backend.process and type(backend.process.kill) == "function" then
      pcall(backend.process.kill, backend.process, 9)
    end
    vim.wait(2000, function()
      return backend.state == "closed"
    end, 20)
  end
  return close_done and close_ok == true and backend.state == "closed"
end

local succeeded, result = xpcall(run, function(value)
  return debug.traceback(tostring(value), 2)
end)
local closed = close_backend()
local tempdir_removed = isolated_temp_dir == nil or uv.fs_stat(isolated_temp_dir) == nil
local runtime_released = backend == nil
  or (
    backend.process == nil
    and next(backend.jobs or {}) == nil
    and next(backend.pending or {}) == nil
  )

if not succeeded then
  io.stderr:write("LIVE_CODEX_TEST failed\n" .. result .. "\n")
elseif not closed or not tempdir_removed or not runtime_released then
  succeeded = false
  io.stderr:write("LIVE_CODEX_TEST failed: backend cleanup validation failed\n")
else
  io.stdout:write(
    ("LIVE_CODEX_TEST passed model=%s effort=%s open_ms=%d request_ms=%d response_content=omitted cleanup=ok\n"):format(
      result.model,
      result.effort,
      result.open_duration_ms,
      result.request_duration_ms
    )
  )
end

if not succeeded then
  vim.cmd("cquit 1")
end
