local config_module = require("bilingua.config")
local curl = require("bilingua.adapters.translation.transports.curl")
local json = require("bilingua.util.json")
local registry_module = require("bilingua.registry")
local runtime_module = require("bilingua.ui.nvim_runtime")
local standard_registry = require("bilingua.standard_registry")

local uv = vim.uv or vim.loop
local service
local backend
local runtime

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
  if not vim.wait(timeout_ms, predicate, 20) then
    fail(("%s timed out after %d ms"):format(label, timeout_ms))
  end
end

local function initial_task()
  return {
    schema_version = 1,
    task_id = "live:llama:initial:v1",
    session_id = "live:llama:v1",
    kind = "initial_translate",
    direction = "source_to_target",
    source_language = "en",
    target_language = "ja",
    edited_after = {
      side = "source",
      language = "en",
      units = {
        {
          unit_id = "src:live:000001",
          kind = "paragraph",
          language = "en",
          content_text = "Run ⟦BIL:0001⟧ safely.",
          structural_path = { "document", "paragraph:1" },
          protected_tokens = {
            {
              placeholder = "⟦BIL:0001⟧",
              literal = "`run`",
              kind = "inline_code",
            },
          },
        },
      },
    },
    context_before = {},
    context_after = {},
    constraints = { preserve_placeholders = true },
    revision = 1,
    metadata = {},
  }
end

local function fragment(side, id, language, text)
  return {
    side = side,
    language = language,
    text_hash = vim.fn.sha256(side .. "\0" .. id .. "\0" .. text),
    units = {
      {
        unit_id = id,
        kind = "paragraph",
        language = language,
        content_text = text,
        structural_path = { "document", "paragraph:1" },
        protected_tokens = {
          {
            placeholder = "⟦BIL:0001⟧",
            literal = "`run`",
            kind = "inline_code",
          },
        },
      },
    },
  }
end

local function semantic_task(initial_translation)
  local source_before = fragment("source", "src:live:000001", "en", "Run ⟦BIL:0001⟧ safely.")
  local source_after =
    fragment("source", "src:live:000001", "en", "Run ⟦BIL:0001⟧ very safely.")
  local target_before = fragment("target", "tgt:live:000001", "ja", initial_translation)
  return {
    schema_version = 1,
    task_id = "live:llama:patch:v1",
    session_id = "live:llama:v1",
    kind = "propagate_edit",
    direction = "source_to_target",
    source_language = "en",
    target_language = "ja",
    mapping_group_id = "group:live:000001",
    baseline = {
      source = source_before,
      target = target_before,
      revision = 1,
    },
    edited_side = "source",
    edited_before = source_before,
    edited_after = source_after,
    destination_before = target_before,
    context_before = {},
    context_after = {},
    constraints = {
      preserve_unedited_meaning = true,
      preserve_style = true,
      preserve_placeholders = true,
    },
    revision = 2,
    metadata = {},
  }
end

local function submit(task, label)
  local done = false
  local result
  local request_error
  local started_at = uv.hrtime()
  local handle = service:submit(task, {
    on_complete = function(value)
      result = value
      done = true
    end,
    on_error = function(value)
      request_error = value
      done = true
    end,
  })
  if not vim.wait(150000, function()
    return done
  end, 20) then
    handle:cancel()
    fail(label .. " timed out after 150000 ms")
  end
  if request_error then
    fail(error_summary(label .. " failed", request_error))
  end
  if type(result) ~= "table" then
    fail(label .. " returned an invalid result")
  end
  return result, elapsed_ms(started_at)
end

local function one_placeholder(text)
  if type(text) ~= "string" then
    return false
  end
  local first = text:find("⟦BIL:0001⟧", 1, true)
  return first ~= nil and text:find("⟦BIL:0001⟧", first + 1, true) == nil
end

local function validate_initial(result)
  local replacements = type(result.replacement_units) == "table" and result.replacement_units or {}
  local replacement = replacements[1]
  if
    result.task_id ~= "live:llama:initial:v1"
    or result.destination_side ~= "target"
    or #replacements ~= 1
    or type(replacement) ~= "table"
    or replacement.corresponds_to_edited_unit_ids[1] ~= "src:live:000001"
    or replacement.language ~= "ja"
    or not one_placeholder(replacement.content_text)
  then
    fail("Initial translation failed codec result validation")
  end
  return replacement.content_text
end

local function validate_patch(result)
  local replacements = type(result.replacement_units) == "table" and result.replacement_units or {}
  local replacement = replacements[1]
  if
    result.task_id ~= "live:llama:patch:v1"
    or result.destination_side ~= "target"
    or #replacements ~= 1
    or type(replacement) ~= "table"
    or replacement.corresponds_to_edited_unit_ids[1] ~= "src:live:000001"
    or replacement.language ~= "ja"
    or not one_placeholder(replacement.content_text)
  then
    fail("Semantic patch failed codec result validation")
  end
end

