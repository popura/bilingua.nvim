local test = require("tests.testlib")
local json = require("bilingua.util.json")
local fake_http = require("tests.fakes.http_transport")
local llama_server = require("bilingua.adapters.translation.backends.llama_server")

local function harness(overrides)
  local pending = {}
  local timers = {}
  local transport = fake_http.new()
  local options = {
    endpoint = "http://127.0.0.1:8080",
    model = "auto",
    curl_command = { "curl" },
    open_timeout_ms = 30000,
    health_poll_interval_ms = 250,
    request_timeout_ms = 0,
    timeout_ms = 120000,
    structured_output = "json_schema",
    disable_thinking = true,
    max_response_bytes = 16 * 1024 * 1024,
    transport = transport,
    schedule = function(callback)
      pending[#pending + 1] = callback
    end,
    timer_factory = function(milliseconds, callback)
      local timer = {
        milliseconds = milliseconds,
        callback = callback,
        active = true,
      }
      function timer:cancel()
        self.active = false
      end
      function timer:fire()
        if self.active then
          self.active = false
          self.callback()
        end
      end
      timers[#timers + 1] = timer
      return timer
    end,
  }
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  local backend = llama_server.new(options)

  local function flush()
    while #pending > 0 do
      local callbacks = pending
      pending = {}
      for _, callback in ipairs(callbacks) do
        callback()
      end
    end
  end

  local function active_timers()
    local count = 0
    for _, timer in ipairs(timers) do
      if timer.active then
        count = count + 1
      end
    end
    return count
  end

  return {
    backend = backend,
    transport = transport,
    timers = timers,
    flush = flush,
    active_timers = active_timers,
  }
end

-- Preconditions: Construction receives each accepted loopback spelling, including
-- uppercase localhost, IPv6 loopback, omitted ports, and one trailing slash.
-- Prerequisites: endpoint parsing is local-only, ASCII case-insensitive for scheme
-- and host, and normalizes rather than broadening the authority or path.
-- Verification items: every instance is new and error-free, canonical endpoint is
-- exact, no request/timer is created, and identity/capability fields are complete.
test.it("normalizes loopback endpoints and exposes backend capabilities", function()
  local cases = {
    { "http://127.0.0.1:8080/", "http://127.0.0.1:8080" },
    { "http://127.0.0.1", "http://127.0.0.1" },
    { "http://localhost:8080", "http://localhost:8080" },
    { "HTTP://LOCALHOST/", "http://localhost" },
    { "http://[::1]:8080/", "http://[::1]:8080" },
    { "http://[::1]", "http://[::1]" },
  }

  for _, case in ipairs(cases) do
    local context = harness({ endpoint = case[1] })
    test.eq(1, context.backend.api_version)
    test.eq("llama_server", context.backend.id)
    test.eq("new", context.backend.state)
    test.eq(case[2], context.backend.endpoint)
    test.eq(nil, context.backend.configuration_error)
    test.eq(nil, context.backend:selected_model())
    test.eq(0, context.transport:queued_count())
    test.eq(0, context.active_timers())
  end

  local structured = harness({ structured_output = "json_schema" }).backend:capabilities()
  test.eq(true, structured.structured_output)
  test.eq(true, structured.schema_in_prompt)
  test.eq(false, structured.streaming)
  test.eq(true, structured.cancellation)
  test.eq(true, structured.system_instructions)
  test.eq(true, structured.parallel_requests)
  test.eq(false, structured.ephemeral_sessions)
  test.eq(nil, structured.max_input_chars)

  local prompt_only = harness({ structured_output = "prompt_only" }).backend:capabilities()
  test.eq(false, prompt_only.structured_output)
  test.eq(true, prompt_only.schema_in_prompt)
end)

-- Preconditions: Each construction has all runtime ports but one malformed user
-- option spanning endpoint authority, model/command, timeout, mode, boolean, or size.
-- Prerequisites: user configuration failures are stored as E_BACKEND_INIT and open
-- reports them asynchronously before acquiring timers or HTTP requests.
-- Verification items: construction never throws, open callback occurs once after
-- flush, state becomes failed, and fake transport/timer counts remain zero.
test.it("rejects malformed options before acquiring runtime resources", function()
  local cases = {
    { endpoint = 1 },
    { endpoint = "https://localhost:8080" },
    { endpoint = "http://example.com:8080" },
    { endpoint = "http://localhost:8080/path" },
    { endpoint = "http://localhost:8080?query=1" },
    { endpoint = "http://localhost:8080#fragment" },
    { endpoint = "http://user@localhost:8080" },
    { endpoint = "http://localhost:0" },
    { endpoint = "http://localhost:65536" },
    { model = "" },
    { curl_command = {} },
    { curl_command = { [2] = "curl" } },
    { curl_command = { "curl", "" } },
    { open_timeout_ms = 0 },
    { open_timeout_ms = 1.5 },
    { health_poll_interval_ms = 0 },
    { health_poll_interval_ms = 301, open_timeout_ms = 300 },
    { request_timeout_ms = -1 },
    { request_timeout_ms = 0.5 },
    { structured_output = "grammar" },
    { disable_thinking = "yes" },
    { max_response_bytes = 0 },
    { max_response_bytes = 1.5 },
  }

  for _, invalid_options in ipairs(cases) do
    local constructed, context = pcall(harness, invalid_options)
    test.eq(true, constructed)
    local callbacks = 0
    local opened
    local open_error
    context.backend:open(function(ok, err)
      callbacks = callbacks + 1
      opened = ok
      open_error = err
    end)
    test.eq(0, callbacks)
    context.flush()

    test.eq(1, callbacks)
    test.eq(nil, opened)
    test.eq("E_BACKEND_INIT", open_error.code)
    test.eq("failed", context.backend.state)
    test.eq(0, context.transport:queued_count())
    test.eq(0, context.active_timers())
  end
end)

-- Preconditions: Constructors omit each runtime dependency in turn, provide an
-- invalid injected transport, or omit process_factory when production transport is
-- requested. Prerequisites: runtime wiring errors are programmer errors rather than
-- user-facing backend initialization results.
-- Verification items: each constructor throws immediately with a dependency name;
-- no backend instance with unusable runtime ports is returned.
test.it("fails fast for missing or malformed runtime dependencies", function()
  local base = {
    schedule = function() end,
    timer_factory = function()
      return { cancel = function() end }
    end,
    transport = fake_http.new(),
  }
  local cases = {
    {
      options = { timer_factory = base.timer_factory, transport = base.transport },
      name = "schedule",
    },
    { options = { schedule = base.schedule, transport = base.transport }, name = "timer_factory" },
    {
      options = { schedule = base.schedule, timer_factory = base.timer_factory, transport = {} },
      name = "transport",
    },
    {
      options = { schedule = base.schedule, timer_factory = base.timer_factory },
      name = "process_factory",
    },
  }

  for _, case in ipairs(cases) do
    local constructed, failure = pcall(llama_server.new, case.options)
    test.eq(false, constructed)
    test.eq(true, tostring(failure):find(case.name, 1, true) ~= nil)
  end
end)

local function begin_open(context)
  local outcome = { callbacks = 0 }
  context.backend:open(function(opened, open_error)
    outcome.callbacks = outcome.callbacks + 1
    outcome.opened = opened
    outcome.open_error = open_error
  end)
  return outcome
end

local function health_ok(context)
  local request = assert(context.transport:take("GET", context.backend.endpoint .. "/health"))
  context.transport:respond(request, {
    status = 200,
    body = json.encode({ status = "ok" }),
    stderr = "",
  })
  context.flush()
  return request
end

local function respond_models(context, data)
  local request = assert(context.transport:take("GET", context.backend.endpoint .. "/v1/models"))
  context.transport:respond(request, {
    status = 200,
    body = json.encode({ data = data }),
    stderr = "",
  })
  context.flush()
  return request
end

-- Preconditions: A new auto-model backend receives healthy JSON and one usable
-- model, then open is called again after reaching ready.
-- Prerequisites: open starts only an overall timer, calls public `/health` without
-- authorization, discovers `/v1/models`, resolves the sole ID, and cancels all open
-- resources before scheduling completion.
-- Verification items: exact GET URLs/options, callback timing and once-only count,
-- ready state/model selection, zero active resources, and asynchronous ready reopen.
test.it("opens through health and one-model discovery then reopens ready", function()
  local context = harness()
  local outcome = begin_open(context)

  test.eq("opening", context.backend.state)
  test.eq(0, outcome.callbacks)
  test.eq(1, context.active_timers())
  local health = assert(context.transport:take("GET", "http://127.0.0.1:8080/health"))
  test.eq({}, health.request.headers)
  test.eq(30000, health.request.timeout_ms)
  context.transport:respond(health, {
    status = 200,
    body = '{"status":"ok"}',
    stderr = "",
  })
  test.eq(0, outcome.callbacks)
  test.eq(nil, context.transport:take("GET", "http://127.0.0.1:8080/v1/models"))
  context.flush()

  local models = assert(context.transport:take("GET", "http://127.0.0.1:8080/v1/models"))
  test.eq({}, models.request.headers)
  test.eq(30000, models.request.timeout_ms)
  context.transport:respond(models, {
    status = 200,
    body = json.encode({ data = json.array({ { id = "local-model" } }) }),
    stderr = "",
  })
  test.eq(0, outcome.callbacks)
  context.flush()

  test.eq(1, outcome.callbacks)
  test.eq(true, outcome.opened)
  test.eq(nil, outcome.open_error)
  test.eq("ready", context.backend.state)
  test.eq("local-model", context.backend:selected_model())
  test.eq(0, context.active_timers())
  test.eq(0, context.transport:active_count())

  local reopened = 0
  context.backend:open(function(opened, open_error)
    test.eq(true, opened)
    test.eq(nil, open_error)
    reopened = reopened + 1
  end)
  test.eq(0, reopened)
  context.flush()
  test.eq(1, reopened)
  test.eq(2, outcome.callbacks + reopened)
end)

-- Preconditions: Health returns 503 twice with each poll timer fired, then an active
-- third health request survives until the overall timer fires; its late response is
-- delivered twice by the adversarial fake after cancellation.
-- Prerequisites: 503 means loading rather than terminal failure, poll delay is 250
-- ms, and overall timeout owns both poll/request cancellation and open settlement.
-- Verification items: no early callback, one request per fired poll, timeout maps to
-- retryable E_BACKEND_TIMEOUT exactly once, and every timer/request is inactive.
test.it("polls repeated health 503 responses until the overall timeout", function()
  local context = harness()
  local outcome = begin_open(context)
  local first = assert(context.transport:take("GET"))
  context.transport:respond(first, { status = 503, body = "loading", stderr = "" })
  context.flush()
  test.eq(0, outcome.callbacks)
  test.eq(2, context.active_timers())
  test.eq(250, context.timers[2].milliseconds)

  context.timers[2]:fire()
  test.eq(nil, context.transport:take("GET"))
  context.flush()
  local second = assert(context.transport:take("GET"))
  context.transport:respond(second, { status = 503, body = "still loading", stderr = "" })
  context.flush()
  test.eq(2, context.active_timers())
  test.eq(250, context.timers[3].milliseconds)

  context.timers[3]:fire()
  context.flush()
  local late = assert(context.transport:take("GET"))
  test.eq(1, context.transport:active_count())
  context.timers[1]:fire()
  context.flush()

  test.eq(1, outcome.callbacks)
  test.eq(nil, outcome.opened)
  test.eq("E_BACKEND_TIMEOUT", outcome.open_error.code)
  test.eq(true, outcome.open_error.retryable)
  test.eq("failed", context.backend.state)
  test.eq(true, late.cancelled)
  test.eq(0, context.transport:active_count())
  test.eq(0, context.active_timers())

  local late_response = { status = 200, body = '{"status":"ok"}', stderr = "" }
  context.transport:respond(late, late_response)
  context.transport:respond(late, late_response)
  context.flush()
  test.eq(1, outcome.callbacks)
end)

-- Preconditions: Separate opens receive malformed JSON, a JSON array, and a health
-- object whose status is not `ok`, each with HTTP 200.
-- Prerequisites: readiness requires a decoded top-level object with exactly the
-- semantic status expected by llama-server; HTTP success alone is insufficient.
-- Verification items: every case fails once with non-retryable E_BACKEND_PROTOCOL,
-- never requests models, and releases the overall timer and active request.
test.it("rejects malformed or unhealthy HTTP-200 health bodies", function()
  local bodies = {
    "not json",
    "[]",
    '{"status":"loading"}',
  }
  for _, body in ipairs(bodies) do
    local context = harness()
    local outcome = begin_open(context)
    local health = assert(context.transport:take("GET"))
    context.transport:respond(health, { status = 200, body = body, stderr = "" })
    context.flush()

    test.eq(1, outcome.callbacks)
    test.eq(nil, outcome.opened)
    test.eq("E_BACKEND_PROTOCOL", outcome.open_error.code)
    test.eq(false, outcome.open_error.retryable)
    test.eq("failed", context.backend.state)
    test.eq(nil, context.transport:take("GET"))
    test.eq(0, context.active_timers())
    test.eq(0, context.transport:active_count())
  end
end)

-- Preconditions: Model discovery receives malformed envelopes, auto mode sees zero
-- or multiple valid IDs, explicit mode sees a valid list that omits its configured
-- model, and auto mode sees invalid candidate records alongside one valid record.
-- Prerequisites: `data` must be a JSON array; only non-empty string IDs are adopted;
-- auto requires exactly one adopted ID, while explicit routing defers membership
-- errors to the later chat request.
-- Verification items: malformed/ambiguous cases return the specified protocol/init
-- codes, explicit and filtered-single cases reach ready with exact selected IDs,
-- and every path settles once without active timers or requests.
test.it("validates model envelopes and resolves auto or explicit models", function()
  local cases = {
    { body = "not json", error_code = "E_BACKEND_PROTOCOL" },
    { body = "[]", error_code = "E_BACKEND_PROTOCOL" },
    { body = '{"data":{}}', error_code = "E_BACKEND_PROTOCOL" },
    {
      body = json.encode({ data = json.array() }),
      error_code = "E_BACKEND_INIT",
    },
    {
      body = json.encode({ data = json.array({ { id = "one" }, { id = "two" } }) }),
      error_code = "E_BACKEND_INIT",
    },
    {
      body = json.encode({ data = json.array({ {}, { id = "" }, { id = "usable" } }) }),
      selected = "usable",
    },
    {
      model = "configured-model",
      body = json.encode({ data = json.array({ { id = "different" } }) }),
      selected = "configured-model",
    },
  }

  for _, case in ipairs(cases) do
    local context = harness({ model = case.model or "auto" })
    local outcome = begin_open(context)
    health_ok(context)
    local models = assert(context.transport:take("GET"))
    context.transport:respond(models, {
      status = 200,
      body = case.body,
      stderr = "",
    })
    context.flush()

    test.eq(1, outcome.callbacks)
    if case.error_code then
      test.eq(nil, outcome.opened)
      test.eq(case.error_code, outcome.open_error.code)
      test.eq("failed", context.backend.state)
    else
      test.eq(true, outcome.opened)
      test.eq(nil, outcome.open_error)
      test.eq(case.selected, context.backend:selected_model())
      test.eq("ready", context.backend.state)
    end
    test.eq(0, context.active_timers())
    test.eq(0, context.transport:active_count())
  end
end)

local function open_ready(context, model_id)
  local outcome = begin_open(context)
  health_ok(context)
  respond_models(context, json.array({ { id = model_id or "local-model" } }))
  test.eq(1, outcome.callbacks)
  test.eq(true, outcome.opened)
  test.eq(nil, outcome.open_error)
  return outcome
end

local function terminal_callbacks(outcome)
  return {
    on_complete = function(result)
      outcome.completions = (outcome.completions or 0) + 1
      outcome.result = result
    end,
    on_error = function(request_error)
      outcome.errors = (outcome.errors or 0) + 1
      outcome.request_error = request_error
    end,
  }
end

local function pending_count(backend)
  local count = 0
  for _ in pairs(backend.pending) do
    count = count + 1
  end
  return count
end

-- Preconditions: A ready JSON-Schema backend receives normalized system/user text,
-- a response Schema, a request-specific timeout, and metadata that must not leak.
-- Prerequisites: chat completion is non-streaming, Schema is passed in llama.cpp's
-- current OpenAI-compatible `response_format.json_schema.schema` shape, thinking
-- is disabled through both current
-- controls, and no tool surface is offered.
-- Verification items: exact POST route/header/timeout and decoded payload fields,
-- ordered messages, selected model, absence of tools/metadata, one pending record,
-- body is encoded JSON, and cancel removes/cancels the task idempotently.
test.it("encodes a schema-constrained chat request without tool access", function()
  local context = harness()
  open_ready(context, "schema-model")
  local outcome = {}
  local schema = {
    type = "object",
    properties = { translated_text = { type = "string" } },
    required = { "translated_text" },
  }
  local handle = context.backend:request({
    request_id = "request:schema",
    system_instructions = "Translate safely.",
    user_content = "SECRET DOCUMENT PAYLOAD",
    response_schema = schema,
    timeout_ms = 3210,
    metadata = { codec_id = "must-not-enter-provider-payload" },
  }, terminal_callbacks(outcome))

  local chat = assert(context.transport:take("POST", "http://127.0.0.1:8080/v1/chat/completions"))
  test.eq({ ["Content-Type"] = "application/json" }, chat.request.headers)
  test.eq(3210, chat.request.timeout_ms)
  local payload = assert(json.decode(chat.request.body))
  test.eq("schema-model", payload.model)
  test.eq(false, payload.stream)
  test.eq(2, #payload.messages)
  test.eq("system", payload.messages[1].role)
  test.eq("Translate safely.", payload.messages[1].content)
  test.eq("user", payload.messages[2].role)
  test.eq("SECRET DOCUMENT PAYLOAD", payload.messages[2].content)
  test.eq("json_schema", payload.response_format.type)
  test.eq("bilingua_response", payload.response_format.json_schema.name)
  test.eq(true, payload.response_format.json_schema.strict)
  test.eq(schema, payload.response_format.json_schema.schema)
  test.eq(nil, payload.response_format.schema)
  test.eq("none", payload.reasoning_effort)
  test.eq(false, payload.chat_template_kwargs.enable_thinking)
  test.eq(nil, payload.tools)
  test.eq(nil, payload.tool_choice)
  test.eq(nil, payload.metadata)
  test.eq(1, pending_count(context.backend))

  handle:cancel()
  handle:cancel()
  test.eq(true, chat.cancelled)
  test.eq(1, context.transport.cancel_count)
  test.eq(0, pending_count(context.backend))
  context.transport:respond(chat, {
    status = 200,
    body = '{"choices":[{"message":{"content":"late"}}]}',
    stderr = "",
  })
  context.flush()
  test.eq(nil, outcome.completions)
  test.eq(nil, outcome.errors)
end)

-- Preconditions: A prompt-only backend with thinking controls disabled receives an
-- empty system instruction and no request-level timeout.
-- Prerequisites: codec prompt carries the Schema meaning in this mode, so provider
-- payload omits response_format; an empty system message is also omitted rather than
-- sent as a distinct chat turn.
-- Verification items: payload has one user message, no Schema/thinking/tool fields,
-- backend-specific timeout is used, and model selection remains explicit.
test.it("omits optional system schema and thinking fields in prompt-only mode", function()
  local context = harness({
    model = "explicit-model",
    structured_output = "prompt_only",
    disable_thinking = false,
    request_timeout_ms = 4321,
  })
  open_ready(context, "different-server-model")
  local handle = context.backend:request({
    request_id = "request:prompt-only",
    system_instructions = "",
    user_content = "document",
    metadata = {},
  }, terminal_callbacks({}))
  local chat = assert(context.transport:take("POST"))
  local payload = assert(json.decode(chat.request.body))

  test.eq("explicit-model", payload.model)
  test.eq(1, #payload.messages)
  test.eq("user", payload.messages[1].role)
  test.eq("document", payload.messages[1].content)
  test.eq(false, payload.stream)
  test.eq(nil, payload.response_format)
  test.eq(nil, payload.reasoning_effort)
  test.eq(nil, payload.chat_template_kwargs)
  test.eq(nil, payload.tools)
  test.eq(4321, chat.request.timeout_ms)
  handle:cancel()
end)

-- Preconditions: Three ready backends exercise a request timeout, a non-zero
-- backend-specific timeout, and request_timeout_ms zero with an injected global
-- timeout. Prerequisites: constructor resolves zero to global while request() gives
-- an explicit per-task timeout highest priority.
-- Verification items: the three transport requests receive 17, 4321, and 5678 ms
-- respectively, with no cross-instance state sharing.
test.it("applies request backend and global timeout precedence", function()
  local cases = {
    {
      options = { request_timeout_ms = 4321, timeout_ms = 5678 },
      request_timeout_ms = 17,
      expected = 17,
    },
    {
      options = { request_timeout_ms = 4321, timeout_ms = 5678 },
      expected = 4321,
    },
    {
      options = { request_timeout_ms = 0, timeout_ms = 5678 },
      expected = 5678,
    },
  }

  for index, case in ipairs(cases) do
    local context = harness(case.options)
    open_ready(context)
    local handle = context.backend:request({
      request_id = "request:timeout:" .. index,
      user_content = "document",
      response_schema = { type = "object" },
      timeout_ms = case.request_timeout_ms,
      metadata = {},
    }, terminal_callbacks({}))
    local chat = assert(context.transport:take("POST"))
    test.eq(case.expected, chat.request.timeout_ms)
    handle:cancel()
  end
end)

-- Preconditions: Calls include invalid callback/input contracts, a valid request on
-- a new backend, a ready Schema backend missing its Schema, and a cyclic Schema that
-- the JSON utility cannot encode.
-- Prerequisites: programmer-owned callback and normalized input shapes throw, while
-- backend state/schema/encoding failures use asynchronous domain errors and never
-- start chat HTTP work.
-- Verification items: throws name the request contract; other cases return cancel
-- handles, deliver one E_BACKEND_UNAVAILABLE or E_BACKEND_PROTOCOL after flush, and
-- leave no pending record or POST request.
test.it("separates programmer request errors from asynchronous backend failures", function()
  local context = harness()
  local constructed, failure = pcall(context.backend.request, context.backend, {}, {})
  test.eq(false, constructed)
  test.eq(true, tostring(failure):find("normalized input", 1, true) ~= nil)

  local not_ready = {}
  local not_ready_handle = context.backend:request({
    request_id = "request:not-ready",
    user_content = "document",
    response_schema = { type = "object" },
    metadata = {},
  }, terminal_callbacks(not_ready))
  test.eq("table", type(not_ready_handle))
  test.eq(nil, not_ready.errors)
  context.flush()
  test.eq(1, not_ready.errors)
  test.eq("E_BACKEND_UNAVAILABLE", not_ready.request_error.code)
  test.eq(0, context.transport:queued_count())

  local missing_context = harness()
  open_ready(missing_context)
  local missing = {}
  local missing_handle = missing_context.backend:request({
    request_id = "request:missing-schema",
    user_content = "document",
    metadata = {},
  }, terminal_callbacks(missing))
  test.eq("table", type(missing_handle))
  missing_context.flush()
  test.eq(1, missing.errors)
  test.eq("E_BACKEND_PROTOCOL", missing.request_error.code)
  test.eq(false, missing.request_error.retryable)
  test.eq(nil, missing_context.transport:take("POST"))
  test.eq(0, pending_count(missing_context.backend))

  local cyclic_context = harness()
  open_ready(cyclic_context)
  local schema = { type = "object" }
  schema.self = schema
  local encoded = {}
  local encoded_handle = cyclic_context.backend:request({
    request_id = "request:encode-failure",
    user_content = "document",
    response_schema = schema,
    metadata = {},
  }, terminal_callbacks(encoded))
  test.eq("table", type(encoded_handle))
  cyclic_context.flush()
  test.eq(1, encoded.errors)
  test.eq("E_BACKEND_PROTOCOL", encoded.request_error.code)
  test.eq(false, encoded.request_error.retryable)
  test.eq(nil, cyclic_context.transport:take("POST"))
  test.eq(0, pending_count(cyclic_context.backend))
end)

local function submit_chat(context, outcome, request_id)
  local handle = context.backend:request({
    request_id = request_id or "request:response",
    user_content = "SECRET DOCUMENT PAYLOAD",
    response_schema = { type = "object" },
    metadata = {},
  }, terminal_callbacks(outcome))
  return handle, assert(context.transport:take("POST"))
end

local function success_body(content, extras)
  local choice = {
    message = { content = content },
    finish_reason = "stop",
  }
  for key, value in pairs(extras or {}) do
    if key == "tool_calls" then
      choice.message.tool_calls = value
    else
      choice[key] = value
    end
  end
  return json.encode({
    model = "response-model",
    choices = json.array({ choice }),
  })
end

-- Preconditions: A ready request receives one valid non-streaming envelope twice
-- before backend scheduling runs.
-- Prerequisites: backend validates only the Chat Completions envelope and leaves the
-- content JSON to the codec; settlement removes pending work before a separately
-- scheduled terminal callback.
-- Verification items: exactly one completion, no error, exact text/model/finish
-- fields, no callback before flush, and zero pending or active transport records.
test.it("delivers one parsed completion despite duplicate transport callbacks", function()
  local context = harness()
  open_ready(context)
  local outcome = {}
  local _, chat = submit_chat(context, outcome)
  local response = {
    status = 200,
    body = success_body('{"translated_text":"翻訳"}'),
    stderr = "",
  }
  context.transport:respond(chat, response)
  context.transport:respond(chat, response)
  test.eq(nil, outcome.completions)
  context.flush()

  test.eq(1, outcome.completions)
  test.eq(nil, outcome.errors)
  test.eq('{"translated_text":"翻訳"}', outcome.result.text)
  test.eq("response-model", outcome.result.model)
  test.eq("stop", outcome.result.finish_reason)
  test.eq(0, pending_count(context.backend))
  test.eq(0, context.transport:active_count())
end)

-- Preconditions: HTTP 200 responses cover invalid JSON/top-level/list/message/content,
-- a malformed tool_calls field, one actual tool call, and finish_reason `length`.
-- Prerequisites: malformed envelopes and truncation are non-retryable protocol
-- failures; any non-empty tool call is a distinct prohibited tool attempt.
-- Verification items: every case invokes only on_error once with its expected code,
-- never returns content, and clears all pending work.
test.it("rejects malformed truncated and tool-calling success envelopes", function()
  local cases = {
    { body = "not json", code = "E_BACKEND_PROTOCOL" },
    { body = "[]", code = "E_BACKEND_PROTOCOL" },
    {
      body = json.encode({ choices = json.array() }),
      code = "E_BACKEND_PROTOCOL",
    },
    { body = '{"choices":{}}', code = "E_BACKEND_PROTOCOL" },
    {
      body = json.encode({ choices = json.array({ {} }) }),
      code = "E_BACKEND_PROTOCOL",
    },
    {
      body = json.encode({ choices = json.array({ { message = {} } }) }),
      code = "E_BACKEND_PROTOCOL",
    },
    {
      body = json.encode({
        choices = json.array({ { message = { content = 1 } } }),
      }),
      code = "E_BACKEND_PROTOCOL",
    },
    {
      body = success_body("content", { tool_calls = {} }),
      code = "E_BACKEND_PROTOCOL",
    },
    {
      body = success_body("content", {
        tool_calls = json.array({ { id = "tool:1" } }),
      }),
      code = "E_BACKEND_TOOL_ATTEMPT",
    },
    {
      body = success_body("partial", { finish_reason = "length" }),
      code = "E_BACKEND_PROTOCOL",
    },
  }

  for index, case in ipairs(cases) do
    local context = harness()
    open_ready(context)
    local outcome = {}
    local _, chat = submit_chat(context, outcome, "request:invalid:" .. index)
    context.transport:respond(chat, { status = 200, body = case.body, stderr = "" })
    context.flush()

    test.eq(nil, outcome.completions)
    test.eq(1, outcome.errors)
    test.eq(case.code, outcome.request_error.code)
    test.eq(false, outcome.request_error.retryable)
    test.eq(0, pending_count(context.backend))
  end
end)

-- Preconditions: Every specified HTTP error status returns a llama-server error
-- object with code/type, an over-limit message, and an extra echoed secret field.
-- Prerequisites: status determines Bilingua code/retryability; only four allowlisted
-- scalar details survive, and server_message is capped at 512 bytes.
-- Verification items: mapping matches the plan, the fixed domain message contains
-- no server/document text, details omit the body and secret, and completion is absent.
test.it("maps HTTP errors while retaining only bounded allowlisted details", function()
  local cases = {
    { status = 400, code = "E_BACKEND_PROTOCOL", retryable = false },
    { status = 404, code = "E_BACKEND_PROTOCOL", retryable = false },
    { status = 405, code = "E_BACKEND_PROTOCOL", retryable = false },
    { status = 409, code = "E_BACKEND_PROTOCOL", retryable = false },
    { status = 422, code = "E_BACKEND_PROTOCOL", retryable = false },
    { status = 401, code = "E_BACKEND_AUTH", retryable = false },
    { status = 403, code = "E_BACKEND_AUTH", retryable = false },
    { status = 408, code = "E_BACKEND_TIMEOUT", retryable = true },
    { status = 504, code = "E_BACKEND_TIMEOUT", retryable = true },
    { status = 429, code = "E_BACKEND_RATE_LIMITED", retryable = true },
    { status = 502, code = "E_BACKEND_UNAVAILABLE", retryable = true },
    { status = 503, code = "E_BACKEND_UNAVAILABLE", retryable = true },
    { status = 500, code = "E_BACKEND_UNAVAILABLE", retryable = true },
  }
  local server_message = ("x"):rep(600) .. "SECRET DOCUMENT PAYLOAD"

  for index, case in ipairs(cases) do
    local context = harness()
    open_ready(context)
    local outcome = {}
    local _, chat = submit_chat(context, outcome, "request:http:" .. index)
    context.transport:respond(chat, {
      status = case.status,
      body = json.encode({
        error = {
          code = "server-code",
          type = "server-type",
          message = server_message,
          echoed_document = "SECRET DOCUMENT PAYLOAD",
        },
        raw_secret = "SECRET DOCUMENT PAYLOAD",
      }),
      stderr = "",
    })
    context.flush()

    local request_error = outcome.request_error
    test.eq(nil, outcome.completions)
    test.eq(1, outcome.errors)
    test.eq(case.code, request_error.code)
    test.eq(case.retryable, request_error.retryable)
    test.eq(nil, request_error.message:find("SECRET", 1, true))
    test.eq(case.status, request_error.details.http_status)
    test.eq("server-code", request_error.details.server_code)
    test.eq("server-type", request_error.details.server_type)
    test.eq(512, #request_error.details.server_message)
    test.eq(nil, request_error.details.echoed_document)
    test.eq(nil, request_error.details.raw_secret)
    test.eq(nil, request_error.details.body)
  end
end)

-- Preconditions: The fake transport reports each neutral transport failure kind on
-- an otherwise valid ready request.
-- Prerequisites: curl-specific kinds are translated at the backend boundary without
-- carrying stderr, body, or transport implementation details into domain errors.
-- Verification items: spawn/timeout/network/protocol/io map to the required domain
-- code and retryability, each callback is scheduled once, and no completion occurs.
test.it("maps curl transport failures to backend errors", function()
  local cases = {
    { kind = "spawn", code = "E_BACKEND_NOT_FOUND", retryable = false },
    { kind = "timeout", code = "E_BACKEND_TIMEOUT", retryable = true },
    { kind = "network", code = "E_BACKEND_UNAVAILABLE", retryable = true },
    { kind = "protocol", code = "E_BACKEND_PROTOCOL", retryable = false },
    { kind = "io", code = "E_BACKEND_UNAVAILABLE", retryable = true },
  }

  for index, case in ipairs(cases) do
    local context = harness()
    open_ready(context)
    local outcome = {}
    local _, chat = submit_chat(context, outcome, "request:transport:" .. index)
    context.transport:respond(chat, nil, {
      kind = case.kind,
      message = "SECRET TRANSPORT DETAIL",
      exit_code = 7,
    })
    context.flush()

    test.eq(nil, outcome.completions)
    test.eq(1, outcome.errors)
    test.eq(case.code, outcome.request_error.code)
    test.eq(case.retryable, outcome.request_error.retryable)
    test.eq(nil, outcome.request_error.message:find("SECRET", 1, true))
  end
end)

-- Preconditions: A valid transport response is emitted, then the caller cancels
-- before the backend's scheduled parser/delivery runs; another late response follows.
-- Prerequisites: cancellation removes pending work and suppresses both already queued
-- and future transport callbacks without changing external server state.
-- Verification items: transport cancel is invoked once, no terminal callback runs,
-- duplicate/late completion remains ignored, and pending/active counts reach zero.
test.it("suppresses queued and late chat responses after cancellation", function()
  local context = harness()
  open_ready(context)
  local outcome = {}
  local handle, chat = submit_chat(context, outcome, "request:cancel-race")
  local response = { status = 200, body = success_body("late content"), stderr = "" }
  context.transport:respond(chat, response)
  handle:cancel()
  handle:cancel()
  context.flush()
  context.transport:respond(chat, response)
  context.flush()

  test.eq(1, context.transport.cancel_count)
  test.eq(nil, outcome.completions)
  test.eq(nil, outcome.errors)
  test.eq(0, pending_count(context.backend))
  test.eq(0, context.transport:active_count())
end)

local function has_shutdown_request(transport)
  for _, record in ipairs(transport.history) do
    if record.request.url:find("shutdown", 1, true) then
      return true
    end
  end
  return false
end

-- Preconditions: Two close callbacks are registered on a never-opened backend before
-- scheduled finalization, followed by another close after it is fully closed.
-- Prerequisites: llama-server is externally owned, so close has no network work;
-- callbacks queue during `closing` and every success remains asynchronous.
-- Verification items: state transitions new→closing→closed, all three callbacks run
-- exactly once after their flush, no timer/request exists, and no shutdown URL appears.
test.it("closes before open and queues repeated asynchronous close callbacks", function()
  local context = harness()
  local callbacks = 0
  context.backend:close(function(closed)
    test.eq(true, closed)
    callbacks = callbacks + 1
  end)
  test.eq("closing", context.backend.state)
  context.backend:close(function(closed)
    test.eq(true, closed)
    callbacks = callbacks + 1
  end)
  test.eq(0, callbacks)
  context.flush()

  test.eq("closed", context.backend.state)
  test.eq(2, callbacks)
  context.backend:close(function(closed)
    test.eq(true, closed)
    callbacks = callbacks + 1
  end)
  test.eq(2, callbacks)
  context.flush()
  test.eq(3, callbacks)
  test.eq(0, context.transport:active_count())
  test.eq(0, context.active_timers())
  test.eq(false, has_shutdown_request(context.transport))

  local optional = harness()
  optional.backend:close()
  optional.flush()
  test.eq("closed", optional.backend.state)
end)

-- Preconditions: Separate opening backends are stopped during an active health GET,
-- a 503 poll delay, and an active model-discovery GET; cancelled fake callbacks or
-- timers are then fired late.
-- Prerequisites: close owns every open-phase request/timer and settles the original
-- open callback with SESSION_CLOSED while preserving its own queued completion.
-- Verification items: each open and close callback runs once, all resources reach
-- zero, late work is ignored, state is closed, and no server shutdown is requested.
test.it("closes cleanly during health polling and model discovery", function()
  local stages = {
    function(context)
      return assert(context.transport:take("GET")), nil
    end,
    function(context)
      local health = assert(context.transport:take("GET"))
      context.transport:respond(health, { status = 503, body = "loading", stderr = "" })
      context.flush()
      return nil, context.timers[2]
    end,
    function(context)
      health_ok(context)
      return assert(context.transport:take("GET")), nil
    end,
  }

  for _, reach_stage in ipairs(stages) do
    local context = harness()
    local outcome = begin_open(context)
    local late_request, late_timer = reach_stage(context)
    local close_callbacks = 0
    context.backend:close(function(closed)
      test.eq(true, closed)
      close_callbacks = close_callbacks + 1
    end)
    test.eq("closing", context.backend.state)
    test.eq(0, close_callbacks)

    if late_request then
      test.eq(true, late_request.cancelled)
      context.transport:respond(late_request, {
        status = 200,
        body = '{"status":"ok"}',
        stderr = "",
      })
    end
    if late_timer then
      test.eq(false, late_timer.active)
      late_timer:fire()
    end
    context.flush()

    test.eq(1, outcome.callbacks)
    test.eq(nil, outcome.opened)
    test.eq("E_SESSION_CLOSED", outcome.open_error.code)
    test.eq(false, outcome.open_error.retryable)
    test.eq(1, close_callbacks)
    test.eq("closed", context.backend.state)
    test.eq(0, context.transport:active_count())
    test.eq(0, context.active_timers())
    test.eq(false, has_shutdown_request(context.transport))
  end
end)

-- Preconditions: One ready backend closes with an active chat request and duplicate
-- close callbacks; another task is service-cancelled before backend close. Both fake
-- transports emit late successful responses after cancellation.
-- Prerequisites: backend close cancels active curl work and reports SESSION_CLOSED,
-- while prior caller cancellation suppresses terminal delivery; external server
-- lifetime remains untouched.
-- Verification items: active job gets one close error, pre-cancelled job gets none,
-- close callbacks succeed once, late responses are ignored, pending/active/timer
-- counts are zero, selected model is retained for status, and no shutdown URL exists.
test.it("cancels active chat work on close and respects prior task cancellation", function()
  local context = harness()
  open_ready(context, "retained-model")
  local active_outcome = {}
  local _, active_chat = submit_chat(context, active_outcome, "request:close-active")
  local close_callbacks = 0
  context.backend:close(function(closed)
    test.eq(true, closed)
    close_callbacks = close_callbacks + 1
  end)
  context.backend:close(function(closed)
    test.eq(true, closed)
    close_callbacks = close_callbacks + 1
  end)
  test.eq(true, active_chat.cancelled)
  test.eq(nil, active_outcome.errors)
  context.transport:respond(active_chat, {
    status = 200,
    body = success_body("late active response"),
    stderr = "",
  })
  context.flush()

  test.eq(1, active_outcome.errors)
  test.eq(nil, active_outcome.completions)
  test.eq("E_SESSION_CLOSED", active_outcome.request_error.code)
  test.eq(false, active_outcome.request_error.retryable)
  test.eq(2, close_callbacks)
  test.eq("closed", context.backend.state)
  test.eq("retained-model", context.backend:selected_model())
  test.eq(0, pending_count(context.backend))
  test.eq(0, context.transport:active_count())
  test.eq(0, context.active_timers())
  test.eq(false, has_shutdown_request(context.transport))

  local cancelled_context = harness()
  open_ready(cancelled_context)
  local cancelled_outcome = {}
  local handle, cancelled_chat =
    submit_chat(cancelled_context, cancelled_outcome, "request:service-cancelled")
  handle:cancel()
  cancelled_context.backend:close()
  cancelled_context.transport:respond(cancelled_chat, {
    status = 200,
    body = success_body("late cancelled response"),
    stderr = "",
  })
  cancelled_context.flush()

  test.eq(nil, cancelled_outcome.errors)
  test.eq(nil, cancelled_outcome.completions)
  test.eq("closed", cancelled_context.backend.state)
  test.eq(0, pending_count(cancelled_context.backend))
  test.eq(0, cancelled_context.transport:active_count())
  test.eq(0, cancelled_context.active_timers())
  test.eq(false, has_shutdown_request(cancelled_context.transport))
end)

-- Preconditions: Health first reports 503, the configured poll timer fires, and the
-- next health plus one-model discovery responses are valid.
-- Prerequisites: a loading response is transient and its body is not parsed as a
-- terminal error; the same overall open timeout spans polling and discovery.
-- Verification items: exactly one delayed retry is sent, open succeeds once with the
-- discovered model, and all request/timer resources are released.
test.it("recovers from a health 503 after one poll delay", function()
  local context = harness()
  local outcome = begin_open(context)
  local first = assert(context.transport:take("GET"))
  context.transport:respond(first, {
    status = 503,
    body = "body is intentionally ignored",
    stderr = "",
  })
  context.flush()
  test.eq(0, outcome.callbacks)
  test.eq(250, context.timers[2].milliseconds)
  context.timers[2]:fire()
  context.flush()

  local second = assert(context.transport:take("GET"))
  context.transport:respond(second, {
    status = 200,
    body = '{"status":"ok"}',
    stderr = "",
  })
  context.flush()
  local models = assert(context.transport:take("GET"))
  context.transport:respond(models, {
    status = 200,
    body = json.encode({ data = json.array({ { id = "recovered-model" } }) }),
    stderr = "",
  })
  context.flush()

  test.eq(1, outcome.callbacks)
  test.eq(true, outcome.opened)
  test.eq(nil, outcome.open_error)
  test.eq("recovered-model", context.backend:selected_model())
  test.eq("ready", context.backend.state)
  test.eq(0, context.transport:active_count())
  test.eq(0, context.active_timers())
end)

-- Preconditions: Separate opens reach a 503 poll delay and an active model request,
-- then their common overall timeout timer fires before the next response.
-- Prerequisites: overall timeout is the sole lifetime owner for every open-phase
-- timer and transport handle, regardless of the current sub-step.
-- Verification items: poll timer or model request is cancelled, callback reports one
-- retryable timeout, late activity has no effect, and all active counts reach zero.
test.it("overall timeout cancels poll-delay and model-discovery resources", function()
  local stages = {
    function(context)
      local health = assert(context.transport:take("GET"))
      context.transport:respond(health, { status = 503, body = "loading", stderr = "" })
      context.flush()
      return nil, context.timers[2]
    end,
    function(context)
      health_ok(context)
      return assert(context.transport:take("GET")), nil
    end,
  }

  for _, reach_stage in ipairs(stages) do
    local context = harness()
    local outcome = begin_open(context)
    local late_request, poll_timer = reach_stage(context)
    context.timers[1]:fire()
    context.flush()

    test.eq(1, outcome.callbacks)
    test.eq("E_BACKEND_TIMEOUT", outcome.open_error.code)
    test.eq(true, outcome.open_error.retryable)
    if poll_timer then
      test.eq(false, poll_timer.active)
      poll_timer:fire()
    end
    if late_request then
      test.eq(true, late_request.cancelled)
      context.transport:respond(late_request, {
        status = 200,
        body = '{"data":[]}',
        stderr = "",
      })
    end
    context.flush()
    test.eq(1, outcome.callbacks)
    test.eq(0, context.transport:active_count())
    test.eq(0, context.active_timers())
  end
end)

-- Preconditions: Additional open calls occur while the first is opening, after a
-- health failure, and after close has completed.
-- Prerequisites: only `new` starts discovery and only `ready` supports idempotent
-- success; all other lifecycle states reject open asynchronously without mutation.
-- Verification items: each extra callback receives one E_BACKEND_INIT, while the
-- original opening callback remains independently settleable with SESSION_CLOSED.
test.it("rejects open from opening failed and closed states", function()
  local opening = harness()
  local original = begin_open(opening)
  local opening_error
  opening.backend:open(function(_, err)
    opening_error = err
  end)
  test.eq(nil, opening_error)
  opening.flush()
  test.eq("E_BACKEND_INIT", opening_error.code)
  test.eq(0, original.callbacks)
  opening.backend:close()
  opening.flush()
  test.eq(1, original.callbacks)
  test.eq("E_SESSION_CLOSED", original.open_error.code)

  local failed = harness()
  local failed_outcome = begin_open(failed)
  local health = assert(failed.transport:take("GET"))
  failed.transport:respond(health, { status = 401, body = "{}", stderr = "" })
  failed.flush()
  test.eq("E_BACKEND_AUTH", failed_outcome.open_error.code)
  local failed_reopen_error
  failed.backend:open(function(_, err)
    failed_reopen_error = err
  end)
  failed.flush()
  test.eq("E_BACKEND_INIT", failed_reopen_error.code)

  local closed = harness()
  closed.backend:close()
  closed.flush()
  local closed_reopen_error
  closed.backend:open(function(_, err)
    closed_reopen_error = err
  end)
  test.eq(nil, closed_reopen_error)
  closed.flush()
  test.eq("E_BACKEND_INIT", closed_reopen_error.code)
  test.eq("closed", closed.backend.state)
end)
