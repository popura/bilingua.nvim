local test = require("tests.testlib")
local task_queue = require("bilingua.app.task_queue")

local function operation(name, started, handles)
  local item = { key = name, priority = 0 }
  item.run = function(done)
    started[#started + 1] = name
    local handle = { cancelled = false, done = done }
    function handle:cancel()
      self.cancelled = true
    end
    handles[name] = handle
    return handle
  end
  return item
end

-- Preconditions: Three distinct groups are queued with a maximum concurrency of
-- two. Prerequisites: task completion may occur out of submission order and pump
-- must fill only the released slot. Verification items: only two operations start
-- initially, completing the second starts the third, and active count never
-- exceeds the configured maximum.
test.it("limits active work and pumps the next distinct group", function()
  local started, handles = {}, {}
  local queue = task_queue.new({ max_concurrency = 2 })

  assert(queue:enqueue(operation("g1", started, handles)))
  assert(queue:enqueue(operation("g2", started, handles)))
  assert(queue:enqueue(operation("g3", started, handles)))
  test.eq({ "g1", "g2" }, started)
  test.eq(2, queue:status().active)
  test.eq(1, queue:status().pending)

  handles.g2.done()
  test.eq({ "g1", "g2", "g3" }, started)
  test.eq(2, queue:status().active)
  test.eq(0, queue:status().pending)
end)

-- Preconditions: One active group occupies the only slot and two revisions for
-- the same waiting group are enqueued. Prerequisites: a waiting key represents
-- only its latest revision. Verification items: the first pending revision never
-- starts and the replacement payload runs once when the active slot is released.
test.it("replaces a waiting operation for the same group", function()
  local started, handles = {}, {}
  local queue = task_queue.new({ max_concurrency = 1 })
  assert(queue:enqueue(operation("active", started, handles)))
  assert(queue:enqueue(operation("old", started, handles)))
  local replacement = operation("new", started, handles)
  replacement.key = "old"
  assert(queue:enqueue(replacement))

  handles.active.done()
  test.eq({ "active", "new" }, started)
end)

-- Preconditions: A group is active when a newer revision for the same key is
-- enqueued. Prerequisites: cancellation is best effort, so the old done callback
-- may arrive after replacement start. Verification items: the old handle and its
-- on_cancel hook run once, replacement starts, and the late old callback cannot
-- release or otherwise disturb the replacement slot.
test.it("cancels active same-group work and ignores its late completion", function()
  local started, handles = {}, {}
  local queue = task_queue.new({ max_concurrency = 1 })
  local cancelled = 0
  local first = operation("old", started, handles)
  first.key = "group"
  first.on_cancel = function()
    cancelled = cancelled + 1
  end
  assert(queue:enqueue(first))
  local old_handle = handles.old

  local replacement = operation("new", started, handles)
  replacement.key = "group"
  assert(queue:enqueue(replacement))
  test.eq(true, old_handle.cancelled)
  test.eq(1, cancelled)
  test.eq({ "old", "new" }, started)
  test.eq(1, queue:status().active)

  old_handle.done()
  test.eq(1, queue:status().active)
  handles.new.done()
  test.eq(0, queue:status().active)
end)

-- Preconditions: An active task and a pending task exist when Session disposal
-- closes the queue. Prerequisites: closed queues reject new work and never pump
-- pending operations. Verification items: active cancellation occurs, all counts
-- reach zero, pending work never starts, and later enqueue returns E_SESSION_CLOSED.
test.it("cancels and rejects work after close", function()
  local started, handles = {}, {}
  local queue = task_queue.new({ max_concurrency = 1 })
  assert(queue:enqueue(operation("active", started, handles)))
  assert(queue:enqueue(operation("pending", started, handles)))

  test.eq(true, queue:close())
  test.eq(true, handles.active.cancelled)
  test.eq({ "active" }, started)
  test.eq(0, queue:status().active)
  test.eq(0, queue:status().pending)
  local accepted, queue_error = queue:enqueue(operation("late", started, handles))
  test.eq(nil, accepted)
  test.eq("E_SESSION_CLOSED", queue_error.code)
end)
