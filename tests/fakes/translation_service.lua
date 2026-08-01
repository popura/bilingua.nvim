local Service = {}
Service.__index = Service

function Service.new(responder)
  return setmetatable({
    api_version = 1,
    responder = responder,
    state = "closed",
    submitted = {},
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
  local cancelled = false
  local result, err = self.responder(task)
  if err then
    callbacks.on_error(err)
  else
    callbacks.on_complete(result)
  end
  return {
    cancel = function()
      cancelled = true
    end,
    is_cancelled = function()
      return cancelled
    end,
  }
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
