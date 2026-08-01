local test = require("tests.testlib")
local coordinator_module = require("bilingua.app.coordinator")
local session_registry = require("bilingua.session_registry")

-- Preconditions: Coordinator has registered a successfully started Session under
-- both source and target buffers. Prerequisites: an autonomous Session disposal
-- cannot return through Coordinator:stop(), so SessionFactory wiring must provide
-- a lifecycle callback. Verification items: invoking it removes both indexes,
-- emits one content-free stopped event, and duplicate notification is idempotent.
test.it("unregisters an autonomously disposed Session exactly once", function()
  local emitted = {}
  local host = {
    current_buffer = function()
      return 7
    end,
    current_window = function()
      return 70
    end,
    inspect_buffer = function()
      return {
        valid = true,
        loaded = true,
        buftype = "",
        modifiable = true,
        binary = false,
        filetype = "text",
        path = "/tmp/source.txt",
      }
    end,
    emit = function(event, data)
      emitted[#emitted + 1] = { event = event, data = data }
    end,
    close_buffer = function()
      return true
    end,
  }
  local created
  local factory = {}
  function factory:create(context)
    created = {
      id = "session:auto-dispose",
      source_buf = context.source_buf,
      target_buf = 17,
      editor = { target_buf = 17 },
      state = "new",
    }
    function created:start(callback)
      self.state = "ready"
      callback(true)
    end
    function created:status_snapshot()
      return {
        session_id = self.id,
        state = self.state,
        source_buf = self.source_buf,
        target_buf = self.target_buf,
        groups = { clean = 1 },
      }
    end
    function created:stop(_, callback)
      self.state = "stopped"
      callback(true)
      return true
    end
    return created
  end
  local sessions = session_registry.new()
  local active = coordinator_module.new({
    session_factory = factory,
    sessions = sessions,
    environment = host,
    resolve_config = function()
      return { source_language = "auto", target_language = "ja" }
    end,
  })
  assert(active:start())
  test.eq(created, sessions:for_buffer(7))
  test.eq(created, sessions:for_buffer(17))

  created.state = "stopped"
  created.on_auto_dispose(created, "target")
  created.on_auto_dispose(created, "target")

  test.eq(nil, sessions:for_buffer(7))
  test.eq(nil, sessions:for_buffer(17))
  test.eq(2, #emitted)
  test.eq("BilinguaSessionStarted", emitted[1].event)
  test.eq("BilinguaSessionStopped", emitted[2].event)
  test.eq(nil, emitted[2].data.text)
end)
