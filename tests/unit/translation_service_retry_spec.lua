local test = require("tests.testlib")
local errors = require("bilingua.domain.error")
local common = require("bilingua.adapters.translation.codecs.common")
local translation_service = require("bilingua.adapters.translation.service")

local function scheduler()
  local pending = {}
  return function(callback)
    pending[#pending + 1] = callback
  end, function()
    while #pending > 0 do
      local callbacks = pending
      pending = {}
      for _, callback in ipairs(callbacks) do
        callback()
      end
    end
  end
end

local function backend()
  local fake = { api_version = 1, id = "retry_backend", requests = {} }
  function fake:capabilities()
    return { structured_output = true, system_instructions = true, cancellation = true }
  end
  function fake:open(callback)
    callback(true)
  end
  function fake:request(request, callbacks)
    self.requests[#self.requests + 1] = { request = request, callbacks = callbacks }
    local handle = { cancelled = false }
    function handle:cancel()
      self.cancelled = true
    end
    return handle
  end
  function fake:close(callback)
    callback(true)
  end
  return fake
end

local function codec()
  return {
    api_version = 1,
    id = "retry_codec",
    encode = function(_, task)
      return { request_id = task.task_id, system_instructions = "base", user_content = "document" }
    end,
    decode = function(_, raw, task)
      if raw == "malformed" then
        return nil,
          errors.new(
            errors.codes.INVALID_OUTPUT,
            "The response is malformed",
            false,
            { retryable_format = true }
          )
      elseif raw == "placeholder-mismatch" then
        return nil,
          errors.new(
            errors.codes.INVALID_OUTPUT,
            "A protected placeholder is missing",
            false,
            { retryable_format = false }
          )
      end
      return {
        schema_version = 1,
        task_id = task.task_id,
        destination_side = "target",
        replacement_units = {},
        warnings = {},
        metadata = {},
      }
    end,
    response_schema = function()
      return { type = "object" }
    end,
  }
end

local function task(id)
  return { schema_version = 1, task_id = id, kind = "propagate_edit" }
end

local function service_fixture()
  local schedule, flush = scheduler()
  local delays = {}
  local fake_backend = backend()
  local instance = translation_service.new({
    backend = fake_backend,
    initial_codec = codec(),
    patch_codec = codec(),
    schedule = schedule,
    defer = function(milliseconds, callback)
      local token = { milliseconds = milliseconds, callback = callback, cancelled = false }
      function token:cancel()
        self.cancelled = true
      end
      delays[#delays + 1] = token
      return token
    end,
    retry = { max_attempts = 3, initial_delay_ms = 500, max_delay_ms = 3000 },
  })
  instance:open(function() end)
  flush()
  return instance, fake_backend, delays, flush
end

-- Preconditions: The first backend attempt fails with an explicitly retryable
-- transient availability error. Prerequisites: retry delay follows configured
-- exponential backoff and terminal callbacks remain exactly-once across attempts.
-- Verification items: no early error is delivered, attempt two starts after 500ms,
-- its valid response completes once, and the original task ID is retained.
test.it("retries a transient backend failure with bounded backoff", function()
  local service, fake_backend, delays, flush = service_fixture()
  local completions, failures = 0, 0
  service:submit(task("task:retry:backend"), {
    on_complete = function()
      completions = completions + 1
    end,
    on_error = function()
      failures = failures + 1
    end,
    is_current = function()
      return true
    end,
  })

  fake_backend.requests[1].callbacks.on_error(
    errors.new(errors.codes.BACKEND_UNAVAILABLE, "temporary", true)
  )
  flush()
  test.eq(0, completions)
  test.eq(0, failures)
  test.eq(1, #delays)
  test.eq(500, delays[1].milliseconds)

  delays[1].callback()
  test.eq(2, #fake_backend.requests)
  fake_backend.requests[2].callbacks.on_complete("valid")
  flush()

  test.eq(1, completions)
  test.eq(0, failures)
  test.eq("task:retry:backend", fake_backend.requests[2].request.request_id)
end)

-- Preconditions: A backend returns parseable transport data that the Codec marks
-- as format-repairable invalid output on consecutive attempts. Prerequisites:
-- model-output repair is allowed only once and must not include the prior payload.
-- Verification items: exactly one delayed retry is made, its correction is appended
-- once to system_instructions without changing document content or retaining the
-- prior response, retry metadata names format repair, and failure remains terminal.
test.it("retries format-repairable invalid output only once", function()
  local service, fake_backend, delays, flush = service_fixture()
  local received
  service:submit(task("task:retry:format"), {
    on_complete = function()
      error("unexpected completion")
    end,
    on_error = function(err)
      received = err
    end,
    is_current = function()
      return true
    end,
  })

  fake_backend.requests[1].callbacks.on_complete("malformed")
  test.eq(1, #delays)
  delays[1].callback()
  fake_backend.requests[2].callbacks.on_complete("malformed")
  flush()

  test.eq(2, #fake_backend.requests)
  test.eq("E_INVALID_OUTPUT", received.code)
  local retry_request = fake_backend.requests[2].request
  local correction = table.concat({
    "The previous response failed JSON format validation.",
    "Re-evaluate the original task and return only one object conforming to the response schema.",
    "Include every required field; use an empty array for a required array field when it has no values.",
    "Do not add prose or code fences.",
  }, " ")
  test.eq("base\n" .. correction, retry_request.system_instructions)
  test.eq("document", retry_request.user_content)
  test.eq("format", retry_request.metadata.retry_reason)
  test.eq(nil, vim.inspect(retry_request):find("malformed", 1, true))
end)

-- Preconditions: Codec validation detects a protected-placeholder mismatch.
-- Prerequisites: semantic safety failures are not format repair and must never be
-- retried even when retry budget remains. Verification items: one backend attempt,
-- no delay token, and immediate scheduled E_INVALID_OUTPUT delivery.
test.it("does not retry protected-token validation failures", function()
  local service, fake_backend, delays, flush = service_fixture()
  local received
  service:submit(task("task:retry:protected"), {
    on_complete = function()
      error("unexpected completion")
    end,
    on_error = function(err)
      received = err
    end,
    is_current = function()
      return true
    end,
  })

  fake_backend.requests[1].callbacks.on_complete("placeholder-mismatch")
  flush()

  test.eq(1, #fake_backend.requests)
  test.eq(0, #delays)
  test.eq("E_INVALID_OUTPUT", received.code)
end)

-- Preconditions: Common JSON decoding receives malformed object syntax.
-- Prerequisites: only the Codec can distinguish format repair from semantic
-- validation; TranslationService must not classify by localized message text.
-- Verification items: E_INVALID_OUTPUT carries the explicit retryable_format flag.
test.it("marks malformed JSON as format-repairable metadata", function()
  local value, decode_error = common.decode_json_object("{broken", {})

  test.eq(nil, value)
  test.eq("E_INVALID_OUTPUT", decode_error.code)
  test.eq(true, decode_error.details.retryable_format)
end)
