local test = require("tests.testlib")
local config_module = require("bilingua.config")
local json = require("bilingua.util.json")
local registry_module = require("bilingua.registry")
local standard_registry = require("bilingua.standard_registry")
local fake_http = require("tests.fakes.http_transport")

local ENDPOINT = "http://127.0.0.1:8080"
local CHAT_URL = ENDPOINT .. "/v1/chat/completions"

local function initial_task(task_id)
  return {
    schema_version = 1,
    task_id = task_id or "task:initial:integration",
    session_id = "session:llama-integration",
    kind = "initial_translate",
    direction = "source_to_target",
    source_language = "auto",
    target_language = "ja",
    edited_after = {
      side = "source",
      language = "auto",
      units = {
        {
          unit_id = "src:u:000001",
          kind = "paragraph",
          language = "auto",
          content_text = "Run ⟦BIL:0001⟧.",
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
    text_hash = "hash:" .. id .. ":" .. text,
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
            literal = "`fast`",
            kind = "inline_code",
          },
        },
      },
    },
  }
end

local function semantic_task()
  local source = fragment("source", "src:u:12", "en", "This is fast ⟦BIL:0001⟧.")
  local target_before =
    fragment("target", "tgt:u:15", "ja", "これは高速です ⟦BIL:0001⟧。")
  local target_after =
    fragment("target", "tgt:u:15", "ja", "これは非常に高速です ⟦BIL:0001⟧。")
  return {
    schema_version = 1,
    task_id = "task:patch:integration",
    session_id = "session:llama-integration",
    kind = "propagate_edit",
    direction = "target_to_source",
    source_language = "en",
    target_language = "ja",
    mapping_group_id = "group:17",
    baseline = { source = source, target = target_before, revision = 3 },
    edited_side = "target",
    edited_before = target_before,
    edited_after = target_after,
    destination_before = source,
    context_before = {},
    context_after = {},
    constraints = {
      preserve_unedited_meaning = true,
      preserve_style = true,
      preserve_placeholders = true,
    },
    revision = 4,
    metadata = {},
  }
end

