local json = require("bilingua.util.json")

local uv = vim.uv or vim.loop
local api
local coordinator
local source_buf
local target_buf
local source_path
local endpoint
local previous_notify = vim.notify
local command_failed = false
local command_error_code
local command_error_message
local status_message

local function fail(message)
  error(message, 0)
end

local function elapsed_ms(started_at)
  return math.floor((uv.hrtime() - started_at) / 1000000)
end

local function buffer_text(buffer)
  return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, true), "\n")
end

local function run_command(command)
  command_failed = false
  command_error_code = nil
  command_error_message = nil
  vim.cmd(command)
  if command_failed then
    local suffix = command_error_code and (" [" .. command_error_code .. "]") or ""
    suffix = suffix .. (command_error_message and (": " .. command_error_message) or "")
    fail(command .. " reported an error" .. suffix)
  end
end

local function runtime_error()
  local session = coordinator and coordinator:require_current_session() or nil
  local value = session and session.sync_engine and session.sync_engine.last_error or nil
  if type(value) ~= "table" then
    return nil, nil
  end
  local message = type(value.message) == "string" and value.message:sub(1, 160) or nil
  return value.code, message
end

local function await(label, timeout_ms, predicate)
  local completed = vim.wait(timeout_ms, function()
    return command_failed or predicate()
  end, 20)
  if command_failed then
    local runtime_code, runtime_message = runtime_error()
    command_error_code = runtime_code or command_error_code
    command_error_message = runtime_message or command_error_message
    local suffix = command_error_code and (" [" .. command_error_code .. "]") or ""
    suffix = suffix .. (command_error_message and (": " .. command_error_message) or "")
    fail(label .. " reported an error" .. suffix)
  end
  if not completed then
    fail(("%s timed out after %d ms"):format(label, timeout_ms))
  end
end

local function select_buffer(buffer)
  local windows = vim.fn.win_findbuf(buffer)
  if #windows == 0 then
    fail("Expected Bilingua buffer has no window")
  end
  vim.api.nvim_set_current_win(windows[1])
end

local function status()
  return api and api.status() or nil
end

local function await_pending(side)
  await("Bilingua " .. side .. " change capture", 5000, function()
    local session = coordinator and coordinator:require_current_session() or nil
    return session and #(session.pending_changes[side] or {}) > 0
  end)
end

local function require_active_task_delta(side)
  local session = coordinator and coordinator:require_current_session() or nil
  local queue = session and session.sync_engine and session.sync_engine.task_queue
  local task
  for _, record in pairs(queue and queue.active_by_key or {}) do
    task = record.item and record.item.task or nil
    if task then
      break
    end
  end
  local before = task and task.edited_before and task.edited_before.units[1]
  local after = task and task.edited_after and task.edited_after.units[1]
  if
    not task
    or task.edited_side ~= side
    or not before
    or not after
    or before.content_text == after.content_text
  then
    fail("Active semantic task did not contain the expected edited-side delta")
  end
end

local function await_clean(label)
  await(label, 180000, function()
    local current = status()
    local groups = current and current.groups or {}
    return current
      and (current.active_tasks or 0) == 0
      and ((groups.clean or 0) > 0 or (groups.conflict or 0) > 0 or (groups.invalid or 0) > 0)
  end)
  local current = status()
  local groups = current and current.groups or {}
  if
    not current
    or current.state ~= "ready"
    or current.health ~= "healthy"
    or (groups.clean or 0) == 0
    or (groups.conflict or 0) > 0
    or (groups.invalid or 0) > 0
  then
    fail(label .. " did not finish cleanly")
  end
end

local function has_protected_literals(text)
  return type(text) == "string"
    and text:find("https://example.invalid", 1, true) ~= nil
    and text:find("`build --dry-run`", 1, true) ~= nil
end

local function probe_server()
  local response = vim
    .system({
      "curl",
      "--silent",
      "--show-error",
      "--max-time",
      "5",
      endpoint .. "/health",
    }, { text = true })
    :wait(7000)
  if response.code ~= 0 then
    return false
  end
  local decoded = json.decode(response.stdout or "")
  return type(decoded) == "table" and decoded.status == "ok"
end

