local test = require("tests.testlib")
local task_queue = require("bilingua.app.task_queue")

-- Preconditions: A queue has one active operation and therefore is not idle.
-- Prerequisites: normal Session shutdown must wait without polling until every
-- accepted operation has settled. Verification items: an idle observer is not
-- called while work is active, is called exactly once after completion, and an
-- observer registered on an already idle queue is delivered immediately.
test.it("notifies observers only after all queued work becomes idle", function()
  local queue = task_queue.new({ max_concurrency = 1 })
  local finish
  assert(queue:enqueue({
    key = "group:1",
    run = function(done)
      finish = done
      return { cancel = function() end }
    end,
  }))

  local notifications = 0
  queue:when_idle(function()
    notifications = notifications + 1
  end)
  test.eq(0, notifications)

  finish()
  test.eq(1, notifications)
  finish()
  test.eq(1, notifications)

  queue:when_idle(function()
    notifications = notifications + 1
  end)
  test.eq(2, notifications)
end)