local function harness()
  local pending = {}
  local delays = {}
  local timers = {}
  local transport = fake_http.new()

  local scheduler = {}
  function scheduler:schedule(callback)
    pending[#pending + 1] = callback
  end
  function scheduler:defer(milliseconds, callback)
    local delay = {
      milliseconds = milliseconds,
      callback = callback,
      active = true,
    }
    local handle = {}
    function handle:cancel()
      delay.active = false
    end
    delay.handle = handle
    delays[#delays + 1] = delay
    return handle
  end

  local function timer_factory(milliseconds, callback)
    local timer = {
      milliseconds = milliseconds,
      callback = callback,
      active = true,
    }
    function timer:cancel()
      self.active = false
    end
    timers[#timers + 1] = timer
    return timer
  end

  local registry = registry_module.new()
  assert(standard_registry.register(registry))
  local config = assert(config_module.resolve({
    sync = {
      retry = {
        max_attempts = 2,
        initial_delay_ms = 5,
        max_delay_ms = 5,
      },
    },
    translation = {
      backend = "llama_server",
      timeout_ms = 7654,
      backends = {
        llama_server = {
          endpoint = ENDPOINT,
          model = "auto",
          structured_output = "json_schema",
          disable_thinking = true,
        },
      },
    },
  }))
  local service = registry:get_translation_service("default")(config, {
    registry = registry,
    scheduler = scheduler,
    backend_runtime = {
      transport = transport,
      schedule = function(callback)
        scheduler:schedule(callback)
      end,
      timer_factory = timer_factory,
    },
  })

  local context = {
    service = service,
    transport = transport,
    pending = pending,
    delays = delays,
    timers = timers,
  }
  function context:flush()
    while #self.pending > 0 do
      local callbacks = self.pending
      self.pending = {}
      pending = self.pending
      for _, callback in ipairs(callbacks) do
        callback()
      end
    end
  end
  function context:fire_retry()
    for _, delay in ipairs(self.delays) do
      if delay.active then
        delay.active = false
        delay.callback()
        return delay
      end
    end
    error("expected one active retry delay")
  end
  function context:active_delays()
    local count = 0
    for _, delay in ipairs(self.delays) do
      if delay.active then
        count = count + 1
      end
    end
    return count
  end
  function context:active_timers()
    local count = 0
    for _, timer in ipairs(self.timers) do
      if timer.active then
        count = count + 1
      end
    end
    return count
  end
  return context
end

local function open_service(context)
  local outcome = { callbacks = 0 }
  context.service:open(function(opened, open_error)
    outcome.callbacks = outcome.callbacks + 1
    outcome.opened = opened
    outcome.open_error = open_error
  end)
  local health = assert(context.transport:take("GET", ENDPOINT .. "/health"))
  context.transport:respond(health, {
    status = 200,
    body = json.encode({ status = "ok" }),
    stderr = "",
  })
  context:flush()
  local models = assert(context.transport:take("GET", ENDPOINT .. "/v1/models"))
  context.transport:respond(models, {
    status = 200,
    body = json.encode({ data = json.array({ { id = "integration-model" } }) }),
    stderr = "",
  })
  context:flush()

  test.eq(1, outcome.callbacks)
  test.eq(true, outcome.opened)
  test.eq(nil, outcome.open_error)
  test.eq("open", context.service.state)
  test.eq("integration-model", context.service.backend:selected_model())
  test.eq(0, context:active_timers())
  test.eq(0, context.transport:active_count())
end

local function submit(context, task, is_current)
  local outcome = { completions = 0, errors = 0 }
  local handle = context.service:submit(task, {
    on_complete = function(result)
      outcome.completions = outcome.completions + 1
      outcome.result = result
    end,
    on_error = function(request_error)
      outcome.errors = outcome.errors + 1
      outcome.request_error = request_error
    end,
    is_current = is_current,
  })
  return outcome, handle
end

local function chat_response(content)
  return {
    status = 200,
    body = json.encode({
      model = "integration-model",
      choices = json.array({
        {
          message = { role = "assistant", content = content },
          finish_reason = "stop",
        },
      }),
    }),
    stderr = "",
  }
end

local function initial_response(task_id)
  return json.encode({
    schema_version = 1,
    task_id = task_id,
    translations = json.array({
      {
        source_unit_id = "src:u:000001",
        source_language = "en",
        translated_text = "実行 ⟦BIL:0001⟧。",
        warnings = json.array(),
      },
    }),
  })
end

local function semantic_response()
  return json.encode({
    schema_version = 1,
    task_id = "task:patch:integration",
    destination_side = "source",
    replacement_units = json.array({
      {
        local_id = "replacement:1",
        corresponds_to_edited_unit_ids = json.array({ "tgt:u:15" }),
        kind = "paragraph",
        content_text = "This is extremely fast ⟦BIL:0001⟧.",
        language = "en",
      },
    }),
    warnings = json.array(),
  })
end

local function json_section(content, first_marker, final_marker)
  local first = assert(content:find(first_marker, 1, true)) + #first_marker
  local final = assert(content:find(final_marker, first, true))
  return assert(json.decode(content:sub(first, final - 1)))
end

local function close_service(context)
  local outcome = { callbacks = 0 }
  context.service:close(function(closed, close_error)
    outcome.callbacks = outcome.callbacks + 1
    outcome.closed = closed
    outcome.close_error = close_error
  end)
  context:flush()
  test.eq(1, outcome.callbacks)
  test.eq(true, outcome.closed)
  test.eq(nil, outcome.close_error)
  test.eq("closed", context.service.state)
  test.eq(0, context.transport:active_count())
  test.eq(0, context:active_timers())
  test.eq(0, context:active_delays())
end

-- Preconditions: Standard registry composition selects llama-server with its real
-- initial_translation_json_v1 codec and an HTTP fake injected only at the transport
-- boundary. Prerequisites: open must complete health/model discovery before submit;
-- llama capabilities place the same Schema in the API parameter and prompt.
-- Verification items: provider payload contains the exact source ID/placeholder,
-- the existing codec decodes the envelope into the shared result, and close leaks no
-- request, backend timer, retry delay, or llama-specific codec dependency.
test.it(
  "translates an initial task through the registered llama backend and existing codec",
  function()
    local context = harness()
    test.eq("llama_server", context.service.backend.id)
    test.eq("initial_translation_json_v1", context.service.initial_codec.id)
    test.eq("semantic_patch_json_v1", context.service.patch_codec.id)
    open_service(context)

    local task = initial_task()
    local outcome = submit(context, task)
    local chat = assert(context.transport:take("POST", CHAT_URL))
    local payload = assert(json.decode(chat.request.body))
    test.eq("json_schema", payload.response_format.type)
    local schema = payload.response_format.json_schema.schema
    test.eq("array", schema.properties.translations.type)
    test.eq(2, #payload.messages)
    local prompt_schema = json_section(
      payload.messages[2].content,
      "RESPONSE_SCHEMA\n",
      "\n\nReturn exactly one JSON object"
    )
    test.eq(schema, prompt_schema)
    local document =
      json_section(payload.messages[2].content, "DOCUMENT_DATA\n", "\n\nRESPONSE_SCHEMA")
    test.eq("src:u:000001", document.units[1].source_unit_id)
    test.eq("⟦BIL:0001⟧", document.units[1].protected_placeholders[1])

    context.transport:respond(chat, chat_response(initial_response(task.task_id)))
    context:flush()
    test.eq(1, outcome.completions)
    test.eq(0, outcome.errors)
    test.eq("target", outcome.result.destination_side)
    test.eq("src:u:000001", outcome.result.replacement_units[1].corresponds_to_edited_unit_ids[1])
    test.eq("実行 ⟦BIL:0001⟧。", outcome.result.replacement_units[1].content_text)
    test.eq("en", outcome.result.metadata.document_source_language)
    close_service(context)
  end
)

-- Preconditions: The same open service receives a target-to-source semantic edit
-- with a protected placeholder and no provider-specific task shape. Prerequisites:
-- standard composition must choose semantic_patch_json_v1 solely from task.kind.
-- Verification items: API/prompt Schemas pin the task, destination, and edited ID;
-- DOCUMENT_DATA keeps before/after sides, and decoding returns one source patch with
-- exact correspondence, content, language, and placeholder before clean close.
test.it(
  "applies a semantic patch through the registered llama backend and existing codec",
  function()
    local context = harness()
    open_service(context)

    local outcome = submit(context, semantic_task())
    local chat = assert(context.transport:take("POST", CHAT_URL))
    local payload = assert(json.decode(chat.request.body))
    local schema = payload.response_format.json_schema.schema
    test.eq("string", schema.properties.destination_side.type)
    test.eq("source", schema.properties.destination_side.const)
    test.eq("task:patch:integration", schema.properties.task_id.const)
    test.eq("array", schema.properties.replacement_units.type)
    local correspondence_schema =
      schema.properties.replacement_units.items.properties.corresponds_to_edited_unit_ids
    test.eq("tgt:u:15", correspondence_schema.items.enum[1])
    local prompt_schema = json_section(
      payload.messages[2].content,
      "RESPONSE_SCHEMA\n",
      "\n\nReturn exactly one JSON object"
    )
    test.eq(schema, prompt_schema)
    local document =
      json_section(payload.messages[2].content, "DOCUMENT_DATA\n", "\n\nRESPONSE_SCHEMA")
    test.eq("src:u:12", document.source_before[1].unit_id)
    test.eq("tgt:u:15", document.target_before[1].unit_id)
    test.eq("tgt:u:15", document.target_after[1].unit_id)
    test.eq("⟦BIL:0001⟧", document.target_after[1].protected_placeholders[1])

    context.transport:respond(chat, chat_response(semantic_response()))
    context:flush()
    test.eq(1, outcome.completions)
    test.eq(0, outcome.errors)
    test.eq("source", outcome.result.destination_side)
    test.eq("tgt:u:15", outcome.result.replacement_units[1].corresponds_to_edited_unit_ids[1])
    test.eq(
      "This is extremely fast ⟦BIL:0001⟧.",
      outcome.result.replacement_units[1].content_text
    )
    test.eq("en", outcome.result.replacement_units[1].language)
    close_service(context)
  end
)

-- Preconditions: The first semantic response is valid JSON with every semantic
-- field except the required empty warnings array; the second response is complete.
-- Prerequisites: missing/unknown JSON object fields are format-shape failures, while
-- IDs, correspondence, placeholders, and other semantic checks remain non-retryable.
-- Verification items: one delayed correction is appended only to system instructions,
-- exactly two POSTs produce one decoded completion, and close releases all resources.
test.it("repairs one missing semantic response field through format retry", function()
  local context = harness()
  open_service(context)
  local outcome = submit(context, semantic_task())
  local first_chat = assert(context.transport:take("POST", CHAT_URL))
  local first_payload = assert(json.decode(first_chat.request.body))
  local missing_warnings = json.encode({
    schema_version = 1,
    task_id = "task:patch:integration",
    destination_side = "source",
    replacement_units = json.array({
      {
        local_id = "replacement:1",
        corresponds_to_edited_unit_ids = json.array({ "tgt:u:15" }),
        kind = "paragraph",
        content_text = "This is extremely fast ⟦BIL:0001⟧.",
        language = "en",
      },
    }),
  })

  context.transport:respond(first_chat, chat_response(missing_warnings))
  context:flush()
  test.eq(0, outcome.completions)
  test.eq(0, outcome.errors)
  test.eq(1, context:active_delays())

  context:fire_retry()
  local second_chat = assert(context.transport:take("POST", CHAT_URL))
  local second_payload = assert(json.decode(second_chat.request.body))
  test.eq(first_payload.messages[2].content, second_payload.messages[2].content)
  test.eq(true, second_payload.messages[1].content:find("JSON format validation", 1, true) ~= nil)

  context.transport:respond(second_chat, chat_response(semantic_response()))
  context:flush()
  test.eq(1, outcome.completions)
  test.eq(0, outcome.errors)
  test.eq("source", outcome.result.destination_side)
  test.eq("tgt:u:15", outcome.result.replacement_units[1].corresponds_to_edited_unit_ids[1])
  test.eq(0, context:active_delays())
  close_service(context)
end)

-- Preconditions: An initial task first receives a valid llama envelope whose
-- assistant content is invalid JSON, followed by one valid response after delay.
-- Prerequisites: codec marks JSON shape failures retryable and TranslationService
-- owns the single format correction while backend remains provider-agnostic.
-- Verification items: one five-ms retry is created, system correction appears
-- exactly once, user/document text is unchanged, prior output is absent, two POSTs
-- produce exactly one completion even with a duplicate transport callback, and all
-- resources are released on close.
test.it("repairs malformed llama content exactly once through the service retry path", function()
  local context = harness()
  open_service(context)
  local task = initial_task("task:initial:retry")
  local outcome = submit(context, task)
  local first_chat = assert(context.transport:take("POST", CHAT_URL))
  local first_payload = assert(json.decode(first_chat.request.body))

  context.transport:respond(first_chat, chat_response("not json"))
  context:flush()
  test.eq(0, outcome.completions)
  test.eq(0, outcome.errors)
  test.eq(1, context:active_delays())
  test.eq(5, context.delays[1].milliseconds)

  context:fire_retry()
  local second_chat = assert(context.transport:take("POST", CHAT_URL))
  local second_payload = assert(json.decode(second_chat.request.body))
  local correction = table.concat({
    "The previous response failed JSON format validation.",
    "Re-evaluate the original task and return only one object conforming to the response schema.",
    "Include every required field; use an empty array for a required array field when it has no values.",
    "Do not add prose or code fences.",
  }, " ")
  test.eq(
    first_payload.messages[1].content .. "\n" .. correction,
    second_payload.messages[1].content
  )
  test.eq(first_payload.messages[2].content, second_payload.messages[2].content)
  test.eq(nil, second_payload.messages[1].content:find("not json", 1, true))
  test.eq(nil, second_payload.messages[2].content:find("not json", 1, true))

  local response = chat_response(initial_response(task.task_id))
  context.transport:respond(second_chat, response)
  context:flush()
  context.transport:respond(second_chat, response)
  context:flush()
  test.eq(1, outcome.completions)
  test.eq(0, outcome.errors)
  test.eq("実行 ⟦BIL:0001⟧。", outcome.result.replacement_units[1].content_text)
  test.eq(0, context:active_delays())

  local chat_requests = 0
  for _, record in ipairs(context.transport.history) do
    if record.request.method == "POST" and record.request.url == CHAT_URL then
      chat_requests = chat_requests + 1
    end
  end
  test.eq(2, chat_requests)
  close_service(context)
end)

-- Preconditions: A valid llama envelope contains an initial-translation JSON
-- object whose translated text omits the source's protected placeholder.
-- Prerequisites: the shared initial codec, rather than the provider backend, owns
-- semantic placeholder validation and classifies it as non-format-repairable.
-- Verification items: one POST yields one E_INVALID_OUTPUT, no retry delay or
-- second POST is created, no completion is delivered, and close releases resources.
test.it("rejects a llama translation that loses a protected placeholder without retry", function()
  local context = harness()
  open_service(context)
  local task = initial_task("task:initial:placeholder-mismatch")
  local outcome = submit(context, task)
  local chat = assert(context.transport:take("POST", CHAT_URL))
  local invalid_content = json.encode({
    schema_version = 1,
    task_id = task.task_id,
    translations = json.array({
      {
        source_unit_id = "src:u:000001",
        source_language = "en",
        translated_text = "実行。",
        warnings = json.array(),
      },
    }),
  })

  context.transport:respond(chat, chat_response(invalid_content))
  context:flush()

  test.eq(0, outcome.completions)
  test.eq(1, outcome.errors)
  test.eq("E_INVALID_OUTPUT", outcome.request_error.code)
  test.eq(false, outcome.request_error.retryable)
  test.eq(0, context:active_delays())
  test.eq(nil, context.transport:take("POST", CHAT_URL))
  close_service(context)
end)

-- Preconditions: A llama response triggers one delayed format repair while the
-- caller still considers the task current, then the task becomes stale before the
-- delay fires. Prerequisites: TranslationService checks currency again at retry
-- delivery and must not send obsolete document data to the backend.
-- Verification items: the first POST creates one delay, firing it returns exactly
-- one E_STALE_RESULT, no second POST/completion occurs, and cleanup reaches zero.
test.it("stops a stale llama format retry before sending a second request", function()
  local context = harness()
  open_service(context)
  local current = true
  local outcome = submit(context, initial_task("task:initial:stale-retry"), function()
    return current
  end)
  local first_chat = assert(context.transport:take("POST", CHAT_URL))

  context.transport:respond(first_chat, chat_response("not json"))
  context:flush()
  test.eq(1, context:active_delays())

  current = false
  context:fire_retry()
  context:flush()

  test.eq(0, outcome.completions)
  test.eq(1, outcome.errors)
  test.eq("E_STALE_RESULT", outcome.request_error.code)
  test.eq(0, context:active_delays())
  test.eq(nil, context.transport:take("POST", CHAT_URL))
  close_service(context)
end)

-- Preconditions: Two in-flight initial tasks are independently cancelled, first
-- through the returned handle and then by closing the owning TranslationService.
-- Prerequisites: service cancellation delegates through backend to the HTTP handle;
-- closing an external llama-server must only release client-owned resources.
-- Verification items: both transport records are cancelled once, duplicate/late
-- response delivery reaches no caller callback, close settles once, active resources
-- are zero, and no server shutdown endpoint was requested.
test.it("suppresses late llama responses after handle cancellation and service close", function()
  local context = harness()
  open_service(context)

  local first_outcome, first_handle = submit(context, initial_task("task:initial:cancel-handle"))
  local first_chat = assert(context.transport:take("POST", CHAT_URL))
  first_handle:cancel()
  first_handle:cancel()
  test.eq(true, first_handle:is_cancelled())
  test.eq(true, first_chat.cancelled)
  test.eq(1, context.transport.cancel_count)
  context.transport:respond(
    first_chat,
    chat_response(initial_response("task:initial:cancel-handle"))
  )
  context:flush()
  test.eq(0, first_outcome.completions)
  test.eq(0, first_outcome.errors)

  local second_outcome = submit(context, initial_task("task:initial:cancel-close"))
  local second_chat = assert(context.transport:take("POST", CHAT_URL))
  local closed = { callbacks = 0 }
  context.service:close(function(ok, close_error)
    closed.callbacks = closed.callbacks + 1
    closed.ok = ok
    closed.close_error = close_error
  end)
  test.eq(true, second_chat.cancelled)
  test.eq(2, context.transport.cancel_count)
  context:flush()
  test.eq(1, closed.callbacks)
  test.eq(true, closed.ok)
  test.eq(nil, closed.close_error)
  context.transport:respond(
    second_chat,
    chat_response(initial_response("task:initial:cancel-close"))
  )
  context.transport:respond(
    second_chat,
    chat_response(initial_response("task:initial:cancel-close"))
  )
  context:flush()

  test.eq(0, second_outcome.completions)
  test.eq(0, second_outcome.errors)
  test.eq("closed", context.service.state)
  test.eq(0, context.transport:active_count())
  test.eq(0, context:active_timers())
  test.eq(0, context:active_delays())
  test.eq(false, context.transport:requested_url(ENDPOINT .. "/shutdown"))
end)