local function run()
  if vim.env.BILINGUA_RUN_LIVE_LLAMA ~= "1" then
    fail("Set BILINGUA_RUN_LIVE_LLAMA=1 to acknowledge a real local-model request")
  end
  if type(vim.system) ~= "function" then
    fail("Live llama session test requires Neovim with vim.system()")
  end

  endpoint = vim.env.BILINGUA_LLAMA_SERVER_URL
  if type(endpoint) ~= "string" or endpoint == "" then
    endpoint = "http://127.0.0.1:8080"
  end
  local configured_model = vim.env.BILINGUA_LLAMA_SERVER_MODEL
  if type(configured_model) ~= "string" or configured_model == "" then
    configured_model = "auto"
  end

  vim.notify = function(message, level, options)
    if level == vim.log.levels.ERROR then
      command_failed = true
      command_error_code = tostring(message):match("%[(E_[A-Z_]+)%]")
      command_error_message = tostring(message):match("^Bilingua: (.-) %[E_[A-Z_]+%]$")
      if command_error_message then
        command_error_message = command_error_message:sub(1, 160)
      end
    elseif options and options.title == "Bilingua" and level == vim.log.levels.INFO then
      status_message = tostring(message)
    end
  end

  dofile("plugin/bilingua.lua")
  api = require("bilingua")
  local configured = api.setup({
    mappings = { enabled = false },
    sync = {
      automatic = false,
      retry = {
        max_attempts = 2,
        initial_delay_ms = 0,
        max_delay_ms = 0,
      },
    },
    stop = { sync_pending = false, timeout_ms = 15000 },
    translation = {
      backend = "llama_server",
      timeout_ms = 120000,
      backends = {
        llama_server = {
          endpoint = endpoint,
          model = configured_model,
          curl_command = { "curl" },
          open_timeout_ms = 60000,
          health_poll_interval_ms = 250,
          request_timeout_ms = 0,
          structured_output = "json_schema",
          disable_thinking = true,
          max_response_bytes = 16 * 1024 * 1024,
        },
      },
    },
  })
  if not configured then
    fail("Live llama session configuration failed")
  end
  local _, ensure_runtime = debug.getupvalue(api.status, 1)
  if type(ensure_runtime) ~= "function" then
    fail("Live llama session could not inspect pending change delivery")
  end
  coordinator = ensure_runtime()

  source_path = vim.fn.tempname() .. ".txt"
  local source_text = "Open https://example.invalid then run `build --dry-run` safely."
  if vim.fn.writefile({ source_text }, source_path) ~= 0 then
    fail("Could not create the synthetic live-test file")
  end
  vim.cmd("silent edit " .. vim.fn.fnameescape(source_path))
  source_buf = vim.api.nvim_get_current_buf()
  vim.bo[source_buf].filetype = "text"

  local initial_started_at = uv.hrtime()
  run_command("BilinguaStart en")
  await("BilinguaStart", 180000, function()
    local current = status()
    return current and current.state == "ready"
  end)
  local initial_ms = elapsed_ms(initial_started_at)
  local current = status()
  target_buf = current.target_buf
  if
    current.backend ~= "llama_server"
    or type(current.model) ~= "string"
    or current.model == ""
    or not vim.api.nvim_buf_is_valid(target_buf)
  then
    fail("BilinguaStart returned incomplete backend status")
  end
  if configured_model ~= "auto" and current.model ~= configured_model then
    fail("BilinguaStatus resolved an unexpected model")
  end
  if not has_protected_literals(buffer_text(target_buf)) then
    fail("Initial translation did not preserve protected literals")
  end

  status_message = nil
  run_command("BilinguaStatus")
  if
    type(status_message) ~= "string"
    or status_message:find("Backend: llama_server", 1, true) == nil
    or status_message:find("Model: " .. current.model, 1, true) == nil
  then
    fail("BilinguaStatus did not report the resolved backend and model")
  end

  local source_sync_started_at = uv.hrtime()
  select_buffer(source_buf)
  vim.api.nvim_buf_set_text(source_buf, 0, 0, 0, #source_text, {
    "Open https://example.invalid then run `build --dry-run` safely. Record this synthetic update.",
  })
  await_pending("source")
  local target_before_source_sync = buffer_text(target_buf)
  run_command("BilinguaSync")
  await("Source-to-target request start", 5000, function()
    local active = status()
    return active and (active.active_tasks or 0) > 0
  end)
  require_active_task_delta("source")
  await_clean("Source-to-target synchronization")
  local target_after_source_sync = buffer_text(target_buf)
  if target_after_source_sync == target_before_source_sync then
    fail("Source-to-target synchronization did not change the destination")
  elseif not has_protected_literals(target_after_source_sync) then
    fail("Source-to-target synchronization did not preserve protected literals")
  end
  local source_sync_ms = elapsed_ms(source_sync_started_at)

  local target_sync_started_at = uv.hrtime()
  select_buffer(target_buf)
  vim.api.nvim_buf_set_text(target_buf, 0, 0, 0, 0, { "確認: " })
  await_pending("target")
  local source_before_target_sync = buffer_text(source_buf)
  run_command("BilinguaSync")
  await("Target-to-source request start", 5000, function()
    local active = status()
    return active and (active.active_tasks or 0) > 0
  end)
  require_active_task_delta("target")
  await_clean("Target-to-source synchronization")
  local source_after_target_sync = buffer_text(source_buf)
  if source_after_target_sync == source_before_target_sync then
    fail("Target-to-source synchronization did not change the destination")
  elseif not has_protected_literals(source_after_target_sync) then
    fail("Target-to-source synchronization did not preserve protected literals")
  end
  local target_sync_ms = elapsed_ms(target_sync_started_at)

  select_buffer(source_buf)
  vim.api.nvim_buf_set_text(source_buf, 0, 0, 0, 0, { "Cancellation check. " })
  await_pending("source")
  run_command("BilinguaSync")
  await("Active llama request", 5000, function()
    local active = status()
    return active and (active.active_tasks or 0) > 0
  end)
  local cancel_started_at = uv.hrtime()
  run_command("BilinguaStop!")
  await("BilinguaStop!", 15000, function()
    return status() == nil
  end)
  local cancel_ms = elapsed_ms(cancel_started_at)
  if not vim.api.nvim_buf_is_valid(source_buf) or vim.api.nvim_buf_is_valid(target_buf) then
    fail("BilinguaStop! did not retain only the source buffer")
  end
  if not probe_server() then
    fail("llama-server was not healthy after BilinguaStop!")
  end

  return {
    initial_ms = initial_ms,
    source_sync_ms = source_sync_ms,
    target_sync_ms = target_sync_ms,
    cancel_ms = cancel_ms,
  }