local function run()
  if vim.env.BILINGUA_RUN_LIVE_LLAMA ~= "1" then
    fail("Set BILINGUA_RUN_LIVE_LLAMA=1 to acknowledge a real local-model request")
  end
  if type(vim.system) ~= "function" then
    fail("Live llama test requires Neovim with vim.system()")
  end

  local endpoint = vim.env.BILINGUA_LLAMA_SERVER_URL
  if type(endpoint) ~= "string" or endpoint == "" then
    endpoint = "http://127.0.0.1:8080"
  end
  local model = vim.env.BILINGUA_LLAMA_SERVER_MODEL
  if type(model) ~= "string" or model == "" then
    model = "auto"
  end
  local config, config_error = config_module.resolve({
    sync = {
      retry = {
        max_attempts = 2,
        initial_delay_ms = 0,
        max_delay_ms = 0,
      },
    },
    translation = {
      backend = "llama_server",
      timeout_ms = 120000,
      backends = {
        llama_server = {
          endpoint = endpoint,
          model = model,
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
  if not config then
    fail(error_summary("Live llama configuration failed", config_error))
  end

  runtime = runtime_module.new()
  local registry = registry_module.new()
  assert(standard_registry.register(registry))
  service = registry:get_translation_service("default")(config, {
    registry = registry,
    scheduler = runtime.scheduler,
    backend_runtime = runtime.backend_runtime,
  })
  backend = service.backend

  local open_done = false
  local open_ok
  local open_error
  local open_started_at = uv.hrtime()
  service:open(function(ok, value)
    open_ok = ok
    open_error = value
    open_done = true
  end)
  await("Live llama service open", 70000, function()
    return open_done
  end)
  if not open_ok then
    fail(error_summary("Live llama service open failed", open_error))
  end
  local selected_model = backend:selected_model()
  if type(selected_model) ~= "string" or selected_model == "" then
    fail("Live llama backend did not select a model")
  end
  local open_duration_ms = elapsed_ms(open_started_at)

  local initial_result, initial_duration_ms = submit(initial_task(), "Initial translation")
  local initial_translation = validate_initial(initial_result)
  local patch_result, patch_duration_ms =
    submit(semantic_task(initial_translation), "Semantic patch")
  validate_patch(patch_result)

  return {
    open_duration_ms = open_duration_ms,
    initial_duration_ms = initial_duration_ms,
    patch_duration_ms = patch_duration_ms,
  }
end

local function close_service()
  if not service then
    return true
  end
  local close_done = false
  local close_ok
  service:close(function(ok)
    close_ok = ok
    close_done = true
  end)
  local completed = vim.wait(15000, function()
    return close_done
  end, 20)
  local released = backend
    and backend.state == "closed"
    and backend.open_request == nil
    and backend.open_timeout_timer == nil
    and backend.health_poll_timer == nil
    and next(backend.pending or {}) == nil
  return completed and close_ok == true and service.state == "closed" and released
end

local function probe_server()
  if not backend or not runtime then
    return false, "server endpoint was not initialized"
  end
  local transport = curl.new({
    command = { "curl" },
    process_factory = runtime.backend_runtime.process_factory,
    schedule = runtime.backend_runtime.schedule,
    max_response_bytes = 4096,
    max_stderr_bytes = 0,
  })
  local done = false
  local response
  local request_error
  local handle = transport:request({
    method = "GET",
    url = backend.endpoint .. "/health",
    headers = {},
    timeout_ms = 5000,
  }, function(value, value_error)
    response = value
    request_error = value_error
    done = true
  end)
  if not vim.wait(7000, function()
    return done
  end, 20) then
    handle:cancel()
    return false, "post-close health probe timed out"
  end
  if request_error then
    local kind = type(request_error) == "table" and request_error.kind or "unknown"
    return false, "post-close health probe transport failure: " .. tostring(kind)
  end
  if type(response) ~= "table" or response.status ~= 200 then
    local status = type(response) == "table" and response.status or "missing"
    return false, "post-close health probe status: " .. tostring(status)
  end
  local decoded = json.decode(response.body)
  if type(decoded) ~= "table" or decoded.status ~= "ok" then
    return false, "post-close health probe returned an invalid readiness object"
  end
  return true
end

local succeeded, result = xpcall(run, function(value)
  return debug.traceback(tostring(value), 2)
end)
local closed = close_service()
local server_alive, probe_error = probe_server()

if not succeeded then
  io.stderr:write("LIVE_LLAMA_TEST failed\n" .. result .. "\n")
elseif not closed then
  succeeded = false
  io.stderr:write("LIVE_LLAMA_TEST failed: backend cleanup validation failed\n")
elseif not server_alive then
  succeeded = false
  io.stderr:write("LIVE_LLAMA_TEST failed: " .. probe_error .. "\n")
else
  io.stdout:write(
    ("LIVE_LLAMA_TEST passed open_ms=%d initial_ms=%d patch_ms=%d model_id=omitted response_content=omitted cleanup=ok server_alive=yes\n"):format(
      result.open_duration_ms,
      result.initial_duration_ms,
      result.patch_duration_ms
    )
  )
end

if not succeeded then
  vim.cmd("cquit 1")
end
