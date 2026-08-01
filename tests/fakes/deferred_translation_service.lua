local Service = {}
Service.__index = Service

function Service.new(responder, should_defer)
  return setmetatable({
    api_version = 1,
    responder = responder,
    should_defer = should_defer,
    state = "closed",
    submitted = {},
    pending = {},
  }, Service)
end

function Service:capabilities()
  return { cancellation = true, parallel_requests = true }
end

function Service:open(callback)
  self.state = "open"
  callback(true)
end

function Service:submit(task, callbacks)
  self.submitted[#self.submitted + 1] = task
  local handle = { cancelled = false }
  function handle:cancel()
    self.cancelled = true
  end
  function handle:is_cancelled()
    return self.cancelled
  end

  local result, err = self.responder(task)
  if self.should_defer(task) then
    self.pending[#self.pending + 1] = {
      callbacks = callbacks,
      result = result,
      error = err,
      handle = handle,
    }
  elseif err then
    callbacks.on_error(err)
  else
    callbacks.on_complete(result)
  end
  return handle
end

function Service:complete_next()
  local pending = table.remove(self.pending, 1)
  assert(pending, "no deferred translation is pending")
  if pending.error then
    pending.callbacks.on_error(pending.error)
  else
    pending.callbacks.on_complete(pending.result)
  end
end

function Service:complete_task(task_id)
  for index, pending in ipairs(self.pending) do
    local pending_task_id = pending.result and pending.result.task_id
    if pending_task_id == task_id then
      table.remove(self.pending, index)
      if pending.error then
        pending.callbacks.on_error(pending.error)
      else
        pending.callbacks.on_complete(pending.result)
      end
      return
    end
  end
  error(("no deferred translation is pending for %s"):format(task_id), 2)
end

function Service:close(callback)
  self.state = "closed"
  if callback then
    callback(true)
  end
end

return {
  new = Service.new,
}
