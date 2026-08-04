local test = require("tests.testlib")
local json = require("bilingua.util.json")
local fake_server = require("tests.fakes.app_server_process")
local codex_backend = require("bilingua.adapters.translation.backends.codex_app_server")

-- Preconditions: No Neovim runtime functions are supplied to the concrete
-- Codex backend. Prerequisites: The backend is isolated from direct Neovim API
-- access and cannot schedule even its own asynchronous initialization error
-- without the injected runtime. Verification items: construction fails fast
-- with a dependency-specific message instead of returning an instance that will
-- later attempt to call a nil scheduler.
test.it("fails fast when an injected runtime dependency is missing", function()
  local constructed, failure = pcall(codex_backend.new, {})

  test.eq(false, constructed)
  test.eq(true, tostring(failure):find("schedule", 1, true) ~= nil)
end)

local function harness(extra)
  local options = extra or {}
  local pending = {}
  local timers = {}
  local removed = {}
  local runtime_calls = { tempdir = 0 }
  local current_ms = 0
  local server = fake_server.new()
  local function schedule(callback)
    pending[#pending + 1] = callback
  end
  local function flush()
    while #pending > 0 do
      local callbacks = pending
      pending = {}
      for _, callback in ipairs(callbacks) do
        callback()
      end
    end
  end
  local function timer_factory(milliseconds, callback)
    local timer = { milliseconds = milliseconds, cancelled = false }
    function timer:cancel()
      self.cancelled = true
    end
    function timer:fire()
      if not self.cancelled then
        self.cancelled = true
        callback()
      end
    end
    timers[#timers + 1] = timer
    return timer
  end
  local backend = codex_backend.new(vim.tbl_extend("force", {
    command = { "codex", "app-server" },
    schedule = schedule,
    timer_factory = timer_factory,
    process_factory = function(command, process_options, on_exit)
      return server:process_factory(command, process_options, on_exit)
    end,
    tempdir_factory = function()
      runtime_calls.tempdir = runtime_calls.tempdir + 1
      return "/tmp/bilingua-isolated-test"
    end,
    remove_tree = function(path)
      removed[#removed + 1] = path
      return true
    end,
    realpath = function(path)
      return path
    end,
    now_ms = function()
      return current_ms
    end,
    request_timeout_ms = 10,
    turn_timeout_ms = 120,
    shutdown_timeout_ms = 5,
  }, options))
  return {
    backend = backend,
    server = server,
    flush = flush,
    timers = timers,
    removed = removed,
    runtime_calls = runtime_calls,
    set_now_ms = function(value)
      current_ms = value
    end,
  }
end

-- Preconditions: Each construction receives all required runtime functions but
-- one malformed user-owned Codex option, including both isolation contradictions.
-- Prerequisites: user configuration errors are stored by the constructor and are
-- delivered asynchronously by open as E_BACKEND_INIT; only missing injected runtime
-- dependencies remain programmer errors that may throw.
-- Verification items: every case constructs without throwing, open fails once with
-- E_BACKEND_INIT, and no process, timer, or temporary directory is created.
test.it("rejects malformed Codex options before acquiring runtime resources", function()
  local cases = {
    { command = "codex app-server" },
    { command = {} },
    { command = { [2] = "codex" } },
    { command = { "codex", "" } },
    { model = "" },
    { reasoning_effort = 1 },
    { require_ephemeral = "yes" },
    { strict_isolation = "yes" },
    { reject_external_instruction_sources = "yes" },
    { experimental_api = "yes" },
    { request_timeout_ms = 0 },
    { request_timeout_ms = 1.5 },
    { shutdown_timeout_ms = -1 },
    { shutdown_timeout_ms = 0.5 },
    { strict_isolation = true, experimental_api = false },
  }

  for _, options in ipairs(cases) do
    local constructed, context = pcall(harness, options)
    test.eq(true, constructed)
    local opened, open_error, callbacks
    context.backend:open(function(ok, err)
      opened = ok
      open_error = err
      callbacks = (callbacks or 0) + 1
    end)
    context.flush()

    test.eq(nil, opened)
    test.eq("E_BACKEND_INIT", open_error.code)
    test.eq(1, callbacks)
    test.eq(nil, context.server.command)
    test.eq(0, #context.timers)
    test.eq(0, context.runtime_calls.tempdir)
  end
end)

local function open_ready(context)
  local opened, open_error
  context.backend:open(function(ok, err)
    opened, open_error = ok, err
  end)
  context.flush()
  local initialize = assert(context.server:take("initialize"))
  context.server:respond(
    initialize,
    { serverInfo = { name = "codex", version = "test" } },
    nil,
    { 3, 5 }
  )
  context.flush()
  assert(context.server:take("initialized"))
  local models = assert(context.server:take("model/list"))
  context.server:respond(models, {
    data = {
      {
        id = "model-id",
        model = "test-model",
        isDefault = true,
        hidden = false,
        inputModalities = { "text" },
        defaultReasoningEffort = "medium",
      },
    },
    nextCursor = json.null,
  })
  context.flush()
  assert(opened, open_error and open_error.message)
  return initialize
end

local function request_payload()
  return {
    request_id = "request:1",
    system_instructions = "SAFE SYSTEM INSTRUCTION",
    user_content = "SECRET DOCUMENT PAYLOAD",
    response_schema = { type = "object" },
    timeout_ms = 120,
    metadata = { codec_id = "test_codec" },
  }
end

local function start_turn(context, callbacks)
  local handle = context.backend:request(request_payload(), callbacks)
  local thread_start = assert(context.server:take("thread/start"))
  context.server:respond(thread_start, {
    thread = { id = "thread:1", ephemeral = true },
    instructionSources = json.array(),
  })
  context.flush()
  local turn_start = assert(context.server:take("turn/start"))
  context.server:respond(turn_start, {
    turn = { id = "turn:1", status = "inProgress", items = json.array() },
  })
  context.flush()
  return handle, thread_start, turn_start
end

-- Preconditions: A Fake app-server accepts initialize and exposes a single
-- default text model, with the first response split across arbitrary chunks.
-- Prerequisites: open owns JSON-RPC request IDs, initialized notification, and
-- model discovery. Verification items: command/cwd isolation, handshake fields,
-- agent-message delta notifications remain subscribed for latency measurement,
-- model selection, structured output without prompt Schema duplication, and one
-- deferred completion.
test.it("opens through the app-server handshake and selects a text model", function()
  local context = harness()
  local callbacks = 0
  context.backend:open(function(ok)
    if ok then
      callbacks = callbacks + 1
    end
  end)
  context.flush()
  test.eq({ "codex", "app-server" }, context.server.command)
  test.eq("/tmp/bilingua-isolated-test", context.server.options.cwd)
  local initialize = assert(context.server:take("initialize"))
  test.eq("bilingua_nvim", initialize.params.clientInfo.name)
  test.eq(true, initialize.params.capabilities.experimentalApi)
  test.eq(nil, initialize.params.capabilities.optOutNotificationMethods)
  context.server:respond(initialize, { serverInfo = {} }, nil, { 1, 2, 4 })
  context.flush()
  test.eq("initialized", assert(context.server:take("initialized")).method)
  local model_list = assert(context.server:take("model/list"))
  context.server:respond(model_list, {
    data = {
      {
        id = "default-id",
        model = "default-model",
        isDefault = true,
        hidden = false,
        inputModalities = { "text" },
        defaultReasoningEffort = "high",
      },
    },
    nextCursor = json.null,
  })
  context.flush()

  test.eq(1, callbacks)
  test.eq("default-model", context.backend:selected_model())
  test.eq(true, context.backend:capabilities().structured_output)
  test.eq(false, context.backend:capabilities().schema_in_prompt)
  test.eq(true, context.backend:capabilities().ephemeral_sessions)
end)

-- Preconditions: The backend is ready and a normalized request contains secret
-- document data only in user_content. Prerequisites: Each task must create an
-- ephemeral thread and validate instructionSources before turn/start.
-- Verification items: thread/start contains no payload, selects a unique
-- permission profile that grants read access only to the isolated workspace,
-- disables network and environment access, and only final item text completes.
test.it("runs each request in an isolated ephemeral thread", function()
  local context = harness()
  open_ready(context)
  local completions = {}
  local handle = context.backend:request(request_payload(), {
    on_complete = function(value)
      completions[#completions + 1] = value
    end,
    on_error = function(err)
      error(err.message)
    end,
  })
  local thread_start = assert(context.server:take("thread/start"))
  test.eq(true, thread_start.params.ephemeral)
  test.eq("never", thread_start.params.approvalPolicy)
  test.eq(nil, thread_start.params.sandbox)
  test.eq("/tmp/bilingua-isolated-test", thread_start.params.runtimeWorkspaceRoots[1])
  test.eq(true, json.is_array(thread_start.params.environments))
  test.eq(0, #thread_start.params.environments)
  test.eq("bilingua_nvim_isolated_bilingua_isolated_test", thread_start.params.permissions)
  local profile =
    assert(thread_start.params.config["permissions." .. thread_start.params.permissions])
  test.eq("read", profile.filesystem[":workspace_roots"]["."])
  test.eq(false, profile.network.enabled)
  test.eq("SAFE SYSTEM INSTRUCTION", thread_start.params.developerInstructions)
  test.eq(nil, json.encode(thread_start):find("SECRET DOCUMENT PAYLOAD", 1, true))
  context.server:respond(thread_start, {
    thread = { id = "thread:1", ephemeral = true },
    instructionSources = json.array(),
  })
  context.flush()
  local turn_start = assert(context.server:take("turn/start"))
  test.eq("SECRET DOCUMENT PAYLOAD", turn_start.params.input[1].text)
  test.eq("/tmp/bilingua-isolated-test", turn_start.params.cwd)
  test.eq(nil, turn_start.params.sandboxPolicy)
  context.server:respond(turn_start, {
    turn = { id = "turn:1", status = "inProgress", items = json.array() },
  })
  context.flush()
  context.server:notify("item/completed", {
    threadId = "thread:1",
    turnId = "turn:1",
    completedAtMs = 1,
    item = { id = "item:1", type = "agentMessage", phase = "final_answer", text = '{"ok":true}' },
  })
  context.server:notify("turn/completed", {
    threadId = "thread:1",
    turn = { id = "turn:1", status = "completed", items = json.array() },
  })
  context.flush()

  test.eq(false, handle:is_cancelled())
  test.eq(1, #completions)
  test.eq('{"ok":true}', completions[1].text)
  test.eq("test-model", completions[1].metadata.model)
end)

-- Preconditions: A ready backend starts one request at a controlled monotonic
-- time, receives two agent-message deltas, and later receives a successful
-- turn/completed notification. Prerequisites: app-server notifications may be
-- delivered in separate scheduled callbacks, and only the first agent-message
-- delta defines the first-output latency. Verification items: the successful
-- response reports elapsed milliseconds from request start to the first delta
-- and turn completion, and the backend exposes the model-selected reasoning
-- effort without retaining response text in its status API.
test.it("measures first agent delta and turn completion latency", function()
  local context = harness()
  open_ready(context)
  context.set_now_ms(100)
  local completion
  start_turn(context, {
    on_complete = function(value)
      completion = value
    end,
    on_error = function(err)
      error(err.message)
    end,
  })

  context.set_now_ms(165)
  context.server:notify("item/agentMessage/delta", {
    threadId = "thread:1",
    turnId = "turn:1",
    itemId = "item:1",
    delta = "{",
  })
  context.flush()
  context.set_now_ms(175)
  context.server:notify("item/agentMessage/delta", {
    threadId = "thread:1",
    turnId = "turn:1",
    itemId = "item:1",
    delta = '"ok":true}',
  })
  context.flush()

  context.set_now_ms(250)
  context.server:notify("item/completed", {
    threadId = "thread:1",
    turnId = "turn:1",
    item = {
      id = "item:1",
      type = "agentMessage",
      phase = "final_answer",
      text = '{"ok":true}',
    },
  })
  context.server:notify("turn/completed", {
    threadId = "thread:1",
    turn = { id = "turn:1", status = "completed", items = json.array() },
  })
  context.flush()

  test.eq("medium", context.backend:selected_reasoning_effort())
  test.eq(65, completion.metadata.first_agent_message_delta_ms)
  test.eq(150, completion.metadata.turn_completed_ms)
end)

-- Preconditions: A caller explicitly disables strict isolation and the
-- experimental API. Prerequisites: This compatibility path must use only stable
-- app-server fields. Verification items: thread/start selects the standard
-- read-only sandbox, turn/start disables network, and neither request contains a
-- permission profile or the removed readOnly.access field.
test.it("uses the stable read-only fallback outside strict isolation", function()
  local context = harness({ strict_isolation = false, experimental_api = false })
  local initialize = open_ready(context)
  test.eq(false, initialize.params.capabilities.experimentalApi)

  local _, thread_start, turn_start = start_turn(context, {
    on_complete = function() end,
    on_error = function(err)
      error(err.message)
    end,
  })
  test.eq("read-only", thread_start.params.sandbox)
  test.eq(nil, thread_start.params.permissions)
  test.eq(nil, thread_start.params.runtimeWorkspaceRoots)
  test.eq(nil, thread_start.params.environments)
  test.eq(nil, thread_start.params.config)
  test.eq("readOnly", turn_start.params.sandboxPolicy.type)
  test.eq(false, turn_start.params.sandboxPolicy.networkAccess)
  test.eq(nil, turn_start.params.sandboxPolicy.access)
end)

-- Preconditions: The app-server reports one user-owned global instruction file
-- together with an instruction file inside the isolated cwd, then reports a
-- different file below the global file's parent directory in a second request.
-- Prerequisites: allowed_instruction_sources names individual canonical files;
-- it does not grant trust to their parent directories. Verification items: the
-- exact configured file reaches turn/start, while the sibling path is rejected
-- before the secret document payload is sent.
test.it("allows only explicitly configured instruction source files", function()
  local allowed_source = "/home/test/.codex/AGENTS.md"
  local context = harness({ allowed_instruction_sources = { allowed_source } })
  open_ready(context)
  context.backend:request(request_payload(), {
    on_complete = function() end,
    on_error = function(err)
      error(err.message)
    end,
  })
  local thread_start = assert(context.server:take("thread/start"))
  context.server:respond(thread_start, {
    thread = { id = "thread:allowed", ephemeral = true },
    instructionSources = {
      allowed_source,
      "/tmp/bilingua-isolated-test/AGENTS.md",
    },
  })
  context.flush()
  local turn_start = assert(context.server:take("turn/start"))
  test.eq("SECRET DOCUMENT PAYLOAD", turn_start.params.input[1].text)

  local blocked = harness({ allowed_instruction_sources = { allowed_source } })
  open_ready(blocked)
  local received_error
  blocked.backend:request(request_payload(), {
    on_complete = function()
      error("unexpected completion")
    end,
    on_error = function(err)
      received_error = err
    end,
  })
  local blocked_thread = assert(blocked.server:take("thread/start"))
  blocked.server:respond(blocked_thread, {
    thread = { id = "thread:blocked", ephemeral = true },
    instructionSources = { "/home/test/.codex/nested/AGENTS.md" },
  })
  blocked.flush()
  test.eq("E_BACKEND_INSTRUCTION_SOURCE", received_error.code)
  test.eq(nil, blocked.server:take("turn/start"))
end)

-- Preconditions: Two thread/start responses are unsafe: one is non-ephemeral and
-- one reports an instruction source outside the isolated directory.
-- Prerequisites: Neither response has yet received document user_content.
-- Verification items: requests fail with the specific security codes and no
-- emitted turn/start or prior outbound message contains the secret payload.
test.it("rejects unsafe threads before sending document content", function()
  local cases = {
    {
      response = {
        thread = { id = "thread:bad", ephemeral = false },
        instructionSources = json.array(),
      },
      code = "E_EPHEMERAL_REQUIRED",
    },
    {
      response = {
        thread = { id = "thread:bad", ephemeral = true },
        instructionSources = { "/outside/AGENTS.md" },
      },
      code = "E_BACKEND_INSTRUCTION_SOURCE",
    },
  }
  for _, case in ipairs(cases) do
    local context = harness()
    open_ready(context)
    local received_error
    context.backend:request(request_payload(), {
      on_complete = function()
        error("unexpected completion")
      end,
      on_error = function(err)
        received_error = err
      end,
    })
    local thread_start = assert(context.server:take("thread/start"))
    context.server:respond(thread_start, case.response)
    context.flush()
    test.eq(case.code, received_error.code)
    test.eq(nil, context.server:take("turn/start"))
    for _, message in ipairs(context.server.outbound) do
      test.eq(nil, json.encode(message):find("SECRET DOCUMENT PAYLOAD", 1, true))
    end
  end
end)

-- Preconditions: A running translation elicits command approval, and unrelated
-- permission/MCP/user-input requests follow. Prerequisites: The backend never asks
-- the user and treats external-action items as protocol violations.
-- Verification items: approval is declined, the turn is interrupted with
-- E_BACKEND_TOOL_ATTEMPT, and every supported server request receives a bounded
-- deny/empty response instead of being ignored.
test.it("declines server requests and aborts prohibited tool attempts", function()
  local context = harness()
  open_ready(context)
  local received_error
  start_turn(context, {
    on_complete = function()
      error("unexpected completion")
    end,
    on_error = function(err)
      received_error = err
    end,
  })
  context.server:request(80, "item/commandExecution/requestApproval", {
    threadId = "thread:1",
    turnId = "turn:1",
  })
  context.server:request(81, "item/permissions/requestApproval", {})
  context.server:request(82, "mcpServer/elicitation/request", {})
  context.server:request(83, "item/tool/requestUserInput", {
    questions = { { id = "question:1", question = "Run it?", options = json.array() } },
  })
  context.flush()

  local approval
  local permission
  local elicitation
  local user_input
  for _, message in ipairs(context.server.outbound) do
    if message.id == 80 then
      approval = message
    end
    if message.id == 81 then
      permission = message
    end
    if message.id == 82 then
      elicitation = message
    end
    if message.id == 83 then
      user_input = message
    end
  end
  test.eq("decline", approval.result.decision)
  test.eq("turn", permission.result.scope)
  test.eq("decline", elicitation.result.action)
  test.eq(0, #user_input.result.answers["question:1"].answers)
  test.eq("E_BACKEND_TOOL_ATTEMPT", received_error.code)
  test.eq("turn/interrupt", assert(context.server:take("turn/interrupt")).method)
end)

-- Preconditions: One running turn is cancelled twice, another running turn reaches
-- its deadline, and late completion notifications arrive. Prerequisites: Local
-- cancellation is immediate and timeout timers are injected deterministically.
-- Verification items: each turn is interrupted once, cancel emits no terminal
-- callback, timeout emits E_BACKEND_TIMEOUT once, and late results are ignored.
test.it("cancels idempotently and normalizes turn timeouts", function()
  local context = harness()
  open_ready(context)
  local cancelled_callbacks = 0
  local handle = start_turn(context, {
    on_complete = function()
      cancelled_callbacks = cancelled_callbacks + 1
    end,
    on_error = function()
      cancelled_callbacks = cancelled_callbacks + 1
    end,
  })
  handle:cancel()
  handle:cancel()
  test.eq(true, handle:is_cancelled())
  test.eq("turn/interrupt", assert(context.server:take("turn/interrupt")).method)
  context.server:notify("turn/completed", {
    threadId = "thread:1",
    turn = { id = "turn:1", status = "completed", items = json.array() },
  })
  context.flush()
  test.eq(0, cancelled_callbacks)

  local timeout_context = harness()
  open_ready(timeout_context)
  local timeout_error
  start_turn(timeout_context, {
    on_complete = function()
      error("unexpected completion")
    end,
    on_error = function(err)
      timeout_error = err
    end,
  })
  local turn_timer
  for _, timer in ipairs(timeout_context.timers) do
    if timer.milliseconds == 120 and not timer.cancelled then
      turn_timer = timer
    end
  end
  assert(turn_timer):fire()
  timeout_context.flush()
  test.eq("E_BACKEND_TIMEOUT", timeout_error.code)
  test.eq("turn/interrupt", assert(timeout_context.server:take("turn/interrupt")).method)
end)

-- Preconditions: A ready backend has one active turn when close begins and its
-- process does not exit before the shutdown deadline. Prerequisites: close must
-- release in-memory/process/temp resources without persisting payloads.
-- Verification items: the active callback receives E_SESSION_CLOSED once, stdin
-- closes, the process is killed after the timer, the isolated directory is
-- removed, and subsequent requests are rejected.
test.it("closes active work and removes the isolated directory", function()
  local context = harness()
  open_ready(context)
  local errors_seen = {}
  start_turn(context, {
    on_complete = function()
      error("unexpected completion")
    end,
    on_error = function(err)
      errors_seen[#errors_seen + 1] = err.code
    end,
  })
  local closed = false
  context.backend:close(function(ok)
    closed = ok
  end)
  context.flush()
  test.eq("E_SESSION_CLOSED", errors_seen[1])
  test.eq(true, context.server.stdin_closed)
  test.eq(false, closed)
  local shutdown_timer
  for _, timer in ipairs(context.timers) do
    if timer.milliseconds == 5 and not timer.cancelled then
      shutdown_timer = timer
    end
  end
  assert(shutdown_timer):fire()
  context.flush()
  test.eq(1, context.server.killed)
  test.eq(true, closed)
  test.eq("/tmp/bilingua-isolated-test", context.removed[1])

  local rejected
  context.backend:request(request_payload(), {
    on_complete = function()
      error("unexpected completion")
    end,
    on_error = function(err)
      rejected = err.code
    end,
  })
  context.flush()
  test.eq("E_SESSION_CLOSED", rejected)
end)

-- Preconditions: The spawned app-server rejects initialize with an authentication
-- RPC error after the isolated cwd has been created. Prerequisites: An open
-- failure owns every resource acquired before the handshake settles and must not
-- wait for an explicit close. Verification items: open reports E_BACKEND_AUTH
-- exactly once, kills the child, removes the isolated directory, and ignores a
-- later process-exit callback.
test.it("cleans acquired resources when initialization fails", function()
  local context = harness()
  local callbacks = 0
  local received_error
  context.backend:open(function(ok, err)
    test.eq(nil, ok)
    callbacks = callbacks + 1
    received_error = err
  end)
  context.flush()
  local initialize = assert(context.server:take("initialize"))

  context.server:respond(initialize, nil, {
    code = -32001,
    message = "authentication required",
  })
  context.flush()

  test.eq(1, callbacks)
  test.eq("E_BACKEND_AUTH", received_error.code)
  test.eq("failed", context.backend.state)
  test.eq(1, context.server.killed)
  test.eq("/tmp/bilingua-isolated-test", context.removed[1])

  context.server:exit(1)
  context.flush()
  test.eq(1, callbacks)
  test.eq(1, context.server.killed)
  test.eq(1, #context.removed)
end)

-- Preconditions: Two concurrent requests contain distinct UTF-8 payloads, and
-- the fake server returns each pair of RPC responses plus all completion
-- notifications as multi-line single chunks in reverse request order.
-- Prerequisites: JSONL framing is independent of chunk boundaries and request,
-- thread, and turn IDs—not arrival order—own correlation. Verification items:
-- each turn receives its exact payload and each caller receives its own UTF-8
-- final answer exactly once despite reversed responses and notifications.
test.it("correlates out-of-order UTF-8 messages from multi-record chunks", function()
  local context = harness()
  open_ready(context)
  local completed = {}
  local callback_counts = { first = 0, second = 0 }

  local function submit(key, request_id, content)
    local payload = request_payload()
    payload.request_id = request_id
    payload.user_content = content
    context.backend:request(payload, {
      on_complete = function(value)
        callback_counts[key] = callback_counts[key] + 1
        completed[key] = value.text
      end,
      on_error = function(err)
        error(err.message)
      end,
    })
  end

  submit("first", "request:一", "原文一🙂")
  submit("second", "request:二", "原文二界")
  local first_thread = assert(context.server:take("thread/start"))
  local second_thread = assert(context.server:take("thread/start"))
  context.server:emit_raw(table.concat({
    json.encode({
      id = second_thread.id,
      result = {
        thread = { id = "thread:二", ephemeral = true },
        instructionSources = json.array(),
      },
    }),
    json.encode({
      id = first_thread.id,
      result = {
        thread = { id = "thread:一", ephemeral = true },
        instructionSources = json.array(),
      },
    }),
    "",
  }, "\n"))
  context.flush()

  local turns = {}
  for _ = 1, 2 do
    local turn = assert(context.server:take("turn/start"))
    turns[turn.params.threadId] = turn
  end
  test.eq("原文一🙂", turns["thread:一"].params.input[1].text)
  test.eq("原文二界", turns["thread:二"].params.input[1].text)
  context.server:emit_raw(table.concat({
    json.encode({
      id = turns["thread:一"].id,
      result = { turn = { id = "turn:一", status = "inProgress", items = json.array() } },
    }),
    json.encode({
      id = turns["thread:二"].id,
      result = { turn = { id = "turn:二", status = "inProgress", items = json.array() } },
    }),
    "",
  }, "\n"))
  context.flush()

  local function item(thread_id, turn_id, text)
    return {
      method = "item/completed",
      params = {
        threadId = thread_id,
        turnId = turn_id,
        item = {
          id = "item:" .. turn_id,
          type = "agentMessage",
          phase = "final_answer",
          text = text,
        },
      },
    }
  end
  local function completed_turn(thread_id, turn_id)
    return {
      method = "turn/completed",
      params = {
        threadId = thread_id,
        turn = { id = turn_id, status = "completed", items = json.array() },
      },
    }
  end
  context.server:emit_raw(table.concat({
    json.encode(item("thread:二", "turn:二", '{"訳":"二界"}')),
    json.encode(completed_turn("thread:二", "turn:二")),
    json.encode(item("thread:一", "turn:一", '{"訳":"一🙂"}')),
    json.encode(completed_turn("thread:一", "turn:一")),
    "",
  }, "\n"))
  context.flush()

  test.eq('{"訳":"一🙂"}', completed.first)
  test.eq('{"訳":"二界"}', completed.second)
  test.eq(1, callback_counts.first)
  test.eq(1, callback_counts.second)
end)

-- Preconditions: A ready backend is waiting for thread/start when stdout emits a
-- newline-terminated malformed JSON record. Prerequisites: Invalid JSONL is a
-- connection-level protocol failure and all owned pending work must settle once.
-- Verification items: the request receives E_BACKEND_PROTOCOL exactly once, the
-- child is killed, and the isolated directory is removed.
test.it("fails pending work and cleans resources on malformed JSON", function()
  local context = harness()
  open_ready(context)
  local errors_seen = {}
  context.backend:request(request_payload(), {
    on_complete = function()
      error("unexpected completion")
    end,
    on_error = function(err)
      errors_seen[#errors_seen + 1] = err.code
    end,
  })
  assert(context.server:take("thread/start"))

  context.server:emit_raw('{"id":\n')
  context.flush()

  test.eq({ "E_BACKEND_PROTOCOL" }, errors_seen)
  test.eq("failed", context.backend.state)
  test.eq(1, context.server.killed)
  test.eq({ "/tmp/bilingua-isolated-test" }, context.removed)
end)

-- Preconditions: One active turn reports status failed; another active backend
-- process exits with code 17. Prerequisites: Provider turn failure and transport
-- loss are different error categories, and late terminal signals cannot complete
-- an already settled request. Verification items: callbacks receive respectively
-- E_TRANSLATION and retryable E_BACKEND_UNAVAILABLE exactly once, while a crash
-- also removes the isolated directory.
test.it("normalizes failed turns and process crashes exactly once", function()
  local failed_context = harness()
  open_ready(failed_context)
  local failed_errors = {}
  start_turn(failed_context, {
    on_complete = function()
      error("unexpected completion")
    end,
    on_error = function(err)
      failed_errors[#failed_errors + 1] = err
    end,
  })
  failed_context.server:notify("turn/completed", {
    threadId = "thread:1",
    turn = { id = "turn:1", status = "failed", items = json.array() },
  })
  failed_context.flush()
  test.eq(1, #failed_errors)
  test.eq("E_TRANSLATION", failed_errors[1].code)

  local crash_context = harness()
  open_ready(crash_context)
  local crash_errors = {}
  start_turn(crash_context, {
    on_complete = function()
      error("unexpected completion")
    end,
    on_error = function(err)
      crash_errors[#crash_errors + 1] = err
    end,
  })
  crash_context.server:exit(17)
  crash_context.flush()

  test.eq(1, #crash_errors)
  test.eq("E_BACKEND_UNAVAILABLE", crash_errors[1].code)
  test.eq(true, crash_errors[1].retryable)
  test.eq("failed", crash_context.backend.state)
  test.eq({ "/tmp/bilingua-isolated-test" }, crash_context.removed)

  crash_context.server:notify("turn/completed", {
    threadId = "thread:1",
    turn = { id = "turn:1", status = "completed", items = json.array() },
  })
  crash_context.flush()
  test.eq(1, #crash_errors)
end)
