local test = require("tests.testlib")
local errors = require("bilingua.domain.error")
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

local function fake_codec(id, result)
  return {
    api_version = 1,
    id = id,
    encoded_capabilities = nil,
    encode = function(self, task, capabilities)
      self.encoded_capabilities = capabilities
      return {
        request_id = task.task_id,
        user_content = "SECRET DOCUMENT PAYLOAD",
        metadata = { codec_id = id },
      }
    end,
    decode = function(_, raw_response, task)
      if raw_response == "invalid" then
        return nil, "decoder detail containing SECRET DOCUMENT PAYLOAD"
      end
      local value = vim.deepcopy(result)
      value.task_id = task.task_id
      return value
    end,
    response_schema = function()
      return { type = "object" }
    end,
  }
end

local function fake_backend(options)
  local resolved = options or {}
  local backend = {
    api_version = 1,
    id = "fake_backend",
    requests = {},
    cancelled = 0,
    state = "closed",
  }
  function backend:capabilities()
    return {
      structured_output = resolved.structured_output == true,
      system_instructions = true,
      cancellation = true,
    }
  end
  function backend:open(callback)
    self.state = "open"
    callback(true)
  end
  function backend:request(request, callbacks)
    if resolved.synchronous_error then
      callbacks.on_error(
        errors.new(errors.codes.BACKEND_UNAVAILABLE, "temporarily unavailable", true)
      )
      return nil
    end
    self.requests[#self.requests + 1] = { request = request, callbacks = callbacks }
    local cancelled = false
    return {
      cancel = function()
        if not cancelled then
          cancelled = true
          self.cancelled = self.cancelled + 1
        end
      end,
      is_cancelled = function()
        return cancelled
      end,
    }
  end
  function backend:close(callback)
    self.state = "closed"
    callback(true)
  end
  return backend
end

local function result()
  return {
    schema_version = 1,
    destination_side = "target",
    replacement_units = {},
    warnings = {},
    metadata = {},
  }
end

local function initial_task(task_id)
  return {
    schema_version = 1,
    task_id = task_id or "task:initial:1",
    kind = "initial_translate",
  }
end

local function patch_task()
  return {
    schema_version = 1,
    task_id = "task:patch:1",
    kind = "propagate_edit",
  }
end

-- Preconditions: A synchronous Fake Backend opens and later emits duplicate
-- completion/error signals for one initial task. Prerequisites: The service is
-- given an explicit main-loop scheduler and separate initial/patch codecs.
-- Verification items: open and task callbacks are deferred, backend capabilities
-- reach the selected initial codec, and exactly the first terminal signal wins.
test.it("schedules callbacks and settles each translation exactly once", function()
  local schedule, flush = scheduler()
  local backend = fake_backend({ structured_output = true })
  local initial = fake_codec("initial", result())
  local patch = fake_codec("patch", result())
  local service = translation_service.new({
    backend = backend,
    initial_codec = initial,
    patch_codec = patch,
    schedule = schedule,
  })
  local opened = false
  service:open(function(ok)
    opened = ok
  end)
  test.eq(false, opened)
  flush()
  test.eq(true, opened)

  local completions = 0
  local failures = 0
  service:submit(initial_task(), {
    on_complete = function()
      completions = completions + 1
    end,
    on_error = function()
      failures = failures + 1
    end,
  })
  test.eq(true, initial.encoded_capabilities.structured_output)
  backend.requests[1].callbacks.on_complete("raw")
  backend.requests[1].callbacks.on_complete("raw again")
  backend.requests[1].callbacks.on_error(errors.new(errors.codes.BACKEND_PROTOCOL, "late", false))
  test.eq(0, completions)
  flush()
  test.eq(1, completions)
  test.eq(0, failures)
  test.eq(nil, patch.encoded_capabilities)
end)

-- Preconditions: One active request has a backend cancel handle and its response
-- arrives after two local cancel calls. Prerequisites: Cancellation can race with
-- already queued backend events. Verification items: the local handle becomes
-- cancelled immediately, delegates cancel once, and suppresses both completion
-- and error callbacks after cancellation.
test.it("cancels idempotently and ignores late backend responses", function()
  local schedule, flush = scheduler()
  local backend = fake_backend()
  local service = translation_service.new({
    backend = backend,
    initial_codec = fake_codec("initial", result()),
    patch_codec = fake_codec("patch", result()),
    schedule = schedule,
  })
  service:open(function() end)
  flush()
  local callbacks = 0
  local handle = service:submit(patch_task(), {
    on_complete = function()
      callbacks = callbacks + 1
    end,
    on_error = function()
      callbacks = callbacks + 1
    end,
  })
  handle:cancel()
  handle:cancel()
  backend.requests[1].callbacks.on_complete("raw")
  flush()

  test.eq(true, handle:is_cancelled())
  test.eq(1, backend.cancelled)
  test.eq(0, callbacks)
end)

-- Preconditions: A Fake Backend reports an error synchronously from request(),
-- then the service is closed and receives another submit. Prerequisites: Public
-- callbacks must always return through the scheduler regardless of failure path.
-- Verification items: the first error is deferred and preserved, close is
-- idempotent, and the later submit is deferred with E_SESSION_CLOSED.
test.it("defers synchronous errors and rejects submit after close", function()
  local schedule, flush = scheduler()
  local backend = fake_backend({ synchronous_error = true })
  local service = translation_service.new({
    backend = backend,
    initial_codec = fake_codec("initial", result()),
    patch_codec = fake_codec("patch", result()),
    schedule = schedule,
  })
  service:open(function() end)
  flush()
  local codes = {}
  service:submit(initial_task(), {
    on_complete = function()
      error("unexpected completion")
    end,
    on_error = function(err)
      codes[#codes + 1] = err.code
    end,
  })
  test.eq(0, #codes)
  flush()
  test.eq("E_BACKEND_UNAVAILABLE", codes[1])

  local closes = 0
  service:close(function()
    closes = closes + 1
  end)
  service:close(function()
    closes = closes + 1
  end)
  flush()
  test.eq(2, closes)
  service:submit(initial_task("task:initial:closed"), {
    on_complete = function()
      error("unexpected completion")
    end,
    on_error = function(err)
      codes[#codes + 1] = err.code
    end,
  })
  test.eq(1, #codes)
  flush()
  test.eq("E_SESSION_CLOSED", codes[2])
end)

-- Preconditions: Codec decoding fails with a plain string containing document
-- text, and diagnostic logging is enabled through an injected recorder.
-- Prerequisites: The service must normalize codec defects and log only event
-- metadata, never request/response/error payloads. Verification items: the caller
-- receives E_INVALID_OUTPUT while every serialized log entry excludes the secret.
test.it("normalizes decoder errors without logging payloads", function()
  local schedule, flush = scheduler()
  local backend = fake_backend()
  local events = {}
  local service = translation_service.new({
    backend = backend,
    initial_codec = fake_codec("initial", result()),
    patch_codec = fake_codec("patch", result()),
    schedule = schedule,
    logger = function(event)
      events[#events + 1] = event
    end,
  })
  service:open(function() end)
  flush()
  local received_error
  service:submit(initial_task(), {
    on_complete = function()
      error("unexpected completion")
    end,
    on_error = function(err)
      received_error = err
    end,
  })
  backend.requests[1].callbacks.on_complete("invalid")
  flush()

  test.eq("E_INVALID_OUTPUT", received_error.code)
  for _, event in ipairs(events) do
    test.eq(nil, vim.inspect(event):find("SECRET DOCUMENT PAYLOAD", 1, true))
  end
end)

-- Preconditions: Backend open is pending when the owner closes the TranslationService,
-- and the backend later reports its obsolete open success. Prerequisites: close
-- invalidates the opening generation and both public callbacks remain scheduled
-- exactly once. Verification items: open reports E_SESSION_CLOSED, close succeeds,
-- late success is ignored, and service state remains closed.
test.it("does not reopen after close races with backend open", function()
  local schedule, flush = scheduler()
  local backend = fake_backend()
  local open_callback
  backend.open = function(self, callback)
    self.state = "opening"
    open_callback = callback
  end
  local service = translation_service.new({
    backend = backend,
    initial_codec = fake_codec("initial", result()),
    patch_codec = fake_codec("patch", result()),
    schedule = schedule,
  })
  local opened, open_error, closed
  service:open(function(ok, err)
    opened, open_error = ok, err
  end)
  service:close(function(ok)
    closed = ok
  end)
  open_callback(true)
  flush()

  test.eq(nil, opened)
  test.eq("E_SESSION_CLOSED", open_error.code)
  test.eq(true, closed)
  test.eq("closed", service.state)
end)

-- Preconditions: TranslationService receives otherwise functional Backend and
-- Codec objects whose API version or required response_schema method is invalid.
-- Prerequisites: Registry substitution is safe only when every nested Port is
-- contract-checked before open() can send document data. Verification items: a
-- version-2 Backend, version-2 Codec, and incomplete Codec each fail construction
-- with a contract-specific Lua error.
test.it("rejects incompatible nested backend and codec ports", function()
  local cases = {
    {
      expected = "inference backend contract",
      mutate = function(backend)
        backend.api_version = 2
      end,
    },
    {
      expected = "task codec contract",
      mutate = function(_, initial)
        initial.api_version = 2
      end,
    },
    {
      expected = "task codec contract",
      mutate = function(_, initial)
        initial.response_schema = nil
      end,
    },
  }

  for _, case in ipairs(cases) do
    local backend = fake_backend()
    local initial = fake_codec("initial", result())
    local patch = fake_codec("patch", result())
    case.mutate(backend, initial, patch)
    local constructed, construction_error = pcall(translation_service.new, {
      backend = backend,
      initial_codec = initial,
      patch_codec = patch,
      schedule = function() end,
    })
    test.eq(false, constructed)
    assert(tostring(construction_error):find(case.expected, 1, true), construction_error)
  end
end)