end

local function cleanup()
  local cleanup_ok = true
  if api and status() then
    local stopped = false
    local stop_ok
    pcall(api.stop, { force = true }, function(ok)
      stop_ok = ok
      stopped = true
    end)
    cleanup_ok = vim.wait(15000, function()
      return stopped
    end, 20) and stop_ok == true
  end
  if target_buf and vim.api.nvim_buf_is_valid(target_buf) then
    cleanup_ok = false
    pcall(vim.api.nvim_buf_delete, target_buf, { force = true })
  end
  if source_buf and vim.api.nvim_buf_is_valid(source_buf) then
    pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
  end
  if source_path and vim.fn.filereadable(source_path) == 1 then
    cleanup_ok = vim.fn.delete(source_path) == 0 and cleanup_ok
  end
  vim.notify = previous_notify
  return cleanup_ok
end

local succeeded, result = xpcall(run, function(value)
  return debug.traceback(tostring(value), 2)
end)
local cleanup_ok = cleanup()

if not succeeded then
  io.stderr:write("LIVE_LLAMA_SESSION_TEST failed\n" .. result .. "\n")
elseif not cleanup_ok then
  succeeded = false
  io.stderr:write("LIVE_LLAMA_SESSION_TEST failed: session cleanup validation failed\n")
else
  io.stdout:write(
    ("LIVE_LLAMA_SESSION_TEST passed initial_ms=%d source_sync_ms=%d target_sync_ms=%d cancel_ms=%d model_id=omitted response_content=omitted protected_literals=ok status=ok cleanup=ok server_alive=yes\n"):format(
      result.initial_ms,
      result.source_sync_ms,
      result.target_sync_ms,
      result.cancel_ms
    )
  )
end

if not succeeded then
  vim.cmd("cquit 1")
end
