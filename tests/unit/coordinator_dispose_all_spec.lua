local test = require("tests.testlib")
local coordinator_module = require("bilingua.app.coordinator")
local session_registry = require("bilingua.session_registry")

local function disposable_session(id, source_buf, target_buf)
  local session = {
    id = id,
    source_buf = source_buf,
    target_buf = target_buf,
    state = "ready",
    force_calls = 0,
  }
  function session:stop(options, callback)
    if options.force then
      self.force_calls = self.force_calls + 1
    end
    self.state = "stopped"
    callback(true)
    return true
  end
  return session
end

-- Preconditions: Coordinator owns one registered Session and one Session whose
-- asynchronous start has not completed. Prerequisites: VimLeavePre cannot prompt,
-- wait for semantic synchronization, or omit a backend that is still opening.
-- Verification items: both Sessions receive one force stop, registered indexes
-- are cleared, pending ownership is removed, and each stop event is emitted once.
test.it("force-disposes registered and starting Sessions on editor exit", function()
  local emitted = {}
  local sessions = session_registry.new()
  local ready = disposable_session("session:ready", 1, 2)
  local starting = disposable_session("session:starting", 3, 4)
  starting.state = "starting_backend"
  assert(sessions:add(ready))
  local active = coordinator_module.new({
    session_factory = {},
    sessions = sessions,
    environment = {
      current_buffer = function()
        return 1
      end,
      current_window = function()
        return 1
      end,
      inspect_buffer = function()
        return {}
      end,
      emit = function(event, data)
        emitted[#emitted + 1] = { event = event, data = data }
      end,
      close_buffer = function()
        return true
      end,
    },
    resolve_config = function()
      return {}
    end,
  })
  active.pending_by_source[3] = starting

  local disposed, dispose_error = active:force_dispose_all()

  test.eq(true, disposed)
  test.eq(nil, dispose_error)
  test.eq(1, ready.force_calls)
  test.eq(1, starting.force_calls)
  test.eq(nil, sessions:for_buffer(1))
  test.eq(nil, sessions:for_buffer(2))
  test.eq(nil, active.pending_by_source[3])
  test.eq(2, #emitted)
  test.eq("BilinguaSessionStopped", emitted[1].event)
  test.eq("BilinguaSessionStopped", emitted[2].event)
end)
