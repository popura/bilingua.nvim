local test = require("tests.testlib")
local errors = require("bilingua.domain.error")
local coordinator_module = require("bilingua.app.coordinator")
local session_registry = require("bilingua.session_registry")

local function environment(buffer_overrides)
  local emitted = {}
  local closed = {}
  local notifications = {}
  local info = {
    valid = true,
    loaded = true,
    buftype = "",
    modifiable = true,
    binary = false,
    filetype = "text",
    path = "/tmp/source.txt",
  }
  for key, value in pairs(buffer_overrides or {}) do
    info[key] = value
  end
  return {
    emitted = emitted,
    closed = closed,
    notifications = notifications,
    current_buffer = function()
      return 7
    end,
    current_window = function()
      return 70
    end,
    inspect_buffer = function()
      return info
    end,
    emit = function(event, data)
      emitted[#emitted + 1] = { event = event, data = data }
    end,
    now_ms = function()
      return 1000
    end,
    notify_error = function(error_code)
      notifications[#notifications + 1] = error_code
    end,
    close_buffer = function(buffer, force)
      closed[#closed + 1] = { buffer = buffer, force = force }
      return true
    end,
  }
end

local function fake_session_factory()
  local factory = { created = {} }
  function factory:create(context, config)
    local session = {
      id = "session:" .. tostring(#self.created + 1),
      source_buf = context.source_buf,
      target_buf = nil,
      editor = { target_buf = 17 },
      state = "new",
      calls = {},
      config = config,
    }
    function session:start(callback)
      self.state = "ready"
      self.target_buf = self.editor.target_buf
      callback(true)
    end
    function session:status_snapshot()
      return {
        session_id = self.id,
        state = self.state,
        source_buf = self.source_buf,
        target_buf = self.target_buf,
        groups = { clean = 1 },
      }
    end
    function session:toggle(buffer)
      self.calls[#self.calls + 1] = { method = "toggle", buffer = buffer }
      return true
    end
    function session:stop(options, callback)
      self.calls[#self.calls + 1] = { method = "stop", force = options.force }
      self.state = "stopped"
      callback(true)
      return true
    end
    self.created[#self.created + 1] = session
    return session
  end
  return factory
end

local function coordinator(environment_override)
  local factory = fake_session_factory()
  local sessions = session_registry.new()
  local active = coordinator_module.new({
    session_factory = factory,
    sessions = sessions,
    environment = environment_override or environment(),
    resolve_config = function(options)
      return {
        source_language = options.source_language or "auto",
        target_language = "ja",
        ui = { notify_backend = true },
      }
    end,
  })
  return active, factory, sessions
end

-- Preconditions: The current buffer is a loaded, modifiable normal text buffer.
-- Prerequisites: SessionFactory completion is synchronous in this fake but the
-- Coordinator API must also support asynchronous completion. Verification items:
-- both buffers are registered only after success, the callback receives a status
-- snapshot rather than the Session, toggle delegates by current buffer, and stop
-- removes both indexes while emitting content-free lifecycle events.
test.it("owns public Session lifecycle without exposing the Session object", function()
  local host = environment()
  local active, factory, sessions = coordinator(host)
  local completed
  local accepted, start_error = active:start({ source_language = "fr" }, function(status, err)
    test.eq(nil, err)
    completed = status
  end)

  test.eq(true, accepted)
  test.eq(nil, start_error)
  test.eq("fr", factory.created[1].config.source_language)
  test.eq("session:1", completed.session_id)
  test.eq(nil, completed.editor)
  test.eq(factory.created[1], sessions:for_buffer(7))
  test.eq(factory.created[1], sessions:for_buffer(17))
  test.eq("BilinguaSessionStarted", host.emitted[1].event)
  test.eq(nil, host.emitted[1].data.text)

  test.eq(true, active:toggle())
  test.eq({ method = "toggle", buffer = 7 }, factory.created[1].calls[1])

  local stopped, stop_error = active:stop({ force = false })
  test.eq(true, stopped)
  test.eq(nil, stop_error)
  test.eq(nil, sessions:for_buffer(7))
  test.eq(nil, sessions:for_buffer(17))
  test.eq("BilinguaSessionStopped", host.emitted[2].event)
end)

-- Preconditions: A ready Session owns the source and target buffers for each of
-- the normal and force quit paths. Prerequisites: source closure may occur only
-- after Session.stop completes and the two registry indexes have been released.
-- Verification items: each path forwards its force flag to stop and close_buffer,
-- closes the source exactly once, unregisters both buffers, and completes its callback.
test.it("closes the source only after normal or force Session shutdown", function()
  for _, force in ipairs({ false, true }) do
    local host = environment()
    local active, factory, sessions = coordinator(host)
    assert(active:start())

    local completed
    local quit, quit_error = active:quit({ force = force }, function(ok, err)
      test.eq(nil, err)
      completed = ok
    end)

    test.eq(true, quit)
    test.eq(nil, quit_error)
    test.eq({ method = "stop", force = force }, factory.created[1].calls[1])
    test.eq({ buffer = 7, force = force }, host.closed[1])
    test.eq(1, #host.closed)
    test.eq(nil, sessions:for_buffer(7))
    test.eq(nil, sessions:for_buffer(17))
    test.eq(true, completed)
  end
end)

-- Preconditions: The current buffer is either a special nofile buffer or an
-- unnamed normal buffer without a backing file path. Prerequisites: MVP sources
-- must be currently opened real-file buffers, and validation occurs before any
-- component or target creation. Verification items: both cases return
-- E_INVALID_SOURCE_BUFFER without constructing a Session or emitting an event.
test.it("rejects an ineligible source buffer before Session construction", function()
  for _, overrides in ipairs({ { buftype = "nofile" }, { path = "" } }) do
    local host = environment(overrides)
    local active, factory = coordinator(host)

    local accepted, start_error = active:start()
    test.eq(nil, accepted)
    test.eq("E_INVALID_SOURCE_BUFFER", start_error.code)
    test.eq(0, #factory.created)
    test.eq(0, #host.emitted)
  end
end)

-- Preconditions: One Session already owns the current source buffer.
-- Prerequisites: ordinary start must preserve it, while force start must first
-- stop and unregister it. Verification items: duplicate start returns a state
-- error; force start records force=true and registers a distinct replacement.
test.it("requires force to replace an existing Session", function()
  local active, factory, sessions = coordinator()
  assert(active:start())

  local duplicate, duplicate_error = active:start()
  test.eq(nil, duplicate)
  test.eq("E_SESSION_STATE", duplicate_error.code)

  local replaced, replace_error = active:start({ force = true })
  test.eq(true, replaced)
  test.eq(nil, replace_error)
  test.eq(true, factory.created[1].calls[1].force)
  test.eq(factory.created[2], sessions:for_buffer(7))
end)
-- Preconditions: A registered Session reports a runtime synchronization error with
-- both safe identifiers and deliberately unsafe document/backend detail fields.
-- Prerequisites: Coordinator is the sole User-autocmd boundary and must rebuild, not
-- forward, the payload. Verification items: the event name and identifiers survive,
-- while text, response, and nested error data are absent from the emitted payload.
test.it("forwards only sanitized runtime event fields", function()
  local host = environment()
  local active, factory = coordinator(host)
  assert(active:start())

  test.eq("function", type(factory.created[1].on_event))
  factory.created[1].on_event("BilinguaError", {
    session_id = "spoofed-session",
    group_id = "group:1",
    task_id = "task:1",
    state = "dirty_source",
    error_code = "E_BACKEND_UNAVAILABLE",
    text = "secret document text",
    response = "secret backend response",
    error = { cause = "secret" },
  })

  local emitted = host.emitted[2]
  test.eq("BilinguaError", emitted.event)
  test.eq("session:1", emitted.data.session_id)
  test.eq("group:1", emitted.data.group_id)
  test.eq("task:1", emitted.data.task_id)
  test.eq("dirty_source", emitted.data.state)
  test.eq("E_BACKEND_UNAVAILABLE", emitted.data.error_code)
  test.eq(nil, emitted.data.text)
  test.eq(nil, emitted.data.response)
  test.eq(nil, emitted.data.error)
end)

-- Preconditions: A ready Session emits the same normalized runtime backend error
-- twice, then a different error and the first code again, within one short window.
-- Prerequisites: ui.notify_backend is enabled and notification input is limited to
-- a public error code. Verification items: the duplicate code is notified once,
-- the distinct code is notified separately, and every sanitized User event remains
-- observable even when its human-facing notification is suppressed.
test.it("deduplicates short-window runtime error notifications by code", function()
  local host = environment()
  local active, factory = coordinator(host)
  assert(active:start())

  factory.created[1].on_event("BilinguaError", {
    error_code = "E_BACKEND_UNAVAILABLE",
    text = "secret document text",
  })
  factory.created[1].on_event("BilinguaError", {
    error_code = "E_BACKEND_UNAVAILABLE",
    response = "secret backend response",
  })
  factory.created[1].on_event("BilinguaError", {
    error_code = "E_BACKEND_AUTH",
    error = { cause = "secret" },
  })
  factory.created[1].on_event("BilinguaError", {
    error_code = "E_BACKEND_UNAVAILABLE",
  })

  test.eq({ "E_BACKEND_UNAVAILABLE", "E_BACKEND_AUTH" }, host.notifications)
  test.eq(5, #host.emitted)
end)

-- Preconditions: The first Session created for a valid source buffer fails during
-- backend startup and has already released its owned resources. Prerequisites: retry
-- must retain only detached start options, construct a fresh Session, and expose its
-- asynchronous completion so callers can install per-Session mappings. Verification
-- items: no failed Session is registered, retry reuses the language option, registers
-- the second Session, clears retry state, and reports the resolved configuration.
test.it("retries a failed start with a fresh Session", function()
  local host = environment()
  local sessions = session_registry.new()
  local factory = { created = {} }
  function factory:create(context, config)
    local ordinal = #self.created + 1
    local session = {
      id = "session:" .. ordinal,
      source_buf = context.source_buf,
      target_buf = ordinal == 2 and 17 or nil,
      editor = { target_buf = ordinal == 2 and 17 or nil },
      state = "new",
      config = config,
    }
    function session:start(callback)
      if ordinal == 1 then
        self.state = "failed"
        callback(nil, errors.new(errors.codes.BACKEND_INIT, "backend failed to open", true))
      else
        self.state = "ready"
        callback(true)
      end
    end
    function session:status_snapshot()
      return {
        session_id = self.id,
        state = self.state,
        source_buf = self.source_buf,
        target_buf = self.target_buf,
        groups = { clean = 1 },
      }
    end
    function session:stop(_, callback)
      self.state = "stopped"
      if callback then
        callback(true)
      end
      return true
    end
    self.created[#self.created + 1] = session
    return session
  end
  local active = coordinator_module.new({
    session_factory = factory,
    sessions = sessions,
    environment = host,
    resolve_config = function(options)
      return {
        source_language = options.source_language or "auto",
        target_language = "ja",
      }
    end,
  })

  local started, start_error = active:start({ source_language = "fr" })
  test.eq(nil, started)
  test.eq("E_BACKEND_INIT", start_error.code)
  test.eq(nil, sessions:for_buffer(7))

  local completion
  local completion_config
  local retried, retry_error = active:retry_current(function(status, err, config)
    test.eq(nil, err)
    completion = status
    completion_config = config
  end)

  test.eq(true, retried)
  test.eq(nil, retry_error)
  test.eq(2, #factory.created)
  test.eq("fr", factory.created[2].config.source_language)
  test.eq("session:2", completion.session_id)
  test.eq("fr", completion_config.source_language)
  test.eq(factory.created[2], sessions:for_buffer(7))
  test.eq(factory.created[2], sessions:for_buffer(17))
  test.eq(nil, active.failed_starts[7])
end)
